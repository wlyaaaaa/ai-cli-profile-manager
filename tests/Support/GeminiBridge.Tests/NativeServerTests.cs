using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using AiCli.GeminiBridge;
namespace AiCli.GeminiBridge.Tests;
internal static partial class TestProgram
{
    private static async Task<int> NativeServerAsync(string settingsPath,bool live)
    {
        if(live&&(!OperatingSystem.IsWindows()||WindowsIdentity.GetCurrent().IsSystem))throw new InvalidOperationException("consumer_user_required");
        var settings=JsonSerializer.Deserialize<BridgeSettings>(await File.ReadAllTextAsync(settingsPath),new JsonSerializerOptions{PropertyNameCaseInsensitive=true})!;
        var models=GeminiModelSet.Load(settings.ModelCatalogPath!);
        if(live){settings.Validate();IsolationAttestation.Verify(settings);}
        IModelBackend source=live?new AntigravityBackend(settings):new NativeCompactionFixture();
        await using var server=new BridgeServer(settings,new NonceOnlyBackend(source),Token,validator.ValidateAsync,models);
        await server.StartAsync();var ready=new{component="aicli-gemini-native-test",backend=live?"live-antigravity":"deterministic-test-fixture",addresses=server.Addresses};
        await File.WriteAllTextAsync(Path.Combine(root,"native-server-ready.json"),JsonSerializer.Serialize(ready));Console.WriteLine(JsonSerializer.Serialize(ready));
        await Console.In.ReadToEndAsync();return 0;
    }
    private sealed class NonceOnlyBackend(IModelBackend inner):IModelBackend
    {
        public BackendDiagnostics? Diagnostics=>inner.Diagnostics;
        public Task<(JsonObject Decision,Usage Usage)> GenerateAsync(CodexRequest r,CancellationToken t)=>Run(r,null,t);
        public Task<(JsonObject Decision,Usage Usage)> GenerateWithSummaryAsync(CodexRequest r,Func<string,CancellationToken,Task> summary,CancellationToken t)=>Run(r,summary,t);
        private async Task<(JsonObject Decision,Usage Usage)> Run(CodexRequest request,Func<string,CancellationToken,Task>? summary,CancellationToken token)
        {
            (JsonObject Decision,Usage Usage) result;
            try{result=summary is null?await inner.GenerateAsync(request,token):await inner.GenerateWithSummaryAsync(request,summary,token);}
            catch(BridgeException e)
            {
                var failure=new{failed=true,error=e.Code,inputItems=request.Input.Count,inputCharacters=request.Input.ToJsonString().Length,toolCount=request.Tools.Count,backend=inner.Diagnostics};
                await File.AppendAllTextAsync(Path.Combine(root,"model-request-metadata.jsonl"),JsonSerializer.Serialize(failure)+"\n");throw;
            }
            catch(Exception e)
            {
                var frames=new System.Diagnostics.StackTrace(e,false).GetFrames()?.Take(12).Select(f=>f.GetMethod()?.DeclaringType?.FullName+"."+f.GetMethod()?.Name).ToArray();
                var failure=new{failed=true,exceptionType=e.GetType().Name,hresult=e.HResult,methods=frames,inputItems=request.Input.Count,inputCharacters=request.Input.ToJsonString().Length,toolCount=request.Tools.Count,backend=inner.Diagnostics};
                await File.AppendAllTextAsync(Path.Combine(root,"model-request-metadata.jsonl"),JsonSerializer.Serialize(failure)+"\n");throw;
            }
            var diagnostic=new{inputItems=request.Input.Count,inputCharacters=request.Input.ToJsonString().Length,toolCount=request.Tools.Count,
                resultKind=JsonValueReader.Text(result.Decision,"kind"),nativeHistoryAuthoritative=true,backend=inner.Diagnostics};
            await File.AppendAllTextAsync(Path.Combine(root,"model-request-metadata.jsonl"),JsonSerializer.Serialize(diagnostic)+"\n",token);
            var decision=await Decision.ValidateAsync(result.Decision,request,validator.ValidateAsync,token);
            // Only the isolated client-provided nonce may reach native Codex.
            // No shell, file, MCP or subagent intent is dispatched by this test.
            if(decision.Calls.Any(c=>c.Tool.Name!="read_nonce"))throw new BridgeException("fixture_unexpected_tool_blocked",502);
            return result;
        }
        public ValueTask DisposeAsync()=>inner.DisposeAsync();
    }
    private sealed class NativeCompactionFixture:IModelBackend
    {
        public Task<(JsonObject Decision,Usage Usage)> GenerateAsync(CodexRequest request,CancellationToken token)
        {
            var text=request.Input.ToJsonString();var marker=Regex.Match(text,@"native-fixture-[a-f0-9]{32}").Value;
            if(marker.Length>0)return Task.FromResult((Final("Retain the verified synthetic nonce: "+marker+". No other task is pending."),new Usage(100,20,0,0,120)));
            var nonce=request.Tools.FirstOrDefault(t=>t.Name=="read_nonce");if(nonce is null)throw new BridgeException("fixture_expected_nonce_not_in_context",502);
            var call=Call(nonce.Index,"{}");call["visible_summary"]="这段摘要来自确定性测试夹具，仅用于验证原生事件，不是 Gemini 实测。";
            return Task.FromResult((call,new Usage(100,20,0,0,120)));
        }
        public ValueTask DisposeAsync()=>ValueTask.CompletedTask;
    }
}