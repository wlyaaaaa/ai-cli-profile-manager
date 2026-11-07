extern alias bridge;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

internal static class StartupPreflightTests
{
    [DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll")] private static extern bool SetStdHandle(int id, IntPtr handle);
    internal static async Task<int?> ChildAsync(string[] args)
    {
        var root = Environment.GetEnvironmentVariable("AICLI_TEST_PREFLIGHT");
        if (root is null) return null;
        if (args.FirstOrDefault() == "__bridge")
            return await bridge::Program.RunAsync(args[2..], () => args[1] == "none" ? null : args[1] == "missing" ? Path.Combine(root, "missing.exe") : Environment.ProcessPath);
        if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) == "pwsh")
        {
            File.WriteAllText(Path.Combine(root, "pwsh.marker"), JsonSerializer.Serialize(args));
            if (!args.Contains("-UpstreamOnly")) return 17;
            Console.WriteLine(JsonSerializer.Serialize(new { schemaVersion = 1, codexHome = root, upstreamFileName = Path.Combine(root, "bridge", "RouterTests.exe"), upstreamPrefixArgs = Array.Empty<string>(), models = Array.Empty<string>() }));
            return 0;
        }
        Console.Write(JsonSerializer.Serialize(args)); Console.Error.Write("native stderr"); return 37;
    }
    internal static async Task RunAsync(Action<bool, string> check)
    {
        if (!OperatingSystem.IsWindows()) return;
        var root = Path.Combine(Path.GetTempPath(), "aicli-startup-" + Guid.NewGuid().ToString("N"));
        var bin = Path.Combine(root, "bridge"); Directory.CreateDirectory(bin);
        try
        {
            foreach (var file in Directory.GetFiles(AppContext.BaseDirectory)) File.Copy(file, Path.Combine(bin, Path.GetFileName(file)));
            File.Copy(Path.Combine(bin, "RouterTests.exe"), Path.Combine(bin, "pwsh.exe"));
            File.WriteAllText(Path.Combine(root, "GetDesktopModelPlan.ps1"), "# isolated fixture");
            async Task<(int Code, string Out, string Err, string? Marker)> Run(bool pipe, string resolver, string[] arguments, string? fixture = null)
            {
                var marker = Path.Combine(root, "pwsh.marker"); File.Delete(marker);
                var start = new ProcessStartInfo(Path.Combine(bin, "RouterTests.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = pipe, RedirectStandardOutput = true, RedirectStandardError = true };
                start.Environment["AICLI_TEST_PREFLIGHT"] = root; start.Environment["PATH"] = bin + ";" + start.Environment["PATH"];
                start.Environment.Remove("AICLI_DESKTOP_PLAN_FILE");
                if (fixture is not null) start.Environment["AICLI_DESKTOP_PLAN_FILE"] = fixture;
                foreach (var arg in new[] { "__bridge", resolver }.Concat(arguments)) start.ArgumentList.Add(arg);
                using var nul = File.OpenRead("NUL"); var previous = GetStdHandle(-10);
                Process process;
                try { if (!pipe) SetStdHandle(-10, nul.SafeFileHandle.DangerousGetHandle()); process = Process.Start(start)!; }
                finally { SetStdHandle(-10, previous); }
                using (process)
                {
                    if (pipe) process.StandardInput.Close();
                    var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
                    try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20)); }
                    finally { if (!process.HasExited) process.Kill(true); }
                    return (process.ExitCode, await stdout, await stderr, File.Exists(marker) ? File.ReadAllText(marker) : null);
                }
            }
            foreach (var signOut in new[] { false, true })
            {
                var args = new[] { "app-server", "--print-startup-config", "--startup-client-info", "{\"title\":\"中文 Desktop\"}" }.Concat(signOut ? new[] { "--startup-sign-out" } : Array.Empty<string>()).ToArray();
                var result = await Run(true, "direct", args);
                check(result.Code == 37 && result.Out == JsonSerializer.Serialize(args) && result.Err == "native stderr" && result.Marker is null, "Startup/sign-out must preserve bytes, arguments and exit code without pwsh.");
            }
            foreach (var resolver in new[] { "missing", "none" }) { var result = await Run(true, resolver, ["app-server", "--print-startup-config"]); check(result.Code == 37 && result.Marker?.Contains("-UpstreamOnly") == true, "Unavailable package/start must fall back to the upstream plan."); }
            var nulResult = await Run(false, "direct", ["app-server", "--future-startup-config"]);
            check(nulResult.Code == 37 && nulResult.Marker is null, "Unknown startup option with NUL stdin must go direct.");
            foreach (var args in new[] { new[] { "app-server" }, new[] { "app-server", "--config", "--print-startup-config", "--startup-client-info", "--print-startup-config" } }) { var result = await Run(true, "direct", args); check(result.Code == 1 && result.Marker is not null && !result.Marker.Contains("-UpstreamOnly"), "Piped RPC and option values must retain the full plan."); }
            var listen = await Run(false, "direct", ["app-server", "--listen=stdio://"]); check(listen.Code == 1 && listen.Marker is not null && !listen.Marker.Contains("-UpstreamOnly"), "Explicit listen must retain the full plan even with NUL stdin.");
            var fixture = Path.Combine(root, "plan.json"); File.WriteAllText(fixture, JsonSerializer.Serialize(new { schemaVersion = 1, codexHome = root, upstreamFileName = Path.Combine(bin, "RouterTests.exe"), upstreamPrefixArgs = new[] { "fixture-first" }, models = Array.Empty<string>() }));
            var fixedResult = await Run(true, "missing", ["app-server", "--print-startup-config"], fixture); check(fixedResult.Code == 37 && fixedResult.Out.Contains("fixture-first") && fixedResult.Marker is null, "Plan fixture must take priority over direct resolution.");
        }
        finally { Directory.Delete(root, true); }
    }
}
