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
    private readonly ConcurrentDictionary<string, byte> publicSummaryProviders = new();
    private readonly PublicSummaryProjection publicSummaries = new();
    private readonly ConcurrentDictionary<string, byte> deepSeekReasoningProviders = new();
    private readonly ConcurrentDictionary<string, DeepSeekTurnState> deepSeekTurns = new();
    private readonly string catalogPath;
    public string? StartupCatalogPath => models.Count > 0 ? catalogPath : null;
    private sealed record ThreadState(string Provider, string? Model);
    private sealed class DeepSeekTurnState
    {
        public object Gate { get; } = new();
        public JsonObject? LastReasoningStartedItem { get; set; }
        public HashSet<string> ActiveReasoningIds { get; } = new(StringComparer.Ordinal);
        public HashSet<string> OpenedSummaryParts { get; } = new(StringComparer.Ordinal);
        public HashSet<string> StartedMessageIds { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, SortedDictionary<long, StringBuilder>> StreamedSummaries { get; } = new(StringComparer.Ordinal);
        public JsonObject? ActiveKeepAliveItem { get; set; }
        public string? KeepAliveAnchorMessageId { get; set; }
        public string? LastAssistantMessageId { get; set; }
        public bool AssistantMessageSeen { get; set; }
    }

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
            var profileId = Text(entry, "profileId");
            if (profileId is "codex-glm-5-3" or "codex-glm-5-3-flash" or "codex-deepseek-flash")
                rawReasoningProviders[routeProvider] = 0;
            if (profileId == "codex-deepseek-flash")
                deepSeekReasoningProviders[routeProvider] = 0;
            if (rawReasoningProviders.ContainsKey(routeProvider) &&
                ((Text(entry["catalogModel"], "base_instructions") ?? "").Contains(PublicSummaryProjection.PolicyMarker, StringComparison.Ordinal) ||
                 (Text(entry["catalogModel"]?["model_messages"], "instructions_template") ?? "").Contains(PublicSummaryProjection.PolicyMarker, StringComparison.Ordinal)))
                publicSummaryProviders[routeProvider] = 0;
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
            if (providerId is not null && publicSummaryProviders.ContainsKey(providerId))
                PublicSummaryProjection.ProjectHistory(result);
            else if (providerId is not null && rawReasoningProviders.ContainsKey(providerId))
                PromoteRawReasoning(result);
        }
        // Paginated history has no provider field; bind it to the already identified thread.
        // Reuse the same projection as full thread reads, without altering native summaries.
        if ((method is "thread/turns/list" or "thread/items/list") &&
            Text(originalParams, "threadId") is { } historyThreadId &&
            threads.TryGetValue(historyThreadId, out var historyState) &&
            rawReasoningProviders.ContainsKey(historyState.Provider))
        {
            if (publicSummaryProviders.ContainsKey(historyState.Provider)) PublicSummaryProjection.ProjectHistory(result);
            else PromoteRawReasoning(result);
        }
        if (method == "thread/settings/update" && Text(originalParams, "threadId") is { } threadId &&
            threads.TryGetValue(threadId, out var state) && SelectedModel(originalParams) is { } selected)
            threads[threadId] = state with { Model = selected };
        if (method == "config/read") RememberProviders(result["config"]);
    }

    public IReadOnlyList<JsonObject>? NormalizeNotifications(JsonObject message)
    {
        if (message["params"] is not JsonObject parameters ||
            Text(parameters, "threadId") is not { } threadId ||
            !threads.TryGetValue(threadId, out var state) ||
            !rawReasoningProviders.ContainsKey(state.Provider)) return null;

        if (publicSummaryProviders.ContainsKey(state.Provider))
        {
            var output = new List<JsonObject>();
            foreach (var projected in publicSummaries.Normalize(message, threadId))
            {
                // Reuse the proven summary continuity/keep-alive transport.
                var normalized = NormalizeDeepSeekNotification(projected, projected["params"]!.AsObject(), threadId);
                if (normalized is not null) output.AddRange(normalized);
                else output.Add(projected);
            }
            return output;
        }
        if (deepSeekReasoningProviders.ContainsKey(state.Provider))
            return NormalizeDeepSeekNotification(message, parameters, threadId);

        return NormalizeRawReasoningNotification(message, parameters)
            ? new[] { message }
            : null;
    }

    // Retained for focused router callers that only expect one immediate event.
    public bool NormalizeNotification(JsonObject message)
    {
        var normalized = NormalizeNotifications(message);
        return normalized is { Count: 1 } && ReferenceEquals(normalized[0], message);
    }

    private IReadOnlyList<JsonObject>? NormalizeDeepSeekNotification(
        JsonObject message, JsonObject parameters, string threadId)
    {
        var method = Text(message, "method");
        var turnId = NotificationTurnId(parameters);
        if (turnId is null)
            return NormalizeRawReasoningNotification(message, parameters) ? new[] { message } : null;

        var turnKey = threadId + "\n" + turnId;
        if (method == "item/started" && parameters["item"] is JsonObject startedItem)
        {
            var itemType = Text(startedItem, "type");
            if (itemType == "reasoning" && Text(startedItem, "id") is { } reasoningItemId)
                return NormalizeDeepSeekReasoningStarted(message, threadId, turnId, turnKey, startedItem, reasoningItemId);
            if (IsAgentMessageItem(itemType) && Text(startedItem, "id") is { } messageItemId)
                return NormalizeDeepSeekAgentMessageStarted(message, threadId, turnId, turnKey, messageItemId);
        }

        if (method == "item/reasoning/textDelta" &&
            Text(parameters, "itemId") is { } rawItemId &&
            Text(parameters, "delta") is { })
        {
            return NormalizeDeepSeekReasoningDelta(
                message, parameters, threadId, turnId, turnKey,
                rawItemId, Integer(parameters["contentIndex"]), removeContentIndex: true);
        }

        if (method == "item/reasoning/summaryPartAdded" &&
            Text(parameters, "itemId") is { } summaryPartItemId)
        {
            var turnState = deepSeekTurns.GetOrAdd(turnKey, _ => new DeepSeekTurnState());
            lock (turnState.Gate)
                turnState.OpenedSummaryParts.Add(DeepSeekSummaryPartKey(summaryPartItemId, Integer(parameters["summaryIndex"])));
            return null;
        }

        if (method == "item/reasoning/summaryTextDelta" &&
            Text(parameters, "itemId") is { } summaryItemId &&
            Text(parameters, "delta") is { })
        {
            return NormalizeDeepSeekReasoningDelta(
                message, parameters, threadId, turnId, turnKey,
                summaryItemId, Integer(parameters["summaryIndex"]), removeContentIndex: false);
        }

        if (method == "item/agentMessage/delta" && Text(parameters, "itemId") is { } deltaMessageId)
            return NormalizeDeepSeekAgentMessageDelta(message, threadId, turnId, turnKey, deltaMessageId);

        if (method == "item/completed" && parameters["item"] is JsonObject completedItem)
        {
            var itemType = Text(completedItem, "type");
            if (itemType == "reasoning" && Text(completedItem, "id") is { } completedReasoningId)
                return NormalizeDeepSeekReasoningCompletion(message, threadId, turnId, turnKey, completedItem, completedReasoningId);
            if (IsAgentMessageItem(itemType) && Text(completedItem, "id") is { } completedMessageId)
                return NormalizeDeepSeekAgentMessageCompletion(message, threadId, turnId, turnKey, completedMessageId);
        }

        if (method is "turn/completed" or "turn/failed" or "turn/cancelled")
            return NormalizeDeepSeekTurnTerminal(message, threadId, turnId, turnKey);

        return NormalizeRawReasoningNotification(message, parameters) ? new[] { message } : null;
    }

    private IReadOnlyList<JsonObject> NormalizeDeepSeekReasoningStarted(
        JsonObject message,
        string threadId,
        string turnId,
        string turnKey,
        JsonObject startedItem,
        string reasoningItemId)
    {
        var turnState = deepSeekTurns.GetOrAdd(turnKey, _ => new DeepSeekTurnState());
        var output = new List<JsonObject> { message };
        lock (turnState.Gate)
        {
            turnState.LastReasoningStartedItem = (JsonObject)startedItem.DeepClone();
            turnState.ActiveReasoningIds.Add(reasoningItemId);

            // A real reasoning item always takes over before the structural keep-alive closes.
            // This ordering guarantees that the Desktop never sees a frame with no active reasoning.
            if (turnState.ActiveKeepAliveItem is not null)
            {
                output.Add(CreateDeepSeekKeepAliveCompletion(
                    message, threadId, turnId, turnState.ActiveKeepAliveItem));
                turnState.ActiveKeepAliveItem = null;
                turnState.KeepAliveAnchorMessageId = null;
            }
        }
        return output;
    }

    private IReadOnlyList<JsonObject>? NormalizeDeepSeekAgentMessageStarted(
        JsonObject message,
        string threadId,
        string turnId,
        string turnKey,
        string messageItemId)
    {
        var turnState = deepSeekTurns.GetOrAdd(turnKey, _ => new DeepSeekTurnState());
        lock (turnState.Gate)
        {
            turnState.AssistantMessageSeen = true;
            turnState.LastAssistantMessageId = messageItemId;
            turnState.StartedMessageIds.Add(messageItemId);
            if (turnState.LastReasoningStartedItem is null) return null;

            // Desktop selects the last item by position, not by outstanding completion count.
            // A resumed/pre-filled start must not expose text before its continuation exists.
            var initialText = Text(message["params"]?["item"], "text") ?? "";
            var start = initialText.Length == 0 ? message : (JsonObject)message.DeepClone();
            if (initialText.Length != 0) start["params"]!["item"]!["text"] = "";
            var output = new List<JsonObject> { start };
            RotateDeepSeekKeepAlive(message, output, turnState, threadId, turnId, messageItemId);
            if (initialText.Length != 0)
                output.Add(CreateDeepSeekNotification(message, "item/agentMessage/delta", new JsonObject
                {
                    ["threadId"] = threadId, ["turnId"] = turnId,
                    ["itemId"] = messageItemId, ["delta"] = initialText
                }));
            return output;
        }
    }

    private IReadOnlyList<JsonObject>? NormalizeDeepSeekAgentMessageDelta(
        JsonObject message,
        string threadId,
        string turnId,
        string turnKey,
        string messageItemId)
    {
        if (!deepSeekTurns.TryGetValue(turnKey, out var turnState)) return null;
        lock (turnState.Gate)
        {
            turnState.AssistantMessageSeen = true;
            turnState.LastAssistantMessageId = messageItemId;
            if (turnState.LastReasoningStartedItem is null)
                return null;
            if (turnState.ActiveKeepAliveItem is not null &&
                turnState.KeepAliveAnchorMessageId == messageItemId)
                return null;

            var output = new List<JsonObject>();
            RotateDeepSeekKeepAlive(message, output, turnState, threadId, turnId, messageItemId);
            output.Add(message);
            return output;
        }
    }

    private IReadOnlyList<JsonObject>? NormalizeDeepSeekAgentMessageCompletion(
        JsonObject message,
        string threadId,
        string turnId,
        string turnKey,
        string messageItemId)
    {
        if (!deepSeekTurns.TryGetValue(turnKey, out var turnState)) return null;
        lock (turnState.Gate)
        {
            turnState.AssistantMessageSeen = true;
            turnState.LastAssistantMessageId = messageItemId;
            if (turnState.LastReasoningStartedItem is null ||
                (turnState.ActiveKeepAliveItem is not null && turnState.KeepAliveAnchorMessageId == messageItemId))
                return null;

            var output = new List<JsonObject>();
            if (turnState.StartedMessageIds.Add(messageItemId))
            {
                // Completion-only messages still need their real position established while empty.
                // Insert the continuation before non-empty output can be promoted to a final answer.
                var started = (JsonObject)message["params"]!["item"]!.DeepClone();
                started["text"] = "";
                output.Add(CreateDeepSeekNotification(message, "item/started", new JsonObject
                {
                    ["threadId"] = threadId, ["turnId"] = turnId, ["item"] = started
                }));
            }
            RotateDeepSeekKeepAlive(message, output, turnState, threadId, turnId, messageItemId);
            output.Add(message);
            return output;
        }
    }

    private IReadOnlyList<JsonObject> NormalizeDeepSeekReasoningDelta(
        JsonObject message,
        JsonObject parameters,
        string threadId,
        string turnId,
        string turnKey,
        string sourceItemId,
        long sourceIndex,
        bool removeContentIndex)
    {
        var turnState = deepSeekTurns.GetOrAdd(turnKey, _ => new DeepSeekTurnState());
        var output = new List<JsonObject>(2);
        lock (turnState.Gate)
        {
            if (!turnState.StreamedSummaries.TryGetValue(sourceItemId, out var parts))
                turnState.StreamedSummaries[sourceItemId] = parts = new();
            if (!parts.TryGetValue(sourceIndex, out var text)) parts[sourceIndex] = text = new();
            text.Append(Text(parameters, "delta"));
            var partKey = DeepSeekSummaryPartKey(sourceItemId, sourceIndex);
            if (turnState.OpenedSummaryParts.Add(partKey))
            {
                output.Add(CreateDeepSeekNotification(
                    message,
                    "item/reasoning/summaryPartAdded",
                    new JsonObject
                    {
                        ["threadId"] = threadId,
                        ["turnId"] = turnId,
                        ["itemId"] = sourceItemId,
                        ["summaryIndex"] = sourceIndex
                    }));
            }

            if (removeContentIndex)
            {
                message["method"] = "item/reasoning/summaryTextDelta";
                parameters["summaryIndex"] = sourceIndex;
                parameters.Remove("contentIndex");
            }
            output.Add(message);
            return output;
        }
    }

    private IReadOnlyList<JsonObject> NormalizeDeepSeekReasoningCompletion(
        JsonObject message,
        string threadId,
        string turnId,
        string turnKey,
        JsonObject completedItem,
        string reasoningItemId)
    {
        var turnState = deepSeekTurns.GetOrAdd(turnKey, _ => new DeepSeekTurnState());
        var output = new List<JsonObject>(2);
        lock (turnState.Gate)
        {
            turnState.ActiveReasoningIds.Remove(reasoningItemId);
            PromoteRawReasoning(completedItem);
            if (turnState.StreamedSummaries.TryGetValue(reasoningItemId, out var streamed) &&
                (completedItem["summary"] is not JsonArray summary || !HasReasoningText(summary)))
            {
                // An encrypted/empty terminal projection must not erase public streamed text.
                var recovered = new JsonArray();
                foreach (var part in streamed.OrderBy(pair => pair.Key)) recovered.Add(part.Value.ToString());
                completedItem["summary"] = recovered;
            }

            // If assistant output is already on screen, insert an empty structural reasoning
            // item before completing the real reasoning item. It carries no invented text; it
            // only preserves the same "reasoning is still present while output streams" shape
            // that Codex Desktop already renders stably for GLM.
            if (turnState.ActiveReasoningIds.Count == 0 &&
                turnState.AssistantMessageSeen &&
                turnState.LastReasoningStartedItem is not null &&
                turnState.ActiveKeepAliveItem is null)
            {
                var anchor = turnState.LastAssistantMessageId ?? "";
                StartDeepSeekKeepAlive(message, output, turnState, threadId, turnId, anchor);
            }

            output.Add(message);
            return output;
        }
    }

    private IReadOnlyList<JsonObject>? NormalizeDeepSeekTurnTerminal(
        JsonObject message,
        string threadId,
        string turnId,
        string turnKey)
    {
        if (!deepSeekTurns.TryRemove(turnKey, out var turnState)) return null;
        lock (turnState.Gate)
        {
            if (turnState.ActiveKeepAliveItem is null) return null;
            return new[]
            {
                CreateDeepSeekKeepAliveCompletion(message, threadId, turnId, turnState.ActiveKeepAliveItem),
                message
            };
        }
    }

    private static void RotateDeepSeekKeepAlive(
        JsonObject source,
        List<JsonObject> output,
        DeepSeekTurnState turnState,
        string threadId,
        string turnId,
        string anchorMessageId)
    {
        var previous = turnState.ActiveKeepAliveItem;
        StartDeepSeekKeepAlive(source, output, turnState, threadId, turnId, anchorMessageId);
        if (previous is not null)
            output.Add(CreateDeepSeekKeepAliveCompletion(source, threadId, turnId, previous));
    }

    private static void StartDeepSeekKeepAlive(
        JsonObject source,
        List<JsonObject> output,
        DeepSeekTurnState turnState,
        string threadId,
        string turnId,
        string anchorMessageId)
    {
        if (turnState.LastReasoningStartedItem is null) return;
        var keepAliveItem = (JsonObject)turnState.LastReasoningStartedItem.DeepClone();
        keepAliveItem["id"] = "__aicli_deepseek_keepalive_" + Guid.NewGuid().ToString("N");
        keepAliveItem["type"] = "reasoning";
        keepAliveItem["summary"] = new JsonArray();
        keepAliveItem["content"] = new JsonArray();
        keepAliveItem.Remove("encrypted_content");
        keepAliveItem.Remove("encryptedContent");

        turnState.ActiveKeepAliveItem = keepAliveItem;
        turnState.KeepAliveAnchorMessageId = anchorMessageId;
        output.Add(CreateDeepSeekNotification(
            source,
            "item/started",
            new JsonObject
            {
                ["threadId"] = threadId,
                ["turnId"] = turnId,
                ["item"] = keepAliveItem.DeepClone()
            }));
    }

    private static JsonObject CreateDeepSeekKeepAliveCompletion(
        JsonObject source,
        string threadId,
        string turnId,
        JsonObject keepAliveItem) =>
        CreateDeepSeekNotification(
            source,
            "item/completed",
            new JsonObject
            {
                ["threadId"] = threadId,
                ["turnId"] = turnId,
                ["item"] = keepAliveItem.DeepClone()
            });

    private static string DeepSeekSummaryPartKey(string itemId, long summaryIndex) =>
        itemId + "\n" + summaryIndex.ToString(System.Globalization.CultureInfo.InvariantCulture);

    private static bool IsAgentMessageItem(string? itemType) =>
        itemType is "agentMessage" or "assistantMessage" or "assistant-message";

    private static JsonObject CreateDeepSeekNotification(
        JsonObject source,
        string method,
        JsonObject parameters)
    {
        var notification = new JsonObject
        {
            ["method"] = method,
            ["params"] = parameters
        };
        if (source["jsonrpc"] is { } jsonRpc)
            notification["jsonrpc"] = jsonRpc.DeepClone();
        return notification;
    }

    private static bool NormalizeRawReasoningNotification(JsonObject message, JsonObject parameters)
    {
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

    private static string? NotificationTurnId(JsonObject parameters) =>
        Text(parameters, "turnId") ?? Text(parameters["turn"], "id");
    private static long Integer(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<long>(out var number) ? number : 0L;

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
        if (Text(entry, "providerId") == "aicli_google_antigravity")
        {
            // Standard Responses summary items are already native summaries;
            // Gemini needs no GLM raw-content projection or DeepSeek keepalive.
            configuration["model_reasoning_summary"] = "detailed";
            configuration["model_reasoning_effort"] = Text(entry, "defaultEffort") ?? "high";
            // Replace only unavailable hosted search with a real Codex-managed
            // MCP tool. This adapter never executes search on the model's behalf.
            configuration["web_search"] = "disabled";
            if (entry["managedPublicWebSearch"] is not JsonObject search)
                throw new RpcException(-32602, "Gemini 的 Codex 搜索工具配置缺失；未开始模型请求。");
            configuration["mcp_servers.aicli_public_web_search"] = search.DeepClone();
        }
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
