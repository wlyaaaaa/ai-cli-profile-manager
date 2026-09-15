using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

// Only model discovery and local thread configuration belong to this adapter.
// The original Codex engine owns authentication, history, tools and execution.
public sealed class ModelRouter
{
    private const string ProviderId = "aicli_desktop_local";
    private readonly Dictionary<string, JsonObject> models = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, ThreadState> threads = new();
    private readonly ConcurrentDictionary<string, byte> upstreamModels = new();
    private readonly ConcurrentDictionary<string, byte> localProviders = new();
    private readonly string catalogPath;
    public string? StartupCatalogPath => models.Count > 0 ? catalogPath : null;
    private readonly JsonObject? provider;
    private sealed record ThreadState(string Provider, string? Model);

    public ModelRouter(JsonObject plan)
    {
        var codexHome = Text(plan, "codexHome") ?? "";
        foreach (var value in plan["models"]?.AsArray() ?? [])
        {
            if (value is not JsonObject entry || Text(entry, "model") is not { } model) continue;
            models.Add(model, (JsonObject)entry.DeepClone());
            if (Text(entry, "providerId") is { } id) localProviders[id] = 0;
        }
        foreach (var value in plan["legacyModels"]?.AsArray() ?? [])
        {
            if (Text(value, "model") is not { } alias || Text(value, "canonicalModel") is not { } canonical ||
                !models.TryGetValue(canonical, out var original) || models.ContainsKey(alias)) continue;
            var entry = (JsonObject)original.DeepClone();
            entry["model"] = alias;
            entry["hidden"] = true;
            entry["catalogModel"]!["slug"] = alias;
            entry["catalogModel"]!["visibility"] = "hide";
            entry["catalogModel"]!["display_name"] = Text(original["catalogModel"], "display_name") + "（旧配置）";
            models[alias] = entry;
        }
        if (models.Count == 0) { catalogPath = ""; return; }
        var endpoints = models.Values.Select(e => Text(e["provider"], "base_url")).Distinct().ToArray();
        if (endpoints.Length != 1 || endpoints[0] is null)
            throw new InvalidOperationException("Desktop local models must share one local endpoint.");
        provider = (JsonObject)models.Values.First()["provider"]!.DeepClone();
        provider["name"] = "AICLI local models";
        localProviders[ProviderId] = 0;
        var combined = new JsonArray();
        foreach (var item in plan["upstreamModels"]?.AsArray() ?? [])
        {
            if (Text(item, "slug") is not { } id) continue;
            upstreamModels[id] = 0;
            if (models.ContainsKey(id)) throw new InvalidOperationException("Upstream and local model IDs conflict.");
            combined.Add(item!.DeepClone());
        }
        foreach (var item in models.Values) combined.Add(item["catalogModel"]!.DeepClone());
        var catalog = new JsonObject { ["models"] = combined };
        var bytes = Encoding.UTF8.GetBytes(catalog.ToJsonString());
        var digest = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()[..12];
        var root = Path.Combine(Text(plan, "codexHome") ?? throw new InvalidOperationException("Missing Codex home."), "aicli-model-catalogs");
        Directory.CreateDirectory(root);
        catalogPath = Path.Combine(root, $"desktop-startup-{digest}.json");
        if (!File.Exists(catalogPath))
        {
            var temporary = catalogPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temporary, bytes);
                try { File.Move(temporary, catalogPath, false); }
                catch (IOException) when (File.Exists(catalogPath)) { }
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }

    public async Task<JsonObject?> BeforeRequestAsync(JsonObject request, Func<string, JsonObject, Task<JsonObject>> callUpstream)
    {
        var method = Text(request, "method");
        var parameters = request["params"] as JsonObject;
        if (models.Count == 0 || parameters is null) return request;
        var selected = SelectedModel(parameters);
        if (method == "thread/start")
        {
            if (selected is not null && models.ContainsKey(selected))
            {
                RejectCollision(selected);
                ConfigureLocal(parameters, ProviderId, selected);
                parameters["allowProviderModelFallback"] = false;
            }
            return request;
        }
        if (method is not ("thread/resume" or "thread/fork" or "thread/settings/update" or "turn/start")) return request;
        var threadId = Text(parameters, "threadId");
        if (threadId is null) return request;
        var state = await ReadThreadAsync(threadId, callUpstream);
        var isLocal = await IsLocalProviderAsync(state.Provider, callUpstream);
        if (selected is not null && models.ContainsKey(selected))
        {
            RejectCollision(selected);
            if (!isLocal) throw CrossProviderError();
        }
        else if (isLocal && selected is not null && selected != state.Model)
        {
            // Native persisted threads keep their provider, including after
            // unsubscribe/resume. Never send an official selection to Ollama.
            throw CrossProviderError();
        }
        if (isLocal && (method is "thread/resume" or "thread/fork"))
        {
            // Preserve the provider recorded in the original task. The
            // combined catalog permits both local models without a rebind.
            ConfigureLocal(parameters, state.Provider, selected ?? state.Model);
        }
        return request;
    }

