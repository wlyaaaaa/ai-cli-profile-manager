using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class RpcException : Exception
{
    public RpcException(int code, string message) : base(message) => Code = code;
    public int Code { get; }
}

internal sealed partial class RpcTransport
{
    private static readonly TimeSpan EofGrace = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan KillGrace = TimeSpan.FromSeconds(2);
    private const string InternalIdPrefix = "__aicli_desktop_internal_";

    private readonly Process process;
    private readonly ModelRouter router;
    private readonly Stream childInput;
    private readonly Stream clientOutput;
    private readonly SemaphoreSlim childWriteLock = new(1, 1);
    private readonly SemaphoreSlim clientWriteLock = new(1, 1);
    private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonObject>> internalRequests = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, ClientRequestContext> clientRequests = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<long, Task> requestTasks = new();
    private readonly string sessionId = Guid.NewGuid().ToString("N");
    private readonly CancellationTokenSource shutdown = new();
    private long internalRequestNumber;
    private long clientRequestNumber;
    private int childInputClosed;

    private RpcTransport(Process process, ModelRouter router)
    {
        this.process = process;
        this.router = router;
        childInput = process.StandardInput.BaseStream;
        clientOutput = Console.OpenStandardOutput();
    }

    public static async Task<int> RunAsync(JsonObject plan, string[] args)
    {
        Process? process = null;
        ChildProcessLifetime? lifetime = null;
        try
        {
            ModelRouter router;
            try
            {
                router = new ModelRouter(plan);
            }
            catch (Exception ex) when (plan["models"] is JsonArray models && models.Count > 0)
            {
                await Program.WriteErrorAsync($"Local desktop model routing is unavailable ({ex.GetType().Name}); continuing with the upstream Codex engine only.").ConfigureAwait(false);
                var upstreamOnlyPlan = (JsonObject)plan.DeepClone();
                upstreamOnlyPlan["models"] = new JsonArray();
                router = new ModelRouter(upstreamOnlyPlan);
            }
            var engineArgs = args.ToList();
            if (router.StartupCatalogPath is { } catalogPath)
            {
                engineArgs.Add("-c");
                engineArgs.Add("model_catalog_json=" + System.Text.Json.JsonSerializer.Serialize(catalogPath));
            }
            process = Program.CreateProcess(plan, engineArgs, redirect: true);
            if (!process.Start())
                throw new InvalidOperationException("The Codex engine did not start.");

            try
            {
                lifetime = ChildProcessLifetime.Attach(process);
            }
            catch
            {
                Program.KillProcessTree(process);
                throw;
            }

            var transport = new RpcTransport(process, router);
            return await transport.RunStartedAsync(lifetime).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            await Program.WriteErrorAsync($"Desktop bridge app-server transport failed ({ex.GetType().Name}).").ConfigureAwait(false);
            if (process is not null)
                Program.KillProcessTree(process);
            lifetime?.Dispose();
            process?.Dispose();
            return 1;
        }
    }

