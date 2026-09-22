using System.Text.Json;
using System.Text.Json.Nodes;
using AiCli.GeminiBridge;
namespace AiCli.GeminiBridge.Tests;
internal static partial class TestProgram
{
 private static async Task DecisionParserTests()
 {
  const string valid="{\"kind\":\"final\",\"visible_summary\":\"中文\",\"final_text\":\"ok\",\"tool_calls\":[]}";
  await Check("decision_parser_diagnostics_do_not_change_valid_values",()=>{Assert(JsonNode.DeepEquals(JsonNode.Parse(valid),DecisionParser.Parse(valid)));return Task.CompletedTask;});
  var malformed=new Dictionary<string,string>{["```json\n"+valid+"\n```"]="decision_json_syntax",[valid+valid]="decision_json_syntax",["{\"kind\":\"final\",\"kind\":\"final\"}"]="decision_duplicate_root_key",["[]"]="decision_root_not_object",["{\"kind\":\"final\",\"private_key_example\":\"private value\"}"]="decision_root_fields",[valid.Replace("\"中文\"","null")]="decision_summary_not_string",[valid.Replace("\"ok\"","null")]="decision_final_not_string",[valid.Replace("[]","{}")]="decision_calls_not_array"};
  foreach(var test in malformed)await Check("decision_diagnostic_"+test.Value+"_"+Outcomes.Count,()=>{
   try{DecisionParser.Parse(test.Key);throw new InvalidOperationException("expected_rejection");}
   catch(BridgeException e){Assert(e.Code=="structured_decision_invalid"&&e.Hints.Contains(test.Value));var publicHints=JsonSerializer.Serialize(e.Hints);Assert(!publicHints.Contains("private_key_example")&&!publicHints.Contains("private value")&&!publicHints.Contains("中文"));}
   return Task.CompletedTask;
  });
 }
}