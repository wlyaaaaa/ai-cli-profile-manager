using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

internal static class Program
{
    internal const string PlanFixtureEnvironmentVariable = "AICLI_DESKTOP_PLAN_FILE";

    public static async Task<int> Main(string[] args)
    {
        DesktopPlan plan;
        try
        {
            plan = await DesktopPlan.LoadAsync(upstreamOnly: !IsAppServerInvocation(args)).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            await WriteErrorAsync($"Desktop bridge could not load the Codex launch plan ({ex.GetType().Name}).").ConfigureAwait(false);
            return 1;
        }

        if (IsAppServerInvocation(args))
            return await RpcTransport.RunAsync(plan.Json, args).ConfigureAwait(false);

        return await RunTransparentAsync(plan, args).ConfigureAwait(false);
    }

    private static async Task<int> RunTransparentAsync(DesktopPlan plan, string[] args)
    {
        using var process = CreateProcess(plan, args, redirect: false);
        try
        {
            if (!process.Start())
                throw new InvalidOperationException("The Codex engine did not start.");
        }
        catch (Exception ex)
        {
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

    private static bool IsAppServerInvocation(IReadOnlyList<string> args)
    {
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

            return string.Equals(arg, "app-server", StringComparison.Ordinal);
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
        if (upstreamOnly)
            return Parse(await ExportPlanAsync(scriptPath, upstreamOnly: true).ConfigureAwait(false));
        try
        {
            jsonText = await ExportPlanAsync(scriptPath, upstreamOnly: false).ConfigureAwait(false);
            return Parse(jsonText);
        }
        catch
        {
            await Program.WriteErrorAsync("Local desktop model discovery failed; continuing with the upstream Codex engine only.").ConfigureAwait(false);
            jsonText = await ExportPlanAsync(scriptPath, upstreamOnly: true).ConfigureAwait(false);
            return Parse(jsonText);
        }
    }

    private static async Task<string> ExportPlanAsync(string scriptPath, bool upstreamOnly)
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
        if (upstreamOnly)
            process.StartInfo.ArgumentList.Add("-UpstreamOnly");

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
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30)).ConfigureAwait(false);
            }
            catch (TimeoutException)
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