    private async Task<int> RunStartedAsync(ChildProcessLifetime lifetime)
    {
        using (process)
        using (lifetime)
        using (var signal = new ConsoleCancellation(() =>
               {
                   shutdown.Cancel();
                   Program.KillProcessTree(process);
               }))
        using (var clientInput = new StreamReader(
                   Console.OpenStandardInput(),
                   new UTF8Encoding(false),
                   detectEncodingFromByteOrderMarks: false,
                   bufferSize: 4096,
                   leaveOpen: true))
        using (var upstreamOutput = new StreamReader(
                   process.StandardOutput.BaseStream,
                   new UTF8Encoding(false),
                   detectEncodingFromByteOrderMarks: false,
                   bufferSize: 4096,
                   leaveOpen: true))
        {
            var childOutputTask = ReadUpstreamAsync(upstreamOutput, CancellationToken.None);
            var childErrorTask = Program.CopyBytesAsync(
                process.StandardError.BaseStream,
                Console.OpenStandardError(),
                CancellationToken.None);
            var inputTask = ReadClientAsync(clientInput, shutdown.Token);
            var exitTask = process.WaitForExitAsync();

            var first = await Task.WhenAny(inputTask, exitTask, Task.Delay(Timeout.Infinite, shutdown.Token)).ConfigureAwait(false);
            if (shutdown.IsCancellationRequested)
            {
                Program.KillProcessTree(process);
                await CloseChildInputAsync().ConfigureAwait(false);
            }
            else if (first == inputTask)
            {
                try { await inputTask.ConfigureAwait(false); }
                catch (OperationCanceledException) { }
                shutdown.Cancel();
                await CloseChildInputAsync().ConfigureAwait(false);
                try
                {
                    await exitTask.WaitAsync(EofGrace).ConfigureAwait(false);
                }
                catch (TimeoutException)
                {
                    Program.KillProcessTree(process);
                    await CloseChildInputAsync().ConfigureAwait(false);
                    try { await exitTask.WaitAsync(KillGrace).ConfigureAwait(false); }
                    catch (TimeoutException) { }
                }
            }
            else
            {
                shutdown.Cancel();
                await CloseChildInputAsync().ConfigureAwait(false);
                try { await inputTask.ConfigureAwait(false); }
                catch (OperationCanceledException) { }
            }

            if (!process.HasExited)
            {
                Program.KillProcessTree(process);
                await CloseChildInputAsync().ConfigureAwait(false);
                try { await exitTask.WaitAsync(KillGrace).ConfigureAwait(false); }
                catch (TimeoutException) { }
            }

            // Closing the lifetime job also terminates any descendants that outlived the direct engine process.
            lifetime.Dispose();
            FailPendingRequests(new IOException("The Codex engine exited before replying."));
            shutdown.Cancel();
            await ObserveTaskAsync(childOutputTask, "app-server stdout").ConfigureAwait(false);
            await ObserveTaskAsync(childErrorTask, "app-server stderr").ConfigureAwait(false);
            await DrainRequestTasksAsync().ConfigureAwait(false);
            return process.HasExited ? process.ExitCode : 1;
        }
    }

