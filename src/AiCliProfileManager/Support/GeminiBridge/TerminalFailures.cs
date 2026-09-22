using System.Text.Json.Nodes;
namespace AiCli.GeminiBridge;

// Operational metadata only. Neither prompts, model responses, upstream error
// prose, credentials nor identity-bearing diagnostic strings are retained.
public sealed record TerminalEvidence(string Status,bool ErrorPresent,int ErrorCharacters,string LastStep,
    bool AgentTextObserved,bool NativeToolAttempted,int InputCharacters,int InputItems,int ToolCount);
public static class TerminalFailures
{
    public static BridgeException Read(JsonObject result,string lastStep,bool agentText,bool nativeTool,
        int inputCharacters,int inputItems,int toolCount)
    {
        var status=JsonValueReader.Text(result,"status");
        var knownStatus=status is "SUCCESS" or "ERROR" or "CANCELED" or "INTERRUPTED" or "INVALID" or "WAITING" or "RUNNING" ? status : "UNKNOWN";
        var text=JsonValueReader.Text(result,"error");
        var classified=AntigravitySession.ClassifyError(text);
        var code=classified.Code;
        if(knownStatus=="SUCCESS" && string.IsNullOrWhiteSpace(JsonValueReader.Text(result,"response")))
            code="antigravity_empty_model_response";
        if(code=="google_model_request_failed") code=knownStatus switch
        {
            "CANCELED" => "antigravity_generation_canceled",
            "INTERRUPTED" => "antigravity_generation_interrupted",
            "WAITING" => "antigravity_waiting_for_input",
            "RUNNING" => "antigravity_nonterminal_result",
            "INVALID" => "antigravity_invalid_result_state",
            "UNKNOWN" => "antigravity_unknown_result_status",
            _ => code
        };
        var step=lastStep is "user_input" or "agent_response" or "tool" or "checkpoint" or "error" ? lastStep : "other";
        return new BridgeException(code,classified.Status){Hints=classified.Hints,
            Evidence=new TerminalEvidence(knownStatus,text is not null,text?.Length??0,step,agentText,nativeTool,inputCharacters,inputItems,toolCount)};
    }
}