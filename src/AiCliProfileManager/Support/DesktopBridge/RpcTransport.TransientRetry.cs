using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;

internal sealed partial class RpcTransport
{
    private const string RetryTrigger = "aicli_transient_failure_retry";
    private const string RetryMessage = "[故障重试] 这轮因服务繁忙或限流停下，已等 10 分钟。请沿原任务重试一次，先确认已做过的动作，避免重复。";
    private readonly ConcurrentDictionary<string, TransientRetry> transientRetries = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, byte> unsubscribedRetryThreads = new(StringComparer.Ordinal);
    private sealed record TransientRetry(string TurnId,
        TaskCompletionSource Changed, TaskCompletionSource<string> NewTurn);

    private static bool CanonicalGuid(string id) => Guid.TryParseExact(id, "D", out var guid) && guid.ToString("D") == id;

    private static bool RetryableFailure(JsonObject turn)
    {
        if (!TryGetString(turn["status"], out var status) || status != "failed" ||
            turn["error"] is not JsonObject error) return false;
        var info = error["codexErrorInfo"];
        if (TryGetString(info, out var kind)) return kind is "serverOverloaded" or "rateLimitExceeded";
        if (info is not JsonObject fields) return false;
        foreach (var name in new[] { "httpConnectionFailed", "responseStreamConnectionFailed",
                     "responseStreamDisconnected", "responseTooManyFailedAttempts" })
            if (fields[name] is JsonObject transport && transport["httpStatusCode"] is JsonValue code &&
                code.TryGetValue<int>(out var statusCode) &&
                (statusCode is 503 or 529 || name == "responseTooManyFailedAttempts" && statusCode == 429)) return true;
        return false;
    }

    private void ObserveRetryClientRequest(JsonObject request)
    {
        if (!TryGetString(request["method"], out var method) ||
            method is not ("turn/start" or "turn/steer" or "turn/interrupt" or "thread/unsubscribe" or
                "thread/archive" or "thread/delete" or "thread/rollback" or "thread/queue/start") ||
            request["params"] is not JsonObject args || !TryGetString(args["threadId"], out var threadId) ||
            !CanonicalGuid(threadId)) return;
        if (method is "thread/unsubscribe" or "thread/archive" or "thread/delete") unsubscribedRetryThreads[threadId] = 0;
        if (transientRetries.TryGetValue(threadId, out var attempt)) attempt.Changed.TrySetResult();
    }

    private void ObserveRetryResubscription(ClientRequestContext context, JsonObject response)
    {
        if (context.Method == "thread/resume" && response["result"]?["thread"] is JsonObject thread &&
            TryGetString(thread["id"], out var id)) unsubscribedRetryThreads.TryRemove(id, out _);
    }

    private void ObserveRetryNotification(JsonObject notification)
    {
        if (notification.ContainsKey("id") || !TryGetString(notification["method"], out var method) ||
            method is not ("turn/completed" or "turn/started") ||
            notification["params"] is not JsonObject args || !TryGetString(args["threadId"], out var threadId) ||
            args["turn"] is not JsonObject turn || !TryGetString(turn["id"], out var turnId) ||
            !CanonicalGuid(threadId) || !CanonicalGuid(turnId)) return;
        if (transientRetries.TryGetValue(threadId, out var previous))
        {
            if (method == "turn/started") { previous.NewTurn.TrySetResult(turnId); return; }
            if (previous.TurnId == turnId) return;
        }
        if (method == "turn/started") return;
        var current = new TransientRetry(turnId, new(TaskCreationOptions.RunContinuationsAsynchronously),
            new(TaskCreationOptions.RunContinuationsAsynchronously));
        previous?.Changed.TrySetResult();
        transientRetries[threadId] = current;
        TrackBackgroundWork(HandleTransientRetryAsync(threadId, current, RetryableFailure(turn)));
    }

