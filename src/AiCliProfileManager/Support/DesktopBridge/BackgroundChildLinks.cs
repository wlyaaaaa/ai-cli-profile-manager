using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

// Only parent/child identity metadata is stored here. All messages, task text,
// tool results and recovery history stay in the official Codex rollout.
internal sealed record BackgroundChildLink(int SchemaVersion, string ParentId, string ThreadId,
    string SessionId, string Model, string Effort, string TaskName, string Cwd, string PermissionIdentity,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? AuthorizationRequestId = null);

internal sealed class BackgroundChildLinks
{
    private readonly string root;
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    public BackgroundChildLinks(string codexHome)
    {
        if (!Path.IsPathFullyQualified(codexHome)) throw new InvalidDataException("Codex home must be absolute.");
        root = Path.Combine(Path.GetFullPath(codexHome), "aicli-background-children");
        if (Directory.Exists(root)) RequireRegularPath(root);
    }

    public IEnumerable<BackgroundChildLink> ReadAll()
    {
        if (!Directory.Exists(root)) yield break;
        RequireRegularPath(root);
        foreach (var path in Directory.EnumerateFiles(root, "*.json", SearchOption.TopDirectoryOnly))
        {
            RequireRegularPath(path);
            if (new FileInfo(path).Length > 16384) throw new InvalidDataException("Background child link is too large.");
            var link = JsonSerializer.Deserialize<BackgroundChildLink>(File.ReadAllText(path, Encoding.UTF8), JsonOptions)
                ?? throw new InvalidDataException("Background child link is empty.");
            Validate(link);
            if (!string.Equals(path, LinkPath(link.ThreadId), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Background child link filename does not match identity.");
            yield return link;
        }
    }

    public IEnumerable<string> ReadModernParents()
    {
        var directory = Path.Combine(root, "parents");
        if (!Directory.Exists(directory)) yield break;
        RequireRegularPath(directory);
        foreach (var path in Directory.EnumerateFiles(directory, "*.json"))
        {
            RequireRegularPath(path);
            if (new FileInfo(path).Length > 1024) throw new InvalidDataException("Parent protocol marker is too large.");
            var marker = JsonSerializer.Deserialize<ParentProtocol>(File.ReadAllText(path, Encoding.UTF8), JsonOptions)
                ?? throw new InvalidDataException("Parent protocol marker is empty.");
            if (marker.SchemaVersion != 2 || string.IsNullOrWhiteSpace(marker.ThreadId) || marker.ThreadId.Length > 160 ||
                Path.GetFileName(path) != Path.GetFileName(LinkPath(marker.ThreadId)))
                throw new InvalidDataException("Parent protocol marker identity differs.");
            yield return marker.ThreadId;
        }
    }

    public void RegisterModernParent(string threadId)
    {
        if (string.IsNullOrWhiteSpace(threadId) || threadId.Length > 160) throw new InvalidDataException("Invalid parent ID.");
        var directory = Path.Combine(root, "parents");
        Directory.CreateDirectory(directory);
        RequireRegularPath(root); RequireRegularPath(directory);
        var target = Path.Combine(directory, Path.GetFileName(LinkPath(threadId)));
        if (File.Exists(target))
        {
            RequireRegularPath(target);
            var marker = JsonSerializer.Deserialize<ParentProtocol>(File.ReadAllText(target, Encoding.UTF8), JsonOptions);
            if (marker != new ParentProtocol(2, threadId)) throw new InvalidDataException("Parent protocol marker differs.");
            return;
        }
        var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(new ParentProtocol(2, threadId), JsonOptions));
            File.Move(temporary, target, overwrite: false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private sealed record ParentProtocol(int SchemaVersion, string ThreadId);

    public void Create(BackgroundChildLink link)
    {
        Validate(link);
        Directory.CreateDirectory(root);
        RequireRegularPath(root);
        var target = LinkPath(link.ThreadId);
        // Immutable link: never rewrite a prior parent or use a name as identity.
        var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                var bytes = JsonSerializer.SerializeToUtf8Bytes(link, JsonOptions);
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, target, overwrite: false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public FileStream Acquire(BackgroundChildLink link)
    {
        Validate(link);
        RequireRegularPath(root);
        var target = LinkPath(link.ThreadId);
        RequireRegularPath(target);
        var current = JsonSerializer.Deserialize<BackgroundChildLink>(File.ReadAllText(target, Encoding.UTF8), JsonOptions);
        if (current != link) throw new InvalidDataException("Background child ownership changed.");
        var lease = target + ".lease";
        if (File.Exists(lease)) RequireRegularPath(lease);
        // The OS releases this file lease if a bridge exits. No stale PID recovery,
        // heartbeat service, or concurrent writers for the same child are needed.
        return new FileStream(lease, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }

    private string LinkPath(string threadId) => Path.Combine(root,
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(threadId))).ToLowerInvariant() + ".json");

    private static void Validate(BackgroundChildLink link)
    {
        if (link.SchemaVersion is not (2 or 3) ||
            (link.SchemaVersion == 3 && (string.IsNullOrEmpty(link.AuthorizationRequestId) || link.AuthorizationRequestId.Length > 256)) ||
            (link.SchemaVersion == 2 && link.AuthorizationRequestId is not null) || new[] { link.ParentId, link.ThreadId, link.SessionId, link.Model, link.Effort, link.TaskName, link.Cwd, link.PermissionIdentity }
            .Any(x => string.IsNullOrWhiteSpace(x) || x.IndexOf('\0') >= 0) ||
            link.ParentId.Length > 160 || link.ThreadId.Length > 160 || link.SessionId.Length > 160 ||
            link.Model.Length > 128 || link.Effort.Length > 32 || link.TaskName.Length > 192 ||
            link.PermissionIdentity.Length != 64 || link.PermissionIdentity.Any(c => !char.IsAsciiHexDigit(c)) ||
            !Path.IsPathFullyQualified(link.Cwd))
            throw new InvalidDataException("Background child metadata is invalid.");
    }

    private static void RequireRegularPath(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("Background child metadata cannot use reparse points.");
    }
}
