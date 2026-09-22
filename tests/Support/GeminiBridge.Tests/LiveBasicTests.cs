using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiCli.GeminiBridge;
namespace AiCli.GeminiBridge.Tests;
internal static partial class TestProgram
{
    private static async Task<int> LiveBasicAsync(string path)
    {
        if(!OperatingSystem.IsWindows()||WindowsIdentity.GetCurrent().IsSystem)throw new InvalidOperationException("normal_consumer_user_required");
        var settings=JsonSerializer.Deserialize<BridgeSettings>(await File.ReadAllTextAsync(path),new JsonSerializerOptions{PropertyNameCaseInsensitive=true})!;
        settings.Validate();IsolationAttestation.Verify(settings);var models=GeminiModelSet.Load(settings.ModelCatalogPath!);
        await using var backend=new AntigravityBackend(settings);using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(250));
        var observations=new List<object>();var identity=new HashSet<string>();var marker="fixture-"+Guid.NewGuid().ToString("N");
        var history=new JsonArray(new JsonObject{["role"]="user",["content"]="这是不含个人资料、不执行任何工具的纯文本测试。请记住并原样回答这段随机标记："+marker});
        try
        {
            for(var turn=0;turn<2;turn++)
            {
                var clock=Stopwatch.StartNew();Console.WriteLine(JsonSerializer.Serialize(new{phase="basic_text",turn,state="started"}));
                var r=CodexRequest.Parse(new JsonObject{["model"]=models.DefaultModel,["instructions"]="This is a pure text synthetic fixture. No tools exist. Return the required final decision JSON.",["input"]=history.DeepClone(),["tools"]=new JsonArray(),["tool_choice"]="none",["store"]=false,["stream"]=false,["prompt_cache_key"]="same-synthetic-thread"},models);
                var(raw,usage)=await backend.GenerateAsync(r,timeout.Token);var decision=await Decision.ValidateAsync(raw,r,validator.ValidateAsync,timeout.Token);
                if(decision.Kind!="final"||!decision.Final.Contains(marker,StringComparison.Ordinal))throw new InvalidOperationException("synthetic_context_not_preserved");
                var id=backend.Diagnostics?.TransportIdentity??throw new InvalidOperationException("identity_missing");if(!identity.Add(id))throw new InvalidOperationException("conversation_reused");
                var observation=new{turn,seconds=Math.Round(clock.Elapsed.TotalSeconds,2),transportHash=id,process=backend.Diagnostics?.BackendProcessId,usage};observations.Add(observation);Console.WriteLine(JsonSerializer.Serialize(observation));
                foreach(var item in ResponsesEvents.Output(decision))history.Add(item!.DeepClone());history.Add(new JsonObject{["role"]="user",["content"]="请再次原样回答刚才的随机标记，不调用工具。"});
            }
            var result=new{pass=true,testLevel="live_text_only_no_codex_tools_or_desktop_claim",uniqueConversations=identity.Count,observations};await File.WriteAllTextAsync(Path.Combine(root,"live-basic-result.json"),JsonSerializer.Serialize(result));Console.WriteLine(JsonSerializer.Serialize(result));return 0;
        }
        catch(Exception e){var result=new{pass=false,error=e is BridgeException b?b.Code:e.GetType().Name,diagnostics=backend.Diagnostics,observations};await File.WriteAllTextAsync(Path.Combine(root,"live-basic-result.json"),JsonSerializer.Serialize(result));Console.WriteLine(JsonSerializer.Serialize(result));return 1;}
    }
}