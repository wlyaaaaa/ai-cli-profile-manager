using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AiCli.GeminiBridge;

public sealed class BridgeException(string code, int status = 400) : Exception(code)
{
    public string Code { get; } = code;
    public int Status { get; } = status;
    public string[] Hints { get; init; } = [];
    public bool RejectedBeforeOutput { get; init; }
    public TerminalEvidence? Evidence { get; init; }
}

public static class JsonValueReader
{
    public static string? Text(JsonNode? node, string key) =>
        node is JsonObject o && o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    public static string RequiredText(JsonNode? node, string key) =>
        Text(node, key) ?? throw new BridgeException("invalid_" + key);
    public static bool Boolean(JsonNode? node, string key, bool fallback) =>
        node is JsonObject o && o[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;
    public static long Integer(JsonNode? node, string key)
    {
        if (node is JsonObject o && o[key] is JsonValue v)
        {
            if (v.TryGetValue<long>(out var number) && number >= 0) return number;
            if (v.TryGetValue<int>(out var small) && small >= 0) return small;
        }
        throw new BridgeException("invalid_" + key, 502);
    }
    public static string Serialize(JsonNode node) => node.ToJsonString();
}

public sealed record VirtualTool(int Index, string Name, string? Namespace, string Kind, JsonObject Definition)
{
    public JsonObject Packet() => new()
    {
        ["tool_index"] = Index,
        ["name"] = Name,
        ["namespace"] = Namespace,
        ["kind"] = Kind,
        ["definition"] = Definition.DeepClone(),
        ["argument_encoding"] = Kind == "custom"
            ? "arguments must be a JSON object containing exactly one string property named input. Do not JSON-stringify that object. Codex receives the input string."
            : "arguments must be a JSON object matching this tool's parameters, not a string containing JSON. The bridge performs native Codex serialization."
    };
}

public sealed record CodexRequest(
    string Model, string Effort, JsonObject Original, JsonArray Input,
    IReadOnlyList<VirtualTool> Tools, bool Parallel, bool Stream, string? Affinity, GeminiSelection? Selection = null)
{
    public static string[] Efforts => GeminiModelSet.Initial.Models.SelectMany(m=>m.Efforts.Select(e=>e.Effort)).Distinct(StringComparer.Ordinal).ToArray();
    public string EffectiveModel => (Selection ?? GeminiModelSet.Initial.Resolve(Model,Effort)).ExactModel;
    public string CliEffort => (Selection ?? GeminiModelSet.Initial.Resolve(Model,Effort)).CliEffort;
    public static CodexRequest Parse(JsonObject request,GeminiModelSet? modelSet=null)
    {
        var model = JsonValueReader.RequiredText(request, "model");
        var selected=(modelSet??GeminiModelSet.Initial).Resolve(model,JsonValueReader.Text(request["reasoning"],"effort"));
        var effort=selected.Effort;
        if (JsonValueReader.Boolean(request, "store", false)) throw new BridgeException("response_storage_not_supported");
        if (request["previous_response_id"] is not null) throw new BridgeException("full_codex_input_required");
        if (JsonValueReader.Boolean(request, "background", false)) throw new BridgeException("background_response_not_supported");
        if (request["instructions"] is not null && request["instructions"]!.GetValueKind() != JsonValueKind.String)
            throw new BridgeException("invalid_instructions");
        JsonArray input;
        if (request["input"] is JsonArray array) input = (JsonArray)array.DeepClone();
        else if (request["input"] is JsonValue value && value.TryGetValue<string>(out var prompt))
            input = new JsonArray(new JsonObject { ["type"] = "message", ["role"] = "user", ["content"] = prompt });
        else throw new BridgeException("invalid_input");
        foreach (var node in input) ValidateInput(node);
        var tools = new List<VirtualTool>();
        var identities = new HashSet<string>(StringComparer.Ordinal);
        if (request["tools"] is not null && request["tools"] is not JsonArray) throw new BridgeException("invalid_tools");
        foreach (var tool in request["tools"]?.AsArray() ?? new JsonArray())
        {
            if (tool is not JsonObject definition) throw new BridgeException("invalid_tool_definition");
            var type = JsonValueReader.RequiredText(definition, "type");
            if (type == "namespace")
            {
                var ns = JsonValueReader.RequiredText(definition, "name");
                if (definition["tools"] is not JsonArray nested) throw new BridgeException("invalid_namespace_tools");
                foreach (var entry in nested)
                    AddTool(entry as JsonObject ?? throw new BridgeException("invalid_namespace_tool"), ns);
            }
            else if (type is "web_search" or "web_search_preview")
            {
                // This server never impersonates OpenAI's hosted search or executes
                // Antigravity search. The native Codex route must expose its real
                // public_web_search function/MCP tool instead.
                if (!((request["tools"] as JsonArray)?.Any(t => JsonValueReader.Text(t, "name") == "public_web_search") ?? false))
                    throw new BridgeException("codex_public_web_search_tool_required");
            }
            else AddTool(definition, null);
        }
        if (tools.Count > 1024) throw new BridgeException("too_many_tools");
        var choice = request["tool_choice"];
        if (choice is JsonValue choiceValue && choiceValue.TryGetValue<string>(out var text) && text is not ("auto" or "none" or "required"))
            throw new BridgeException("unsupported_tool_choice");
        if (choice is JsonObject named && JsonValueReader.Text(named, "type") is not ("function" or "custom"))
            throw new BridgeException("unsupported_named_tool_choice");
        var affinity = JsonValueReader.Text(request, "prompt_cache_key");
        if (affinity?.Length > 512) throw new BridgeException("invalid_prompt_cache_key");
        return new CodexRequest(model, effort, (JsonObject)request.DeepClone(), input, tools,
            JsonValueReader.Boolean(request, "parallel_tool_calls", true) && selected.Definition.SupportsParallelToolCalls, JsonValueReader.Boolean(request, "stream", false), affinity,selected);

        void AddTool(JsonObject definition, string? ns)
        {
            var kind = JsonValueReader.RequiredText(definition, "type");
            if (kind is not ("function" or "custom")) throw new BridgeException("unsupported_tool_type");
            var name = JsonValueReader.RequiredText(definition, "name");
            if (name.Length == 0 || name.Length > 256 || ns?.Length > 256) throw new BridgeException("invalid_tool_name");
            if (!identities.Add((ns ?? "") + "\0" + name)) throw new BridgeException("duplicate_tool_identity");
            if (kind == "function" && definition["parameters"] is not JsonObject && definition["parameters"] is not null)
                throw new BridgeException("invalid_function_schema");
            tools.Add(new VirtualTool(tools.Count, name, ns, kind, (JsonObject)definition.DeepClone()));
        }
    }

    private static void ValidateInput(JsonNode? node)
    {
        if (node is not JsonObject item) throw new BridgeException("invalid_input_item");
        var type = JsonValueReader.Text(item, "type") ?? (item.ContainsKey("role") ? "message" : "");
        if (type == "message")
        {
            if (JsonValueReader.Text(item, "role") is not ("user" or "assistant" or "developer" or "system"))
                throw new BridgeException("unsupported_message_role");
            if (item["content"] is JsonValue text && text.TryGetValue<string>(out _)) return;
            if (item["content"] is not JsonArray content) throw new BridgeException("invalid_message_content");
            foreach (var part in content)
                if (JsonValueReader.Text(part, "type") is not ("input_text" or "output_text" or "text") || JsonValueReader.Text(part, "text") is null)
                    throw new BridgeException("non_text_input_not_supported");
        }
        else if (type is "function_call" or "function_call_output" or "custom_tool_call" or "custom_tool_call_output")
        {
            if (JsonValueReader.Text(item, "call_id") is null) throw new BridgeException("missing_call_identity");
            // Tool result blocks containing media are not silently discarded.
            if (item["output"] is JsonArray outputs)
                foreach (var part in outputs)
                    if (JsonValueReader.Text(part, "type") is not ("input_text" or "output_text" or "text"))
                        throw new BridgeException("non_text_tool_output_not_supported");
        }
        else if (type == "reasoning")
        {
            // Only public summary text is forwarded. OpenAI encrypted reasoning
            // is neither decoded nor represented as Gemini's hidden thoughts.
            item.Remove("encrypted_content");
            item.Remove("content");
        }
        else throw new BridgeException("unsupported_input_item");
    }

    public JsonObject Packet() => new()
    {
        ["protocol"] = "aicli.codex-model-decision.v1",
        ["input_mode"] = "authoritative_full",
        ["instructions"] = Original["instructions"]?.DeepClone(),
        ["input"] = Input.DeepClone(),
        ["tools"] = new JsonArray(Tools.Select(t => (JsonNode)t.Packet()).ToArray()),
        ["tool_choice"] = Original["tool_choice"]?.DeepClone() ?? JsonValue.Create("auto"),
        ["parallel_tool_calls"] = Parallel,
        ["response_text_format"] = Original["text"]?.DeepClone(),
        ["max_output_tokens"] = Original["max_output_tokens"]?.DeepClone()
    };

}

public sealed record Decision(string Kind, string Summary, string Final, IReadOnlyList<(VirtualTool Tool, string Arguments)> Calls)
{
    public static async Task<Decision> ValidateAsync(JsonObject decision, CodexRequest request,
        Func<JsonObject, JsonNode, CancellationToken, Task<bool>> validateSchema, CancellationToken cancellationToken)
    {
        var expected = new HashSet<string>(["kind", "visible_summary", "final_text", "tool_calls"], StringComparer.Ordinal);
        if (decision.Count != expected.Count || decision.Any(p => !expected.Contains(p.Key))) throw new BridgeException("invalid_decision_fields", 502);
        var kind = JsonValueReader.RequiredText(decision, "kind");
        var summary = JsonValueReader.RequiredText(decision, "visible_summary");
        var final = JsonValueReader.RequiredText(decision, "final_text");
        if (decision["tool_calls"] is not JsonArray array || summary.Length > 65536 || final.Length > 2097152)
            throw new BridgeException("invalid_decision", 502);
        if (kind is not ("final" or "tool_calls")) throw new BridgeException("invalid_decision_kind", 502);
        if ((kind == "final" && array.Count != 0) || (kind == "tool_calls" && (array.Count == 0 || final.Length != 0)))
            throw new BridgeException("contradictory_decision", 502);
        if (array.Count > (request.Parallel ? 32 : 1)) throw new BridgeException("parallel_tool_limit_exceeded", 502);
        var choiceText = request.Original["tool_choice"] is JsonValue cv && cv.TryGetValue<string>(out var cs) ? cs : null;
        if (choiceText == "none" && array.Count != 0) throw new BridgeException("tool_choice_none_violated", 502);
        if ((choiceText == "required" || request.Original["tool_choice"] is JsonObject) && array.Count == 0)
            throw new BridgeException("tool_choice_required_violated", 502);
        var calls = new List<(VirtualTool, string)>();
        foreach (var node in array)
        {
            if (node is not JsonObject call) throw new BridgeException("invalid_tool_index",502){Hints=["call_not_object"]};
            var tool = ToolSelector.Resolve(call,request.Tools);
            string arguments;
            JsonNode parsed;
            if (call["arguments"] is JsonObject direct)
            {
                // Keep model output typed. A second model-generated JSON string
                // needlessly doubles escaping for PowerShell, paths and patches.
                parsed = direct.DeepClone();
                arguments = direct.ToJsonString(new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
            }
            else
            {
                // Compatibility with prior model decisions and deterministic
                // fixtures, without coercing invalid typed arguments into JSON.
                if (call.ContainsKey("arguments")) throw new BridgeException("tool_arguments_object_required", 502);
                arguments = JsonValueReader.RequiredText(call, "arguments_json");
                try { parsed = JsonNode.Parse(arguments) ?? throw new JsonException(); }
                catch (JsonException) { throw new BridgeException("invalid_tool_arguments_json", 502); }
            }
            if (arguments.Length > 2097152) throw new BridgeException("tool_arguments_too_large", 502);
            if (parsed is not JsonObject obj) throw new BridgeException("tool_arguments_object_required", 502);
            if (request.Original["tool_choice"] is JsonObject named &&
                (JsonValueReader.Text(named, "name") != tool.Name || JsonValueReader.Text(named, "namespace") != tool.Namespace))
                throw new BridgeException("named_tool_choice_violated", 502);
            if (tool.Kind == "custom")
            {
                if (obj.Count != 1 || JsonValueReader.Text(obj, "input") is not string raw)
                    throw new BridgeException("invalid_custom_tool_input", 502);
                arguments = raw;
            }
            else if (tool.Definition["parameters"] is JsonObject schema &&
                !await validateSchema(schema, parsed, cancellationToken).ConfigureAwait(false))
                throw new BridgeException("tool_arguments_schema_mismatch", 502);
            calls.Add((tool, arguments));
        }
        return new Decision(kind, summary, final, calls);
    }
}

public sealed record Usage(long Input, long Output, long Thinking, long Cached, long Total)
{
    public static Usage Read(JsonNode? node) => new(JsonValueReader.Integer(node,"input_tokens"), JsonValueReader.Integer(node,"output_tokens"),
        JsonValueReader.Integer(node,"thinking_tokens"), JsonValueReader.Integer(node,"cache_read_tokens"), JsonValueReader.Integer(node,"total_tokens"));
    public Usage Since(Usage? before)
    {
        before ??= new Usage(0,0,0,0,0);
        var u = new Usage(Input-before.Input,Output-before.Output,Thinking-before.Thinking,Cached-before.Cached,Total-before.Total);
        if (u.Input < 0 || u.Output < 0 || u.Thinking < 0 || u.Cached < 0 || u.Total < 0)
            throw new BridgeException("upstream_usage_regressed",502);
        return u;
    }
    public JsonObject ToResponses() => new()
    {
        ["input_tokens"]=Input,["output_tokens"]=Output,["total_tokens"]=Total,
        ["input_tokens_details"]=new JsonObject{["cached_tokens"]=Cached},
        ["output_tokens_details"]=new JsonObject{["reasoning_tokens"]=Thinking}
    };
}

public static class ResponsesEvents
{
    public static JsonObject Response(string id, string model, string status, JsonArray output, Usage? usage=null) => new()
    {
        ["id"]=id,["object"]="response",["created_at"]=DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
        ["status"]=status,["model"]=model,["output"]=output.DeepClone(),["error"]=null,["incomplete_details"]=null,
        ["usage"]=usage?.ToResponses(),["parallel_tool_calls"]=true,["store"]=false
    };
    public static JsonArray Output(Decision decision)
    {
        var output = new JsonArray();
        if (decision.Summary.Length > 0)
            output.Add(new JsonObject{["id"]="rs_"+Guid.NewGuid().ToString("N"),["type"]="reasoning",["status"]="completed",
                ["summary"]=new JsonArray(new JsonObject{["type"]="summary_text",["text"]=decision.Summary})});
        foreach (var (tool, arguments) in decision.Calls)
        {
            var item = new JsonObject{["id"]="fc_"+Guid.NewGuid().ToString("N"),["type"]=tool.Kind=="custom"?"custom_tool_call":"function_call",
                ["status"]="completed",["call_id"]="call_"+Guid.NewGuid().ToString("N"),["name"]=tool.Name};
            if (tool.Namespace is not null) item["namespace"]=tool.Namespace;
            item[tool.Kind=="custom"?"input":"arguments"]=arguments;
            output.Add(item);
        }
        if (decision.Kind=="final")
            output.Add(new JsonObject{["id"]="msg_"+Guid.NewGuid().ToString("N"),["type"]="message",["status"]="completed",["role"]="assistant",["channel"]="final",
                ["content"]=new JsonArray(new JsonObject{["type"]="output_text",["text"]=decision.Final,["annotations"]=new JsonArray(),["logprobs"]=new JsonArray()})});
        return output;
    }
    public static IEnumerable<JsonObject> Items(JsonArray output)
    {
        for(var index=0;index<output.Count;index++)
        {
            var item=output[index]!.AsObject();var id=JsonValueReader.RequiredText(item,"id");var type=JsonValueReader.RequiredText(item,"type");
            var initial=(JsonObject)item.DeepClone();initial["status"]="in_progress";
            if(type=="message")initial["content"]=new JsonArray();
            if(type=="reasoning")initial["summary"]=new JsonArray();
            if(type=="function_call")initial["arguments"]="";
            if(type=="custom_tool_call")initial["input"]="";
            yield return new JsonObject{["type"]="response.output_item.added",["output_index"]=index,["item"]=initial};
            if(type=="function_call" || type=="custom_tool_call")
            {
                var field=type=="function_call"?"arguments":"input";var prefix=type=="function_call"?"response.function_call_arguments":"response.custom_tool_call_input";
                yield return new JsonObject{["type"]=prefix+".delta",["item_id"]=id,["output_index"]=index,["delta"]=item[field]!.DeepClone()};
                yield return new JsonObject{["type"]=prefix+".done",["item_id"]=id,["output_index"]=index,[field]=item[field]!.DeepClone()};
            }
            else if(type=="reasoning")
            {
                var text=JsonValueReader.RequiredText(item["summary"]![0],"text");
                yield return new JsonObject{["type"]="response.reasoning_summary_part.added",["item_id"]=id,["output_index"]=index,["summary_index"]=0,["part"]=new JsonObject{["type"]="summary_text",["text"]=""}};
                yield return new JsonObject{["type"]="response.reasoning_summary_text.delta",["item_id"]=id,["output_index"]=index,["summary_index"]=0,["delta"]=text};
                yield return new JsonObject{["type"]="response.reasoning_summary_text.done",["item_id"]=id,["output_index"]=index,["summary_index"]=0,["text"]=text};
                yield return new JsonObject{["type"]="response.reasoning_summary_part.done",["item_id"]=id,["output_index"]=index,["summary_index"]=0,["part"]=item["summary"]![0]!.DeepClone()};
            }
            else if(type=="message")
            {
                var text=JsonValueReader.RequiredText(item["content"]![0],"text");
                yield return new JsonObject{["type"]="response.content_part.added",["item_id"]=id,["output_index"]=index,["content_index"]=0,["part"]=new JsonObject{["type"]="output_text",["text"]="",["annotations"]=new JsonArray(),["logprobs"]=new JsonArray()}};
                yield return new JsonObject{["type"]="response.output_text.delta",["item_id"]=id,["output_index"]=index,["content_index"]=0,["delta"]=text,["logprobs"]=new JsonArray()};
                yield return new JsonObject{["type"]="response.output_text.done",["item_id"]=id,["output_index"]=index,["content_index"]=0,["text"]=text,["logprobs"]=new JsonArray()};
                yield return new JsonObject{["type"]="response.content_part.done",["item_id"]=id,["output_index"]=index,["content_index"]=0,["part"]=item["content"]![0]!.DeepClone()};
            }
            yield return new JsonObject{["type"]="response.output_item.done",["output_index"]=index,["item"]=item.DeepClone()};
        }
    }
}
