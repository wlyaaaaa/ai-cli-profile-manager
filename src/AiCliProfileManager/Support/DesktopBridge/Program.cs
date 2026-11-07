using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("RouterTests")]

internal static class Program
{
    internal const string PlanFixtureEnvironmentVariable = "AICLI_DESKTOP_PLAN_FILE";

    public static Task<int> Main(string[] args) => RunAsync(args);

    internal static async Task<int> RunAsync(string[] args, Func<string?>? packageEngine = null)
    {
        var isAppServer = IsAppServerInvocation(args, out var startupCommand);
        if (startupCommand && string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(PlanFixtureEnvironmentVariable)))
        {
            var engine = (packageEngine ?? RegisteredPackageEngine.Find)();
            if (engine is not null)
            {
                try { return await RunTransparentAsync(DesktopPlan.ForExecutable(engine), args, retryPlanOnStartFailure: true).ConfigureAwait(false); }
                catch (System.ComponentModel.Win32Exception) { }
                catch (InvalidOperationException) { }
            }
        }
        DesktopPlan plan;
        try
        {
            plan = await DesktopPlan.LoadAsync(upstreamOnly: !isAppServer).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            var planKind = isAppServer ? "full model" : "upstream";
            await WriteErrorAsync($"Desktop bridge could not load the Codex {planKind} launch plan ({ex.GetType().Name}).").ConfigureAwait(false);
            return 1;
        }

        if (isAppServer)
            return await RpcTransport.RunAsync(plan.Json, args).ConfigureAwait(false);