    private async Task HandleTransientRetryAsync(string threadId, TransientRetry retry, bool retryable)
    {
        var ended = System.Diagnostics.Stopwatch.StartNew();
        await Task.Yield(); // No filesystem work or waiting in the upstream notification reader.
        var state = Path.GetDirectoryName(Environment.GetEnvironmentVariable("EAGENT_AI_TURN_EVENTS") ??
            @"E:\Data\RemoteComputerMCP\state\cockpit-dispatch-events.jsonl")!;
        var stem = Path.Combine(state, "codex-transient-retry", $"{threadId}.{retry.TurnId}");
        var accepted = false;
        string? retryTurnId = null;
        var status = "skipped";
        var reason = "turn_changed";
        bool OriginalStillCurrent() => !retry.Changed.Task.IsCompleted && !retry.NewTurn.Task.IsCompleted &&
            !unsubscribedRetryThreads.ContainsKey(threadId) &&
            transientRetries.TryGetValue(threadId, out var current) && ReferenceEquals(current, retry);
        try
        {
            var request = stem + ".json";
            using (var input = new FileStream(request, FileMode.Open, FileAccess.Read, FileShare.Delete))
            {
                File.Delete(request); // Claim the exact hook entry, including cleanup of ordinary turns.
                if (input.Length > 1024 || JsonNode.Parse(input) is not JsonObject entry ||
                    !TryGetString(entry["session_id"], out var session) || session != threadId ||
                    !TryGetString(entry["turn_id"], out var turnId) || turnId != retry.TurnId) return;
            }
            if (!retryable) return;
            accepted = true;
            if (!OriginalStillCurrent()) return;
            var remaining = TimeSpan.FromMinutes(10) - ended.Elapsed;
            if (remaining > TimeSpan.Zero)
            {
                try { await Task.WhenAny(retry.Changed.Task, retry.NewTurn.Task).WaitAsync(remaining, shutdown.Token).ConfigureAwait(false); }
                catch (TimeoutException) { } // Reaching ten minutes is the normal retry trigger.
            }
            shutdown.Token.ThrowIfCancellationRequested();
            if (!OriginalStillCurrent()) return;
            var read = await CallBoundedUpstreamAsync("thread/read", new JsonObject
            { ["threadId"] = threadId, ["includeTurns"] = false }, shutdown.Token).ConfigureAwait(false);
            if (read["result"]?["thread"] is not JsonObject thread ||
                !TryGetString(thread["id"], out var observedId) || observedId != threadId ||
                thread["status"] is not JsonObject stateValue || !TryGetString(stateValue["type"], out var nativeStatus) ||
                nativeStatus is not ("idle" or "systemError") ||
                !await NativeThreadLoadedAsync(threadId, OriginalStillCurrent).ConfigureAwait(false))
            { reason = "thread_not_loaded_or_idle"; return; }
            var turns = await CallBoundedUpstreamAsync("thread/turns/list", new JsonObject
            { ["threadId"] = threadId, ["limit"] = 1, ["sortDirection"] = "desc", ["itemsView"] = "notLoaded" },
                shutdown.Token).ConfigureAwait(false);
            if (turns["result"]?["data"] is not JsonArray latest || latest.Count != 1 ||
                latest[0] is not JsonObject last || !TryGetString(last["id"], out var lastId) ||
                lastId != retry.TurnId || !RetryableFailure(last) || !OriginalStillCurrent()) return;
            var wake = await StartContextWakeAsync(threadId, RetryTrigger, RetryTrigger, RetryMessage,
                shutdown.Token, OriginalStillCurrent).ConfigureAwait(false);
            status = "unconfirmed";
            reason = "native_start_unconfirmed";
            if (wake["result"]?["turn"] is JsonObject started && TryGetString(started["id"], out var newId) &&
                CanonicalGuid(newId) && newId != retry.TurnId &&
                TryGetString(started["status"], out var startedStatus) && startedStatus == "inProgress" &&
                await retry.NewTurn.Task.WaitAsync(TimeSpan.FromSeconds(5), shutdown.Token).ConfigureAwait(false) == newId)
            {
                status = "started";
                retryTurnId = newId;
            }
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { reason = "desktop_closed"; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or
            JsonException or TimeoutException or OperationCanceledException or InvalidOperationException)
        {
            if (status != "unconfirmed" && OriginalStillCurrent())
            { status = "unconfirmed"; reason = "native_or_state_read_unconfirmed"; }
        }
        finally
        {
            transientRetries.TryRemove(new KeyValuePair<string, TransientRetry>(threadId, retry));
            if (accepted)
            {
                var receipt = new JsonObject { ["session_id"] = threadId, ["turn_id"] = retry.TurnId, ["status"] = status };
                if (retryTurnId is not null) receipt["retry_turn_id"] = retryTurnId;
                else receipt["reason"] = reason;
                try
                {
                    var temporary = stem + "." + sessionId + ".tmp";
                    File.WriteAllText(temporary, receipt.ToJsonString());
                    File.Move(temporary, stem + ".receipt.json", overwrite: true);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                { await Program.WriteErrorAsync("Desktop retry receipt could not be written.").ConfigureAwait(false); }
            }
        }
    }

    private async Task<bool> NativeThreadLoadedAsync(string threadId, Func<bool> stillCurrent)
    {
        string? cursor = null;
        do
        {
            var page = await CallBoundedUpstreamAsync("thread/loaded/list", new JsonObject
            { ["limit"] = 100, ["cursor"] = cursor }, shutdown.Token).ConfigureAwait(false);
            if (page["result"] is not JsonObject result || result["data"] is not JsonArray data) return false;
            if (data.Any(id => TryGetString(id, out var value) && value == threadId)) return true;
            cursor = TryGetString(result["nextCursor"], out var next) ? next : null;
        } while (cursor is not null && stillCurrent());
        return false;
    }
}
