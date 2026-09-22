using System.Text.Json.Nodes;
var root=Path.Combine(Path.GetTempPath(),"gemini-router-"+Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var count=0;
void Check(bool value,string message){if(!value)throw new Exception(message);count++;}
Task<JsonObject> NoCall(string method,JsonObject? parameters)=>throw new Exception("Unexpected internal RPC: "+method);
JsonObject Parse(string json)=>JsonNode.Parse(json)!.AsObject();
try
{
    var entry=Parse("""{"profileId":"codex-gemini-3-8-flash","model":"gemini-3.8-flash-high","providerId":"aicli_google_antigravity","routeProviderId":"aicli_google_antigravity","kind":"managed-proxy","provider":{"name":"Google Antigravity","base_url":"http://127.0.0.1:43199/v1","wire_api":"responses","requires_openai_auth":false},"contextWindow":1048576,"defaultEffort":"high","catalogModel":{"slug":"gemini-3.8-flash-high","display_name":"Gemini 3.8 Flash","context_window":1048576,"auto_compact_token_limit":943718,"default_reasoning_level":"high","default_reasoning_summary":"detailed","supported_reasoning_levels":[{"effort":"low","description":"Low"},{"effort":"medium","description":"Medium"},{"effort":"high","description":"High"}]},"managedPublicWebSearch":{"command":"pwsh","args":["-File","search.ps1"],"enabled":true,"required":true,"enabled_tools":["public_web_search"]}}""");
    var plan=new JsonObject{["codexHome"]=root,["models"]=new JsonArray(entry),["upstreamModels"]=new JsonArray()};
    var router=new ModelRouter(plan);
    var start=Parse("""{"id":1,"method":"thread/start","params":{"model":"gemini-3.8-flash-high","permissions":":danger-full-access","config":{"future_key":"preserved"}}}""");
    await router.BeforeRequestAsync(start,NoCall);
    var p=start["params"]!.AsObject();var c=p["config"]!.AsObject();
    Check(p["modelProvider"]!.GetValue<string>()=="aicli_google_antigravity","exact provider");
    Check(p["allowProviderModelFallback"]!.GetValue<bool>()==false,"no fallback");
    Check(c["model_reasoning_summary"]!.GetValue<string>()=="detailed","native summaries enabled");
    Check(c["model_reasoning_effort"]!.GetValue<string>()=="high","valid Google default");
    Check(c["web_search"]!.GetValue<string>()=="disabled","hosted search is not impersonated");
    Check(c["mcp_servers.aicli_public_web_search"]!["required"]!.GetValue<bool>(),"Codex search required");
    Check(c["model_auto_compact_token_limit"]!.GetValue<long>()==943718,"native compaction retained");
    Check(p["permissions"]!.GetValue<string>()==":danger-full-access","permissions unchanged");
    Check(c["future_key"]!.GetValue<string>()=="preserved","unrelated configuration retained");
    router.AfterResponse("thread/start",p,Parse("""{"result":{"thread":{"id":"gemini-thread","modelProvider":"aicli_google_antigravity"},"model":"gemini-3.8-flash-high","modelProvider":"aicli_google_antigravity"}}"""));
    var turn=Parse("""{"id":2,"method":"turn/start","params":{"threadId":"gemini-thread","model":"gemini-3.8-flash-high","effort":"low"}}""");
    await router.BeforeRequestAsync(turn,NoCall);
    Check(turn["params"]!["effort"]!.GetValue<string>()=="low","explicit user effort is not overwritten");
    var history=Parse("""{"result":{"thread":{"id":"gemini-thread","modelProvider":"aicli_google_antigravity","turns":[{"id":"turn-1","status":"completed","items":[{"id":"r1","type":"reasoning","summary":["已确认文件内容与预期一致。"],"content":["Do not promote this raw field"]},{"id":"m1","type":"agentMessage","text":"独立的最终答案","phase":"final_answer"}]}]}}}""");
    var before=history.DeepClone();
    router.AfterResponse("thread/read",new JsonObject{["threadId"]="gemini-thread"},history);
    Check(JsonNode.DeepEquals(before,history),"native Gemini summaries and final history must pass unchanged");
    var missing=(JsonObject)plan.DeepClone();missing["models"]![0]!.AsObject().Remove("managedPublicWebSearch");
    var invalidRouter=new ModelRouter(missing);var rejected=false;
    try{await invalidRouter.BeforeRequestAsync(Parse("""{"method":"thread/start","params":{"model":"gemini-3.8-flash-high"}}"""),NoCall);}catch(RpcException){rejected=true;}
    Check(rejected,"missing Codex search wiring is not silently accepted");
    var futurePlan=(JsonObject)plan.DeepClone();var future=futurePlan["models"]![0]!.AsObject();
    future["profileId"]="codex-gemini-synthetic-future";future["model"]="gemini-synthetic-future-exact";future["defaultEffort"]="medium";
    future["contextWindow"]=262144L;future["catalogModel"]!["slug"]="gemini-synthetic-future-exact";future["catalogModel"]!["context_window"]=262144L;
    future["catalogModel"]!["default_reasoning_level"]="medium";future["catalogModel"]!["auto_compact_token_limit"]=235929L;
    var futureRouter=new ModelRouter(futurePlan);var futureStart=Parse("""{"method":"thread/start","params":{"model":"gemini-synthetic-future-exact"}}""");
    await futureRouter.BeforeRequestAsync(futureStart,NoCall);
    var futureConfig=futureStart["params"]!["config"]!;
    Check(futureConfig["model_reasoning_effort"]!.GetValue<string>()=="medium","future model uses its own effort");
    Check(futureConfig["model_auto_compact_token_limit"]!.GetValue<long>()==235929,"future model uses its own context");
    Check(futureConfig["mcp_servers.aicli_public_web_search"] is not null,"future model keeps native search without hardcoded profile");
    Check(futureConfig["model_reasoning_summary"]!.GetValue<string>()=="detailed","future model keeps native summaries");
    Console.WriteLine($"PASS: {count} Gemini desktop router checks");
}
catch(Exception e){Console.Error.WriteLine("FAIL: "+e.Message);Environment.ExitCode=1;}
finally{Directory.Delete(root,true);}
public sealed class RpcException(int code,string message):Exception(message){public int Code{get;}=code;}
