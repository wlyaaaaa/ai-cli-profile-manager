using System.Collections.Concurrent;
using System.Text.Json.Nodes;

internal sealed partial class RpcTransport
{
    private const string OpenAiChildToolName = "openai_child";
    private const string ProtectedJudgmentAgentType = "gpt6_astra_high_protected_judgment";
    private const string OpenAiProvider = "openai";
    private const string ProtectedJudgmentThreadSource = "aicli.protected-judgment.";
    private static readonly string[] OpenAiChildRequiredFields =
        { "agent_type", "model", "reasoning_effort", "task_name", "message" };
    private const string ProtectedJudgmentArgumentsHelp =
        "For agent_type=gpt6_astra_high_protected_judgment, send ONLY agent_type, model, reasoning_effort, task_name and message; " +
        "model must be gpt-6-astra and reasoning_effort must be high. Omit wait_ms, thread_id, reply_to and fork_turns entirely (not null). " +
        "This route synchronously returns a fresh persistent judgment and its evidence, not a background handle. " +
        "Creating a judgment does not grant approval or execution authority.";
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

        if (!tools.OfType<JsonObject>().Any(tool => TryGetString(tool["name"], out var name) && name == OpenAiChildToolName))
            tools.Add(CreateOpenAiChildToolSpec());
        if (!tools.OfType<JsonObject>().Any(tool => TryGetString(tool["name"], out var name) && name == ChildControlTool))
            tools.Add(CreateChildControlToolSpec());
    }

    private static JsonObject CreateOpenAiChildToolSpec()
    {
        var required = new JsonArray();
        foreach (var name in OpenAiChildRequiredFields)
            required.Add(name);
        var agentTypes = new JsonArray { "openai_child", ProtectedJudgmentAgentType };
        return new JsonObject
        {
            ["type"] = "function",
            ["name"] = OpenAiChildToolName,
            ["description"] = "Start or continue a background OpenAI child. Provider is fixed to OpenAI; select authorized model/effort explicitly. Include initial context in message. A returned running state is admission, not completion. To continue the SAME child after it finishes or send an update while it works, pass its thread_id with the unchanged model/effort/task_name. To answer its question include reply_to. Progress/questions/final results arrive as marked agent machine context, never human authorization. Use openai_child_control for list/status/wait/stop; do not create independent tasks. For ordinary openai_child only: default wait_ms=1000, maximum 30000. " + ProtectedJudgmentArgumentsHelp,
            ["inputSchema"] = new JsonObject
            {
                ["type"] = "object",
                ["additionalProperties"] = false,
                ["required"] = required,
                ["properties"] = new JsonObject
                {
                    ["agent_type"] = new JsonObject { ["type"] = "string", ["enum"] = agentTypes, ["description"] = ProtectedJudgmentArgumentsHelp },
                    ["model"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 128 },
                    ["reasoning_effort"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 32 },
                    ["task_name"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 192 },
                    ["message"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 500000 },
                    ["thread_id"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 160, ["description"] = "Ordinary openai_child only: continue this exact child. MUST be omitted for protected judgment." },
                    ["reply_to"] = new JsonObject { ["type"] = "string", ["minLength"] = 1, ["maxLength"] = 256, ["description"] = "Ordinary openai_child only: answer a pending question, not a final_message_id. Omit for ordinary follow-up and for protected judgment." },
                    ["wait_ms"] = new JsonObject { ["type"] = "integer", ["minimum"] = 0, ["maximum"] = 30000, ["description"] = "Ordinary openai_child only: wait for background progress. MUST be omitted for protected judgment, which waits synchronously." }
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
        RememberParentProtocol(context, threadId);
    }

    private static bool IsOpenAiChildServerRequest(JsonObject message) =>
        TryGetString(message["method"], out var method) && method == "item/tool/call" &&
        message.ContainsKey("id") && message["params"] is JsonObject parameters &&
        TryGetString(parameters["tool"], out var tool) && tool is OpenAiChildToolName or ChildControlTool or ParentMessageTool;

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
        if (TryGetString(request["params"]?["tool"], out var requestedTool) && requestedTool != OpenAiChildToolName)
        {
            await HandleBackgroundAuxiliaryRequestAsync(request).ConfigureAwait(false);
            return;
        }
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
                !openAiChildCallIds.TryAdd(parentThreadId + ":" + callId, 0) ||
                !TryGetString(arguments["agent_type"], out var agentType) ||
                !TryGetString(arguments["model"], out var model) ||
                !TryGetString(arguments["reasoning_effort"], out var effort) ||
                !TryGetString(arguments["task_name"], out var taskName) ||
                !TryGetString(arguments["message"], out var prompt) ||
                model.Length > 128 || effort.Length > 32 || taskName.Length > 192 || prompt.Length > 500000 ||
                agentType is not ("openai_child" or ProtectedJudgmentAgentType))
            {
                await WriteOpenAiChildToolResultAsync(requestId ?? JsonValue.Create("invalid")!, false, new JsonObject
                {
                    ["schemaVersion"] = 1,
                    ["error"] = "OPENAI_CHILD_REQUEST_INVALID"
                }, shutdown.Token).ConfigureAwait(false);
                return;
            }

            // Validate the selected role before any upstream call. Old threads keep
            // their original tool schema, so the error must teach the same contract.
            if (agentType == ProtectedJudgmentAgentType)
            {
                var invalidFields = !HasOnly(arguments, OpenAiChildRequiredFields);
                if (invalidFields || model != "gpt-6-astra" || effort != "high")
                {
                    await WriteOpenAiChildToolResultAsync(requestId, false, new JsonObject
                    {
                        ["schemaVersion"] = 1,
                        ["error"] = invalidFields ? "OPENAI_CHILD_PROTECTED_ARGUMENTS_INVALID" : "OPENAI_CHILD_PROTECTED_IDENTITY_INVALID",
                        ["message"] = ProtectedJudgmentArgumentsHelp,
                        ["required_fields"] = new JsonArray(OpenAiChildRequiredFields.Select(f => (JsonNode)JsonValue.Create(f)!).ToArray()),
                        ["child_created"] = false,
                        ["retry_action"] = "Correct the arguments and retry openai_child in the same parent. No new parent thread, permission rebind or fallback role is required."
                    }, shutdown.Token).ConfigureAwait(false);
                    return;
                }
            }
            else if (!HasOnly(arguments, "agent_type", "model", "reasoning_effort", "task_name", "message", "thread_id", "reply_to", "wait_ms"))
            {
                await TryWriteOpenAiChildFailureAsync(requestId, "OPENAI_CHILD_REQUEST_INVALID").ConfigureAwait(false);
                return;
            }

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            timeout.CancelAfter(OpenAiChildTimeout);
            if (agentType == OpenAiChildToolName && !modernParents.ContainsKey(parentThreadId) && childAuthorization?.Enabled == true)
                throw new BackgroundChildException("OPENAI_CHILD_PARENT_PROTOCOL_REQUIRES_NEW_THREAD");
            if (!modernParents.ContainsKey(parentThreadId) && arguments.Count != 5)
                throw new BackgroundChildException("OPENAI_CHILD_PARENT_PROTOCOL_REQUIRES_NEW_THREAD");
            // Resumed pre-upgrade roots retain their old native tool schema. Keep
            // their established one-shot behavior instead of returning unknown handles.
            var result = agentType == ProtectedJudgmentAgentType || !modernParents.ContainsKey(parentThreadId)
                ? await RunOpenAiChildAsync(parent, agentType, model, effort, taskName, prompt, timeout.Token).ConfigureAwait(false)
                : await SendBackgroundChildAsync(parent, model, effort, taskName, prompt, arguments, callId, timeout.Token).ConfigureAwait(false);
            await WriteOpenAiChildToolResultAsync(requestId, true, result, timeout.Token).ConfigureAwait(false);
            AnnounceBackgroundResult(result);
        }
        catch (NativeChildAuthorizationException ex)
        {
            if (requestId is not null) await TryWriteOpenAiChildFailureAsync(requestId, ex.Code + ": " + ex.Message).ConfigureAwait(false);
        }
        catch (BackgroundChildException ex)
        {
            if (requestId is not null) await TryWriteOpenAiChildFailureAsync(requestId, ex.Code).ConfigureAwait(false);
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
        var pending = new PendingHiddenThread(model, parent.Cwd)
        { Source = persistent ? ProtectedJudgmentThreadSource + Guid.NewGuid().ToString("N") : null };
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
            if (pending.Source is not null) threadParameters["threadSource"] = pending.Source;
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
        if (message.ContainsKey("id") || !TryGetString(message["method"], out var method) || message["params"] is not JsonObject parameters)
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
                    var source = TryGetString(startedThread["threadSource"], out var sourceValue) ? sourceValue : null;
                    var pending = pendingHiddenThreads.FirstOrDefault(candidate => candidate.Source is not null
                        ? candidate.Source == source
                        : candidate.Model == model && (string.IsNullOrWhiteSpace(candidate.Cwd) || candidate.Cwd == cwd));
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
        if (ObserveBackgroundChildNotification(threadId, method, parameters)) return true;
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
        public string? Source { get; set; }
    }
}