    private async Task ReadClientAsync(TextReader input, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            string? line;
            try
            {
                line = await input.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }
            if (line is null)
                return;

            var message = ParseObject(line);
            if (message is not null && IsClientResponse(message))
            {
                await WriteChildLineAsync(line, cancellationToken).ConfigureAwait(false);
                continue;
            }

            if (message is null || message["method"] is not JsonValue methodValue ||
                !methodValue.TryGetValue<string>(out _) || !message.ContainsKey("id"))
            {
                await WriteChildLineAsync(line, cancellationToken).ConfigureAwait(false);
                continue;
            }

            var sequence = Interlocked.Increment(ref clientRequestNumber);
            var task = HandleClientRequestAsync(line, message, cancellationToken);
            requestTasks[sequence] = task;
            _ = task.ContinueWith(
                completed =>
                {
                    requestTasks.TryRemove(sequence, out var ignored);
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }
    }

    private async Task HandleClientRequestAsync(string originalLine, JsonObject request, CancellationToken cancellationToken)
    {
        var externalId = request["id"]?.DeepClone();
        var idKey = GetIdKey(externalId);
        var method = request["method"]!.GetValue<string>();
        var originalParams = request["params"] is JsonObject parameters
            ? (JsonObject)parameters.DeepClone()
            : null;
        var originalRequest = (JsonObject)request.DeepClone();

        JsonObject? routed;
        try
        {
            routed = await router.BeforeRequestAsync(request, CallUpstreamAsync).ConfigureAwait(false);
        }
        catch (RpcException ex)
        {
            await WriteClientLineAsync(CreateErrorResponse(externalId, ex.Code, ex.Message), cancellationToken).ConfigureAwait(false);
            return;
        }
        catch (Exception ex)
        {
            await Program.WriteErrorAsync($"Desktop bridge request handling failed ({ex.GetType().Name}).").ConfigureAwait(false);
            await WriteClientLineAsync(CreateErrorResponse(externalId, -32603, "Desktop bridge request failed."), cancellationToken).ConfigureAwait(false);
            return;
        }

        if (routed is null)
            return;

        InjectOpenAiChildTool(routed);

        if (IsLocalResponse(routed))
        {
            EnsureResponseIdentity(routed, externalId);
            await WriteClientLineAsync(routed.ToJsonString(), cancellationToken).ConfigureAwait(false);
            return;
        }

        if (!routed.ContainsKey("method"))
        {
            EnsureResponseIdentity(routed, externalId);
            await WriteClientLineAsync(routed.ToJsonString(), cancellationToken).ConfigureAwait(false);
            return;
        }

        if (externalId is not null)
        {
            var routedParams = routed["params"] is JsonObject routedParameters
                ? (JsonObject)routedParameters.DeepClone()
                : null;
            var context = new ClientRequestContext(externalId.DeepClone(), method, originalParams, routedParams);
            if (!clientRequests.TryAdd(idKey, context))
            {
                await WriteClientLineAsync(CreateErrorResponse(externalId, -32600, "A request with this id is already pending."), cancellationToken).ConfigureAwait(false);
                return;
            }
        }

        PreserveExternalId(routed, originalRequest);
        var outgoing = JsonNode.DeepEquals(originalRequest, routed) ? originalLine : routed.ToJsonString();
        try
        {
            await WriteChildLineAsync(outgoing, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            if (externalId is not null)
                clientRequests.TryRemove(idKey, out _);
            if (!cancellationToken.IsCancellationRequested)
            {
                await Program.WriteErrorAsync($"Desktop bridge could not forward a request ({ex.GetType().Name}).").ConfigureAwait(false);
                await WriteClientLineAsync(CreateErrorResponse(externalId, -32603, "Could not forward the request to Codex."), CancellationToken.None).ConfigureAwait(false);
            }
        }
    }

    private async Task ReadUpstreamAsync(TextReader input, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            string? line;
            try
            {
                line = await input.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }
            if (line is null)
                return;

            var message = ParseObject(line);
            if (message is not null && IsOpenAiChildServerRequest(message))
            {
                DispatchOpenAiChildServerRequest(message);
                continue;
            }
            if (message is not null && TryHandleOpenAiChildNotification(message))
                continue;

            if (message is not null && IsResponse(message) && TryGetIdKey(message["id"], out var responseId))
            {
                if (responseId.StartsWith("s:" + InternalIdPrefix + sessionId + "_", StringComparison.Ordinal) &&
                    internalRequests.TryRemove(responseId, out var internalCompletion))
                {
                    internalCompletion.TrySetResult(message);
                    continue;
                }

                if (clientRequests.TryRemove(responseId, out var context))
                {
                    var beforeResponse = (JsonObject)message.DeepClone();
                    if (context.ExternalId is not null)
                        message["id"] = context.ExternalId.DeepClone();
                    try
                    {
                        router.AfterResponse(context.Method, context.OriginalParams, message);
                        RememberManagedParentThread(context, message);
                    }
                    catch (Exception ex)
                    {
                        await Program.WriteErrorAsync($"Desktop bridge response handling failed ({ex.GetType().Name}).").ConfigureAwait(false);
                        message = beforeResponse;
                    }

                    var outgoing = JsonNode.DeepEquals(beforeResponse, message) ? line : message.ToJsonString();
                    await WriteClientLineAsync(outgoing, cancellationToken).ConfigureAwait(false);
                    continue;
                }
            }

            // Provider-specific presentation compatibility is bounded to managed notifications.
            // null preserves the original bytes, an empty list buffers this notification,
            // and multiple entries let a provider flush delayed lifecycle events in order.
            var normalized = message is null ? null : router.NormalizeNotifications(message);
            if (normalized is null)
            {
                await WriteClientLineAsync(line, cancellationToken).ConfigureAwait(false);
                continue;
            }
            // Keep a presentation transition together. Other replies cannot interleave with
            // its item start and continuation, and stdout is flushed only after the whole group.
            if (normalized.Count > 0)
                await WriteClientLineAsync(string.Join("\n", normalized.Select(notification => notification.ToJsonString())), cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task<JsonObject> CallUpstreamAsync(string method, JsonObject parameters)
    {
        if (Volatile.Read(ref childInputClosed) != 0)
            throw new IOException("The Codex engine input is closed.");

        var id = InternalIdPrefix + sessionId + "_" + Interlocked.Increment(ref internalRequestNumber).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var idKey = "s:" + id;
        var completion = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!internalRequests.TryAdd(idKey, completion))
            throw new InvalidOperationException("Could not allocate an internal request id.");

        var request = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id,
            ["method"] = method,
            ["params"] = parameters.DeepClone()
        };
        try
        {
            await WriteChildLineAsync(request.ToJsonString(), shutdown.Token).ConfigureAwait(false);
            return await completion.Task.ConfigureAwait(false);
        }
        catch
        {
            internalRequests.TryRemove(idKey, out _);
            throw;
        }
    }

    private async Task WriteChildLineAsync(string line, CancellationToken cancellationToken)
    {
        await childWriteLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (Volatile.Read(ref childInputClosed) != 0)
                throw new IOException("The Codex engine input is closed.");
            var bytes = Encoding.UTF8.GetBytes(line + "\n");
            await childInput.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
            await childInput.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            childWriteLock.Release();
        }
    }

    private async Task WriteClientLineAsync(string line, CancellationToken cancellationToken)
    {
        await clientWriteLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var bytes = Encoding.UTF8.GetBytes(line + "\n");
            await clientOutput.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
            await clientOutput.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            clientWriteLock.Release();
        }
    }

