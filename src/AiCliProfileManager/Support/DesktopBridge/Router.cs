using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

// Only model discovery and managed thread configuration belong to this adapter.
// The original Codex engine owns authentication, history, tools and execution.
public sealed class ModelRouter
{
    private const string LocalProviderId = "aicli_desktop_local";
    private readonly Dictionary<string, JsonObject> models = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> modelProviders = new(StringComparer.Ordinal);
    private readonly Dictionary<string, JsonObject> providers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, ThreadState> threads = new();
    private readonly ConcurrentDictionary<string, byte> upstreamModels = new();
    private readonly ConcurrentDictionary<string, byte> managedProviders = new();
    private readonly ConcurrentDictionary<string, byte> rawReasoningProviders = new();
    private readonly string catalogPath;
    public string? StartupCatalogPath => models.Count > 0 ? catalogPath : null;
    private sealed record ThreadState(string Provider, string? Model);

    public ModelRouter(JsonObject plan)
    {
        var codexHome = Text(plan, "codexHome") ?? "";
        foreach (var value in plan["models"]?.AsArray() ?? [])
        {
            if (value is not JsonObject entry || Text(entry, "model") is not { } model) continue;
            models.Add(model, (JsonObject)entry.DeepClone());
            var routeProvider = Text(entry, "routeProviderId") ?? Text(entry, "providerId")
                ?? throw new InvalidOperationException("A managed desktop model has no provider ID.");
            if (entry["provider"] is not JsonObject definition)
                throw new InvalidOperationException("A managed desktop model has no provider definition.");
            modelProviders[model] = routeProvider;
            managedProviders[routeProvider] = 0;
            if (Text(entry, "profileId") is "codex-glm-5-3" or "codex-glm-5-3-flash" or "codex-deepseek-flash")
                rawReasoningProviders[routeProvider] = 0;
            var normalized = (JsonObject)definition.DeepClone();
            if (routeProvider == LocalProviderId) normalized["name"] = "AICLI local models";
            if (providers.TryGetValue(routeProvider, out var existing) && !JsonNode.DeepEquals(existing, normalized))
                throw new InvalidOperationException("Desktop models in one provider group must share one definition.");
            providers[routeProvider] = normalized;
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
            modelProviders[alias] = modelProviders[canonical];
        }
        if (models.Count == 0) { catalogPath = ""; return; }
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
                var providerId = modelProviders[selected];
                ConfigureManaged(parameters, providerId, providerId, selected);
                parameters["allowProviderModelFallback"] = false;
            }
            return request;
        }
        if (method is not ("thread/resume" or "thread/fork" or "thread/settings/update" or "turn/start")) return request;
        var threadId = Text(parameters, "threadId");
        if (threadId is null) return request;
        var state = await ReadThreadAsync(threadId, callUpstream);
        var providerGroup = await ResolveManagedProviderAsync(state.Provider, callUpstream);
        if (selected is not null && models.ContainsKey(selected))
        {
            RejectCollision(selected);
            if (providerGroup is null || modelProviders[selected] != providerGroup) throw CrossProviderError();
        }
        else if (providerGroup is not null && selected is not null && selected != state.Model)
        {
            // Persisted managed threads keep their provider. Never send an
            // official or cross-provider selection to the wrong service.
            throw CrossProviderError();
        }
        if (providerGroup is not null && (method is "thread/resume" or "thread/fork"))
        {
            ConfigureManaged(parameters, state.Provider, providerGroup, selected ?? state.Model);
        }
        return request;
    }

    public void AfterResponse(string method, JsonObject? originalParams, JsonObject response)
    {
        if (response["result"] is not JsonObject result) return;
        if (method is "thread/start" or "thread/resume" or "thread/read" or "thread/fork")
        {
            RememberThread(result);
            var providerId = Text(result, "modelProvider") ?? Text(result["thread"], "modelProvider");
            if (providerId is not null && rawReasoningProviders.ContainsKey(providerId))
                PromoteRawReasoning(result);
        }
        if (method == "thread/settings/update" && Text(originalParams, "threadId") is { } threadId &&
            threads.TryGetValue(threadId, out var state) && SelectedModel(originalParams) is { } selected)
            threads[threadId] = state with { Model = selected };
        if (method == "config/read") RememberProviders(result["config"]);
    }

    public bool NormalizeNotification(JsonObject message)
    {
        if (message["params"] is not JsonObject parameters ||
            Text(parameters, "threadId") is not { } threadId ||
            !threads.TryGetValue(threadId, out var state) ||
            !rawReasoningProviders.ContainsKey(state.Provider)) return false;

        var method = Text(message, "method");
        if (method == "item/reasoning/textDelta")
        {
            message["method"] = "item/reasoning/summaryTextDelta";
            parameters["summaryIndex"] = parameters["contentIndex"]?.DeepClone() ?? JsonValue.Create(0);
            parameters.Remove("contentIndex");
            return true;
        }
        return PromoteRawReasoning(parameters);
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

    private async Task<string?> ResolveManagedProviderAsync(string id, Func<string, JsonObject, Task<JsonObject>> call)
    {
        if (managedProviders.ContainsKey(id)) return id;
        if (!id.StartsWith("aicli_ollama_", StringComparison.Ordinal)) return null;
        var response = await call("config/read", new JsonObject { ["includeLayers"] = false, ["cwd"] = null });
        RememberProviders(response["result"]?["config"]);
        return managedProviders.ContainsKey(id) ? LocalProviderId : null;
    }

    private void RememberProviders(JsonNode? configuration)
    {
        if (!providers.TryGetValue(LocalProviderId, out var localProvider) ||
            configuration?["model_providers"] is not JsonObject definitions) return;
        foreach (var (id, definition) in definitions)
            if (id.StartsWith("aicli_ollama_", StringComparison.Ordinal) &&
                Text(definition, "base_url")?.TrimEnd('/') == Text(localProvider, "base_url")?.TrimEnd('/'))
                managedProviders[id] = 0;
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

    private void ConfigureManaged(JsonObject parameters, string providerId, string providerGroup, string? model)
    {
        if (!providers.TryGetValue(providerGroup, out var provider)) return;
        parameters["modelProvider"] = providerId;
        var configuration = parameters["config"] as JsonObject;
        if (configuration is null) { configuration = new JsonObject(); parameters["config"] = configuration; }
        configuration["model_provider"] = providerId;
        if (model is not null) configuration["model"] = model;
        configuration[$"model_providers.{providerId}"] = provider.DeepClone();
        var entry = model is not null && models.TryGetValue(model, out var exact)
            ? exact
            : models.Values.First(value => modelProviders[Text(value, "model")!] == providerGroup);
        var window = entry["contextWindow"]!.GetValue<long>();
        configuration["model_context_window"] = window;
        // The official user default can differ from a managed provider.
        // Keep compaction within the selected model's declared capacity.
        var metadata = entry["catalogModel"]!;
        configuration["model_auto_compact_token_limit"] = metadata["auto_compact_token_limit"]?.DeepClone() ?? JsonValue.Create(window * 90 / 100);
    }

    private void RejectCollision(string model)
    {
        if (upstreamModels.ContainsKey(model)) throw new RpcException(-32602, "Managed and upstream catalogs contain the same model ID; select an unambiguous model.");
    }
    private static RpcException CrossProviderError() => new(-32602,
        "此模型与当前任务使用不同的模型服务。请新建任务后选择它；当前任务和历史保持原连接。同一服务内的模型仍可切换。");
    private static string? SelectedModel(JsonObject? parameters) =>
        Text(parameters?["collaborationMode"]?["settings"], "model") ?? Text(parameters, "model");
    private static bool PromoteRawReasoning(JsonNode? node)
    {
        var changed = false;
        if (node is JsonObject obj)
        {
            if (Text(obj, "type") == "reasoning" &&
                (obj["summary"] is not JsonArray summary || !HasReasoningText(summary)) &&
                obj["content"] is JsonArray content)
            {
                var promoted = new JsonArray();
                foreach (var part in content)
                {
                    if (ReasoningText(part) is { Length: > 0 } text) promoted.Add(text);
                }
                if (promoted.Count > 0)
                {
                    obj["summary"] = promoted;
                    changed = true;
                }
            }
            foreach (var child in obj.ToList()) changed |= PromoteRawReasoning(child.Value);
        }
        else if (node is JsonArray array)
        {
            foreach (var child in array) changed |= PromoteRawReasoning(child);
        }
        return changed;
    }
    private static bool HasReasoningText(JsonArray parts) =>
        parts.Any(part => ReasoningText(part) is { Length: > 0 });
    private static string? ReasoningText(JsonNode? part)
    {
        if (part is JsonValue value && value.TryGetValue<string>(out var text)) return text;
        return Text(part, "text");
    }
    private static string? Text(JsonNode? node, string key) => node is JsonObject obj && obj[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}
