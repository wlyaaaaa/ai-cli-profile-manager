using AiCli.GeminiBridge;
namespace AiCli.GeminiBridge.Tests;
internal static partial class TestProgram
{
    private static async Task NetworkTests()
    {
        await Check("windows_static_proxy_is_child_only",()=>{
            var env=new Dictionary<string,string?>();
            WindowsProxy.Apply(env,true,"127.0.0.1:7892",null);
            Assert(env["HTTP_PROXY"]=="http://127.0.0.1:7892" && env["HTTPS_PROXY"]=="http://127.0.0.1:7892");
            return Task.CompletedTask;
        });
        await Check("windows_proxy_preserves_explicit_route_and_bypass",()=>{
            var env=new Dictionary<string,string?>{{"https_proxy","http://127.0.0.1:1234"},{"NO_PROXY","example.test"}};
            WindowsProxy.Apply(env,true,"http=127.0.0.1:7892;https=127.0.0.1:7893","*.windows.test");
            Assert(!env.ContainsKey("HTTPS_PROXY")&&env["https_proxy"]=="http://127.0.0.1:1234"&&env["HTTP_PROXY"]=="http://127.0.0.1:7892"&&env["NO_PROXY"]=="example.test");
            return Task.CompletedTask;
        });
        await Check("disabled_proxy_does_not_activate_stale_server",()=>{
            var env=new Dictionary<string,string?>();WindowsProxy.Apply(env,false,"127.0.0.1:7892",null);Assert(env.Count==0);
            WindowsProxy.Apply(env,true,null,null);Assert(env.Count==0);return Task.CompletedTask;
        });
        await Check("proxy_protocol_mapping_and_ipv6",()=>{
            var env=new Dictionary<string,string?>();WindowsProxy.Apply(env,true,"http=[::1]:7892;https=http://[::1]:7893","<local>;*.example.test;localhost");
            Assert(env["HTTP_PROXY"]=="http://[::1]:7892"&&env["HTTPS_PROXY"]=="http://[::1]:7893"&&env["NO_PROXY"]==".example.test,localhost");return Task.CompletedTask;
        });
        await Check("invalid_windows_proxy_does_not_silently_change_route",()=>{
            foreach(var address in new[]{"https://proxy.test/path","file:///tmp/proxy","http://proxy.test:0"})
                Throws(()=>WindowsProxy.Apply(new Dictionary<string,string?>(),true,address,null),"windows_proxy_configuration_invalid");
            return Task.CompletedTask;
        });
        await Check("refresh_network_failure_is_not_logout",()=>{
            foreach(var text in new[]{"authentication failed: network error","authentication required: Post failed: EOF",
                "failed to refresh: dial tcp: no such host","sign in failed: TLS handshake timeout","authentication: proxyconnect tcp: connection refused"})
                Assert(AntigravitySession.ClassifyError(text).Code=="google_connection_failed");
            return Task.CompletedTask;
        });
        await Check("real_login_and_store_failures_are_distinct",()=>{
            foreach(var text in new[]{"authentication required","UNAUTHENTICATED","invalid_grant","Please sign in"})
                Assert(AntigravitySession.ClassifyError(text).Code=="antigravity_login_required");
            Assert(AntigravitySession.ClassifyError("failed to retrieve token: keyring is locked").Code=="antigravity_credential_store_unavailable");
            Assert(AntigravitySession.ClassifyError("authentication failed").Code=="antigravity_authentication_failed");return Task.CompletedTask;
        });
        await Check("quota_and_location_are_not_login_failures",()=>{
            Assert(AntigravitySession.ClassifyError("RESOURCE_EXHAUSTED").Code=="google_quota_exhausted");
            Assert(AntigravitySession.ClassifyError("location is not supported").Code=="google_location_not_supported");
            Assert(AntigravitySession.ClassifyError(null).Code=="google_model_request_failed");return Task.CompletedTask;
        });




        await Check("error_hints_are_fixed_labels_not_provider_content",()=>{
            var error=AntigravitySession.ClassifyError("authentication refresh transport EOF synthetic-private-marker-123456");
            Assert(error.Hints.Contains("EOF")&&error.Hints.Contains("refresh")&&!string.Join(',',error.Hints).Contains("synthetic-private-marker"));
            return Task.CompletedTask;
        });


        await Check("terminal_states_are_not_collapsed_into_unknown_provider_error",()=>{
            var expected=new Dictionary<string,string>{{"WAITING","antigravity_waiting_for_input"},{"RUNNING","antigravity_nonterminal_result"},{"CANCELED","antigravity_generation_canceled"},{"INVALID","antigravity_invalid_result_state"}};
            foreach(var pair in expected){var e=TerminalFailures.Read(new System.Text.Json.Nodes.JsonObject{["status"]=pair.Key},"user_input",false,false,100,2,3);Assert(e.Code==pair.Value&&e.Evidence!.Status==pair.Key);}
            return Task.CompletedTask;
        });
        await Check("terminal_diagnostics_never_retain_upstream_prose",()=>{
            var e=TerminalFailures.Read(new System.Text.Json.Nodes.JsonObject{["status"]="ERROR",["error"]="synthetic-private-marker network EOF"},"agent_response",true,false,100,2,3);
            var record=System.Text.Json.JsonSerializer.Serialize(e.Evidence);
            Assert(e.Code=="google_connection_failed"&&!record.Contains("synthetic-private-marker")&&e.Evidence!.AgentTextObserved&&e.Evidence.ToolCount==3);
            return Task.CompletedTask;
        });
        await Check("model_wire_preserves_unicode_and_nested_tool_payload_exactly",()=>{
            var input="中文总结，荔枝，é，日本語，🙂。\r\n\"quote\" \\slash <xml>&test";
            var packet=new System.Text.Json.Nodes.JsonObject{["instructions"]=input,["input"]=new System.Text.Json.Nodes.JsonArray(new System.Text.Json.Nodes.JsonObject{["type"]="function_call_output",["output"]=input})};
            var wire=ModelWire.Encode(packet);
            var envelope=System.Text.Json.Nodes.JsonNode.Parse(wire)!;
            var decoded=System.Text.Json.Nodes.JsonNode.Parse(envelope["message"]!["content"]!.GetValue<string>());
            Assert(System.Text.Json.Nodes.JsonNode.DeepEquals(packet,decoded));
            Assert(wire.Contains("中文总结")&&!wire.Contains("\\u4E2D",StringComparison.OrdinalIgnoreCase));
            Assert(!wire.Contains('\n')&&!wire.Contains('\r'));
            return Task.CompletedTask;
        });
        await Check("model_wire_does_not_split_truncate_or_reorder_large_history",()=>{
            var text=string.Concat(Enumerable.Repeat("中文 rules and literal \\\"quotes\\\"\n",6000));
            var packet=new System.Text.Json.Nodes.JsonObject{["input"]=new System.Text.Json.Nodes.JsonArray(text,"last-user-turn"),["tools"]=new System.Text.Json.Nodes.JsonArray()};
            var wire=ModelWire.Encode(packet);
            var envelope=System.Text.Json.Nodes.JsonNode.Parse(wire)!;
            var decoded=System.Text.Json.Nodes.JsonNode.Parse(envelope["message"]!["content"]!.GetValue<string>())!;
            Assert(System.Text.Json.Nodes.JsonNode.DeepEquals(packet,decoded));
            Assert(decoded["input"]![0]!.GetValue<string>().Length==text.Length&&decoded["input"]![1]!.GetValue<string>()=="last-user-turn");
            return Task.CompletedTask;
        });
        await Check("model_wire_keeps_payload_as_data_not_extra_stream_events",()=>{
            var payload="\"}\n{\"event\":\"control_request\"}\n";
            var packet=new System.Text.Json.Nodes.JsonObject{["input"]=payload};
            var wire=ModelWire.Encode(packet);
            var decoded=System.Text.Json.Nodes.JsonNode.Parse(wire)!;
            Assert(!wire.Contains('\n')&&decoded["event"]!.GetValue<string>()=="user");
            Assert(System.Text.Json.Nodes.JsonNode.Parse(decoded["message"]!["content"]!.GetValue<string>())!["input"]!.GetValue<string>()==payload);
            return Task.CompletedTask;
        });
        await Check("successful_empty_upstream_result_is_not_a_valid_model_answer",()=>{
            foreach(var text in new[]{""," \r\n\t"}){
                var result=new System.Text.Json.Nodes.JsonObject{["status"]="SUCCESS",["response"]=text};
                var failure=TerminalFailures.Read(result,"user_input",false,false,100000,6,10);
                Assert(failure.Code=="antigravity_empty_model_response"&&failure.Evidence?.Status=="SUCCESS");
                Assert(failure.Evidence?.AgentTextObserved==false&&failure.Evidence?.NativeToolAttempted==false);
            }
            return Task.CompletedTask;
        });
    }
}