    public void AfterResponse(string method, JsonObject? originalParams, JsonObject response)
    {
        if (response["result"] is not JsonObject result) return;
        if (method is "thread/start" or "thread/resume" or "thread/read" or "thread/fork")
            RememberThread(result);
        if (method == "thread/settings/update" && Text(originalParams, "threadId") is { } threadId &&
            threads.TryGetValue(threadId, out var state) && SelectedModel(originalParams) is { } selected)
            threads[threadId] = state with { Model = selected };
        if (method == "config/read") RememberProviders(result["config"]);
    }

    private async Task<ThreadState> ReadThreadAsync(string id, Func<string, JsonObject, Task<JsonObject>> call)
    {
        if (threads.TryGetValue(id, out var state)) return state;
        var response = await call("thread/read", new JsonObject { ["threadId"] = id, ["includeTurns"] = false });
        if (response["error"] is JsonObject error)
            throw new RpcException(error["code"]?.GetValue<int>() ?? -32603, Text(error, "message") ?? "Could not read task connection.");
        if (response["result"] is JsonObject result) RememberThread(result);
        return threads.TryGetValue(id, out state) ? state :
            throw new RpcException(-32603, "Could not identify the saved task's model provider.");
    }

    private async Task<bool> IsLocalProviderAsync(string id, Func<string, JsonObject, Task<JsonObject>> call)
    {
        if (localProviders.ContainsKey(id)) return true;
        if (!id.StartsWith("aicli_ollama_", StringComparison.Ordinal)) return false;
        var response = await call("config/read", new JsonObject { ["includeLayers"] = false, ["cwd"] = null });
        RememberProviders(response["result"]?["config"]);
        return localProviders.ContainsKey(id);
    }

    private void RememberProviders(JsonNode? configuration)
    {
        if (provider is null || configuration?["model_providers"] is not JsonObject definitions) return;
        foreach (var (id, definition) in definitions)
            if (id.StartsWith("aicli_ollama_", StringComparison.Ordinal) &&
                Text(definition, "base_url")?.TrimEnd('/') == Text(provider, "base_url")?.TrimEnd('/'))
                localProviders[id] = 0;
    }

    private void RememberThread(JsonObject result)
    {
        if (result["thread"] is not JsonObject thread || Text(thread, "id") is not { } id) return;
        var providerId = Text(result, "modelProvider") ?? Text(thread, "modelProvider");
        if (providerId is null) return;
        var model = Text(result, "model") ?? Text(thread, "model");
        if (model is null && threads.TryGetValue(id, out var previous)) model = previous.Model;
        threads[id] = new ThreadState(providerId, model);
    }

    private void ConfigureLocal(JsonObject parameters, string providerId, string? model)
    {
        if (provider is null) return;
        parameters["modelProvider"] = providerId;
        var configuration = parameters["config"] as JsonObject;
        if (configuration is null) { configuration = new JsonObject(); parameters["config"] = configuration; }
        configuration["model_provider"] = providerId;
        if (model is not null) configuration["model"] = model;
        configuration[$"model_providers.{providerId}"] = provider.DeepClone();
        var entry = model is not null && models.TryGetValue(model, out var exact) ? exact : models.Values.First();
        var window = entry["contextWindow"]!.GetValue<long>();
        configuration["model_context_window"] = window;
        // The official user default can be larger than the local context.
        // Keep the local compaction threshold within its declared capacity.
        var metadata = entry["catalogModel"]!;
        var percentage = metadata["effective_context_window_percent"]?.GetValue<int>() ?? 95;
        configuration["model_auto_compact_token_limit"] = metadata["auto_compact_token_limit"]?.DeepClone() ?? JsonValue.Create(window * percentage / 100);
    }

    private void RejectCollision(string model)
    {
        if (upstreamModels.ContainsKey(model)) throw new RpcException(-32602, "Local and upstream catalogs contain the same model ID; select an unambiguous local profile.");
    }
    private static RpcException CrossProviderError() => new(-32602,
        "此模型与当前任务使用不同的模型服务。请新建任务后选择它；当前任务和历史保持原连接。两个本地 Qwen 模型可在本地任务中切换。");
    private static string? SelectedModel(JsonObject? parameters) =>
        Text(parameters?["collaborationMode"]?["settings"], "model") ?? Text(parameters, "model");
    private static string? Text(JsonNode? node, string key) => node is JsonObject obj && obj[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}
