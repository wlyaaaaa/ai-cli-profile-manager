using System.Diagnostics;
using Microsoft.Win32;
namespace AiCli.GeminiBridge;

// Translate the user's existing Windows static proxy for the CLI child only.
// Explicit environment overrides take precedence. No global settings are changed.
public static class WindowsProxy
{
    public static void ApplyCurrentUser(ProcessStartInfo start)
    {
        if (!OperatingSystem.IsWindows()) return;
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
        Apply(start.Environment, key?.GetValue("ProxyEnable") is int enabled && enabled != 0,
            key?.GetValue("ProxyServer") as string, key?.GetValue("ProxyOverride") as string);
    }
    public static void Apply(IDictionary<string,string?> environment, bool enabled, string? server, string? bypass)
    {
        if (!enabled || string.IsNullOrWhiteSpace(server)) return;
        var mappings = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        string? common = null;
        foreach (var part in server.Split(';',StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var split = part.IndexOf('=');
            if (split > 0) mappings[part[..split].Trim()] = part[(split+1)..].Trim();
            else if (split < 0) common = part;
        }
        foreach (var protocol in new[]{"http","https"})
        {
            var name = protocol.ToUpperInvariant()+"_PROXY";
            if (HasValue(environment,name) || HasValue(environment,"ALL_PROXY")) continue;
            var address = mappings.TryGetValue(protocol,out var selected) ? selected : common;
            if (string.IsNullOrWhiteSpace(address)) continue;
            var value = address.Contains("://",StringComparison.Ordinal) ? address : "http://"+address;
            if (!Uri.TryCreate(value,UriKind.Absolute,out var uri) ||
                uri.Scheme is not ("http" or "https" or "socks5" or "socks5h") ||
                string.IsNullOrEmpty(uri.Host) || uri.Port is 0 or >65535 ||
                uri.AbsolutePath is not ("" or "/") || uri.Query.Length != 0 || uri.Fragment.Length != 0)
                throw new BridgeException("windows_proxy_configuration_invalid",503);
            environment[name] = value;
        }
        if (!HasValue(environment,"NO_PROXY") && !string.IsNullOrWhiteSpace(bypass))
        {
            var hosts=bypass.Split(';',StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Where(x=>!x.Equals("<local>",StringComparison.OrdinalIgnoreCase))
                .Select(x=>x.StartsWith("*.",StringComparison.Ordinal) ? x[1..] : x).ToArray();
            if(hosts.Length>0) environment["NO_PROXY"]=string.Join(',',hosts);
        }
    }
    private static bool HasValue(IDictionary<string,string?> environment,string name) =>
        environment.Any(p=>p.Key.Equals(name,StringComparison.OrdinalIgnoreCase)&&!string.IsNullOrWhiteSpace(p.Value));
}