using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

// Refresh only the advertised catalog. The running engine, threads, provider
// routing, credentials and the managed model set are never replaced here.
internal sealed class LiveModelCatalog
{
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan RefreshTimeout = TimeSpan.FromSeconds(15);
    private readonly JsonObject startupPlan;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, Snapshot> snapshots = new(StringComparer.Ordinal);
    private readonly Queue<string> snapshotOrder = new();
    private Snapshot? current;
    private DateTimeOffset refreshAfter = DateTimeOffset.UtcNow + RefreshInterval;
    private string sourceStamp;
    private sealed record Snapshot(string Id, JsonObject Result, JsonObject[] Models);

    public LiveModelCatalog(JsonObject plan)
    {
        startupPlan = (JsonObject)plan.DeepClone();
        sourceStamp = GetSourceStamp();
    }

    public async Task<JsonObject> ListAsync(JsonObject? parameters,
        Func<string, JsonObject, Task<JsonObject>> callUpstream, CancellationToken cancellationToken)
    {
        parameters ??= new JsonObject();
        // Do not guess the meaning of a future protocol option.
        if (parameters.Any(p => p.Key is not ("cursor" or "limit" or "includeHidden")))
            return await callUpstream("model/list", parameters).ConfigureAwait(false);
        bool includeHidden;
        int limit;
        string? cursor;
        try
        {
            includeHidden = parameters["includeHidden"]?.GetValue<bool>() ?? false;
            limit = parameters["limit"]?.GetValue<int>() ?? 100;
            cursor = parameters["cursor"]?.GetValue<string>();
            if (limit < 1) throw new InvalidOperationException();
        }
        catch (Exception ex) when (ex is InvalidOperationException or FormatException or OverflowException)
        {
            throw new RpcException(-32602, "Invalid model list parameters.");
        }

        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (cursor is not null)
            {
                var parts = cursor.Split(':');
                if (parts.Length != 4 || parts[0] != "aicli-models-v1" ||
                    !snapshots.TryGetValue(parts[1], out var saved) ||
                    parts[2] != (includeHidden ? "1" : "0") ||
                    !int.TryParse(parts[3], NumberStyles.None, CultureInfo.InvariantCulture, out var offset))
                    throw new RpcException(-32602, "Model list cursor is invalid or expired; request the first page again.");
                return Page(saved, includeHidden, offset, limit);
            }

            // Startup has already obtained the official catalog. Ask the running
            // native engine for its wire representation, not a handwritten mapper.
            if (current is null)
                current = Save(await ReadAllAsync(callUpstream).ConfigureAwait(false));

            var stamp = GetSourceStamp();
            if (DateTimeOffset.UtcNow >= refreshAfter || stamp != sourceStamp)
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(RefreshTimeout);
                try
                {
                    var fresh = await DesktopPlan.ReloadAsync(timeout.Token).ConfigureAwait(false);
                    if (fresh.Json["upstreamModels"] is not JsonArray official || official.Count == 0 ||
                        !string.Equals(fresh.Json["codexHome"]?.GetValue<string>(),
                            startupPlan["codexHome"]?.GetValue<string>(), StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("No valid official catalog was returned.");

                    var candidate = (JsonObject)fresh.Json.DeepClone();
                    // A missing/empty/changed local profile in a discovery result
                    // must never remove or re-route a model in this running bridge.
                    candidate["models"] = startupPlan["models"]!.DeepClone();
                    candidate["legacyModels"] = startupPlan["legacyModels"]?.DeepClone();
                    var converter = new ModelRouter(candidate); // validates ID collisions
                    var result = await ConvertWithNativeEngineAsync(candidate,
                        converter.StartupCatalogPath!, timeout.Token).ConfigureAwait(false);
                    current = Save(result);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    await Program.WriteErrorAsync($"Desktop model catalog refresh failed ({ex.GetType().Name}); keeping the last complete model list.").ConfigureAwait(false);
                }
                // Debounce failures as well as successes. A broken source must not
                // launch a new process for every menu render.
                sourceStamp = GetSourceStamp();
                refreshAfter = DateTimeOffset.UtcNow + RefreshInterval;
            }
            return Page(current, includeHidden, 0, limit);
        }
        finally { gate.Release(); }
    }

    private Snapshot Save(JsonObject result)
    {
        if (result["data"] is not JsonArray rows || rows.Count == 0)
            throw new InvalidOperationException("The model list is empty or malformed.");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var models = new List<JsonObject>();
        foreach (var row in rows)
        {
            if (row is not JsonObject model || model["id"] is not JsonValue idValue ||
                !idValue.TryGetValue<string>(out var id) || string.IsNullOrWhiteSpace(id) || !seen.Add(id))
                throw new InvalidOperationException("The model list contains an invalid or duplicate ID.");
            models.Add((JsonObject)model.DeepClone());
        }
        foreach (var entry in startupPlan["models"]!.AsArray())
        {
            var id = entry?["model"]?.GetValue<string>();
            if (id is null || !models.Any(m => m["model"]?.GetValue<string>() == id))
                throw new InvalidOperationException("A managed model is missing from the model list.");
        }
        var bytes = Encoding.UTF8.GetBytes(result.ToJsonString());
        var key = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()[..16];
        if (snapshots.TryGetValue(key, out var existing)) return existing;
        var snapshot = new Snapshot(key, (JsonObject)result.DeepClone(), models.ToArray());
        snapshots.Add(key, snapshot);
        snapshotOrder.Enqueue(key);
        // Pagination pins one immutable generation, even across a refresh.
        while (snapshotOrder.Count > 8) snapshots.Remove(snapshotOrder.Dequeue());
        return snapshot;
    }

