using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiCli.GeminiBridge;

namespace AiCli.GeminiBridge.Tests;

internal static partial class TestProgram
{
    private static async Task StreamingTests()
    {
        await Check("upstream_allocation_is_not_misreported_as_a_region_restriction",()=>
        {
            Assert(AntigravitySession.ClassifyError("allocation failed").Code=="google_model_request_failed");
            Assert(AntigravitySession.ClassifyError("User location is not supported").Code=="google_location_not_supported");
            Assert(AntigravitySession.ClassifyError("RESOURCE_EXHAUSTED").Code=="google_quota_exhausted");
            return Task.CompletedTask;
        });
        await Check("public_summary_decodes_every_fragment_boundary",()=>
        {
            var summary="正在检查 \"中文\" 路径 C:\\测试。\n下一步🙂";
            var wire=new JsonObject{["visible_summary"]=summary,["kind"]="final",["final_text"]="final only",["tool_calls"]=new JsonArray()}.ToJsonString();
            for(var chunk=1;chunk<=17;chunk++)
            {
                var decoder=new PublicSummaryDecoder();var output=new StringBuilder();
                for(var i=0;i<wire.Length;i+=chunk)output.Append(decoder.Append(wire.Substring(i,Math.Min(chunk,wire.Length-i))));
                decoder.ValidateFinal(summary);Assert(output.ToString()==summary);
            }
            return Task.CompletedTask;
        });
        await Check("public_summary_does_not_extract_nested_or_final_text",()=>
        {
            var decoder=new PublicSummaryDecoder();
            Assert(decoder.Append("{\"tool_calls\":[{\"visible_summary\":\"DO_NOT_LEAK\"}],\"final_text\":\"visible_summary is not a key here\",")=="");
            Assert(decoder.Append("\"visible_summary\":\"PUBLIC\"}")=="PUBLIC");
            decoder.ValidateFinal("PUBLIC");return Task.CompletedTask;
        });
        await Check("public_summary_is_available_before_json_and_tool_intent_finish",()=>
        {
            var decoder=new PublicSummaryDecoder();
            Assert(decoder.Append("{\"visible_summary\":\"先核对")=="先核对");
            Assert(decoder.Append("运行状态。\",\"kind\":")=="运行状态。");
            decoder.ValidateFinal("先核对运行状态。");return Task.CompletedTask;
        });
        await Check("public_summary_rejects_invalid_escapes_and_terminal_rewrite",()=>
        {
            Throws(()=>new PublicSummaryDecoder().Append("{\"visible_summary\":\"a\\q\"}"),"public_summary_wire_invalid");
            Throws(()=>new PublicSummaryDecoder().Append("{\"visible_summary\":\"\\uD800\"}"),"public_summary_wire_invalid");
            Throws(()=>new PublicSummaryDecoder().Append("```json\n{}"),"public_summary_wire_invalid");
            var decoder=new PublicSummaryDecoder();decoder.Append("{\"visible_summary\":\"first\"}");
            Throws(()=>decoder.ValidateFinal("different"),"public_summary_terminal_mismatch");return Task.CompletedTask;
        });
        await Check("public_summary_duplicate_keys_remain_invalid_full_decisions",()=>
        {
            Throws(()=>AntigravitySession.ParseDecision(new JsonObject{["response"]="{\"kind\":\"final\",\"visible_summary\":\"a\",\"visible_summary\":\"b\",\"final_text\":\"x\",\"tool_calls\":[]}"}),"structured_decision_invalid");
            return Task.CompletedTask;
        });
        await Check("http_summary_precedes_result_without_duplicate_events",async()=>
        {
            var backend=new HeldSummaryBackend();
            await using var server=new BridgeServer(Settings(),backend,Token,validator.ValidateAsync);await server.StartAsync();
            using var client=new HttpClient{BaseAddress=new Uri(server.Addresses.Single()),Timeout=TimeSpan.FromSeconds(15)};
            client.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",Token);
            var body=Request();body["stream"]=true;
            using var request=new HttpRequestMessage(HttpMethod.Post,"/v1/responses"){Content=new StringContent(body.ToJsonString(),Encoding.UTF8,"application/json")};
            using var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead);
            using var reader=new StreamReader(await response.Content.ReadAsStreamAsync());
            var events=new List<JsonNode>();var summaries=0;
            try
            {
                while(summaries<2)
                {
                    var line=await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5));
                    if(line is null)throw new InvalidOperationException("early_stream_end");
                    if(!line.StartsWith("data: ",StringComparison.Ordinal))continue;
                    var e=JsonNode.Parse(line[6..])!;events.Add(e);
                    if(JsonValueReader.Text(e,"type")=="response.reasoning_summary_text.delta")summaries++;
                    Assert(JsonValueReader.Text(e,"type")!="response.completed");
                }
                Assert(!backend.Release.Task.IsCompleted);
                backend.Release.TrySetResult();
                var rest=await reader.ReadToEndAsync().WaitAsync(TimeSpan.FromSeconds(5));
                events.AddRange(rest.Split('\n').Where(x=>x.StartsWith("data: ",StringComparison.Ordinal)).Select(x=>JsonNode.Parse(x[6..])!));
                Assert(events.Count(e=>JsonValueReader.Text(e,"type")=="response.reasoning_summary_text.delta")==2);
                var added=events.Where(e=>JsonValueReader.Text(e,"type")=="response.output_item.added"&&JsonValueReader.Text(e["item"],"type")=="reasoning").Single();
                var terminal=events.Single(e=>JsonValueReader.Text(e,"type")=="response.completed");
                Assert(JsonValueReader.Text(added["item"],"id")==JsonValueReader.Text(terminal["response"]!["output"]![0],"id"));
                Assert(JsonValueReader.Text(terminal["response"]!["output"]![0]!["summary"]![0],"text")==HeldSummaryBackend.Summary);
                for(var i=0;i<events.Count;i++)Assert(JsonValueReader.Integer(events[i],"sequence_number")==i);
            }
            finally { backend.Release.TrySetResult(); }
        });
        await Check("http_disconnect_cancels_backend_and_next_request_succeeds",async()=>
        {
            var backend=new HeldSummaryBackend();
            await using var server=new BridgeServer(Settings(),backend,Token,validator.ValidateAsync);await server.StartAsync();
            using var client=new HttpClient{BaseAddress=new Uri(server.Addresses.Single()),Timeout=TimeSpan.FromSeconds(15)};
            client.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",Token);
            var body=Request();body["stream"]=true;body["input"]="CANCEL_PROBE";
            using(var request=new HttpRequestMessage(HttpMethod.Post,"/v1/responses"){Content=new StringContent(body.ToJsonString(),Encoding.UTF8,"application/json")})
            {
                using var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead);
                await backend.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }
            await backend.Canceled.Task.WaitAsync(TimeSpan.FromSeconds(5));
            backend.Release.TrySetResult();body["input"]="NEXT";
            using var next=await client.PostAsync("/v1/responses",new StringContent(body.ToJsonString(),Encoding.UTF8,"application/json"));
            var text=await next.Content.ReadAsStringAsync();Assert(text.Contains("response.completed")&&!text.Contains("response.failed"));
        });
    }
    private sealed class HeldSummaryBackend:IModelBackend
    {
        public const string Summary="正在核对状态。随后验证结果。";
        public readonly TaskCompletionSource Release=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource Started=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource Canceled=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<(JsonObject Decision,Usage Usage)> GenerateAsync(CodexRequest request,CancellationToken token)=>throw new NotSupportedException();
        public async Task<(JsonObject Decision,Usage Usage)> GenerateWithSummaryAsync(CodexRequest request,Func<string,CancellationToken,Task> onSummary,CancellationToken token)
        {
            Started.TrySetResult();
            try
            {
                if(request.Input.ToJsonString().Contains("CANCEL_PROBE"))await Task.Delay(Timeout.Infinite,token);
                await onSummary("正在核对状态。",token);await onSummary("随后验证结果。",token);
                await Release.Task.WaitAsync(token);
                var final=Final("verified final");final["visible_summary"]=Summary;
                return (final,new Usage(10,10,0,0,20));
            }
            catch(OperationCanceledException){Canceled.TrySetResult();throw;}
        }
        public ValueTask DisposeAsync()=>ValueTask.CompletedTask;
    }
}