        return await RunTransparentAsync(plan, args).ConfigureAwait(false);
    }

    private static async Task<int> RunTransparentAsync(DesktopPlan plan, string[] args, bool retryPlanOnStartFailure = false)
    {
        using var process = CreateProcess(plan, args, redirect: false);
        try
        {
            if (!process.Start())
                throw new InvalidOperationException("The Codex engine did not start.");
        }
        catch (Exception ex)
        {
            if (retryPlanOnStartFailure) throw;
            await WriteErrorAsync($"Desktop bridge could not start the Codex engine ({ex.GetType().Name}).").ConfigureAwait(false);
            return 1;
        }

        ChildProcessLifetime lifetime;
        try
        {
            lifetime = ChildProcessLifetime.Attach(process);
        }
        catch (Exception ex)
        {
            Program.KillProcessTree(process);
            await WriteErrorAsync($"Desktop bridge could not bind the Codex process lifetime ({ex.GetType().Name}).").ConfigureAwait(false);
            return 1;
        }

        using (lifetime)
        {
            try
            {
                await process.WaitForExitAsync().ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Program.KillProcessTree(process);
                await WriteErrorAsync($"Desktop bridge lost the Codex process ({ex.GetType().Name}).").ConfigureAwait(false);
                return 1;
            }
            lifetime.Dispose();
            return process.ExitCode;
        }
    }

    internal static Process CreateProcess(DesktopPlan plan, IReadOnlyList<string> args, bool redirect)
        => CreateProcess(plan.UpstreamFileName, plan.UpstreamPrefixArgs, args, redirect);

    internal static Process CreateProcess(JsonObject plan, IReadOnlyList<string> args, bool redirect)
    {
        var executable = plan["upstreamFileName"]?.GetValue<string>()
            ?? throw new InvalidOperationException("The launch plan has no upstream executable.");
        var prefix = new List<string>();
        if (plan["upstreamPrefixArgs"] is JsonArray prefixArgs)
        {
            foreach (var arg in prefixArgs)
            {
                if (arg is not JsonValue value || !value.TryGetValue<string>(out var text))
                    throw new InvalidOperationException("The launch plan has an invalid executable prefix.");
                prefix.Add(text);
            }
        }
        return CreateProcess(executable, prefix, args, redirect);
    }

    private static Process CreateProcess(string executable, IReadOnlyList<string> prefix, IReadOnlyList<string> args, bool redirect)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = redirect,
            RedirectStandardInput = redirect,
            RedirectStandardOutput = redirect,
            RedirectStandardError = redirect
        };
        if (redirect)
        {
            startInfo.StandardInputEncoding = new UTF8Encoding(false);
            startInfo.StandardOutputEncoding = new UTF8Encoding(false);
            startInfo.StandardErrorEncoding = new UTF8Encoding(false);
        }
        // A capability fact for the real upstream host, never a user permission.
        // Old bridge processes do not advertise scoped child authorization.
        startInfo.Environment["AICLI_OPENAI_CHILD_AUTHORIZATION_PROTOCOL"] = "2";
        foreach (var prefixArg in prefix)
            startInfo.ArgumentList.Add(prefixArg);
        foreach (var arg in args)
            startInfo.ArgumentList.Add(arg);
        return new Process { StartInfo = startInfo, EnableRaisingEvents = true };
    }

    internal static void KillProcessTree(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
    }

    internal static async Task CopyBytesAsync(
        Stream source,
        Stream destination,
        CancellationToken cancellationToken,
        bool closeDestinationOnCompletion = false)
    {
        try
        {
            await source.CopyToAsync(destination, 64 * 1024, cancellationToken).ConfigureAwait(false);
            await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        finally
        {
            if (closeDestinationOnCompletion)
            {
                try { destination.Close(); } catch { }
            }
        }
    }

    private static readonly HashSet<string> ValueOptions = new(StringComparer.Ordinal)
    {
        "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env",
        "-i", "--image", "-m", "--model", "--local-provider", "-p", "--profile",
        "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a", "--ask-for-approval"
    };

    private static readonly HashSet<string> FlagOptions = new(StringComparer.Ordinal)
    {
        "--strict-config", "--oss", "--approve-for-me", "--dangerously-bypass-approvals-and-sandbox",
        "--dangerously-bypass-hook-trust", "--worktree", "--search", "--no-alt-screen"
    };

    private static bool IsAppServerInvocation(IReadOnlyList<string> args, out bool startupCommand)
    {
        startupCommand = false;
        for (var index = 0; index < args.Count; index++)
        {
            var arg = args[index];
            if (arg == "--") return false;
            if (arg is "--help" or "-h" or "--version" or "-V") return false;

            if (arg.StartsWith("--", StringComparison.Ordinal))
            {
                var equals = arg.IndexOf('=');
                var option = equals >= 0 ? arg[..equals] : arg;
                if (ValueOptions.Contains(option))
                {
                    if (equals >= 0) continue;
                    if (++index >= args.Count) return false;
                    continue;
                }
                if (FlagOptions.Contains(option)) continue;
                return false;
            }

            if (arg.StartsWith('-') && arg.Length > 1)
            {
                if (ValueOptions.Contains(arg))
                {
                    if (++index >= args.Count) return false;
                    continue;
                }
                if (arg.StartsWith("-c", StringComparison.Ordinal) && arg.Length > 2) continue;
                if (arg.StartsWith("-p", StringComparison.Ordinal) && arg.Length > 2) continue;
                return false;
            }

            if (!string.Equals(arg, "app-server", StringComparison.Ordinal)) return false;
            // Startup policy output is a one-shot native command, not a stdio RPC session.
            var hasListen = false;
            for (++index; index < args.Count; index++)
            {
                arg = args[index];
                if (arg == "--") break;
                var equals = arg.IndexOf('=');
                var option = equals >= 0 ? arg[..equals] : arg;
                if (option == "--print-startup-config") { startupCommand = true; return false; }
                if (option == "--listen") hasListen = true;
                if (equals < 0 && (ValueOptions.Contains(option) ||
                    option is "--startup-client-info" or "--listen")) index++;
            }
            startupCommand = !hasListen && !RegisteredPackageEngine.HasPipedInput();
            return !startupCommand;
        }
        return false;
    }

    internal static async Task WriteErrorAsync(string message)
    {
        try
        {
            var bytes = Encoding.UTF8.GetBytes(message + Environment.NewLine);
            await Console.OpenStandardError().WriteAsync(bytes).ConfigureAwait(false);
        }
        catch { }
    }

}