    private static JsonObject Page(Snapshot snapshot, bool includeHidden, int offset, int limit)
    {
        var rows = snapshot.Models.Where(m => includeHidden || m["hidden"]?.GetValue<bool>() != true).ToArray();
        if (offset < 0 || offset > rows.Length)
            throw new RpcException(-32602, "Model list cursor offset is invalid.");
        var take = Math.Min(limit, rows.Length - offset);
        var result = (JsonObject)snapshot.Result.DeepClone();
        result["data"] = new JsonArray(rows.Skip(offset).Take(take).Select(m => m.DeepClone()).ToArray());
        var next = offset + take;
        result["nextCursor"] = next < rows.Length
            ? $"aicli-models-v1:{snapshot.Id}:{(includeHidden ? "1" : "0")}:{next}" : null;
        return new JsonObject { ["result"] = result };
    }

    private string GetSourceStamp()
    {
        var home = startupPlan["codexHome"]!.GetValue<string>();
        var paths = new List<string> { Path.Combine(home, "models_cache.json"), Path.Combine(home, "config.toml") };
        // The already-existing fixture entry is also a real changing source in
        // integration tests; no timer or process behavior is stubbed out.
        var fixture = Environment.GetEnvironmentVariable(Program.PlanFixtureEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(fixture)) paths.Add(fixture);
        return string.Join("|", paths.Select(path =>
        {
            try { var f = new FileInfo(path); return f.Exists ? $"{f.Length}:{f.LastWriteTimeUtc.Ticks}" : "missing"; }
            catch (IOException) { return "unavailable"; }
            catch (UnauthorizedAccessException) { return "unavailable"; }
        }));
    }

    private static async Task<JsonObject> ReadAllAsync(Func<string, JsonObject, Task<JsonObject>> call)
    {
        var all = new JsonArray();
        var cursors = new HashSet<string>(StringComparer.Ordinal);
        string? cursor = null;
        JsonObject? template = null;
        do
        {
            var response = await call("model/list", new JsonObject
                { ["includeHidden"] = true, ["limit"] = 100, ["cursor"] = cursor }).ConfigureAwait(false);
            if (response["error"] is JsonObject error)
                throw new RpcException(error["code"]?.GetValue<int>() ?? -32603,
                    error["message"]?.GetValue<string>() ?? "Native model listing failed.");
            if (response["result"] is not JsonObject result || result["data"] is not JsonArray data)
                throw new InvalidOperationException("Native model list has no data array.");
            template ??= (JsonObject)result.DeepClone();
            foreach (var model in data) all.Add(model?.DeepClone());
            cursor = result["nextCursor"]?.GetValue<string>();
            if (all.Count > 10000 || (cursor is not null && (!cursors.Add(cursor) || data.Count == 0)))
                throw new InvalidOperationException("Native model pagination did not terminate.");
        } while (cursor is not null);
        template!["data"] = all;
        template["nextCursor"] = null;
        return template;
    }

    private static async Task<JsonObject> ConvertWithNativeEngineAsync(JsonObject plan, string catalogPath, CancellationToken token)
    {
        using var process = Program.CreateProcess(plan, new[]
        {
            "app-server", "--stdio", "-c", "model_catalog_json=" + System.Text.Json.JsonSerializer.Serialize(catalogPath)
        }, redirect: true);
        process.StartInfo.Environment["CODEX_HOME"] = plan["codexHome"]!.GetValue<string>();
        if (!process.Start()) throw new InvalidOperationException("Native catalog reader could not start.");
        ChildProcessLifetime? lifetime = null;
        try
        {
            lifetime = ChildProcessLifetime.Attach(process);
            var stderr = process.StandardError.ReadToEndAsync(token);
            var number = 0;
            async Task<JsonObject> Call(string method, JsonObject parameters)
            {
                var id = ++number;
                var request = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method, ["params"] = parameters };
                await process.StandardInput.WriteLineAsync(request.ToJsonString().AsMemory(), token).ConfigureAwait(false);
                await process.StandardInput.FlushAsync(token).ConfigureAwait(false);
                while (true)
                {
                    var line = await process.StandardOutput.ReadLineAsync(token).ConfigureAwait(false);
                    if (line is null) throw new IOException("Native catalog reader closed before replying.");
                    if (JsonNode.Parse(line) is not JsonObject response) continue;
                    if (response["id"] is JsonValue value && value.TryGetValue<int>(out var received) && received == id)
                        return response;
                }
            }
            var init = await Call("initialize", new JsonObject
                { ["clientInfo"] = new JsonObject { ["name"] = "aicli-model-catalog", ["version"] = "1" } }).ConfigureAwait(false);
            if (init["error"] is not null) throw new InvalidOperationException("Native catalog initialization failed.");
            await process.StandardInput.WriteLineAsync("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}".AsMemory(), token).ConfigureAwait(false);
            return await ReadAllAsync(Call).ConfigureAwait(false);
        }
        finally
        {
            Program.KillProcessTree(process);
            lifetime?.Dispose();
        }
    }
}
