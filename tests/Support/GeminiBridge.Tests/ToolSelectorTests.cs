using System.Text.Json.Nodes;
using AiCli.GeminiBridge;
namespace AiCli.GeminiBridge.Tests;
internal static partial class TestProgram
{
 private static async Task ToolSelectorTests()
 {
  var tools=new[]{new VirtualTool(0,"exec_command","functions","function",new JsonObject()),new VirtualTool(1,"read","files","function",new JsonObject()),new VirtualTool(2,"read","other","function",new JsonObject())};
  JsonObject CallWith(string key,JsonNode value)=>new(){[key]=value,["arguments"]=new JsonObject()};
  await Check("tool_selector_exact_index_and_consistent_metadata",()=>{
   var call=CallWith("tool_index",JsonValue.Create(0)!);call["name"]="exec_command";call["namespace"]="functions";call["type"]="function_call";call["call_id"]="model-generated-id";
   Assert(ToolSelector.Resolve(call,tools).Index==0);return Task.CompletedTask;
  });
  await Check("tool_selector_exact_unique_name_without_guessing",()=>{
   Assert(ToolSelector.Resolve(CallWith("name",JsonValue.Create("functions.exec_command")!),tools).Index==0);
   var call=CallWith("name",JsonValue.Create("read")!);call["namespace"]="files";Assert(ToolSelector.Resolve(call,tools).Index==1);return Task.CompletedTask;
  });
  await Check("tool_selector_ambiguous_and_unknown_names_are_rejected",()=>{
   Throws(()=>ToolSelector.Resolve(CallWith("name",JsonValue.Create("read")!),tools),"invalid_tool_index");
   Throws(()=>ToolSelector.Resolve(CallWith("name",JsonValue.Create("functions.EXEC_COMMAND")!),tools),"invalid_tool_index");return Task.CompletedTask;
  });
  await Check("tool_selector_conflicts_never_prefer_one_identity",()=>{
   var call=CallWith("tool_index",JsonValue.Create(1)!);call["name"]="exec_command";Throws(()=>ToolSelector.Resolve(call,tools),"invalid_tool_index");
   call["name"]="read";call["namespace"]="other";Throws(()=>ToolSelector.Resolve(call,tools),"invalid_tool_index");return Task.CompletedTask;
  });
  await Check("tool_selector_integer_number_has_lossless_normalization",()=>{
   var call=JsonNode.Parse("{\"tool_index\":0.0,\"arguments\":{}}")!.AsObject();Assert(ToolSelector.Resolve(call,tools).Index==0);
   call["tool_index"]=0.5;Throws(()=>ToolSelector.Resolve(call,tools),"invalid_tool_index");call["tool_index"]="0";Throws(()=>ToolSelector.Resolve(call,tools),"invalid_tool_index");return Task.CompletedTask;
  });
  await Check("tool_selector_unknown_fields_mixed_arguments_and_empty_tools_fail",()=>{
   var call=CallWith("tool_index",JsonValue.Create(0)!);call["extra"]="synthetic-secret-not-diagnostic";Throws(()=>ToolSelector.Resolve(call,tools),"invalid_tool_index");call.Remove("extra");call["arguments_json"]="{}";Throws(()=>ToolSelector.Resolve(call,tools),"invalid_tool_index");call.Remove("arguments_json");
   try{ToolSelector.Resolve(call,Array.Empty<VirtualTool>());throw new InvalidOperationException();}catch(BridgeException e){Assert(e.Hints.Contains("no_registered_tools")&&!string.Join(',',e.Hints).Contains("synthetic-secret"));}return Task.CompletedTask;
  });
 }
}