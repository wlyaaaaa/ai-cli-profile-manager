using System.Text.Json.Nodes;

var root = Path.Combine(Path.GetTempPath(), "aicli-router-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var checks = 0;
void Check(bool condition, string description)
{
    if (!condition) throw new Exception(description);
    checks++;
}
JsonObject Parse(string value) => JsonNode.Parse(value)!.AsObject();
JsonObject Model(string id, string name) => new()
{
    ["model"] = id, ["providerId"] = "aicli_ollama_" + id,
    ["routeProviderId"] = "aicli_desktop_local", ["kind"] = "local",
    ["provider"] = new JsonObject { ["name"] = name, ["base_url"] = "http://127.0.0.1:32100/v1", ["wire_api"] = "responses", ["requires_openai_auth"] = false },
    ["contextWindow"] = 262144L,
    ["catalogModel"] = new JsonObject
    {
        ["slug"] = id, ["display_name"] = name, ["description"] = "Local fixture", ["context_window"] = 262144,
        ["default_reasoning_level"] = "high", ["effective_context_window_percent"] = 95,
        ["input_modalities"] = new JsonArray("text"), ["multi_agent_version"] = "v2",
        ["supported_reasoning_levels"] = new JsonArray(new JsonObject { ["effort"] = "high", ["description"] = "High" })
    }
};
JsonObject CloudModel() => new()
{
    ["model"] = "qwen3.8-max-0902", ["providerId"] = "aicli_qwen38_max_paygo",
    ["routeProviderId"] = "aicli_qwen38_max_paygo", ["kind"] = "cloud",
    ["provider"] = new JsonObject
    {
        ["name"] = "Qwen3.8 Max 0902", ["base_url"] = "https://workspace.example/compatible-mode/v1",
        ["wire_api"] = "responses", ["requires_openai_auth"] = false,
        ["auth"] = new JsonObject
        {
            ["command"] = "pwsh", ["args"] = new JsonArray("-File", "token.ps1"),
            ["timeout_ms"] = 10000, ["refresh_interval_ms"] = 0
        }
    },
    ["contextWindow"] = 983616L,
    ["catalogModel"] = new JsonObject
    {
        ["slug"] = "qwen3.8-max-0902", ["display_name"] = "Qwen3.8 Max 0902",
        ["description"] = "Cloud fixture", ["context_window"] = 983616,
        ["default_reasoning_level"] = "xhigh", ["effective_context_window_percent"] = 95,
        ["auto_compact_token_limit"] = 885254, ["input_modalities"] = new JsonArray("text", "image"),
        ["supported_reasoning_levels"] = new JsonArray(new JsonObject { ["effort"] = "xhigh", ["description"] = "XHigh" })
    }
};
JsonObject GlmModel() => new()
{
    ["profileId"] = "codex-glm-5-3-flash", ["model"] = "glm-5.3-flash",
    ["providerId"] = "aicli_glm_5_3_flash", ["routeProviderId"] = "aicli_glm_5_3_flash", ["kind"] = "cloud",
    ["provider"] = new JsonObject
    {
        ["name"] = "GLM-5.3-Flash", ["base_url"] = "https://open.bigmodel.cn/api/v1",
        ["wire_api"] = "responses", ["requires_openai_auth"] = false,
        ["auth"] = new JsonObject { ["command"] = "pwsh", ["args"] = new JsonArray("-File", "token.ps1") }
    },
    ["contextWindow"] = 1048576L,
    ["catalogModel"] = new JsonObject
    {
        ["slug"] = "glm-5.3-flash", ["display_name"] = "GLM-5.3-Flash",
        ["context_window"] = 1048576, ["auto_compact_token_limit"] = 943718,
        ["default_reasoning_level"] = "max", ["input_modalities"] = new JsonArray("text", "image"),
        ["supported_reasoning_levels"] = new JsonArray(new JsonObject { ["effort"] = "max", ["description"] = "Max" })
    }
};
var plan = new JsonObject { ["codexHome"] = root, ["models"] = new JsonArray(Model("local-a", "Named local A"), Model("local-b", "Named local B"), CloudModel(), GlmModel()) };
Task<JsonObject> NoCall(string method, JsonObject args) => throw new Exception("Unexpected upstream call: " + method);
try
{
    File.WriteAllText(Path.Combine(root, "models_cache.json"), "{\"models\":[{\"slug\":\"cloud-next-generation\",\"vendorMetadata\":{\"unknownFutureField\":17}}]}");
    plan["upstreamModels"] = JsonNode.Parse(File.ReadAllText(Path.Combine(root, "models_cache.json")))!["models"]!.DeepClone();
    var router = new ModelRouter(plan);
    var startup = JsonNode.Parse(File.ReadAllText(router.StartupCatalogPath!))!;
    Check(startup["models"]!.AsArray().Count == 5 && startup["models"]![0]!["vendorMetadata"]!["unknownFutureField"]!.GetValue<int>() == 17, "Startup catalog must preserve native metadata and load managed models before initialization.");
    var original = Parse("{\"id\":1,\"method\":\"thread/start\",\"params\":{\"model\":\"cloud-next-generation\",\"config\":{\"custom\":42}}}");
    var official = original.DeepClone();
    await router.BeforeRequestAsync(original, NoCall);
    Check(JsonNode.DeepEquals(original, official), "Official thread configuration must remain unchanged.");

    var local = Parse("{\"id\":2,\"method\":\"thread/start\",\"params\":{\"model\":\"local-a\",\"config\":{\"model_provider\":\"openai\",\"custom\":42}}}");
    await router.BeforeRequestAsync(local, NoCall);
    Check(local["params"]!["modelProvider"]!.GetValue<string>() == "aicli_desktop_local" && local["params"]!["allowProviderModelFallback"]!.GetValue<bool>() == false, "Local selection must bind its service without fallback.");
    Check(local["params"]!["config"]!["model_provider"]!.GetValue<string>() == "aicli_desktop_local" && local["params"]!["config"]!["custom"]!.GetValue<int>() == 42, "Local overrides must agree and preserve unrelated settings.");
    Check(local["params"]!["config"]!["model_context_window"]!.GetValue<long>() == 262144 && !local.ToJsonString().Contains("env_key"), "Local capacity and authentication must come from the local plan.");
    Check(local["params"]!["config"]!["model_auto_compact_token_limit"]!.GetValue<long>() == 235929, "Managed model fallback compaction must use 90 percent of context.");

    var cloud = Parse("{\"id\":3,\"method\":\"thread/start\",\"params\":{\"model\":\"qwen3.8-max-0902\",\"config\":{}}}");
    await router.BeforeRequestAsync(cloud, NoCall);
    Check(cloud["params"]!["modelProvider"]!.GetValue<string>() == "aicli_qwen38_max_paygo", "Cloud selection must bind its exact provider.");
    Check(cloud["params"]!["config"]!["model_providers.aicli_qwen38_max_paygo"]!["auth"]!["command"]!.GetValue<string>() == "pwsh", "Cloud authentication must stay command-backed.");
    Check(!cloud.ToJsonString().Contains("env_key"), "Cloud selection must not serialize an API key environment variable.");
    Check(cloud["params"]!["config"]!["model_auto_compact_token_limit"]!.GetValue<int>() == 885254, "Cloud model compaction must use its declared 90 percent limit.");

    router.AfterResponse("thread/start", null, Parse("{\"result\":{\"modelProvider\":\"aicli_glm_5_3_flash\",\"model\":\"glm-5.3-flash\",\"thread\":{\"id\":\"glm-task\",\"modelProvider\":\"aicli_glm_5_3_flash\"}}}"));
    var reasoningDelta = Parse("{\"method\":\"item/reasoning/textDelta\",\"params\":{\"threadId\":\"glm-task\",\"turnId\":\"turn-1\",\"itemId\":\"reason-1\",\"contentIndex\":0,\"delta\":\"分析步骤\"}} ");
    Check(router.NormalizeNotification(reasoningDelta), "GLM raw reasoning delta must be normalized for the desktop summary renderer.");
    Check(reasoningDelta["method"]!.GetValue<string>() == "item/reasoning/summaryTextDelta" && reasoningDelta["params"]!["summaryIndex"]!.GetValue<int>() == 0 && reasoningDelta["params"]!["contentIndex"] is null, "GLM reasoning delta must use the summary protocol shape.");
    var reasoningCompleted = Parse("{\"method\":\"item/completed\",\"params\":{\"threadId\":\"glm-task\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"reason-1\",\"type\":\"reasoning\",\"summary\":[],\"content\":[\"完整分析\"]}}}");
    Check(router.NormalizeNotification(reasoningCompleted) && reasoningCompleted["params"]!["item"]!["summary"]![0]!.GetValue<string>() == "完整分析", "GLM completed raw reasoning must remain visible as a desktop summary.");
    var qwenReasoning = Parse("{\"method\":\"item/reasoning/textDelta\",\"params\":{\"threadId\":\"cloud-task\",\"itemId\":\"reason-2\",\"contentIndex\":0,\"delta\":\"raw\"}}");
    router.AfterResponse("thread/start", null, Parse("{\"result\":{\"modelProvider\":\"aicli_qwen38_max_paygo\",\"model\":\"qwen3.8-max-0902\",\"thread\":{\"id\":\"cloud-task\",\"modelProvider\":\"aicli_qwen38_max_paygo\"}}}"));
    Check(!router.NormalizeNotification(qwenReasoning), "Native Qwen reasoning summaries must pass through unchanged.");

    var response = Parse("{\"result\":{\"data\":[{\"model\":\"new-upstream-model\",\"isDefault\":true,\"futureField\":17}],\"nextCursor\":\"native-cursor\"}}");
    var unchanged = response.DeepClone();
    router.AfterResponse("model/list", Parse("{\"limit\":2}"), response);
    Check(JsonNode.DeepEquals(response, unchanged), "Native model discovery and pagination must pass through untouched.");
    var config = Parse("{\"result\":{\"config\":{\"model\":\"cloud-next-generation\",\"model_catalog_json\":\"native-startup-catalog\",\"unknown\":{\"x\":7}}}}");
    unchanged = config.DeepClone();
    router.AfterResponse("config/read", null, config);
    Check(JsonNode.DeepEquals(config, unchanged), "The adapter must not manufacture a display-only config layer.");

    router.AfterResponse("thread/start", null, Parse("{\"result\":{\"modelProvider\":\"aicli_desktop_local\",\"model\":\"local-a\",\"thread\":{\"id\":\"local-task\",\"modelProvider\":\"aicli_desktop_local\"}}}"));
    var change = Parse("{\"id\":4,\"method\":\"thread/settings/update\",\"params\":{\"threadId\":\"local-task\",\"model\":\"local-b\",\"effort\":\"high\"}}");
    Check(await router.BeforeRequestAsync(change, NoCall) is not null, "Both local models must be selectable in the same task.");
    var rejected = false;
    try { await router.BeforeRequestAsync(Parse("{\"id\":5,\"method\":\"turn/start\",\"params\":{\"threadId\":\"local-task\",\"model\":\"cloud-next-generation\"}}"), NoCall); }
    catch (RpcException error) { rejected = error.Code == -32602; }
    Check(rejected, "Cross-service selection must not dispatch to the wrong provider.");

    var failure = Parse("{\"id\":6,\"error\":{\"code\":-32603,\"message\":\"upstream unavailable\"}}");
    var sameFailure = failure.DeepClone();
    router.AfterResponse("model/list", null, failure);
    Check(JsonNode.DeepEquals(failure, sameFailure), "An upstream failure must not be replaced by a successful local list.");
    var unknown = Parse("{\"id\":7,\"method\":\"future/method\",\"params\":{\"model\":\"local-a\",\"payload\":[1,2,3]}}");
    var sameUnknown = unknown.DeepClone();
    await router.BeforeRequestAsync(unknown, NoCall);
    Check(JsonNode.DeepEquals(unknown, sameUnknown), "Unknown protocol methods must pass through unchanged.");
    var collisionPlan = (JsonObject)plan.DeepClone();
    collisionPlan["upstreamModels"]!.AsArray().Add(new JsonObject { ["slug"] = "local-a" });
    rejected = false;
    try { _ = new ModelRouter(collisionPlan); }
    catch (InvalidOperationException) { rejected = true; }
    Check(rejected, "Conflicting native/local IDs must never silently replace the native model.");
    Console.WriteLine($"PASS: {checks} desktop router checks");
}
catch (Exception error) { Console.Error.WriteLine("FAIL: " + error.Message); Environment.ExitCode = 1; }
finally { Directory.Delete(root, recursive: true); }

public sealed class RpcException(int code, string message) : Exception(message) { public int Code { get; } = code; }
