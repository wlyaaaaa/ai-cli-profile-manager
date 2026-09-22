using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace AiCli.GeminiBridge;

// This is UTF-8 NDJSON over a process pipe, never HTML or JavaScript.
// Preserve human-readable Unicode in the packet the model sees instead of
// converting Chinese and tool text to nested ASCII escape sequences.
public static class ModelWire
{
    private static readonly JsonSerializerOptions Options = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };
    public static string Encode(JsonObject packet) => new JsonObject
    {
        ["event"] = "user",
        ["message"] = new JsonObject { ["content"] = packet.ToJsonString(Options) }
    }.ToJsonString(Options);
}