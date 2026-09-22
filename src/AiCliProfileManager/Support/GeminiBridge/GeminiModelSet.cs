using System.Collections.ObjectModel;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
namespace AiCli.GeminiBridge;

public sealed record GeminiEffort(string Effort,string Model,string CliEffort);
public sealed record GeminiModel(string Id,string ProfileId,string DisplayName,string MenuModel,string DefaultEffort,
    long ContextWindow,int AutoCompactPercent,bool SupportsPublicSummary,bool SupportsParallelToolCalls,IReadOnlyList<GeminiEffort> Efforts);
public sealed record GeminiSelection(GeminiModel Definition,string RequestedModel,string Effort,string ExactModel,string CliEffort);

// No provider URL, executable, shell argument list or credentials can be
// supplied through model data. A loaded instance is an immutable request snapshot.
public sealed class GeminiModelSet
{
    private readonly IReadOnlyDictionary<string,GeminiModel> byExact;
    public IReadOnlyList<GeminiModel> Models {get;}
    public string DefaultModel {get;}
    public string ApprovedCliSha256 {get;}
    public string Fingerprint {get;}
    public IEnumerable<string> ExactIds=>byExact.Keys;
    private static readonly Lazy<GeminiModelSet> initial=new(()=>{
        using var input=typeof(GeminiModelSet).Assembly.GetManifestResourceStream("AiCli.GeminiBridge.InitialModelSet.json")
            ??throw new BridgeException("initial_model_set_missing",503);
        using var reader=new StreamReader(input,Encoding.UTF8);return Parse(reader.ReadToEnd());
    });
    // Embedded initial data is for backwards-compatible pure parsing/tests.
    // Production startup requires the externally installed model-set snapshot.
    public static GeminiModelSet Initial=>initial.Value;
    public static GeminiModelSet Load(string path)
    {
        try{return Parse(File.ReadAllText(path,new UTF8Encoding(false,true)));}
        catch(BridgeException){throw;}
        catch(Exception e) when(e is IOException or UnauthorizedAccessException or DecoderFallbackException)
        {throw new BridgeException("model_set_unreadable",503);}
    }
    private GeminiModelSet(string defaultModel,string sha,string fingerprint,IReadOnlyList<GeminiModel> models,IReadOnlyDictionary<string,GeminiModel> exact)
    {DefaultModel=defaultModel;ApprovedCliSha256=sha;Fingerprint=fingerprint;Models=models;byExact=exact;}
    public static GeminiModelSet Parse(string text)
    {
        try
        {
            using var doc=JsonDocument.Parse(text,new JsonDocumentOptions{MaxDepth=32});Unique(doc.RootElement);
            if(doc.RootElement.ValueKind!=JsonValueKind.Object)throw new BridgeException("model_set_schema_invalid",503);
            var root=JsonNode.Parse(text)!.AsObject();
            Fields(root,["schema","defaultModel","cli","models"]);
            Fields(root["cli"],["approvedSha256","verifiedVersion"]);
            if(JsonValueReader.Text(root,"schema")!="aicli.gemini-model-set.v1" || root["models"] is not JsonArray array || array.Count is <1 or >128)
                throw new BridgeException("model_set_schema_invalid",503);
            var version=JsonValueReader.RequiredText(root["cli"],"verifiedVersion");
            if(string.IsNullOrWhiteSpace(version)||version.Length>64)throw new BridgeException("model_set_schema_invalid",503);
            var def=Token(root,"defaultModel");var sha=JsonValueReader.RequiredText(root["cli"],"approvedSha256");
            if(!Regex.IsMatch(sha,"^[a-f0-9]{64}$",RegexOptions.CultureInvariant))throw new BridgeException("model_set_cli_hash_invalid",503);
            var models=new List<GeminiModel>();var exact=new Dictionary<string,GeminiModel>(StringComparer.Ordinal);
            var ids=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var profiles=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(var node in array)
            {
                Fields(node,["id","profileId","displayName","menuModel","defaultEffort","contextWindow","autoCompactPercent","inputModalities","supportsPublicSummary","supportsParallelToolCalls","efforts","evidence"]);
                if(node?["evidence"] is JsonNode evidence)
                {
                    if(evidence is not JsonObject evidenceObject || evidenceObject.Any(p=>p.Value is not JsonValue v || !v.TryGetValue<string>(out _)))
                        throw new BridgeException("model_set_schema_invalid",503);
                }
                var id=Token(node,"id");var profile=Token(node,"profileId");var menu=Token(node,"menuModel");var effort=Token(node,"defaultEffort");
                if(!ids.Add(id)||!profiles.Add(profile))throw new BridgeException("model_set_duplicate_identity",503);
                var name=JsonValueReader.RequiredText(node,"displayName");if(string.IsNullOrWhiteSpace(name)||name.Length>128)throw new BridgeException("model_set_display_name_invalid",503);
                var window=JsonValueReader.Integer(node,"contextWindow");var percent=JsonValueReader.Integer(node,"autoCompactPercent");
                if(window<1024||window>16777216||percent!=90)throw new BridgeException("model_set_context_invalid",503);
                if(node?["inputModalities"] is not JsonArray media || media.Count!=1 || media[0]?.GetValue<string>()!="text")
                    throw new BridgeException("model_set_modality_not_supported",503);
                if(node?["efforts"] is not JsonArray levels || levels.Count is <1 or >12)throw new BridgeException("model_set_efforts_invalid",503);
                var mapped=new List<GeminiEffort>();var unique=new HashSet<string>(StringComparer.Ordinal);
                foreach(var level in levels){Fields(level,["effort","model","cliEffort"]);var key=Token(level,"effort");if(!unique.Add(key))throw new BridgeException("model_set_duplicate_effort",503);mapped.Add(new(key,Token(level,"model"),Token(level,"cliEffort")));}
                if(!mapped.Any(x=>x.Effort==effort&&x.Model==menu))throw new BridgeException("model_set_default_mapping_invalid",503);
                var model=new GeminiModel(id,profile,name,menu,effort,window,(int)percent,
                    RequiredBoolean(node,"supportsPublicSummary"),RequiredBoolean(node,"supportsParallelToolCalls"),Array.AsReadOnly(mapped.ToArray()));
                foreach(var mid in mapped.Select(x=>x.Model).Distinct(StringComparer.Ordinal))
                    if(!exact.TryAdd(mid,model))throw new BridgeException("model_set_exact_identity_collision",503);
                models.Add(model);
            }
            if(!models.Any(m=>m.MenuModel==def))throw new BridgeException("model_set_default_model_invalid",503);
            return new(def,sha,Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant(),
                Array.AsReadOnly(models.ToArray()),new ReadOnlyDictionary<string,GeminiModel>(exact));
        }
        catch(BridgeException){throw;}
        catch(Exception e) when(e is JsonException or InvalidOperationException or FormatException or OverflowException)
        {throw new BridgeException("model_set_schema_invalid",503);}
    }
    public GeminiSelection Resolve(string model,string? effort)
    {
        if(!byExact.TryGetValue(model,out var definition))throw new BridgeException("unsupported_exact_model");
        if(effort is null)
        {
            var matches=definition.Efforts.Where(x=>x.Model==model).ToArray();
            effort=model==definition.MenuModel?definition.DefaultEffort:matches.Length==1?matches[0].Effort:throw new BridgeException("explicit_reasoning_effort_required");
        }
        var selected=definition.Efforts.SingleOrDefault(x=>x.Effort==effort)??throw new BridgeException("unsupported_reasoning_effort");
        if(model!=definition.MenuModel && model!=selected.Model)throw new BridgeException("exact_model_effort_mismatch");
        return new(definition,model,effort,selected.Model,selected.CliEffort);
    }
    private static bool RequiredBoolean(JsonNode? node,string name)
    {
        if(node?[name] is JsonValue value && value.TryGetValue<bool>(out var result))return result;
        throw new BridgeException("model_set_schema_invalid",503);
    }
    private static void Fields(JsonNode? node,string[] allowed)
    {
        if(node is not JsonObject obj || obj.Any(x=>!allowed.Contains(x.Key,StringComparer.Ordinal)))
            throw new BridgeException("model_set_schema_invalid",503);
    }
    private static string Token(JsonNode? node,string key)
    {
        var value=JsonValueReader.RequiredText(node,key);
        if(!Regex.IsMatch(value,"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$",RegexOptions.CultureInvariant))throw new BridgeException("model_set_identifier_invalid",503);
        return value;
    }
    private static void Unique(JsonElement node)
    {
        if(node.ValueKind==JsonValueKind.Object){var names=new HashSet<string>(StringComparer.Ordinal);foreach(var p in node.EnumerateObject()){if(!names.Add(p.Name))throw new BridgeException("model_set_duplicate_property",503);Unique(p.Value);}}
        else if(node.ValueKind==JsonValueKind.Array)foreach(var v in node.EnumerateArray())Unique(v);
    }
}