using System.Collections.Concurrent;

internal sealed partial class RpcTransport
{
    private NativeChildAuthorization? childAuthorization;
    private readonly ConcurrentDictionary<string, FileSystemWatcher> consentWatchers = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, SemaphoreSlim> consentChangeLocks = new(StringComparer.Ordinal);

    private void InitializeChildAuthorization(string codexHome)
    {
        childAuthorization = new NativeChildAuthorization(codexHome);
        shutdown.Token.Register(() =>
        {
            foreach (var watcher in consentWatchers.Values) watcher.Dispose();
            foreach (var child in backgroundChildren.Values)
            {
                lock (child.Gate)
                {
                    child.AuthorizationExpiry?.Cancel();
                    child.AuthorizationExpiry?.Dispose();
                    child.AuthorizationExpiry = null;
                }
            }
        });
    }

    private Task<NativeChildGrant> CheckChildAuthorizationAsync(ParentThreadContext parent,
        string model, string effort, string taskName, string? threadId, string action,
        string? requestId, CancellationToken token) => childAuthorization is null
        ? Task.FromResult(NativeChildGrant.Unmanaged)
        : childAuthorization.CheckAsync(parent.ThreadId, model, effort, taskName,
            threadId, action, requestId, token);

    private async Task<NativeChildGrant> CheckChildAuthorizationAsync(BackgroundChild child,
        string action, CancellationToken token)
    {
        if (childAuthorization is null) return NativeChildGrant.Unmanaged;
        var grant = await childAuthorization.CheckAsync(child.Link.ParentId, child.Link.Model,
            child.Link.Effort, child.Link.TaskName, child.Link.ThreadId, action,
            child.Link.AuthorizationRequestId, token).ConfigureAwait(false);
        ObserveChildAuthorization(child, grant);
        return grant;
    }

    private void ObserveChildAuthorization(BackgroundChild child, NativeChildGrant grant)
    {
        if (!grant.Managed || grant.ConsentPath is null) return;
        // Observe the one existing permission file inside the current bridge.
        // There is no polling service and no copy of the permission decision.
        consentWatchers.GetOrAdd(child.Link.ParentId, _ =>
        {
            var watcher = new FileSystemWatcher(Path.GetDirectoryName(grant.ConsentPath)!, Path.GetFileName(grant.ConsentPath))
            { NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size };
            void Changed(object? sender, FileSystemEventArgs args) =>
                TrackBackgroundWork(RecheckParentChildPermissionsAsync(child.Link.ParentId));
            watcher.Changed += Changed; watcher.Created += Changed; watcher.Deleted += Changed;
            watcher.Renamed += (sender, args) => Changed(sender, args);
            watcher.Error += (sender, args) => TrackBackgroundWork(RecheckParentChildPermissionsAsync(child.Link.ParentId));
            watcher.EnableRaisingEvents = true;
            return watcher;
        });
        lock (child.Gate)
        {
            if (child.AuthorizationGrantId == grant.GrantId && child.AuthorizationExpiresAt == grant.ExpiresAt) return;
            child.AuthorizationExpiry?.Cancel(); child.AuthorizationExpiry?.Dispose();
            child.AuthorizationExpiry = null;
            child.AuthorizationGrantId = grant.GrantId;
            child.AuthorizationExpiresAt = grant.ExpiresAt;
            if (grant.ExpiresAt is not null)
            {
                var expiry = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
                child.AuthorizationExpiry = expiry;
                TrackBackgroundWork(RecheckAtExpiryAsync(child.Link.ParentId, grant.ExpiresAt.Value, expiry.Token));
            }
        }
    }

    private async Task RecheckAtExpiryAsync(string parentId, DateTimeOffset expiresAt, CancellationToken token)
    {
        try
        {
            var delay = expiresAt - DateTimeOffset.UtcNow;
            if (delay > TimeSpan.Zero) await Task.Delay(delay, token).ConfigureAwait(false);
            await RecheckParentChildPermissionsAsync(parentId).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
    }

    private async Task RecheckParentChildPermissionsAsync(string parentId)
    {
        if (shutdown.IsCancellationRequested || childAuthorization?.Enabled != true) return;
        var serial = consentChangeLocks.GetOrAdd(parentId, _ => new SemaphoreSlim(1, 1));
        try
        {
            await serial.WaitAsync(shutdown.Token).ConfigureAwait(false);
            try
            {
                foreach (var child in backgroundChildren.Values.Where(c => c.Link.ParentId == parentId))
                {
                    lock (child.Gate)
                        if (!child.Loaded || child.Turn is null || child.Turn.Terminal.Task.IsCompleted) continue;
                    try { await CheckChildAuthorizationAsync(child, "check", shutdown.Token).ConfigureAwait(false); }
                    catch (NativeChildAuthorizationException)
                    { await StopUnauthorizedChildAsync(child).ConfigureAwait(false); }
                }
            }
            finally { serial.Release(); }
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { }
    }

    private async Task StopUnauthorizedChildAsync(BackgroundChild child)
    {
        try
        {
            // Loading the exact existing thread is allowed for readback/stop.
            // It never submits new task input or creates a replacement session.
            await child.Operation.WaitAsync(shutdown.Token).ConfigureAwait(false);
            try { await EnsureBackgroundChildLoadedAsync(child, shutdown.Token).ConfigureAwait(false); }
            finally { child.Operation.Release(); }
            await InterruptBackgroundChildAsync(child, "authorization_changed").ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (shutdown.IsCancellationRequested) { }
        catch
        {
            lock (child.Gate)
            {
                if (child.Turn is { } turn && !turn.Terminal.Task.IsCompleted) turn.Status = "stop_unconfirmed";
                child.Version++; child.Signal();
            }
        }
    }
}
