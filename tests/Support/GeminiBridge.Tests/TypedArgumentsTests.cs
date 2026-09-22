using System.Text.Json.Nodes;
using AiCli.GeminiBridge;
namespace AiCli.GeminiBridge.Tests;
internal static partial class TestProgram
{
 private static async Task TypedArgumentsTests()
 {
  await Check("typed_function_arguments_preserve_quotes_unicode_and_newlines",async()=>{
   var command="$p='E:\\临时 目录\\check.txt';\n[IO.File]::WriteAllText($p,\"value\\\"with quotes\"); Get-Content $p";
   var request=CodexRequest.Parse(new JsonObject{["model"]="gemini-3.8-flash-high",["input"]="synthetic",["tools"]=new JsonArray(new JsonObject{["type"]="function",["name"]="exec_command",["parameters"]=new JsonObject{["type"]="object",["properties"]=new JsonObject{["cmd"]=new JsonObject{["type"]="string"}},["required"]=new JsonArray("cmd"),["additionalProperties"]=false}})});
   var raw=new JsonObject{["kind"]="tool_calls",["visible_summary"]="读取测试文件。",["final_text"]="",["tool_calls"]=new JsonArray(new JsonObject{["tool_index"]=0,["arguments"]=new JsonObject{["cmd"]=command}})};
   var decision=await Decision.ValidateAsync(raw,request,validator.ValidateAsync,default);
   Assert(JsonNode.Parse(decision.Calls[0].Arguments)!["cmd"]!.GetValue<string>()==command);
   var item=ResponsesEvents.Output(decision).Single(x=>x!["type"]!.GetValue<string>()=="function_call")!;
   Assert(JsonNode.Parse(item["arguments"]!.GetValue<string>())!["cmd"]!.GetValue<string>()==command);
  });
  await Check("typed_arguments_reject_nonobject_and_ambiguous_legacy_fields",async()=>{
   var request=CodexRequest.Parse(new JsonObject{["model"]="gemini-3.8-flash-high",["input"]="test",["tools"]=new JsonArray(new JsonObject{["type"]="function",["name"]="read_nonce",["parameters"]=new JsonObject{["type"]="object",["properties"]=new JsonObject(),["additionalProperties"]=false}})});
   var raw=new JsonObject{["kind"]="tool_calls",["visible_summary"]="",["final_text"]="",["tool_calls"]=new JsonArray(new JsonObject{["tool_index"]=0,["arguments"]="{}"})};
   await ThrowsAsync(()=>Decision.ValidateAsync(raw,request,validator.ValidateAsync,default),"tool_arguments_object_required");
   raw["tool_calls"]![0]!["arguments"]=new JsonObject();raw["tool_calls"]![0]!["arguments_json"]="{}";
   await ThrowsAsync(()=>Decision.ValidateAsync(raw,request,validator.ValidateAsync,default),"invalid_tool_index");
  });
  await Check("typed_custom_input_is_preserved_without_second_json_encoding",async()=>{
   var input="*** Begin Patch\n*** Add File: 文件.txt\n+quoted \"text\"\\path\n*** End Patch";
   var request=CodexRequest.Parse(new JsonObject{["model"]="gemini-3.8-flash-high",["input"]="test",["tools"]=new JsonArray(new JsonObject{["type"]="custom",["name"]="apply_patch"})});
   var raw=new JsonObject{["kind"]="tool_calls",["visible_summary"]="",["final_text"]="",["tool_calls"]=new JsonArray(new JsonObject{["tool_index"]=0,["arguments"]=new JsonObject{["input"]=input}})};
   var decision=await Decision.ValidateAsync(raw,request,validator.ValidateAsync,default);Assert(decision.Calls[0].Arguments==input);
  });
  await Check("canonical_output_schema_requests_typed_arguments_only",()=>{
   var schema=AntigravitySession.DecisionSchema();var fields=schema["properties"]!["tool_calls"]!["items"]!["properties"]!.AsObject();
   Assert(fields.ContainsKey("arguments")&&!fields.ContainsKey("arguments_json")&&fields["arguments"]!["type"]!.GetValue<string>()=="object");return Task.CompletedTask;
  });
 }
}