internal static class RegisteredPackageEngine
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetPackagesByPackageFamily(string family, ref uint count, IntPtr names, ref uint length, IntPtr buffer);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetPackagePathByFullName(string name, ref uint length, StringBuilder? path);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern uint GetFileType(IntPtr handle);

    internal static bool HasPipedInput() => !OperatingSystem.IsWindows() || GetFileType(GetStdHandle(-10)) == 3;

    internal static string? Find()
    {
        if (!OperatingSystem.IsWindows()) return null;
        IntPtr names = IntPtr.Zero, buffer = IntPtr.Zero;
        try
        {
            uint count = 0, length = 0;
            const string family = "OpenAI.Codex_2p2nqsd0c76g0";
            if (GetPackagesByPackageFamily(family, ref count, names, ref length, buffer) != 122 || count == 0) return null;
            names = Marshal.AllocHGlobal(checked((int)count * IntPtr.Size));
            buffer = Marshal.AllocHGlobal(checked((int)length * sizeof(char)));
            if (GetPackagesByPackageFamily(family, ref count, names, ref length, buffer) != 0) return null;
            var packages = new List<(Version Version, string Name)>();
            for (var i = 0; i < count; i++)
            {
                var name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(names, i * IntPtr.Size));
                var parts = name?.Split('_');
                if (parts is { Length: >= 2 } && Version.TryParse(parts[1], out var version)) packages.Add((version, name!));
            }
            var latest = packages.OrderByDescending(p => p.Version).FirstOrDefault();
            if (latest.Name is null) return null;
            length = 0;
            if (GetPackagePathByFullName(latest.Name, ref length, null) != 122) return null;
            var path = new StringBuilder(checked((int)length));
            if (GetPackagePathByFullName(latest.Name, ref length, path) != 0) return null;
            var engine = Path.Combine(path.ToString(), "app", "resources", "codex.exe");
            return File.Exists(engine) ? engine : null;
        }
        catch { return null; }
        finally
        {
            if (names != IntPtr.Zero) Marshal.FreeHGlobal(names);
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
        }
    }
}

internal sealed class DesktopPlan
{
    private DesktopPlan(JsonObject json, string upstreamFileName, IReadOnlyList<string> upstreamPrefixArgs)
    {
        Json = json;
        UpstreamFileName = upstreamFileName;
        UpstreamPrefixArgs = upstreamPrefixArgs;
    }

    public JsonObject Json { get; }
    public string UpstreamFileName { get; }
    public IReadOnlyList<string> UpstreamPrefixArgs { get; }

    internal static DesktopPlan ForExecutable(string path) => new(new JsonObject(), path, Array.Empty<string>());

