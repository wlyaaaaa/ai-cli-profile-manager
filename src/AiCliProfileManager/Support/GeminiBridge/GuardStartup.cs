namespace AiCli.GeminiBridge;

// Fixed-label diagnostics only. V2 retains no cross-request session or retry state.
public sealed record BackendDiagnostics(string Phase,string? Failure,string[] Hints,int StartupAttempts,int RecoveryAttempts=0,TerminalEvidence? Terminal=null,string? TransportIdentity=null,int? BackendProcessId=null);
