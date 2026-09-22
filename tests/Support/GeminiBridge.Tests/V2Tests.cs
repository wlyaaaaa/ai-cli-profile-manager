using System.Text.Json;
using System.Text.Json.Nodes;
using AiCli.GeminiBridge;
namespace AiCli.GeminiBridge.Tests;
internal static partial class TestProgram
{
    private static JsonObject InitialModels(){using var s=typeof(GeminiModelSet).Assembly.GetManifestResourceStream("AiCli.GeminiBridge.InitialModelSet.json")!;using var r=new StreamReader(s);return JsonNode.Parse(r.ReadToEnd())!.AsObject();}
    private static JsonObject FutureModel()
    {
        var m=(JsonObject)InitialModels()["models"]![0]!.DeepClone();
        m["id"]="gemini-fixture-next";m["profileId"]="codex-gemini-fixture-next";m["displayName"]="Synthetic next model";
        m["menuModel"]="gemini-fixture-next-preview-exact";m["defaultEffort"]="high";m["contextWindow"]=262144;
        m["efforts"]=new JsonArray(new JsonObject{["effort"]="high",["model"]="gemini-fixture-next-preview-exact",["cliEffort"]="medium"});return m;
    }
    private static async Task V2Tests()
    {
        await Check("new_model_is_resolved_from_data_without_a_driver_edit",()=>{
            var data=InitialModels();data["models"]!.AsArray().Add(FutureModel());var models=GeminiModelSet.Parse(data.ToJsonString());
            var request=CodexRequest.Parse(Request("gemini-fixture-next-preview-exact"),models);
            Assert(request.EffectiveModel=="gemini-fixture-next-preview-exact"&&request.Effort=="high"&&request.CliEffort=="medium");
            Assert(request.Selection!.Definition.ContextWindow==262144&&models.Models.Count==2);
            var old=CodexRequest.Parse(Request(),models);Assert(old.EffectiveModel=="gemini-3.8-flash-high");return Task.CompletedTask;
        });
        await Check("future_model_does_not_inherit_nonexistent_effort_levels",()=>{
            var data=InitialModels();data["models"]!.AsArray().Add(FutureModel());var models=GeminiModelSet.Parse(data.ToJsonString());
            var r=Request("gemini-fixture-next-preview-exact");r["reasoning"]=new JsonObject{["effort"]="low"};
            Throws(()=>CodexRequest.Parse(r,models),"unsupported_reasoning_effort");return Task.CompletedTask;
        });
        await Check("model_data_is_immutable_per_loaded_snapshot",()=>{
            var source=InitialModels();var before=GeminiModelSet.Parse(source.ToJsonString());source["models"]!.AsArray().Add(FutureModel());
            var after=GeminiModelSet.Parse(source.ToJsonString());Assert(before.Models.Count==1&&after.Models.Count==2&&before.Fingerprint!=after.Fingerprint);
            Throws(()=>before.Resolve("gemini-fixture-next-preview-exact",null),"unsupported_exact_model");return Task.CompletedTask;
        });
        await Check("unknown_model_never_falls_back_to_the_default",()=>{
            Throws(()=>GeminiModelSet.Initial.Resolve("latest",null),"unsupported_exact_model");
            Throws(()=>GeminiModelSet.Initial.Resolve("gemini-99-unregistered",null),"unsupported_exact_model");return Task.CompletedTask;
        });
        await Check("duplicate_profile_and_exact_model_identity_are_rejected",()=>{
            var d=InitialModels();var m=FutureModel();m["profileId"]=d["models"]![0]!["profileId"]!.DeepClone();d["models"]!.AsArray().Add(m);
            Throws(()=>GeminiModelSet.Parse(d.ToJsonString()),"model_set_duplicate_identity");
            d=InitialModels();m=FutureModel();m["menuModel"]="gemini-3.8-flash-high";m["efforts"]![0]!["model"]="gemini-3.8-flash-high";d["models"]!.AsArray().Add(m);
            Throws(()=>GeminiModelSet.Parse(d.ToJsonString()),"model_set_exact_identity_collision");return Task.CompletedTask;
        });
        await Check("model_data_cannot_supply_command_line_switches",()=>{
            var d=InitialModels();d["models"]![0]!["efforts"]![0]!["model"]="--dangerously-skip-permissions";
            Throws(()=>GeminiModelSet.Parse(d.ToJsonString()),"model_set_identifier_invalid");return Task.CompletedTask;
        });
        await Check("unsupported_modalities_and_duplicate_json_fields_fail_closed",()=>{
            var d=InitialModels();d["models"]![0]!["inputModalities"]=new JsonArray("text","image");
            Throws(()=>GeminiModelSet.Parse(d.ToJsonString()),"model_set_modality_not_supported");
            Throws(()=>GeminiModelSet.Parse("{\"schema\":\"x\",\"schema\":\"y\"}"),"model_set_duplicate_property");return Task.CompletedTask;
        });
        await Check("model_loader_rejects_non_schema_evidence_and_missing_version",()=>{
            var data=InitialModels();data["models"]![0]!["evidence"]=new JsonObject{["arbitrary"]="ok",["bad"]=new JsonObject()};
            Throws(()=>GeminiModelSet.Parse(data.ToJsonString()),"model_set_schema_invalid");
            data=InitialModels();data["cli"]!.AsObject().Remove("verifiedVersion");Throws(()=>GeminiModelSet.Parse(data.ToJsonString()),"invalid_verifiedVersion");
            return Task.CompletedTask;
        });
        await Check("every_provider_call_gets_a_new_disposed_transaction_with_complete_input",async()=>{
            var seen=new List<JsonArray>();var transactions=new List<FakeFresh>();
            await using var backend=new AntigravityBackend(Settings(),(r,t)=>{var f=new FakeFresh((request,_,_)=>{seen.Add((JsonArray)request.Input.DeepClone());return Task.FromResult((Final("ok"),new Usage(10,1,0,0,11)));});transactions.Add(f);return Task.FromResult<IFreshModelTransaction>(f);});
            var first=Request();first["prompt_cache_key"]="same-thread";var a=CodexRequest.Parse(first);await backend.GenerateAsync(a,CancellationToken.None);
            first["input"]=new JsonArray(a.Input[0]!.DeepClone(),new JsonObject{["role"]="user",["content"]="next"});await backend.GenerateAsync(CodexRequest.Parse(first),CancellationToken.None);
            Assert(transactions.Count==2&&transactions.All(t=>t.Disposed)&&seen[0].Count==1&&seen[1].Count==2);
            Assert(JsonNode.DeepEquals(seen[1][0],seen[0][0]));
        });
        await Check("codex_context_is_the_only_project_authority_including_no_project",()=>{
            foreach(var instructions in new[]{
                @"Codex project association: none; current cwd: C:\Users\Synthetic\NoProject",
                @"Codex project association: repo:synthetic; current cwd: E:\Work\SyntheticRepo"})
            {
                var raw=Request();raw["instructions"]=instructions;
                raw["input"]=new JsonArray(
                    new JsonObject{["role"]="system",["content"]="The Codex thread owns project and workspace state."},
                    new JsonObject{["role"]="user",["content"]="hello"});
                var parsed=CodexRequest.Parse(raw);var packet=parsed.Packet();
                Assert(JsonValueReader.Text(packet,"instructions")==instructions&&JsonNode.DeepEquals(packet["input"],parsed.Input));
                Assert(packet["project"] is null&&packet["cwd"] is null&&packet["workspace"] is null&&packet["antigravity_project"] is null);
            }
            return Task.CompletedTask;
        });        await Check("fresh_driver_retries_preoutput_connection_location_and_structured_decision_once",async()=>{
            foreach(var code in new[]{"google_connection_failed","google_location_not_supported","structured_decision_invalid"}){
                int count=0;var created=new List<FakeFresh>();
                await using var backend=new AntigravityBackend(Settings(),(r,t)=>{
                    var index=count++;var f=new FakeFresh((_,_,_)=>index==0
                        ? throw new BridgeException(code,503){RejectedBeforeOutput=true}
                        : Task.FromResult((Final("recovered"),new Usage(1,1,0,0,2))));
                    created.Add(f);return Task.FromResult<IFreshModelTransaction>(f);
                });
                var(result,_)=await backend.GenerateAsync(CodexRequest.Parse(Request()),CancellationToken.None);
                Assert(JsonValueReader.Text(result,"final_text")=="recovered"&&count==2&&created.All(x=>x.Disposed));
                Assert(backend.Diagnostics?.Phase=="completed"&&backend.Diagnostics.StartupAttempts==2&&backend.Diagnostics.RecoveryAttempts==1);
            }
        });
        await Check("fresh_driver_surfaces_retryable_error_after_one_retry",async()=>{
            foreach(var code in new[]{"google_connection_failed","google_location_not_supported","structured_decision_invalid"}){
                int count=0;var created=new List<FakeFresh>();
                await using var backend=new AntigravityBackend(Settings(),(r,t)=>{
                    count++;var f=new FakeFresh((_,_,_)=>throw new BridgeException(code,503){RejectedBeforeOutput=true});created.Add(f);return Task.FromResult<IFreshModelTransaction>(f);
                });
                await ThrowsAsync(()=>backend.GenerateAsync(CodexRequest.Parse(Request()),CancellationToken.None),code);
                Assert(count==2&&created.All(x=>x.Disposed)&&backend.Diagnostics?.Failure==code&&backend.Diagnostics.StartupAttempts==2&&backend.Diagnostics.RecoveryAttempts==1);
            }
        });
        await Check("fresh_driver_never_replays_after_output_or_for_nonretryable_errors",async()=>{
            foreach(var entry in new[]{("antigravity_login_required",false),("antigravity_empty_model_response",false),("google_connection_failed",false),("google_location_not_supported",false),("structured_decision_invalid",false)}){
                int count=0;FakeFresh? f=null;
                await using var backend=new AntigravityBackend(Settings(),(r,t)=>{count++;f=new FakeFresh((_,_,_)=>throw new BridgeException(entry.Item1,503){RejectedBeforeOutput=entry.Item2});return Task.FromResult<IFreshModelTransaction>(f);});
                await ThrowsAsync(()=>backend.GenerateAsync(CodexRequest.Parse(Request()),CancellationToken.None),entry.Item1);
                Assert(count==1&&f!.Disposed&&backend.Diagnostics?.Failure==entry.Item1&&backend.Diagnostics.RecoveryAttempts==0);
            }
        });        await Check("cancelled_transaction_is_disposed_and_next_request_is_fresh",async()=>{
            var started=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);var created=new List<FakeFresh>();
            await using var backend=new AntigravityBackend(Settings(),(r,t)=>{var index=created.Count;var f=new FakeFresh(async(_,_,token)=>{if(index==0){started.TrySetResult();await Task.Delay(Timeout.Infinite,token);}return(Final("new"),new Usage(1,1,0,0,2));});created.Add(f);return Task.FromResult<IFreshModelTransaction>(f);});
            using var cancel=new CancellationTokenSource();var run=backend.GenerateAsync(CodexRequest.Parse(Request()),cancel.Token);await started.Task;cancel.Cancel();
            try{await run;throw new InvalidOperationException("expected_cancel");}catch(OperationCanceledException){}
            await backend.GenerateAsync(CodexRequest.Parse(Request()),CancellationToken.None);Assert(created.Count==2&&created.All(x=>x.Disposed));
        });
        await Check("fresh_shutdown_cancels_active_transactions",async()=>{
            var started=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);FakeFresh? f=null;
            var backend=new AntigravityBackend(Settings(),(r,t)=>{f=new FakeFresh(async(_,_,token)=>{started.TrySetResult();await Task.Delay(Timeout.Infinite,token);return(Final("unreachable"),new Usage(0,0,0,0,0));});return Task.FromResult<IFreshModelTransaction>(f);});
            var run=backend.GenerateAsync(CodexRequest.Parse(Request()),CancellationToken.None);await started.Task;
            await backend.DisposeAsync();try{await run;throw new InvalidOperationException("expected_cancel");}catch(OperationCanceledException){}Assert(f!.Disposed);
        });
        await Check("early_child_errors_are_specific_without_raw_stderr_retention",()=>{
            var input=new ChildStderrEvidence();input.Observe("bufio.Scanner: token too long; synthetic-private-text");
            Assert(input.Failure?.Code=="backend_input_size_rejected");
            var network=new ChildStderrEvidence();network.Observe("Eligibility check failed: authentication request: EOF synthetic-private-text");
            Assert(network.Failure?.Code=="google_connection_failed"&&!string.Join(',',network.Failure.Hints).Contains("synthetic-private-text"));
            var ordinary=new ChildStderrEvidence();ordinary.Observe("ready; initialization complete");Assert(ordinary.Failure is null);
            var login=new ChildStderrEvidence();login.Observe("authentication required; visit authorization page");Assert(login.Failure?.Code=="antigravity_login_required"&&login.AbortChild);
            var location=new ChildStderrEvidence();location.Observe("location is not supported");Assert(location.Failure?.Code=="google_location_not_supported"&&!location.AbortChild);
            return Task.CompletedTask;
        });
        await Check("cleanup_failure_never_publishes_successful_health",async()=>{
            await using var backend=new AntigravityBackend(Settings(),(r,t)=>Task.FromResult<IFreshModelTransaction>(new CleanupFailureFixture()));
            await ThrowsAsync(()=>backend.GenerateAsync(CodexRequest.Parse(Request()),CancellationToken.None),"backend_io_failed");
            Assert(backend.Diagnostics?.Phase=="cleanup"&&backend.Diagnostics?.Failure=="backend_io_failed");
        });
        await Check("isolation_receipt_binds_runtime_and_static_templates",()=>{
            var h=new string('a',64);var data=new JsonObject{["schema"]="aicli.antigravity-isolation.v2",["cliSha256"]=h,["interpreterSha256"]=h,["templateSha256"]=h,["preToolDenialObserved"]=true,["cleanupVerified"]=true,["verifiedUtc"]=DateTimeOffset.UtcNow.ToString("O")};
            IsolationAttestation.ValidateReceipt(data,h,h,h);
            Throws(()=>IsolationAttestation.ValidateReceipt(data,new string('b',64),h,h),"isolation_receipt_mismatch");
            data["cleanupVerified"]=false;Throws(()=>IsolationAttestation.ValidateReceipt(data,h,h,h),"isolation_receipt_mismatch");return Task.CompletedTask;
        });
    }
    private static async Task UpdateAdmissionTests()
    {
        await Check("model_update_refuses_to_interrupt_active_request",async()=>{
            var backend=new UpdateBusyBackend();await using var server=new BridgeServer(Settings(),backend,Token,validator.ValidateAsync);await server.StartAsync();
            using var client=new HttpClient{BaseAddress=new Uri(server.Addresses.Single()),Timeout=TimeSpan.FromSeconds(20)};
            client.DefaultRequestHeaders.Authorization=new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer",Token);
            var pending=client.PostAsync("/v1/responses",new StringContent(Request().ToJsonString(),System.Text.Encoding.UTF8,"application/json"));
            await backend.Started.Task;
            using var denied=await client.PostAsync("/shutdown",null);
            Assert(denied.StatusCode==System.Net.HttpStatusCode.Conflict&&!backend.Canceled);
            backend.Continue.TrySetResult();using var completed=await pending;
            Assert(completed.IsSuccessStatusCode&&!backend.Canceled);
        });
        await Check("bad_second_tool_prevents_all_tool_dispatch",async()=>{
            await using var server=new BridgeServer(Settings(),new InvalidBatchBackend(),Token,validator.ValidateAsync);await server.StartAsync();
            using var client=new HttpClient{BaseAddress=new Uri(server.Addresses.Single()),Timeout=TimeSpan.FromSeconds(20)};
            client.DefaultRequestHeaders.Authorization=new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer",Token);
            var request=Request();request["stream"]=true;request["tools"]=new JsonArray(Function("read_nonce"));
            using var response=await client.PostAsync("/v1/responses",new StringContent(request.ToJsonString(),System.Text.Encoding.UTF8,"application/json"));
            var stream=await response.Content.ReadAsStringAsync();
            Assert(stream.Contains("response.failed")&&!stream.Contains("response.function_call_arguments")&&!stream.Contains("response.completed"));
        });
    }
    private sealed class UpdateBusyBackend:IModelBackend
    {
        public readonly TaskCompletionSource Started=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource Continue=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Canceled;
        public async Task<(JsonObject Decision,Usage Usage)> GenerateAsync(CodexRequest request,CancellationToken token){Started.TrySetResult();try{await Continue.Task.WaitAsync(token);}catch(OperationCanceledException){Canceled=true;throw;}return(Final("complete"),new Usage(1,1,0,0,2));}
        public ValueTask DisposeAsync()=>ValueTask.CompletedTask;
    }
    private sealed class InvalidBatchBackend:IModelBackend
    {
        public Task<(JsonObject Decision,Usage Usage)> GenerateAsync(CodexRequest request,CancellationToken token){var result=Call(0,"{}");result["tool_calls"]!.AsArray().Add(new JsonObject{["tool_index"]=0,["arguments_json"]="{\"unknown\":true}"});return Task.FromResult((result,new Usage(1,1,0,0,2)));}
        public ValueTask DisposeAsync()=>ValueTask.CompletedTask;
    }
    private sealed class CleanupFailureFixture:IFreshModelTransaction
    {
        public Task<(JsonObject Decision,Usage Usage)> GenerateFreshAsync(CodexRequest request,Func<string,CancellationToken,Task>? summary,CancellationToken token)=>Task.FromResult((Final("never-success"),new Usage(1,1,0,0,2)));
        public ValueTask DisposeAsync()=>ValueTask.FromException(new IOException("synthetic-owned-cleanup-failure"));
    }
    private sealed class FakeFresh(Func<CodexRequest,Func<string,CancellationToken,Task>?,CancellationToken,Task<(JsonObject,Usage)>> run):IFreshModelTransaction
    {
        public bool Disposed {get;private set;}
        public Task<(JsonObject Decision,Usage Usage)> GenerateFreshAsync(CodexRequest r,Func<string,CancellationToken,Task>? s,CancellationToken t)=>run(r,s,t);
        public ValueTask DisposeAsync(){Disposed=true;return ValueTask.CompletedTask;}
    }
}