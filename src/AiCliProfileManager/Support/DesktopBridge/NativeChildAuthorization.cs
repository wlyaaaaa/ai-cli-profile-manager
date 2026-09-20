using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

// Adapter to an already installed native routing policy. This is not a second
// permission store, a model selector, or a standalone agent runtime.
internal sealed record NativeChildGrant(bool Managed, string? GrantId = null,
    DateTimeOffset? ExpiresAt = null, string? ConsentPath = null)
{
    public static readonly NativeChildGrant Unmanaged = new(false);
}

internal sealed class NativeChildAuthorizationException : Exception
{
    public string Code { get; }
    public NativeChildAuthorizationException(string code, string reason) : base(reason) => Code = code;
}

internal sealed class NativeChildAuthorization
{
    private readonly string home;
    private readonly string policyDirectory;
    private bool observedManagedPolicy;
    private static readonly UTF8Encoding Utf8 = new(false);

    public NativeChildAuthorization(string codexHome)
    {
        var directory = new DirectoryInfo(Path.GetFullPath(codexHome));
        home = directory.Exists && directory.LinkTarget is not null
            ? directory.ResolveLinkTarget(true)!.FullName : directory.FullName;
        policyDirectory = Path.Combine(home, "managed-hooks", "native-economy");
        observedManagedPolicy = Directory.Exists(policyDirectory) || HasManagedHook();
    }

    private bool HasManagedHook()
    {
        var path = Path.Combine(home, "hooks.json");
        if (!File.Exists(path)) return false;
        try
        {
            if (new FileInfo(path).Length > 4 * 1024 * 1024)
                throw new IOException("Hook configuration is too large.");
            return File.ReadAllText(path, Utf8).Contains("codex_native_economy_gate.py", StringComparison.Ordinal);
        }
        catch (IOException) { return true; }
        catch (UnauthorizedAccessException) { return true; }
    }

    public bool Enabled
    {
        get
        {
            // Removing an active manifest is an unavailable policy, not a grant.
            if (Directory.Exists(policyDirectory) || HasManagedHook()) observedManagedPolicy = true;
            return observedManagedPolicy;
        }
    }

    public async Task<NativeChildGrant> CheckAsync(string parentId, string model, string effort,
        string taskName, string? threadId, string action, string? requestId, CancellationToken token)
    {
        if (!Enabled) return NativeChildGrant.Unmanaged;
        try
        {
            var runtime = ResolveRuntime();
            var start = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "py.exe"),
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = Utf8, StandardOutputEncoding = Utf8, StandardErrorEncoding = Utf8
            };
            foreach (var arg in new[] { "-3", "-B", "-X", "utf8", "-I", runtime, "--child-authorization" })
                start.ArgumentList.Add(arg);
            start.Environment["CODEX_HOME"] = home;
            var request = new JsonObject
            {
                ["parent_id"] = parentId, ["model"] = model, ["reasoning_effort"] = effort,
                ["task_name"] = taskName, ["thread_id"] = threadId,
                ["action"] = action, ["request_id"] = requestId
            };
            using var bound = CancellationTokenSource.CreateLinkedTokenSource(token);
            bound.CancelAfter(TimeSpan.FromSeconds(20));
            using var process = Process.Start(start) ?? throw new IOException("Authorization adapter did not start.");
            try
            {
                var stdout = process.StandardOutput.ReadToEndAsync(bound.Token);
                var stderr = process.StandardError.ReadToEndAsync(bound.Token);
                await process.StandardInput.WriteLineAsync(request.ToJsonString().AsMemory(), bound.Token).ConfigureAwait(false);
                process.StandardInput.Close();
                await process.WaitForExitAsync(bound.Token).ConfigureAwait(false);
                var output = await stdout.ConfigureAwait(false);
                var error = await stderr.ConfigureAwait(false);
                if (output.Length > 65536 || error.Length > 65536)
                    throw new IOException("Authorization adapter output is invalid.");
                JsonObject? result = null;
                try { result = JsonNode.Parse(output) as JsonObject; } catch { }
                if (result?["status"]?.GetValue<string>() == "blocked")
                    throw new NativeChildAuthorizationException("OPENAI_CHILD_AUTHORIZATION_DENIED",
                        result["reason"]?.GetValue<string>() ?? "Current permission does not cover this operation.");
                if (process.ExitCode != 0 || !string.IsNullOrWhiteSpace(error) || result?["status"]?.GetValue<string>() != "allowed")
                    throw new IOException("Installed authorization adapter is unavailable or incompatible.");
                var grantId = result["grant_id"]?.GetValue<string>();
                var path = result["consent_path"]?.GetValue<string>();
                if (grantId is null || !Regex.IsMatch(grantId, "^[0-9a-f]{32}$") ||
                    path is null || !Path.IsPathFullyQualified(path) || !path.EndsWith(".routing.json", StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Authorization readback is incomplete.");
                DateTimeOffset? expiry = result["expires_at_utc"] is null ? null :
                    DateTimeOffset.Parse(result["expires_at_utc"]!.GetValue<string>(), System.Globalization.CultureInfo.InvariantCulture);
                return new NativeChildGrant(true, grantId, expiry, Path.GetFullPath(path));
            }
            finally
            {
                if (!process.HasExited)
                    try { process.Kill(true); } catch { }
            }
        }
        catch (NativeChildAuthorizationException) { throw; }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or
            System.ComponentModel.Win32Exception or FormatException or InvalidOperationException or OperationCanceledException)
        {
            // Do not return raw helper output, command arguments, grants or user quotes.
            throw new NativeChildAuthorizationException("OPENAI_CHILD_AUTHORIZATION_UNAVAILABLE",
                "The installed routing permission could not be verified. Inspect the existing policy; do not switch model or execution route.");
        }
    }

    private string ResolveRuntime()
    {
        var manifestPath = Path.Combine(policyDirectory, "active-runtime.json");
        RequireRegular(manifestPath, 65536);
        var manifest = JsonNode.Parse(File.ReadAllText(manifestPath, Utf8)) as JsonObject;
        if (manifest?["schema"]?.GetValue<string>() != "agents.codex-native-economy-runtime-manifest.v1")
            throw new IOException("Installed routing manifest is invalid.");
        var sha = manifest["active_runtime_sha256"]?.GetValue<string>();
        var selected = manifest["active_runtime_path"]?.GetValue<string>();
        if (sha is null || !Regex.IsMatch(sha, "^[0-9a-f]{64}$") || selected is null || !Path.IsPathFullyQualified(selected))
            throw new IOException("Installed routing selection is invalid.");
        var expected = Path.GetFullPath(Path.Combine(policyDirectory, "runtimes", sha, "codex_native_economy_runtime.py"));
        if (!string.Equals(Path.GetFullPath(selected), expected, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Routing runtime escaped its managed directory.");
        RequireRegular(expected, 4 * 1024 * 1024);
        foreach (var parent in new[] { policyDirectory, Path.GetDirectoryName(expected)!, Path.GetDirectoryName(Path.GetDirectoryName(expected)!)! })
            if ((File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Routing runtime directory is redirected.");
        using var input = File.OpenRead(expected);
        if (!string.Equals(Convert.ToHexString(SHA256.HashData(input)), sha, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Installed routing runtime hash differs.");
        return expected;
    }

    private static void RequireRegular(string path, long maxBytes)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length == 0 || info.Length > maxBytes ||
            (info.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
            throw new IOException("Installed routing file is unavailable.");
    }
}