    public static async Task<DesktopPlan> LoadAsync(bool upstreamOnly = false)
    {
        var fixture = Environment.GetEnvironmentVariable(Program.PlanFixtureEnvironmentVariable);
        string jsonText;
        if (!string.IsNullOrWhiteSpace(fixture))
        {
            jsonText = await File.ReadAllTextAsync(fixture).ConfigureAwait(false);
            return Parse(jsonText);
        }

        var scriptPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "GetDesktopModelPlan.ps1"));
        return Parse(await ExportPlanAsync(scriptPath, upstreamOnly).ConfigureAwait(false));
    }

    public static async Task<DesktopPlan> ReloadAsync(CancellationToken cancellationToken)
    {
        var fixture = Environment.GetEnvironmentVariable(Program.PlanFixtureEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(fixture))
            return Parse(await File.ReadAllTextAsync(fixture, cancellationToken).ConfigureAwait(false));
        var script = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "GetDesktopModelPlan.ps1"));
        return Parse(await ExportPlanAsync(script, false, cancellationToken).ConfigureAwait(false));
    }

    internal static async Task<JsonObject> ResolveModelAsync(string model, string? effort)
    {
        var provider = Environment.GetEnvironmentVariable("AICLI_MODEL_ROUTING_PROVIDER")
            ?? Environment.GetEnvironmentVariable("AICLI_MODEL_ROUTING_PROVIDER", EnvironmentVariableTarget.User);
        if (string.IsNullOrEmpty(provider)) return new JsonObject { ["model"] = model, ["effort"] = effort };
        var script = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "GetDesktopModelPlan.ps1"));
        return JsonNode.Parse(await ExportPlanAsync(script, true, resolveModel: model, effort: effort).ConfigureAwait(false))?.AsObject()
            ?? throw new InvalidOperationException("Model resolver returned no selection.");
    }

    private static async Task<string> ExportPlanAsync(string scriptPath, bool upstreamOnly, CancellationToken cancellationToken = default, string? resolveModel = null, string? effort = null)
    {
        if (!File.Exists(scriptPath))
            throw new FileNotFoundException("The desktop launch-plan script is unavailable.");

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "pwsh",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false)
            }
        };
        process.StartInfo.ArgumentList.Add("-NoProfile");
        process.StartInfo.ArgumentList.Add("-File");
        process.StartInfo.ArgumentList.Add(scriptPath);
        if (resolveModel is not null)
        {
            process.StartInfo.ArgumentList.Add("-ResolveModel"); process.StartInfo.ArgumentList.Add(resolveModel);
            if (effort is not null) { process.StartInfo.ArgumentList.Add("-Effort"); process.StartInfo.ArgumentList.Add(effort); }
        }
        else if (upstreamOnly) process.StartInfo.ArgumentList.Add("-UpstreamOnly");

        if (!process.Start())
            throw new InvalidOperationException("PowerShell did not start.");

        ChildProcessLifetime lifetime;
        try
        {
            lifetime = ChildProcessLifetime.Attach(process);
        }
        catch
        {
            Program.KillProcessTree(process);
            throw;
        }

        using (lifetime)
        {
            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();
            try
            {
                var startupLimit = TimeSpan.FromSeconds(upstreamOnly ? 30 : 90);
                await process.WaitForExitAsync().WaitAsync(startupLimit, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
            {
                Program.KillProcessTree(process);
                throw new TimeoutException("The launch-plan script exceeded its startup limit.");
            }
            lifetime.Dispose();
            var stdout = await stdoutTask.ConfigureAwait(false);
            _ = await stderrTask.ConfigureAwait(false);
            if (process.ExitCode != 0)
                throw new InvalidOperationException("The launch-plan script failed.");
            return stdout;
        }
    }

    private static DesktopPlan Parse(string jsonText)
    {
        JsonObject plan;
        try
        {
            plan = JsonNode.Parse(jsonText) as JsonObject ?? throw new JsonException("The plan must be a JSON object.");
        }
        catch (JsonException)
        {
            throw new InvalidOperationException("The launch-plan script did not return a JSON object.");
        }

        var schemaVersion = plan["schemaVersion"]?.GetValue<int>();
        var codexHome = plan["codexHome"]?.GetValue<string>();
        var executable = plan["upstreamFileName"]?.GetValue<string>();
        if (schemaVersion != 1 || string.IsNullOrWhiteSpace(codexHome) || string.IsNullOrWhiteSpace(executable))
            throw new InvalidOperationException("The launch plan is incomplete or unsupported.");

        var prefixArgs = new List<string>();
        if (plan["upstreamPrefixArgs"] is JsonArray prefix)
        {
            foreach (var arg in prefix)
            {
                if (arg is not JsonValue value || !value.TryGetValue<string>(out var text))
                    throw new InvalidOperationException("The launch plan has an invalid executable prefix.");
                prefixArgs.Add(text);
            }
        }
        else
        {
            throw new InvalidOperationException("The launch plan has no executable prefix list.");
        }

        if (plan["models"] is not JsonArray)
            throw new InvalidOperationException("The launch plan has an invalid model list.");

        return new DesktopPlan(plan, executable, prefixArgs);
    }
}
