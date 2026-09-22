using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiCli.GeminiBridge;

namespace AiCli.GeminiBridge.Tests;

internal static partial class TestProgram
{
    private static readonly List<TestOutcome> Outcomes = [];
    private static readonly string Token = new('t', 48);
    private static string root = "", pwsh = "";
    private static PowerShellSchemaValidator validator = null!;
    public static async Task<int> Main(string[] args)
    {
        if(args.Length>=3 && args[2] is ("--live-basic" or "--live-fresh" or "--serve-native-live"))
        {
            // The shared source lifecycle is copied into this test build.
            // Fake/offline modes remain available; live mode cannot reopen it.
            var lifecycle=JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"GeminiIntegrationState.json")));
            if(lifecycle?["schema"]?.GetValue<string>()!="aicli.gemini-integration-state.v1" || lifecycle?["state"]?.GetValue<string>()!="experimental")
            { Console.Error.WriteLine("gemini_integration_frozen"); return 64; }
        }
        root = args[0]; pwsh = args[1]; Directory.CreateDirectory(root);
        validator = new PowerShellSchemaValidator(pwsh, root);
        if(args.Length==4&&args[2] is ("--serve-native-fixture" or "--serve-native-live"))return await NativeServerAsync(args[3],args[2]=="--serve-native-live");
        if(args.Length==4&&args[2]=="--live-basic")return await LiveBasicAsync(args[3]);
        if(args.Length==4&&args[2]=="--live-fresh")return await LiveFreshAsync(args[3]);
        if (args.Length == 4 && args[2] == "--serve-fixture")
        {
            await using var server = new BridgeServer(Settings(),new FixtureBackend(),Token,validator.ValidateAsync);
            await server.StartAsync();
            await File.WriteAllTextAsync(args[3],JsonSerializer.Serialize(new{url=server.Addresses.Single(),pid=Environment.ProcessId}));
            await server.WaitAsync(); return 0;
        }
        await Check("exact_model_no_fallback", () => {
            foreach(var effort in CodexRequest.Efforts) Assert(CodexRequest.Parse(Request("gemini-3.8-flash-"+effort)).EffectiveModel.EndsWith(effort));
            Throws(()=>CodexRequest.Parse(Request("gemini-3.8-flash")),"unsupported_exact_model");
            var r=Request();r["reasoning"]=new JsonObject{["effort"]="max"};Throws(()=>CodexRequest.Parse(r),"unsupported_reasoning_effort"); return Task.CompletedTask;
        });
        await Check("no_alternate_server_history",()=>{
            var r=Request();r["previous_response_id"]="resp_old";Throws(()=>CodexRequest.Parse(r),"full_codex_input_required");
            r=Request();r["store"]=true;Throws(()=>CodexRequest.Parse(r),"response_storage_not_supported"); return Task.CompletedTask;
        });
        await Check("unsupported_media_is_not_dropped",()=>{
            var r=Request();r["input"]=JsonNode.Parse("[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,test\"}]}]");
            Throws(()=>CodexRequest.Parse(r),"non_text_input_not_supported");return Task.CompletedTask;
        });
        await Check("encrypted_reasoning_is_not_forwarded",()=>{
            var r=Request();r["input"]=new JsonArray(new JsonObject{["type"]="reasoning",["encrypted_content"]="private-test",["content"]="hidden-test",["summary"]=new JsonArray()});
            var packet=CodexRequest.Parse(r).Packet().ToJsonString();Assert(!packet.Contains("private-test")&&!packet.Contains("hidden-test"));return Task.CompletedTask;
        });
        await Check("namespace_is_separate_from_tool_name",async()=>{
            var r=Request();r["tools"]=new JsonArray(new JsonObject{["type"]="namespace",["name"]="functions",["tools"]=new JsonArray(Function("read_nonce"))});
            var request=CodexRequest.Parse(r);var d=await Validate(Call(0,"{}"),request);var o=ResponsesEvents.Output(d).Single(x=>JsonValueReader.Text(x,"type")=="function_call")!;
            Assert(o["name"]!.GetValue<string>()=="read_nonce"&&o["namespace"]!.GetValue<string>()=="functions");
            var events=ResponsesEvents.Items(new JsonArray(o.DeepClone())).ToArray();Assert(events.Any(e=>e["type"]!.GetValue<string>()=="response.function_call_arguments.done"));
        });
        await Check("custom_tool_input_round_trips",async()=>{
            var r=Request();r["tools"]=new JsonArray(new JsonObject{["type"]="custom",["name"]="apply_patch"});
            var raw="*** Begin Patch\n*** Add File: test.txt\n+中文\n*** End Patch";
            var d=await Validate(Call(0,new JsonObject{["input"]=raw}.ToJsonString()),CodexRequest.Parse(r));
            Assert(ResponsesEvents.Output(d).Single(x=>JsonValueReader.Text(x,"type")=="custom_tool_call")!["input"]!.GetValue<string>()==raw);
        });
        await Check("schema_is_actually_enforced",async()=>{
            var r=Request();r["tools"]=new JsonArray(Function("read_nonce"));var request=CodexRequest.Parse(r);
            await Validate(Call(0,"{}"),request);
            await ThrowsAsync(()=>Validate(Call(0,"{\"unexpected\":1}"),request),"tool_arguments_schema_mismatch");
            var schema=JsonNode.Parse("{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\"}},\"required\":[\"n\"]}")!.AsObject();
            Assert(await validator.ValidateAsync(schema,JsonNode.Parse("{\"n\":3}")!,CancellationToken.None));
            Assert(!await validator.ValidateAsync(schema,JsonNode.Parse("{\"n\":\"3\"}")!,CancellationToken.None));
        });
        await Check("unknown_tool_index_is_rejected",async()=>{
            await ThrowsAsync(()=>Validate(Call(99,"{}"),CodexRequest.Parse(Request())),"invalid_tool_index");
        });
        await Check("parallel_and_required_choices_are_enforced",async()=>{
            var r=Request();r["tools"]=new JsonArray(Function("read_nonce"));r["parallel_tool_calls"]=false;
            var decision=Call(0,"{}");decision["tool_calls"]!.AsArray().Add(decision["tool_calls"]![0]!.DeepClone());
            await ThrowsAsync(()=>Validate(decision,CodexRequest.Parse(r)),"parallel_tool_limit_exceeded");
            r["tool_choice"]="required";await ThrowsAsync(()=>Validate(Final("no tool"),CodexRequest.Parse(r)),"tool_choice_required_violated");
        });
        await Check("hosted_search_is_not_impersonated",()=>{
            var r=Request();r["tools"]=new JsonArray(new JsonObject{["type"]="web_search"});
            Throws(()=>CodexRequest.Parse(r),"codex_public_web_search_tool_required");return Task.CompletedTask;
        });
        await Check("full_context_is_retained_even_with_same_cache_key",()=>{
            var a=Request();a["prompt_cache_key"]="same-codex-thread";var before=CodexRequest.Parse(a);
            var b=(JsonObject)a.DeepClone();b["input"]=new JsonArray(before.Input[0]!.DeepClone(),new JsonObject{["role"]="user",["content"]="next"});
            var next=CodexRequest.Parse(b).Packet();Assert(JsonValueReader.Text(next,"input_mode")=="authoritative_full"&&next["input"]!.AsArray().Count==2);
            Assert(JsonNode.DeepEquals(next["input"]![0],before.Input[0]));return Task.CompletedTask;
        });
        await Check("cumulative_usage_not_double_counted",()=>{
            var d=new Usage(130,25,18,40,155).Since(new Usage(100,10,8,20,110));Assert(d.Input==30&&d.Output==15&&d.Thinking==10&&d.Total==45);
            Throws(()=>new Usage(100,1,0,0,101).Since(new Usage(100,10,8,20,110)),"upstream_usage_regressed");return Task.CompletedTask;
        });
        await Check("child_credentials_are_removed_only_from_child",()=>{
            var start=ChildEnvironment.Redirected(pwsh);start.Environment["GEMINI_API_KEY"]="synthetic-not-a-secret";start.Environment["GOOGLE_API_KEY"]="synthetic";start.Environment["HTTPS_PROXY"]="http://127.0.0.1:1";
            ChildEnvironment.Scrub(start,root,pwsh);Assert(!start.Environment.ContainsKey("GEMINI_API_KEY")&&!start.Environment.ContainsKey("GOOGLE_API_KEY")&&start.Environment.ContainsKey("HTTPS_PROXY"));return Task.CompletedTask;
        });
        await Check("static_hook_handles_unicode_and_spaces",async()=>{
            var dir=Path.Combine(root,"空格 guard path");Directory.CreateDirectory(dir);
            var command=AntigravitySession.HookCommand(dir,"test","{\"decision\":\"deny\"}");var encoded=command.Split(' ')[^1];
            var start=ChildEnvironment.Redirected(pwsh);foreach(var arg in new[]{"-NoLogo","-NoProfile","-NonInteractive","-EncodedCommand",encoded})start.ArgumentList.Add(arg);
            using var p=Process.Start(start)!;p.StandardInput.Close();var output=await p.StandardOutput.ReadToEndAsync();await p.WaitForExitAsync();Assert(p.ExitCode==0&&output.Contains("deny")&&File.Exists(Path.Combine(dir,"test.receipt")));
        });
        await Check("owned_journal_restores_all_ids_atomically",()=>{
            var dir=Path.Combine(root,"journal");Directory.CreateDirectory(dir);var journal=Path.Combine(dir,"owned.json");
            var a="11111111-1111-4111-8111-111111111111";var b="22222222-2222-4222-8222-222222222222";
            var storage=new OwnedStorage(Path.Combine(dir,"absent-native-store"),journal);storage.RememberAll([a,b]);
            var ids=JsonNode.Parse(File.ReadAllText(journal))!["conversation_ids"]!.AsArray();Assert(ids.Count==2);
            storage.Clean();Assert(!File.Exists(journal));return Task.CompletedTask;
        });
        await Check("shared_summary_map_preserves_unrelated_bytes",()=>{
            var a="11111111-1111-4111-8111-111111111111";var b="22222222-2222-4222-8222-222222222222";
            var keep=Map(b);var bytes=Map(a).Concat(keep).ToArray();Assert(OwnedStorage.FilterMap(bytes,a).SequenceEqual(keep));return Task.CompletedTask;
        });
        await Check("process_job_ends_own_child",async()=>{
            var start=ChildEnvironment.Redirected(pwsh);foreach(var arg in new[]{"-NoLogo","-NoProfile","-NonInteractive","-Command","Start-Sleep -Seconds 60"})start.ArgumentList.Add(arg);
            using var p=Process.Start(start)!;p.StandardInput.Close();var job=NativeJob.Attach(p);job.Dispose();using var timeout=new CancellationTokenSource(5000);await p.WaitForExitAsync(timeout.Token);Assert(p.HasExited);
        });
        await UpdateAdmissionTests();
        await DecisionParserTests();
        await ToolSelectorTests();
        await TypedArgumentsTests();
        await V2Tests();
        await WireTests();
        await NetworkTests();
        await StreamingTests();
        await HttpTests();
        var failed=Outcomes.Count(x=>!x.Pass);
        Console.WriteLine(JsonSerializer.Serialize(new{passed=Outcomes.Count-failed,failed,tests=Outcomes}));return failed==0?0:1;
    }
    private static BridgeSettings Settings()=>new("test-only-not-launched","",pwsh,root,0,30,300,2);
    private static JsonObject Request(string model="gemini-3.8-flash-high")=>new(){["model"]=model,["input"]="test",["stream"]=false,["store"]=false};
    private static JsonObject Function(string name)=>new(){["type"]="function",["name"]=name,["parameters"]=JsonNode.Parse("{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}")};
    internal static JsonObject Final(string text)=>new(){["kind"]="final",["visible_summary"]="",["final_text"]=text,["tool_calls"]=new JsonArray()};
    internal static JsonObject Call(int index,string arguments)=>new(){["kind"]="tool_calls",["visible_summary"]="Reading the test nonce through Codex.",["final_text"]="",["tool_calls"]=new JsonArray(new JsonObject{["tool_index"]=index,["arguments_json"]=arguments})};
    private static Task<Decision> Validate(JsonObject raw,CodexRequest request)=>Decision.ValidateAsync(raw,request,validator.ValidateAsync,CancellationToken.None);
    private static void Assert(bool value){if(!value)throw new InvalidOperationException("assertion_failed");}
    private static void Throws(Action action,string code){try{action();}catch(BridgeException e)when(e.Code==code){return;}throw new InvalidOperationException("expected_"+code);}
    private static async Task ThrowsAsync(Func<Task> action,string code){try{await action();}catch(BridgeException e)when(e.Code==code){return;}throw new InvalidOperationException("expected_"+code);}
    private sealed record TestOutcome(string Name,bool Pass,string? Error=null);
    private static async Task Check(string name,Func<Task> action){try{await action();Outcomes.Add(new TestOutcome(name,true));}catch(Exception e){Outcomes.Add(new TestOutcome(name,false,e.GetType().Name+":"+e.Message));}}
    private static byte[] Map(string id){var key=Encoding.UTF8.GetBytes(id);var body=new byte[]{10,(byte)key.Length}.Concat(key).Concat(new byte[]{18,1,1}).ToArray();return new byte[]{10,(byte)body.Length}.Concat(body).ToArray();}
    private static async Task HttpTests()
    {
        await using var server=new BridgeServer(Settings(),new FixtureBackend(),Token,validator.ValidateAsync);await server.StartAsync();
        using var client=new HttpClient{BaseAddress=new Uri(server.Addresses.Single()),Timeout=TimeSpan.FromSeconds(20)};
        await Check("loopback_requires_local_token",async()=>{var r=await client.GetAsync("/health");Assert(r.StatusCode==HttpStatusCode.Unauthorized);});
        client.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",Token);
        await Check("browser_origin_rejected",async()=>{using var req=new HttpRequestMessage(HttpMethod.Get,"/health");req.Headers.Add("Origin","https://example.test");using var r=await client.SendAsync(req);Assert(r.StatusCode==HttpStatusCode.Unauthorized);});
        await Check("http_final_response",async()=>{using var r=await Post(Request());var body=JsonNode.Parse(await r.Content.ReadAsStringAsync())!;Assert(r.IsSuccessStatusCode&&body["status"]!.GetValue<string>()=="completed");});
        await Check("sse_events_and_terminal_identity",async()=>{var request=Request();request["stream"]=true;using var r=await Post(request);var text=await r.Content.ReadAsStringAsync();var events=text.Split('\n').Where(x=>x.StartsWith("data: ",StringComparison.Ordinal)).Select(x=>JsonNode.Parse(x[6..])!).ToArray();Assert(events[0]["type"]!.GetValue<string>()=="response.created"&&events[^1]["type"]!.GetValue<string>()=="response.completed");Assert(events[0]["response"]!["id"]!.GetValue<string>()==events[^1]["response"]!["id"]!.GetValue<string>());for(var i=0;i<events.Length;i++)Assert(events[i]["sequence_number"]!.GetValue<int>()==i);});
        await Check("sse_failure_is_not_completion",async()=>{var request=Request();request["stream"]=true;request["input"]="FIXTURE_FAILURE";using var r=await Post(request);var text=await r.Content.ReadAsStringAsync();Assert(text.Contains("response.failed")&&!text.Contains("response.completed")&&!text.Contains("private-upstream-details"));});
        async Task<HttpResponseMessage> Post(JsonObject request)=>await client.PostAsync("/v1/responses",new StringContent(request.ToJsonString(),Encoding.UTF8,"application/json"));
    }
    private sealed class FixtureBackend:IModelBackend
    {
        public Task<(JsonObject Decision,Usage Usage)> GenerateAsync(CodexRequest request,CancellationToken token)
        {
            var text=request.Input.ToJsonString();if(text.Contains("FIXTURE_FAILURE"))throw new BridgeException("fixture_backend_failed",502);
            if(request.Tools.Count>0)
            {
                var result=request.Input.LastOrDefault(x=>JsonValueReader.Text(x,"type") is "function_call_output" or "custom_tool_call_output");
                if(result is not null)return Task.FromResult((Final("CODEX_TOOL_RESULT: "+result["output"]!.ToJsonString()),new Usage(100,10,0,0,110)));
                var nonce=request.Tools.FirstOrDefault(x=>x.Name=="read_nonce")??throw new BridgeException("test_nonce_tool_missing",502);
                return Task.FromResult((Call(nonce.Index,"{}"),new Usage(100,10,0,0,110)));
            }
            return Task.FromResult((Final("FIXTURE_OK"),new Usage(100,10,0,0,110)));
        }
        public ValueTask DisposeAsync()=>ValueTask.CompletedTask;
    }
}
