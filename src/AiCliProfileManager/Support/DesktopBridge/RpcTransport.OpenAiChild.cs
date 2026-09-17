using System.Collections.Concurrent;
using System.Text.Json.Nodes;

internal sealed partial class RpcTransport
{
    private const string OpenAiChildToolName = "openai_child";
    private const string ProtectedJudgmentAgentType = "gpt6_astra_high_protected_judgment";
    private const string OpenAiProvider = "openai";
    private static readonly TimeSpan OpenAiChildTimeout = TimeSpan.FromMinutes(30);

    private readonly ConcurrentDictionary<string, ParentThreadContext> managedParentThreads = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, OpenAiChildRun> openAiChildRuns = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, byte> openAiChildCallIds = new(StringComparer.Ordinal);
    private readonly object hiddenThreadGate = new();
    private readonly List<PendingHiddenThread> pendingHiddenThreads = new();
    private readonly HashSet<string> hiddenThreadIds = new(StringComparer.Ordinal);

    private static void InjectOpenAiChildTool(JsonObject request)
    {
        if (!TryGetString(request["method"], out var method) || method != "thread/start" ||
            request["params"] is not JsonObject parameters ||
            !TryGetString(parameters["modelProvider"], out var provider) ||
            !provider.StartsWith("aicli_", StringComparison.Ordinal))
            return;

        JsonArray tools;
        if (parameters["dynamicTools"] is JsonArray existing)
        {
            tools = existing;
        }
        else if (parameters["dynamicTools"] is null)
        {
            tools = new JsonArray();
            parameters["dynamicTools"] = tools;
        }
        else
        {
            return;
        }

        if (tools.OfType<JsonObject>().Any(tool => TryGetString(tool["name"], out var name) && name == OpenAiChildToolName))
            return;
        tools.Add(CreateOpenAiChildToolSpec());
    }

    private static JsonObject CreateOpenAiChildToolSpec()
    {
        var required = new JsonArray();
        foreach (var name in new[] { "agent_type", "model", "reasoning_effort", "task_name", "message" })
            required.Add(name);
        var agentTypes = new JsonArray { "openai_child", ProtectedJudgmentAgentType };
        return new JsonObject
        {
            ["type"] = "function",
            ["name"] = OpenAiChildToolName,
            ["description"] = "Delegate one bounded task from an AICLI non-OpenAI parent to an OpenAI Codex child. The provider is fixed to OpenAI. Select the OpenAI model and reasoning effort explicitly. This route has no inherited parent history, so include the needed context in message.",
            ["inputSchema"] = new JsonObject
            {
                ["type"] = "object",
                ["additionalProperties"] = false,
                ["required"] = required,
                ["properties"] = new JsonObject
                {
                    ["agent_type"] = new JsonObject { ["type"] = "string", ["enum"] = agentTypes },
                    ["model"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 128 },
                    ["reasoning_effort"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 32 },
                    ["task_name"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 192 },
                    ["message"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 500000 }
                }
            },
            ["deferLoading"] = false
        };
    }

    private void RememberManagedParentThread(ClientRequestContext context, JsonObject response)
    {
        if (context.Method is not ("thread/start" or "thread/resume") ||
            context.RoutedParams is not JsonObject routed ||
            !TryGetString(routed["modelProvider"], out var provider) ||
            !provider.StartsWith("aicli_", StringComparison.Ordinal) ||
            response["result"] is not JsonObject result ||
            result["thread"] is not JsonObject thread ||
            !TryGetString(thread["id"], out var threadId))
            return;

        var cwd = TryGetString(thread["cwd"], out var observedCwd)
            ? observedCwd
            : TryGetString(routed["cwd"], out var requestedCwd) ? requestedCwd : string.Empty;
        managedParentThreads[threadId] = new ParentThreadContext(threadId, cwd, provider);
    }