    private Task WriteClientLineAsync(JsonObject message, CancellationToken cancellationToken) =>
        WriteClientLineAsync(message.ToJsonString(), cancellationToken);

    private async Task CloseChildInputAsync()
    {
        await childWriteLock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (Interlocked.Exchange(ref childInputClosed, 1) == 0)
            {
                try { process.StandardInput.Close(); } catch { }
            }
        }
        finally
        {
            childWriteLock.Release();
        }
    }

    private void FailPendingRequests(Exception exception)
    {
        foreach (var (id, completion) in internalRequests)
        {
            if (internalRequests.TryRemove(id, out var pending))
                pending.TrySetException(exception);
        }
    }

    private async Task DrainRequestTasksAsync()
    {
        var tasks = requestTasks.Values.ToArray();
        if (tasks.Length == 0) return;
        try { await Task.WhenAll(tasks).WaitAsync(KillGrace).ConfigureAwait(false); }
        catch (TimeoutException) { }
        catch (Exception) { }
    }

    private static async Task ObserveTaskAsync(Task task, string streamName)
    {
        try { await task.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        catch (Exception ex)
        {
            await Program.WriteErrorAsync($"Desktop bridge {streamName} ended ({ex.GetType().Name}).").ConfigureAwait(false);
        }
    }

    private static JsonObject? ParseObject(string line)
    {
        try { return JsonNode.Parse(line) as JsonObject; }
        catch (JsonException) { return null; }
    }

    private static bool IsClientResponse(JsonObject message) =>
        !message.ContainsKey("method") && message.ContainsKey("id") && (message.ContainsKey("result") || message.ContainsKey("error"));

    private static bool IsResponse(JsonObject message) =>
        !message.ContainsKey("method") && message.ContainsKey("id") && (message.ContainsKey("result") || message.ContainsKey("error"));

    private static bool IsLocalResponse(JsonObject message) =>
        !message.ContainsKey("method") && (message.ContainsKey("result") || message.ContainsKey("error"));

    private static JsonObject CreateErrorResponse(JsonNode? id, int code, string message) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id?.DeepClone(),
        ["error"] = new JsonObject { ["code"] = code, ["message"] = message }
    };

    private static void EnsureResponseIdentity(JsonObject response, JsonNode? id)
    {
        response["jsonrpc"] ??= JsonValue.Create("2.0");
        response["id"] = id?.DeepClone();
    }

    private static void PreserveExternalId(JsonObject request, JsonObject original)
    {
        if (original.ContainsKey("id"))
            request["id"] = original["id"]?.DeepClone();
    }

    private static string GetIdKey(JsonNode? id) =>
        id is null ? "null" : TryGetIdKey(id, out var key) ? key : "other:" + id.ToJsonString();

    private static bool TryGetIdKey(JsonNode? id, out string key)
    {
        if (id is JsonValue value)
        {
            if (value.TryGetValue<string>(out var text))
            {
                key = "s:" + text;
                return true;
            }
            if (value.TryGetValue<JsonElement>(out var element) && element.ValueKind == JsonValueKind.Number)
            {
                key = "n:" + element.GetRawText();
                return true;
            }
            if (value.TryGetValue<long>(out var signed))
            {
                key = "n:" + signed.ToString(System.Globalization.CultureInfo.InvariantCulture);
                return true;
            }
            if (value.TryGetValue<ulong>(out var unsigned))
            {
                key = "n:" + unsigned.ToString(System.Globalization.CultureInfo.InvariantCulture);
                return true;
            }
            if (value.TryGetValue<double>(out var floating))
            {
                key = "n:" + floating.ToString("R", System.Globalization.CultureInfo.InvariantCulture);
                return true;
            }
        }
        key = string.Empty;
        return false;
    }

    private sealed record ClientRequestContext(JsonNode? ExternalId, string Method, JsonObject? OriginalParams, JsonObject? RoutedParams);

    private sealed class ConsoleCancellation : IDisposable
    {
        private readonly ConsoleCancelEventHandler handler;
        public ConsoleCancellation(Action cancel)
        {
            handler = (_, eventArgs) =>
            {
                eventArgs.Cancel = true;
                cancel();
            };
            Console.CancelKeyPress += handler;
        }
        public void Dispose() => Console.CancelKeyPress -= handler;
    }

}

