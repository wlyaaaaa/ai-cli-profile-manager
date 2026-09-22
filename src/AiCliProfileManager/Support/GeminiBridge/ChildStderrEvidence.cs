namespace AiCli.GeminiBridge;

// Ephemeral stderr is classified into fixed operational labels. Raw lines,
// account identifiers, URLs and credentials are never retained or logged.
public sealed class ChildStderrEvidence
{
    private BridgeException? last;
    public BridgeException? Failure=>Volatile.Read(ref last);
    public bool AbortChild=>Failure?.Code is "antigravity_login_required" or "antigravity_credential_store_unavailable";
    public void Observe(string text)
    {
        BridgeException? candidate=null;
        if(text.Contains("token too long",StringComparison.OrdinalIgnoreCase)||text.Contains("input too large",StringComparison.OrdinalIgnoreCase))
            candidate=new BridgeException("backend_input_size_rejected",502){Hints=["stdin_size"]};
        else if(text.Contains("invalid JSON",StringComparison.OrdinalIgnoreCase)||text.Contains("invalid character",StringComparison.OrdinalIgnoreCase))
            candidate=new BridgeException("backend_input_json_rejected",502){Hints=["stdin_json"]};
        else
        {
            var classified=AntigravitySession.ClassifyError(text);
            if(classified.Code is "google_connection_failed" or "antigravity_login_required" or "google_location_not_supported" or
                "google_quota_exhausted" or "antigravity_credential_store_unavailable")candidate=classified;
        }
        if(candidate is not null)Volatile.Write(ref last,candidate);
    }
}