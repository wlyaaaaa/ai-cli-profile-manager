using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AiCli.GeminiBridge;
namespace AiCli.GeminiBridge.Tests;
internal static partial class TestProgram
{
    private static async Task WireTests()
    {
        await Check("unicode_packet_is_readable_lossless_single_line",()=>{
            var source=new JsonObject{["instructions"]="中文说明：请读取文件，不猜测。",["input"]="第一行\n第二行\r\n引号\"反斜杠\\ emoji🧭",["tools"]=new JsonArray()};
            var wire=ModelWire.Encode(source);var envelope=JsonNode.Parse(wire)!;
            var body=envelope["message"]!["content"]!.GetValue<string>();
            Assert(wire.Contains("中文说明")&&!wire.Contains('\n')&&!wire.Contains('\r')&&envelope["event"]!.GetValue<string>()=="user");
            Assert(JsonNode.DeepEquals(source,JsonNode.Parse(body)));return Task.CompletedTask;
        });
        await Check("unicode_encoding_reduces_wire_without_removing_information",()=>{
            var source=new JsonObject{["input"]=string.Concat(Enumerable.Repeat("中文上下文和真实工具结果不能截断。",300)),["tool_arguments"]="{\"path\":\"E:\\\\目录\\\\文件.txt\"}"};
            var previous=new JsonObject{["event"]="user",["message"]=new JsonObject{["content"]=source.ToJsonString()}}.ToJsonString();
            var current=ModelWire.Encode(source);
            Assert(Encoding.UTF8.GetByteCount(current)<Encoding.UTF8.GetByteCount(previous));
            Assert(JsonNode.DeepEquals(source,JsonNode.Parse(JsonNode.Parse(current)!["message"]!["content"]!.GetValue<string>())));
            return Task.CompletedTask;
        });
        await Check("pipe_encoding_retains_markup_and_control_characters_as_data",()=>{
            var source=new JsonObject{["input"]="</script><>&'\"\u0000\u0001\n\t"};
            var wire=ModelWire.Encode(source);Assert(!wire.Contains('\n')&&!wire.Contains('\u0000'));
            Assert(JsonNode.DeepEquals(source,JsonNode.Parse(JsonNode.Parse(wire)!["message"]!["content"]!.GetValue<string>())));
            return Task.CompletedTask;
        });
        await Check("empty_success_is_an_explicit_failure_not_valid_model_output",()=>{
            foreach(var text in new string?[]{null,""," \r\n"}){
                var e=TerminalFailures.Read(new JsonObject{["status"]="SUCCESS",["response"]=text},"agent_response",false,false,10,1,0);
                Assert(e.Code=="antigravity_empty_model_response");
            }
            return Task.CompletedTask;
        });
    }
}