using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiCli.GeminiBridge;
namespace AiCli.GeminiBridge.Tests;
internal static partial class TestProgram
{
    private static async Task<int> LiveFreshAsync(string path)
    {
        if(!OperatingSystem.IsWindows()||WindowsIdentity.GetCurrent().IsSystem)throw new InvalidOperationException("normal_consumer_user_required");
        var settings=JsonSerializer.Deserialize<BridgeSettings>(await File.ReadAllTextAsync(path),new JsonSerializerOptions{PropertyNameCaseInsensitive=true})!;
        settings.Validate();var models=GeminiModelSet.Load(settings.ModelCatalogPath!);IsolationAttestation.Verify(settings);
        await using var backend=new AntigravityBackend(settings);using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(480));
        var records=new List<object>();var identities=new HashSet<string>(StringComparer.Ordinal);var history=new JsonArray();
        var secret=Guid.NewGuid().ToString("N");var model=models.DefaultModel;
        async Task<(Decision D,JsonArray Output)> Ask(string phase,JsonArray input,JsonArray tools)
        {
            var clock=Stopwatch.StartNew();var chunks=0;double? firstSummary=null;
            var request=CodexRequest.Parse(new JsonObject{["model"]=model,["instructions"]="This is an isolated synthetic adapter test. The only tool is the provided virtual function. Do not call native tools or guess private preferences. Keep the output decision JSON valid.",["input"]=input.DeepClone(),["tools"]=tools,["stream"]=true,["store"]=false,["prompt_cache_key"]="same-synthetic-native-thread"},models);
            Console.WriteLine(JsonSerializer.Serialize(new{phase,status="started"}));
            var(raw,usage)=await backend.GenerateWithSummaryAsync(request,(delta,_)=>{chunks++;firstSummary??=clock.Elapsed.TotalSeconds;return Task.CompletedTask;},timeout.Token);
            var decision=await Decision.ValidateAsync(raw,request,validator.ValidateAsync,timeout.Token);
            var id=backend.Diagnostics?.TransportIdentity??throw new InvalidOperationException("transport_identity_missing");
            if(!identities.Add(id))throw new InvalidOperationException("conversation_reused");
            var row=new{phase,status="completed",seconds=Math.Round(clock.Elapsed.TotalSeconds,2),summaryChunks=chunks,firstSummarySeconds=firstSummary,transportIdentity=id,backendProcessId=backend.Diagnostics?.BackendProcessId,usage};
            records.Add(row);Console.WriteLine(JsonSerializer.Serialize(row));return(decision,ResponsesEvents.Output(decision));
        }
        try
        {
            var plain=new JsonArray(new JsonObject{["role"]="user",["content"]="这是没有个人资料的接口测试。不调用工具，只用中文说明不知道我的饮品偏好，不要猜测。"});
            var(a,_)=await Ask("plain_chinese",plain,new JsonArray());if(a.Kind!="final"||string.IsNullOrWhiteSpace(a.Final))throw new InvalidOperationException("plain_answer_missing");
            history.Add(new JsonObject{["role"]="user",["content"]="请先用中文说明准备查证随机字符串，然后调用 read_nonce，收到结果后原样给出字符串。不得自己编造，不得调用原生工具。"});
            var tools=new JsonArray(Function("read_nonce"));var(call,items)=await Ask("request_virtual_tool",history,tools);
            if(call.Kind!="tool_calls"||call.Calls.Count!=1||call.Calls[0].Tool.Name!="read_nonce"||string.IsNullOrWhiteSpace(call.Summary))throw new InvalidOperationException("tool_intent_or_summary_missing");
            foreach(var item in items)history.Add(item!.DeepClone());
            var toolItem=items.Single(x=>JsonValueReader.Text(x,"type")=="function_call")!;
            history.Add(new JsonObject{["type"]="function_call_output",["call_id"]=toolItem["call_id"]!.DeepClone(),["output"]=secret});
            var(answer,answerItems)=await Ask("fresh_tool_result",history,new JsonArray(Function("read_nonce")));
            if(answer.Kind!="final"||!answer.Final.Contains(secret,StringComparison.Ordinal))throw new InvalidOperationException("tool_result_not_preserved");
            foreach(var item in answerItems)history.Add(item!.DeepClone());
            history.Add(new JsonObject{["role"]="user",["content"]="继续同一对话，不调用工具，请再次原样给出刚才实际得到的随机字符串。"});
            var(follow,_)=await Ask("fresh_followup",history,new JsonArray());
            if(follow.Kind!="final"||!follow.Final.Contains(secret,StringComparison.Ordinal))throw new InvalidOperationException("followup_memory_failed");
            var result=new{pass=true,testLevel="real_adapter_only_not_native_codex_or_desktop",transactions=records,uniqueConversations=identities.Count};
            await File.WriteAllTextAsync(Path.Combine(root,"live-fresh-result.json"),JsonSerializer.Serialize(result));Console.WriteLine(JsonSerializer.Serialize(result));return 0;
        }
        catch(Exception e)
        {
            var result=new{pass=false,testLevel="real_adapter_only_not_native_codex_or_desktop",error=e is BridgeException b?b.Code:e.GetType().Name,diagnostics=backend.Diagnostics,transactions=records};
            await File.WriteAllTextAsync(Path.Combine(root,"live-fresh-result.json"),JsonSerializer.Serialize(result));Console.WriteLine(JsonSerializer.Serialize(result));return 1;
        }
    }
}