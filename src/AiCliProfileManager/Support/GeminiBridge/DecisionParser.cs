using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace AiCli.GeminiBridge;

// Diagnostics describe only protocol shape. No response fragments, property
// values, arbitrary property names, credentials or hidden reasoning are kept.
public static class DecisionParser
{
    private static readonly string[] Required=["kind","visible_summary","final_text","tool_calls"];
    public static JsonObject Parse(string? response)
    {
        if(response is null || response.Length>8*1024*1024)throw new BridgeException("structured_decision_missing",502);
        BridgeException Invalid(string stage,IEnumerable<string>? detail=null) => new("structured_decision_invalid",502)
        { Hints = new[]{stage,Prefix(response),"response_chars="+response.Length.ToString(CultureInfo.InvariantCulture)}.Concat(detail??[]).ToArray() };
        JsonDocument document;
        try{document=JsonDocument.Parse(response,new JsonDocumentOptions{MaxDepth=128});}
        catch(JsonException e)
        {
            throw Invalid("decision_json_syntax",new[]{"json_line="+(e.LineNumber??-1),"json_byte="+(e.BytePositionInLine??-1)});
        }
        using(document)
        {
            if(document.RootElement.ValueKind!=JsonValueKind.Object)throw Invalid("decision_root_not_object");
            void Unique(JsonElement value,int depth)
            {
                if(value.ValueKind==JsonValueKind.Object)
                {
                    var seen=new HashSet<string>(StringComparer.Ordinal);
                    foreach(var property in value.EnumerateObject())
                    {if(!seen.Add(property.Name))throw Invalid(depth==0?"decision_duplicate_root_key":"decision_duplicate_nested_key");Unique(property.Value,depth+1);}
                }
                else if(value.ValueKind==JsonValueKind.Array)foreach(var item in value.EnumerateArray())Unique(item,depth+1);
            }
            Unique(document.RootElement,0);
            var node=JsonNode.Parse(response,new JsonNodeOptions(),new JsonDocumentOptions{MaxDepth=128})!.AsObject();
            var hints=new List<string>();
            foreach(var key in Required)if(!node.ContainsKey(key))hints.Add("missing_"+key);
            var unknown=node.Count(p=>!Required.Contains(p.Key,StringComparer.Ordinal));
            if(unknown>0)hints.Add("extra_field_count="+unknown);
            if(hints.Count>0)throw Invalid("decision_root_fields",hints);
            if(JsonValueReader.Text(node,"kind") is not ("final" or "tool_calls"))throw Invalid("decision_kind_invalid");
            if(JsonValueReader.Text(node,"visible_summary") is null)throw Invalid("decision_summary_not_string");
            if(JsonValueReader.Text(node,"final_text") is null)throw Invalid("decision_final_not_string");
            if(node["tool_calls"] is not JsonArray)throw Invalid("decision_calls_not_array");
            return node;
        }
    }
    private static string Prefix(string value)
    {
        var s=value.AsSpan().TrimStart();
        if(s.Length==0)return "prefix_empty";
        if(s.StartsWith("```"))return "prefix_markdown_fence";
        return s[0] switch{'{'=>"prefix_object",'['=>"prefix_array",'"'=>"prefix_string",'<'=>"prefix_markup",'\uFEFF'=>"prefix_bom",_=>"prefix_other"};
    }
}