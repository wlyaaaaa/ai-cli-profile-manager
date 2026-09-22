using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Server.Kestrel.Core;

namespace AiCli.GeminiBridge;

public sealed class BridgeServer : IAsyncDisposable
{
    private readonly WebApplication app;
    private readonly IModelBackend backend;
    private long lastRequestUtcTicks=DateTimeOffset.UtcNow.UtcTicks;
    private int active;
    private FailureDiagnostic? lastFailure;
    private sealed record FailureDiagnostic(string Code,string[] Hints,int ToolCount,int InputItems);
    private bool accepting=true;
    private readonly object requestAdmission=new();
    private readonly CancellationTokenSource lifetime=new();
    private Task? idleTask;
    public IReadOnlyCollection<string> Addresses=>app.Urls.ToArray();
    public BridgeServer(BridgeSettings settings,IModelBackend backend,string token,
        Func<JsonObject,JsonNode,CancellationToken,Task<bool>> validateSchema,GeminiModelSet? modelSet=null)
    {
        if(token.Length<32||token.Length>1024)throw new BridgeException("invalid_local_bearer_token",503);
        this.backend=backend;
        var models=modelSet??(settings.ModelCatalogPath is null?GeminiModelSet.Initial:GeminiModelSet.Load(settings.ModelCatalogPath));
        var builder=WebApplication.CreateSlimBuilder(new WebApplicationOptions{Args=[],ApplicationName=typeof(BridgeServer).Assembly.FullName});
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(options=>
        {
            options.AddServerHeader=false;
            options.Limits.MaxRequestBodySize=64L*1024*1024;
            options.Limits.MaxRequestLineSize=8192;
            options.Listen(IPAddress.Loopback,settings.Port,listen=>listen.Protocols=HttpProtocols.Http1);
        });
        app=builder.Build();
        var expected=Encoding.UTF8.GetBytes("Bearer "+token);
        app.Use(async (context,next)=>
        {
            var presented=Encoding.UTF8.GetBytes(context.Request.Headers.Authorization.ToString());
            if(!IPAddress.IsLoopback(context.Connection.RemoteIpAddress??IPAddress.None)||
                context.Request.Headers.ContainsKey("Origin")||!CryptographicOperations.FixedTimeEquals(expected,presented))
            {context.Response.StatusCode=401;return;}
            context.Response.Headers.CacheControl="no-store";
            await next(context).ConfigureAwait(false);
        });
        app.MapGet("/health",()=>Results.Json(new{component="aicli.gemini-responses",protocol="responses-v1",pid=Environment.ProcessId,backend=backend.Diagnostics,lastFailure=Volatile.Read(ref lastFailure)}));
        app.MapPost("/shutdown",()=>
        {
            lock(requestAdmission)
            {
                // An installation/model-set update must not cancel a user's
                // active generation. The caller can retry once work is idle.
                if(active!=0)return Results.Conflict(new{stopping=false,busy=true});
                accepting=false;app.Lifetime.StopApplication();return Results.Json(new{stopping=true});
            }
        });
        app.MapGet("/v1/models",()=>Results.Json(new{ @object="list",data=models.ExactIds.Select(id=>new{id,@object="model",owned_by="Google Antigravity"})}));
        app.MapPost("/v1/responses",async context=>
        {
            lock(requestAdmission)
            {
                if(!accepting){context.Response.StatusCode=503;return;}
                Interlocked.Increment(ref active);Interlocked.Exchange(ref lastRequestUtcTicks,DateTimeOffset.UtcNow.UtcTicks);
            }
            string? responseId=null;CodexRequest? request=null;var sequence=0;
            string? summaryId=null;var streamedSummary=new StringBuilder();
            using var writeGate=new SemaphoreSlim(1,1);
            using var operation=CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted,lifetime.Token);
            operation.CancelAfter(TimeSpan.FromSeconds(settings.TurnTimeoutSeconds+30));
            try
            {
                if(context.Request.Headers.ContentEncoding.Count!=0)throw new BridgeException("request_content_encoding_not_supported",415);
                if(context.Request.ContentType?.StartsWith("application/json",StringComparison.OrdinalIgnoreCase)!=true)
                    throw new BridgeException("json_content_type_required",415);
                JsonObject body;
                try{body=(await JsonNode.ParseAsync(context.Request.Body,cancellationToken:operation.Token).ConfigureAwait(false))?.AsObject()??throw new JsonException();}
                catch(JsonException){throw new BridgeException("invalid_request_json");}
                catch(InvalidOperationException){throw new BridgeException("invalid_request_json");}
                request=CodexRequest.Parse(body,models);responseId="resp_"+Guid.NewGuid().ToString("N");
                if(request.Stream)
                {
                    context.Response.ContentType="text/event-stream; charset=utf-8";
                    context.Response.Headers["X-Accel-Buffering"]="no";
                    await Send(new JsonObject{["type"]="response.created",["response"]=ResponsesEvents.Response(responseId,request.EffectiveModel,"in_progress",new JsonArray())}).ConfigureAwait(false);
                    await Send(new JsonObject{["type"]="response.in_progress",["response"]=ResponsesEvents.Response(responseId,request.EffectiveModel,"in_progress",new JsonArray())}).ConfigureAwait(false);
                }
                var generation=request.Stream
                    ? backend.GenerateWithSummaryAsync(request,SendSummary,operation.Token)
                    : backend.GenerateAsync(request,operation.Token);
                try
                {
                    while(request.Stream&&!generation.IsCompleted)
                    {
                        var completed=await Task.WhenAny(generation,Task.Delay(TimeSpan.FromSeconds(10),operation.Token)).ConfigureAwait(false);
                        operation.Token.ThrowIfCancellationRequested();
                        if(completed!=generation)
                        {
                            // Transport liveness only: no fabricated reasoning,
                            // tool events, progress claims or placeholder text.
                            await writeGate.WaitAsync(operation.Token).ConfigureAwait(false);
                            try
                            {
                                await context.Response.WriteAsync(": keep-alive\n\n",operation.Token).ConfigureAwait(false);
                                await context.Response.Body.FlushAsync(operation.Token).ConfigureAwait(false);
                            }
                            finally { writeGate.Release(); }
                        }
                    }
                    var (raw,usage)=await generation.ConfigureAwait(false);
                    var decision=await Decision.ValidateAsync(raw,request,validateSchema,operation.Token).ConfigureAwait(false);
                    await ValidateFinalFormatAsync(request,decision,validateSchema,operation.Token).ConfigureAwait(false);
                    var output=ResponsesEvents.Output(decision);
                    if(summaryId is not null)
                    {
                        if(streamedSummary.ToString()!=decision.Summary || JsonValueReader.Text(output[0],"type")!="reasoning")
                            throw new BridgeException("public_summary_terminal_mismatch",502);
                        output[0]!["id"]=summaryId;
                    }
                    Volatile.Write(ref lastFailure,null);
                    var response=ResponsesEvents.Response(responseId,request.EffectiveModel,"completed",output,usage);
                    response["parallel_tool_calls"]=request.Parallel;
                    if(request.Stream)
                    {
                        foreach(var e in ResponsesEvents.Items(output))
                        {
                            if(summaryId is not null && JsonValueReader.Integer(e,"output_index")==0 &&
                                JsonValueReader.Text(e,"type") is "response.output_item.added" or "response.reasoning_summary_part.added" or "response.reasoning_summary_text.delta") continue;
                            await Send(e).ConfigureAwait(false);
                        }
                        await Send(new JsonObject{["type"]="response.completed",["response"]=response}).ConfigureAwait(false);
                    }
                    else await context.Response.WriteAsJsonAsync(response,cancellationToken:operation.Token).ConfigureAwait(false);
                }
                finally
                {
                    if(!generation.IsCompleted)
                    {
                        await operation.CancelAsync().ConfigureAwait(false);
                        try{await generation.ConfigureAwait(false);}catch(Exception){/* cancellation is already surfaced below */}
                    }
                }
            }
            catch(OperationCanceledException)
            {
                if(!context.RequestAborted.IsCancellationRequested)await Failure(new BridgeException("model_request_timed_out",504)).ConfigureAwait(false);
            }
            catch(BridgeException e){await Failure(e).ConfigureAwait(false);}
            catch(Exception){await Failure(new BridgeException("bridge_request_failed",502)).ConfigureAwait(false);}
            finally{Interlocked.Decrement(ref active);Interlocked.Exchange(ref lastRequestUtcTicks,DateTimeOffset.UtcNow.UtcTicks);}

            async Task Send(JsonObject e)
            {
                await writeGate.WaitAsync(operation.Token).ConfigureAwait(false);
                try
                {
                    e["sequence_number"]=sequence++;
                    var text="event: "+JsonValueReader.RequiredText(e,"type")+"\ndata: "+e.ToJsonString()+"\n\n";
                    await context.Response.WriteAsync(text,operation.Token).ConfigureAwait(false);
                    await context.Response.Body.FlushAsync(operation.Token).ConfigureAwait(false);
                }
                finally { writeGate.Release(); }
            }
            async Task SendSummary(string delta,CancellationToken cancellationToken)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if(delta.Length==0)return;
                if(streamedSummary.Length+delta.Length>65536)throw new BridgeException("public_summary_too_large",502);
                if(summaryId is null)
                {
                    summaryId="rs_"+Guid.NewGuid().ToString("N");
                    await Send(new JsonObject{["type"]="response.output_item.added",["output_index"]=0,["item"]=new JsonObject
                    { ["id"]=summaryId,["type"]="reasoning",["status"]="in_progress",["summary"]=new JsonArray() }}).ConfigureAwait(false);
                    await Send(new JsonObject{["type"]="response.reasoning_summary_part.added",["item_id"]=summaryId,["output_index"]=0,
                        ["summary_index"]=0,["part"]=new JsonObject{["type"]="summary_text",["text"]=""}}).ConfigureAwait(false);
                }
                streamedSummary.Append(delta);
                await Send(new JsonObject{["type"]="response.reasoning_summary_text.delta",["item_id"]=summaryId,
                    ["output_index"]=0,["summary_index"]=0,["delta"]=delta}).ConfigureAwait(false);
            }
            async Task Failure(BridgeException e)
            {
                Volatile.Write(ref lastFailure,new FailureDiagnostic(e.Code,e.Hints,request?.Tools.Count??0,request?.Input.Count??0));
                if(context.RequestAborted.IsCancellationRequested)return;
                try
                {
                    var error=new JsonObject{["type"]=e.Status>=500?"server_error":"invalid_request_error",["code"]=e.Code,["message"]=e.Code};
                    if(context.Response.HasStarted)
                    {
                        var response=ResponsesEvents.Response(responseId!,request!.EffectiveModel,"failed",new JsonArray());response["error"]=error;
                        var ev=new JsonObject{["type"]="response.failed",["sequence_number"]=sequence++,["response"]=response};
                        await context.Response.WriteAsync("event: response.failed\ndata: "+ev.ToJsonString()+"\n\n",context.RequestAborted).ConfigureAwait(false);
                    }
                    else{context.Response.StatusCode=e.Status;await context.Response.WriteAsJsonAsync(new JsonObject{["error"]=error},cancellationToken:context.RequestAborted).ConfigureAwait(false);}
                }
                catch(IOException){}catch(OperationCanceledException){}
            }
        });
        idleTask=IdleStopAsync(settings.IdleSeconds);
    }
    private static async Task ValidateFinalFormatAsync(CodexRequest request,Decision decision,
        Func<JsonObject,JsonNode,CancellationToken,Task<bool>> validator,CancellationToken token)
    {
        if(decision.Kind!="final"||request.Original["text"]?["format"] is not JsonObject format)return;
        var type=JsonValueReader.Text(format,"type");if(type is null or "text")return;
        if(type is not ("json_object" or "json_schema"))throw new BridgeException("unsupported_response_text_format");
        JsonNode final;try{final=JsonNode.Parse(decision.Final)??throw new JsonException();}catch(JsonException){throw new BridgeException("final_json_format_violated",502);}
        if(type=="json_object"&&final is not JsonObject)throw new BridgeException("final_json_object_required",502);
        if(type=="json_schema"&&(format["schema"] is not JsonObject schema || !await validator(schema,final,token).ConfigureAwait(false)))
            throw new BridgeException("final_json_schema_violated",502);
    }
    public Task StartAsync(CancellationToken token=default)=>app.StartAsync(token);
    public Task WaitAsync(CancellationToken token=default)=>app.WaitForShutdownAsync(token);
    private async Task IdleStopAsync(int seconds)
    {
        try
        {
            while(!lifetime.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(10),lifetime.Token).ConfigureAwait(false);
                lock(requestAdmission)
                {
                    if(active==0 && DateTimeOffset.UtcNow.UtcTicks-Interlocked.Read(ref lastRequestUtcTicks)>TimeSpan.FromSeconds(seconds).Ticks)
                    {accepting=false;app.Lifetime.StopApplication();return;}
                }
            }
        }
        catch(OperationCanceledException){}
    }
    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync().ConfigureAwait(false);
        if(idleTask is not null)await idleTask.ConfigureAwait(false);
        await app.StopAsync().ConfigureAwait(false);
        try{await backend.DisposeAsync().ConfigureAwait(false);}
        finally{await app.DisposeAsync().ConfigureAwait(false);lifetime.Dispose();}
    }
}