internal sealed class ChildProcessLifetime : IDisposable
{
    private readonly SafeJobHandle? job;
    private int disposed;

    private ChildProcessLifetime(SafeJobHandle? job) => this.job = job;

    public static ChildProcessLifetime Attach(Process process)
    {
        if (!OperatingSystem.IsWindows())
            return new ChildProcessLifetime(null);

        var job = NativeMethods.CreateJobObject(IntPtr.Zero, null);
        if (job.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            job.Dispose();
            throw new System.ComponentModel.Win32Exception(error, "Could not create the Codex process lifetime job.");
        }

        try
        {
            var limits = new JobObjectExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = NativeMethods.JobObjectLimitKillOnJobClose;
            var size = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
            var memory = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, memory, false);
                if (!NativeMethods.SetInformationJobObject(job, NativeMethods.JobObjectExtendedLimitInformationClass, memory, (uint)size))
                {
                    var error = Marshal.GetLastWin32Error();
                    throw new System.ComponentModel.Win32Exception(error, "Could not configure the Codex process lifetime job.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(memory);
            }

            if (!NativeMethods.AssignProcessToJobObject(job, process.Handle))
            {
                var error = Marshal.GetLastWin32Error();
                throw new System.ComponentModel.Win32Exception(error, "Could not attach the Codex engine to its process lifetime job.");
            }

            return new ChildProcessLifetime(job);
        }
        catch
        {
            job.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0)
            job?.Dispose();
    }

    private sealed class SafeJobHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private SafeJobHandle() : base(ownsHandle: true) { }
        protected override bool ReleaseHandle() => NativeMethods.CloseHandle(handle);
    }

    private static class NativeMethods
    {
        public const int JobObjectExtendedLimitInformationClass = 9;
        public const uint JobObjectLimitKillOnJobClose = 0x00002000;

        [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeJobHandle CreateJobObject(IntPtr attributes, string? name);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(
            SafeJobHandle job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(SafeJobHandle job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr handle);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
}