    private static bool IsOpenAiChildServerRequest(JsonObject message) =>
        TryGetString(message["method"], out var method) && method == "item/tool/call" &&
        message.ContainsKey("id") && message["params"] is JsonObject parameters &&
        TryGetString(parameters["tool"], out var tool) && tool == OpenAiChildToolName;

    private void DispatchOpenAiChildServerRequest(JsonObject request)
    {
        var sequence = Interlocked.Increment(ref clientRequestNumber);
        var task = HandleOpenAiChildServerRequestAsync((JsonObject)request.DeepClone());
        requestTasks[sequence] = task;
        _ = task.ContinueWith(
            completed => requestTasks.TryRemove(sequence, out var ignored),
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private async Task HandleOpenAiChildServerRequestAsync(JsonObject request)
    {
        var requestId = request["id"]?.DeepClone();
        try
        {
            if (requestId is null || request["params"] is not JsonObject parameters ||
                parameters["arguments"] is not JsonObject arguments ||
                !TryGetString(parameters["callId"], out var callId) || callId.Length > 256 ||
                !TryGetString(parameters["threadId"], out var parentThreadId) ||
                !TryGetString(parameters["turnId"], out _) ||
                (parameters["namespace"] is JsonValue namespaceValue &&
                    namespaceValue.TryGetValue<string>(out var ns) && !string.IsNullOrWhiteSpace(ns)) ||
                !managedParentThreads.TryGetValue(parentThreadId, out var parent) ||
                !openAiChildCallIds.TryAdd(callId, 0) ||
                arguments.Count != 5 ||
                !TryGetString(arguments["agent_type"], out var agentType) ||
                !TryGetString(arguments["model"], out var model) ||
                !TryGetString(arguments["reasoning_effort"], out var effort) ||
                !TryGetString(arguments["task_name"], out var taskName) ||
                !TryGetString(arguments["message"], out var prompt) ||
                model.Length > 128 || effort.Length > 32 || taskName.Length > 192 || prompt.Length > 500000 ||
                agentType is not ("openai_child" or ProtectedJudgmentAgentType) ||
                (agentType == ProtectedJudgmentAgentType && (model != "gpt-6-astra" || effort != "high")))
            {
                await WriteOpenAiChildToolResultAsync(requestId ?? JsonValue.Create("invalid")!, false, new JsonObject
                {
                    ["schemaVersion"] = 1,
                    ["error"] = "OPENAI_CHILD_REQUEST_INVALID"
                }, shutdown.Token).ConfigureAwait(false);
                return;
            }

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            timeout.CancelAfter(OpenAiChildTimeout);
            var result = await RunOpenAiChildAsync(parent, agentType, model, effort, taskName, prompt, timeout.Token).ConfigureAwait(false);
            await WriteOpenAiChildToolResultAsync(requestId, true, result, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            if (!shutdown.IsCancellationRequested && requestId is not null)
                await TryWriteOpenAiChildFailureAsync(requestId, "OPENAI_CHILD_TIMEOUT").ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            await Program.WriteErrorAsync($"Desktop bridge OpenAI child failed ({ex.GetType().Name}).").ConfigureAwait(false);
            if (requestId is not null)
                await TryWriteOpenAiChildFailureAsync(requestId, "OPENAI_CHILD_UNAVAILABLE").ConfigureAwait(false);
        }
    }

    private async Task<JsonObject> RunOpenAiChildAsync(
        ParentThreadContext parent,
        string agentType,
        string model,
        string effort,
        string taskName,
        string prompt,
        CancellationToken cancellationToken)
    {
        var persistent = agentType == ProtectedJudgmentAgentType;
        var pending = new PendingHiddenThread(model, parent.Cwd);
        lock (hiddenThreadGate)
            pendingHiddenThreads.Add(pending);

        string? threadId = null;
        try
        {
            var threadParameters = new JsonObject
            {
                ["model"] = model,
                ["modelProvider"] = OpenAiProvider,
                ["approvalPolicy"] = "never",
                ["sandbox"] = "danger-full-access",
                ["ephemeral"] = !persistent
            };
            if (!string.IsNullOrWhiteSpace(parent.Cwd))
                threadParameters["cwd"] = parent.Cwd;

            var startResponse = await CallUpstreamAsync("thread/start", threadParameters).WaitAsync(cancellationToken).ConfigureAwait(false);
            var startResult = RequireRpcResult(startResponse, "OpenAI child thread/start failed.");
            if (startResult["thread"] is not JsonObject thread ||
                !TryGetString(thread["id"], out threadId) ||
                !TryGetString(startResult["modelProvider"], out var observedProvider) || observedProvider != OpenAiProvider ||
                !TryGetString(startResult["model"], out var observedModel) || observedModel != model)
                throw new InvalidDataException("OpenAI child thread identity mismatch.");
            var sessionId = TryGetString(thread["sessionId"], out var observedSession) ? observedSession : threadId;
            ConfirmHiddenThread(pending, threadId);

            var run = new OpenAiChildRun(threadId);
            if (!openAiChildRuns.TryAdd(threadId, run))
                throw new InvalidOperationException("OpenAI child thread is already active.");
            try
            {
                var turnParameters = new JsonObject
                {
                    ["threadId"] = threadId,
                    ["input"] = new JsonArray
                    {
                        new JsonObject { ["type"] = "text", ["text"] = prompt }
                    },
                    ["approvalPolicy"] = "never",
                    ["model"] = model,
                    ["effort"] = effort
                };
                var turnResponse = await CallUpstreamAsync("turn/start", turnParameters).WaitAsync(cancellationToken).ConfigureAwait(false);
                var turnResult = RequireRpcResult(turnResponse, "OpenAI child turn/start failed.");
                if (turnResult["turn"] is not JsonObject turn || !TryGetString(turn["id"], out var turnId))
                    throw new InvalidDataException("OpenAI child turn identity is unavailable.");
                run.TurnId = turnId;

                var terminal = await run.Terminal.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                if (terminal["turn"] is not JsonObject terminalTurn ||
                    !TryGetString(terminalTurn["id"], out var terminalTurnId) || terminalTurnId != turnId ||
                    !TryGetString(terminalTurn["status"], out var terminalStatus) || terminalStatus != "completed")
                    throw new InvalidDataException("OpenAI child turn did not complete successfully.");

                FinalAgentMessage? final = run.ReadFinalAgentMessage(turnId);
                JsonObject? readThread = null;
                if (persistent)
                {
                    var readResponse = await CallUpstreamAsync("thread/read", new JsonObject
                    {
                        ["threadId"] = threadId,
                        ["includeTurns"] = true
                    }).WaitAsync(cancellationToken).ConfigureAwait(false);
                    var readResult = RequireRpcResult(readResponse, "OpenAI child thread/read failed.");
                    if (readResult["thread"] is not JsonObject observedThread ||
                        !TryGetString(observedThread["modelProvider"], out var readProvider) || readProvider != OpenAiProvider ||
                        !TryGetString(observedThread["model"], out var readModel) || readModel != model)
                        throw new InvalidDataException("OpenAI child readback identity mismatch.");
                    readThread = observedThread;
                    if (TryGetString(readThread["sessionId"], out var readSession) && readSession != sessionId)
                        throw new InvalidDataException("OpenAI child session identity mismatch.");
                    var readFinal = ReadFinalAgentMessage(readThread, turnId);
                    if (final is not null && (final.Id != readFinal.Id || final.Text != readFinal.Text))
                        throw new InvalidDataException("OpenAI child streamed final does not match durable history.");
                    final = readFinal;
                }
                if (final is null)
                    throw new InvalidDataException("OpenAI child final answer is unavailable from the live stream.");
                var result = new JsonObject
                {
                    ["schemaVersion"] = 1,
                    ["agent_type"] = agentType,
                    ["task_name"] = taskName,
                    ["model_provider"] = OpenAiProvider,
                    ["model"] = model,
                    ["reasoning_effort"] = effort,
                    ["thread_id"] = threadId,
                    ["session_id"] = sessionId,
                    ["turn_id"] = turnId,
                    ["final_message_id"] = final.Id,
                    ["final_text"] = final.Text,
                    ["persistent"] = persistent
                };
                if (persistent && readThread is not null && TryGetString(readThread["path"], out var transcriptPath))
                {
                    result["transcript_path"] = transcriptPath;
                    result["host_event"] = new JsonObject
                    {
                        ["session_id"] = sessionId,
                        ["turn_id"] = turnId,
                        ["transcript_path"] = transcriptPath
                    };
                }
                return result;
            }
            finally
            {
                openAiChildRuns.TryRemove(threadId, out _);
            }
        }
        finally
        {
            CancelPendingHiddenThread(pending);
        }
    }

    private static JsonObject RequireRpcResult(JsonObject response, string message)
    {
        if (response["error"] is not null || response["result"] is not JsonObject result)
            throw new IOException(message);
        return result;
    }

    private static FinalAgentMessage ReadFinalAgentMessage(JsonObject thread, string turnId)
    {
        if (thread["turns"] is not JsonArray turns)
            throw new InvalidDataException("OpenAI child history is unavailable.");

        JsonObject? target = null;
        foreach (var node in turns.OfType<JsonObject>())
        {
            if (TryGetString(node["id"], out var id) && id == turnId)
            {
                target = node;
                break;
            }
        }
        if (target?["items"] is not JsonArray items)
            throw new InvalidDataException("OpenAI child turn items are unavailable.");

        JsonObject? lastMessage = null;
        JsonObject? finalMessage = null;
        foreach (var item in items.OfType<JsonObject>())
        {
            if (!TryGetString(item["type"], out var type) || type != "agentMessage" ||
                !TryGetString(item["id"], out _) || !TryGetString(item["text"], out _))
                continue;
            lastMessage = item;
            if (TryGetString(item["phase"], out var phase) && phase == "final_answer")
                finalMessage = item;
        }
        var selected = finalMessage ?? lastMessage;
        if (selected is null || !TryGetString(selected["id"], out var messageId) || !TryGetString(selected["text"], out var text))
            throw new InvalidDataException("OpenAI child final answer is unavailable.");
        return new FinalAgentMessage(messageId, text);
    }

    private bool TryHandleOpenAiChildNotification(JsonObject message)
    {
        if (!TryGetString(message["method"], out var method) || message["params"] is not JsonObject parameters)
            return false;

        if (method == "thread/started" && parameters["thread"] is JsonObject startedThread &&
            TryGetString(startedThread["id"], out var startedThreadId))
        {
            lock (hiddenThreadGate)
            {
                if (hiddenThreadIds.Contains(startedThreadId))
                    return true;
                if (TryGetString(startedThread["modelProvider"], out var provider) && provider == OpenAiProvider)
                {
                    var model = TryGetString(startedThread["model"], out var observedModel) ? observedModel : string.Empty;
                    var cwd = TryGetString(startedThread["cwd"], out var observedCwd) ? observedCwd : string.Empty;
                    var pending = pendingHiddenThreads.FirstOrDefault(candidate =>
                        candidate.Model == model && (string.IsNullOrWhiteSpace(candidate.Cwd) || candidate.Cwd == cwd));
                    if (pending is not null)
                    {
                        pendingHiddenThreads.Remove(pending);
                        pending.ObservedThreadId = startedThreadId;
                        hiddenThreadIds.Add(startedThreadId);
                        return true;
                    }
                }
            }
        }

        if (!TryGetString(parameters["threadId"], out var threadId))
            return false;
        lock (hiddenThreadGate)
        {
            if (!hiddenThreadIds.Contains(threadId))
                return false;
        }
        if (openAiChildRuns.TryGetValue(threadId, out var run))
        {
            if (method == "item/completed" &&
                TryGetString(parameters["turnId"], out var itemTurnId) &&
                parameters["item"] is JsonObject item &&
                TryGetString(item["type"], out var itemType) && itemType == "agentMessage" &&
                TryGetString(item["id"], out var itemId) &&
                TryGetString(item["text"], out var itemText))
            {
                var isFinal = TryGetString(item["phase"], out var phase) && phase == "final_answer";
                run.ObserveAgentMessage(itemTurnId, new FinalAgentMessage(itemId, itemText), isFinal);
            }
            if (method == "turn/completed")
                run.Terminal.TrySetResult((JsonObject)parameters.DeepClone());
        }
        return true;
    }

    private void ConfirmHiddenThread(PendingHiddenThread pending, string threadId)
    {
        lock (hiddenThreadGate)
        {
            pendingHiddenThreads.Remove(pending);
            if (pending.ObservedThreadId is not null && pending.ObservedThreadId != threadId)
                throw new InvalidDataException("OpenAI child thread notification identity mismatch.");
            pending.ObservedThreadId ??= threadId;
            hiddenThreadIds.Add(threadId);
        }
    }

    private void CancelPendingHiddenThread(PendingHiddenThread pending)
    {
        lock (hiddenThreadGate)
            pendingHiddenThreads.Remove(pending);
    }

    private async Task WriteOpenAiChildToolResultAsync(JsonNode requestId, bool success, JsonObject payload, CancellationToken cancellationToken)
    {
        var response = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = requestId.DeepClone(),
            ["result"] = new JsonObject
            {
                ["success"] = success,
                ["contentItems"] = new JsonArray
                {
                    new JsonObject { ["type"] = "inputText", ["text"] = payload.ToJsonString() }
                }
            }
        };
        await WriteChildLineAsync(response.ToJsonString(), cancellationToken).ConfigureAwait(false);
    }

    private async Task TryWriteOpenAiChildFailureAsync(JsonNode requestId, string code)
    {
        try
        {
            await WriteOpenAiChildToolResultAsync(requestId, false, new JsonObject
            {
                ["schemaVersion"] = 1,
                ["error"] = code
            }, CancellationToken.None).ConfigureAwait(false);
        }
        catch { }
    }

    private static bool TryGetString(JsonNode? node, out string value)
    {
        if (node is JsonValue json && json.TryGetValue<string>(out var text) && !string.IsNullOrWhiteSpace(text))
        {
            value = text;
            return true;
        }
        value = string.Empty;
        return false;
    }

    private sealed record ParentThreadContext(string ThreadId, string Cwd, string Provider);
    private sealed record FinalAgentMessage(string Id, string Text);

    private sealed class OpenAiChildRun
    {
        private readonly object messageGate = new();
        private string? observedTurnId;
        private FinalAgentMessage? lastMessage;
        private FinalAgentMessage? finalMessage;

        public OpenAiChildRun(string threadId) => ThreadId = threadId;
        public string ThreadId { get; }
        public string? TurnId { get; set; }
        public TaskCompletionSource<JsonObject> Terminal { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void ObserveAgentMessage(string turnId, FinalAgentMessage message, bool isFinal)
        {
            lock (messageGate)
            {
                if (observedTurnId is not null && observedTurnId != turnId)
                    return;
                observedTurnId ??= turnId;
                lastMessage = message;
                if (isFinal)
                    finalMessage = message;
            }
        }

        public FinalAgentMessage? ReadFinalAgentMessage(string turnId)
        {
            lock (messageGate)
            {
                if (observedTurnId != turnId)
                    return null;
                return finalMessage ?? lastMessage;
            }
        }
    }

    private sealed class PendingHiddenThread
    {
        public PendingHiddenThread(string model, string cwd)
        {
            Model = model;
            Cwd = cwd;
        }
        public string Model { get; }
        public string Cwd { get; }
        public string? ObservedThreadId { get; set; }
    }
}
