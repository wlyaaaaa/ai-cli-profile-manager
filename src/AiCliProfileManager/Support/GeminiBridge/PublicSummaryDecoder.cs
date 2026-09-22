using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AiCli.GeminiBridge;

// Only the top-level, explicitly public visible_summary string is projected.
// This decoder never consumes thought events, tools, final_text or nested keys.
// Preview does not authorize execution: the complete decision still must pass
// strict JSON, duplicate-key, schema, identity and tool-choice validation.
public sealed class PublicSummaryDecoder
{
    private readonly StringBuilder wire = new();
    private readonly StringBuilder decoded = new();
    private int offset = -1, sent;
    private bool complete;

    public string Append(string text)
    {
        if (complete) return "";
        wire.Append(text);
        if (wire.Length > 8 * 1024 * 1024) throw Invalid();
        if (offset < 0) Locate();
        if (offset < 0) return "";
        while (offset < wire.Length)
        {
            var c = wire[offset];
            if (c == '"') { complete = true; offset++; break; }
            if (c < 0x20) throw Invalid();
            if (c == '\\')
            {
                if (offset + 1 >= wire.Length) break;
                var escape = wire[offset + 1];
                if (escape == 'u')
                {
                    if (offset + 6 > wire.Length) break;
                    if (!ushort.TryParse(wire.ToString(offset + 2, 4), NumberStyles.AllowHexSpecifier,
                        CultureInfo.InvariantCulture, out var code)) throw Invalid();
                    decoded.Append((char)code); offset += 6;
                }
                else
                {
                    decoded.Append(escape switch
                    {
                        '"' => '"', '\\' => '\\', '/' => '/', 'b' => '\b', 'f' => '\f',
                        'n' => '\n', 'r' => '\r', 't' => '\t', _ => throw Invalid()
                    });
                    offset += 2;
                }
            }
            else { decoded.Append(c); offset++; }
            if (decoded.Length > 65536) throw Invalid();
        }
        var end = sent;
        while (end < decoded.Length)
        {
            if (char.IsHighSurrogate(decoded[end]))
            {
                if (end + 1 == decoded.Length && !complete) break;
                if (end + 1 >= decoded.Length || !char.IsLowSurrogate(decoded[end + 1])) throw Invalid();
                end += 2;
            }
            else
            {
                if (char.IsLowSurrogate(decoded[end])) throw Invalid();
                end++;
            }
        }
        var delta = decoded.ToString(sent, end - sent); sent = end;
        return delta;
    }

    private void Locate()
    {
        var bytes = Encoding.UTF8.GetBytes(wire.ToString());
        var reader = new Utf8JsonReader(bytes, isFinalBlock: false, state: default);
        try
        {
            if (!reader.Read()) return;
            if (reader.TokenType != JsonTokenType.StartObject) throw Invalid();
            while (reader.Read())
            {
                if (reader.TokenType != JsonTokenType.PropertyName || reader.CurrentDepth != 1 ||
                    !reader.ValueTextEquals("visible_summary")) continue;
                var i = checked((int)reader.BytesConsumed);
                // Utf8JsonReader consumes the property separator with its name.
                while (i < bytes.Length && bytes[i] is 0x20 or 0x09 or 0x0A or 0x0D) i++;
                if (i < bytes.Length && bytes[i] == ':')
                {
                    i++;
                    while (i < bytes.Length && bytes[i] is 0x20 or 0x09 or 0x0A or 0x0D) i++;
                }
                if (i == bytes.Length) return;
                if (bytes[i] != '"') throw Invalid();
                offset = Encoding.UTF8.GetCharCount(bytes.AsSpan(0, i + 1));
                return;
            }
        }
        catch (JsonException) { throw Invalid(); }
    }

    public void ValidateFinal(string summary)
    {
        if (sent > 0 && (!complete || !StringComparer.Ordinal.Equals(decoded.ToString(), summary)))
            throw new BridgeException("public_summary_terminal_mismatch", 502);
    }
    private static BridgeException Invalid() => new("public_summary_wire_invalid", 502);
}
