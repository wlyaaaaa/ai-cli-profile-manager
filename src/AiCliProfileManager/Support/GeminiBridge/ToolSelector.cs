using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace AiCli.GeminiBridge;

// Accept only equivalent explicit references to tools in this exact Codex
// request. Never guess a tool, prefer a conflicting name, or fuzzy-match aliases.
public static class ToolSelector
{
    private static readonly HashSet<string> Fields=["tool_index","name","namespace","arguments","arguments_json","type","id","call_id"];
    public static VirtualTool Resolve(JsonObject call,IReadOnlyList<VirtualTool> tools)
    {
        BridgeException Invalid(string hint)=>new("invalid_tool_index",502){Hints=[hint,tools.Count==0?"no_registered_tools":"registered_tools_present"]};
        if(call.Any(p=>!Fields.Contains(p.Key)))throw Invalid("unknown_call_field");
        if(call.ContainsKey("arguments")==call.ContainsKey("arguments_json"))throw Invalid("arguments_field_ambiguous_or_missing");
        if(tools.Count==0)throw Invalid("no_registered_tools");
        int? selected=null;
        if(call.ContainsKey("tool_index"))
        {
            var value=call["tool_index"];
            if(value is null||value.GetValueKind()!=JsonValueKind.Number||
                !decimal.TryParse(value.ToJsonString(),NumberStyles.Float,CultureInfo.InvariantCulture,out var number)||
                decimal.Truncate(number)!=number)throw Invalid("index_not_integer");
            if(number<0||number>=tools.Count)throw Invalid("index_out_of_range");
            selected=(int)number;
        }
        var name=JsonValueReader.Text(call,"name");var ns=JsonValueReader.Text(call,"namespace");
        if(call.ContainsKey("name")&&name is null)throw Invalid("name_not_string");
        if(call["namespace"] is not null&&ns is null)throw Invalid("namespace_not_string");
        if(ns is not null&&name is null)throw Invalid("namespace_without_name");
        bool Matches(VirtualTool tool)=>
            (ns is null||StringComparer.Ordinal.Equals(ns,tool.Namespace))&&
            (StringComparer.Ordinal.Equals(name,tool.Name)||
             (ns is null&&tool.Namespace is not null&&StringComparer.Ordinal.Equals(name,tool.Namespace+"."+tool.Name)));
        if(selected is null)
        {
            if(name is null)throw Invalid("selector_missing");
            var matches=tools.Where(Matches).ToArray();
            if(matches.Length!=1)throw Invalid(matches.Length==0?"tool_name_unknown":"tool_name_ambiguous");
            selected=matches[0].Index;
        }
        var result=tools[selected.Value];
        if(name is not null&&!Matches(result))throw Invalid("index_name_conflict");
        if(call.ContainsKey("type"))
        {
            var type=JsonValueReader.Text(call,"type");
            if(type!=result.Kind&&type!=result.Kind+"_call"&&!(result.Kind=="custom"&&type=="custom_tool_call"))throw Invalid("call_type_conflict");
        }
        foreach(var key in new[]{"id","call_id"})
            if(call.ContainsKey(key)&&(JsonValueReader.Text(call,key) is not string id||id.Length>256))throw Invalid("invalid_optional_call_identity");
        return result;
    }
}