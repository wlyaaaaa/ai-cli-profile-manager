using System.Collections.Concurrent;
using System.Text.Json.Nodes;

// Display-only projection. The upstream engine remains the owner of every real
// message and reasoning item; this class never writes its transcript or calls a model.
public sealed class PublicSummaryProjection
{
    public const string PolicyMarker = "# AICLI public progress summary v1";
    public const string ItemPrefix = "aicli-public-summary:";
    private readonly ConcurrentDictionary<string, TurnState> turns = new();
    private sealed class TurnState
    {
        public object Gate { get; } = new();
        public JsonObject? Pending { get; set; }
        public Dictionary<string, JsonObject> Summaries { get; } = new(StringComparer.Ordinal);
    }
    private static string? Text(JsonNode? node, string key) =>
        node?[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    private static bool IsMessage(string? type) => type is "agentMessage" or "agent_message";
    private static bool IsTool(string? type) => type is "commandExecution" or "dynamicToolCall"
        or "mcpToolCall" or "fileChange" or "webSearch" or "imageView" or "collabAgentToolCall";
    private static bool IsFinal(JsonObject item) => Text(item, "phase") is "final_answer" or "final";
    private static JsonObject SummaryItem(JsonObject message) => new()
    {
        ["type"] = "reasoning", ["id"] = ItemPrefix + Text(message, "id"),
        ["summary"] = new JsonArray(Text(message, "text") ?? ""), ["content"] = new JsonArray()
    };
    private static JsonObject Event(JsonObject source, string method, JsonObject parameters)
    {
        var output = (JsonObject)source.DeepClone();
        output.Remove("id");
        output["method"] = method;
        output["params"] = parameters;
        return output;
    }
    private static void Emit(JsonObject source, JsonObject item, TurnState state,
        string threadId, string turnId, List<JsonObject> output)
    {
        var id = Text(item, "id");
        var text = Text(item, "text");
        if (id is null || string.IsNullOrWhiteSpace(text) || IsFinal(item) || state.Summaries.ContainsKey(id)) return;
        var complete = SummaryItem(item);
        state.Summaries[id] = complete;
        var started = (JsonObject)complete.DeepClone();
        started["summary"] = new JsonArray();
        output.Add(Event(source, "item/started", new JsonObject
        { ["threadId"] = threadId, ["turnId"] = turnId, ["item"] = started }));
        output.Add(Event(source, "item/reasoning/summaryPartAdded", new JsonObject
        { ["threadId"] = threadId, ["turnId"] = turnId, ["itemId"] = Text(complete, "id"), ["summaryIndex"] = 0 }));
        output.Add(Event(source, "item/reasoning/summaryTextDelta", new JsonObject
        { ["threadId"] = threadId, ["turnId"] = turnId, ["itemId"] = Text(complete, "id"), ["summaryIndex"] = 0, ["delta"] = text }));
    }

    public IReadOnlyList<JsonObject> Normalize(JsonObject message, string threadId)
    {
        if (message["params"] is not JsonObject parameters) return new[] { message };
        var method = Text(message, "method") ?? "";
        var turnId = Text(parameters, "turnId") ?? Text(parameters["turn"], "id");
        if (method is "thread/closed" or "thread/archived")
        {
            foreach (var key in turns.Keys.Where(k => k.StartsWith(threadId + "\n", StringComparison.Ordinal)))
                turns.TryRemove(key, out _);
            return new[] { message };
        }
        // The public-summary feature is additive. Preserve the pre-existing live reasoning
        // stream exactly; Router keeps handling it with the established transient display path.
        // ProjectHistory below still omits native reasoning, so it never becomes persistent history.
        if ((method is "item/started" or "item/completed") && Text(parameters["item"], "type") == "reasoning")
            return new[] { message };
        if (method.StartsWith("item/reasoning/", StringComparison.Ordinal))
            return new[] { message };
        if (turnId is null) return new[] { message };
        var keyForTurn = threadId + "\n" + turnId;
        var state = turns.GetOrAdd(keyForTurn, _ => new TurnState());
        lock (state.Gate)
        {
            var output = new List<JsonObject>();
            if (method is "turn/completed" or "turn/failed" or "turn/cancelled")
            {
                foreach (var item in state.Summaries.Values)
                    output.Add(Event(message, "item/completed", new JsonObject
                    { ["threadId"] = threadId, ["turnId"] = turnId, ["item"] = item.DeepClone() }));
                turns.TryRemove(keyForTurn, out _);
                output.Add(message);
                return output;
            }
            // GLM can omit phase. A following tool proves the previous completed
            // message was progress. Never guess from wording, length or message position.
            if (method == "item/started" && IsTool(Text(parameters["item"], "type")) && state.Pending is not null)
            {
                Emit(message, state.Pending, state, threadId, turnId, output);
                state.Pending = null;
            }
            output.Add(message); // Preserve all real user-visible messages, including finals.
            if (method == "item/completed" && parameters["item"] is JsonObject completed && IsMessage(Text(completed, "type")))
            {
                if (Text(completed, "phase") == "commentary")
                {
                    Emit(message, completed, state, threadId, turnId, output);
                    state.Pending = null;
                }
                else state.Pending = IsFinal(completed) ? null : (JsonObject)completed.DeepClone();
            }
            return output;
        }
    }

    // Reconstruct from the engine's own public messages; no second history store.
    // A phase-less message at a page boundary is left alone until evidence of a
    // following tool is available. Its original transcript text is never removed.
    public static void ProjectHistory(JsonNode? node)
    {
        if (node is JsonObject obj)
        {
            foreach (var property in obj.ToArray()) ProjectHistory(property.Value);
            return;
        }
        if (node is not JsonArray array) return;
        var items = array.OfType<JsonObject>().ToArray();
        if (!items.Any(item => IsMessage(Text(item, "type"))))
        {
            foreach (var child in array) ProjectHistory(child);
            return;
        }
        var progress = new HashSet<string>(StringComparer.Ordinal);
        JsonObject? pending = null;
        foreach (var item in items)
        {
            var type = Text(item, "type");
            if (IsMessage(type))
            {
                if (Text(item, "phase") == "commentary" && Text(item, "id") is { } id) progress.Add(id);
                pending = IsFinal(item) ? null : item;
            }
            else if (IsTool(type) && pending is not null)
            {
                if (Text(pending, "id") is { } id) progress.Add(id);
                pending = null;
            }
            else if (type is "userMessage" or "user_message") pending = null;
        }
        if (progress.Count == 0) return;
        var projected = new List<JsonNode?>();
        foreach (var child in array)
        {
            if (child is JsonObject item && Text(item, "type") == "reasoning") continue;
            projected.Add(child?.DeepClone());
            if (child is JsonObject message && Text(message, "id") is { } id && progress.Contains(id)
                && !string.IsNullOrWhiteSpace(Text(message, "text")))
                projected.Add(SummaryItem(message));
        }
        array.Clear();
        foreach (var child in projected) array.Add(child);
    }
}
