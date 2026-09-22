# Pure acceptance receipt verification. Never starts a model or mutates deployment.
function Read-AiCliGeminiModelAcceptance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$ModelSet,
        [Parameter(Mandatory)][string]$CandidateReleaseId,
        [Parameter(Mandatory)][string]$ModelSetSha256,
        [Parameter(Mandatory)][string]$CliSha256,
        [Parameter(Mandatory)][string]$IsolationReceiptSha256,
        [TimeSpan]$MaxAge=[TimeSpan]::FromHours(24)
    )
    $raw=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    $r=$raw|ConvertFrom-Json -AsHashtable -Depth 40
    if($r.schema-cne'aicli.gemini-model-acceptance.v1'-or$r.pass-ne$true-or$r.candidateReleaseId-cne$CandidateReleaseId-or
       $r.modelSetSha256-cne$ModelSetSha256-or$r.cliSha256-cne$CliSha256-or$r.isolationReceiptSha256-cne$IsolationReceiptSha256-or[int]$r.driverProtocolVersion-ne2){throw 'gemini_model_acceptance_mismatch'}
    try{$verified=[DateTimeOffset]::Parse([string]$r.verifiedUtc,[Globalization.CultureInfo]::InvariantCulture)}catch{throw 'gemini_model_acceptance_time_invalid'}
    $now=[DateTimeOffset]::UtcNow;if($verified-gt$now.AddMinutes(5)-or($now-$verified)-gt$MaxAge){throw 'gemini_model_acceptance_expired'}
    $expected=@($ModelSet.models|ForEach-Object {$m=$_;@($m.efforts|ForEach-Object {$m.id+'|'+$_.model+'|'+$_.effort+'|'+$_.cliEffort})})
    $coverage=@($r.coverage);if($coverage.Count-ne$expected.Count){throw 'gemini_model_acceptance_coverage_mismatch'}
    $actual=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($c in $coverage){
        $outcome=[string]$c.outcome
        if($outcome-ceq'capability_pass'){
            if($c.summaryObserved-ne$true-or$c.toolIntentVerified-ne$true-or$c.nonceRoundTrip-ne$true-or$c.freshTransactionsVerified-ne$true){throw 'gemini_model_acceptance_capability_missing'}
        } elseif($outcome-ceq'allowed_operational_error'){
            if([string]$c.errorCode-cnotin@('google_location_not_supported','google_connection_failed')-or[int]$c.operationalAttempts-lt1-or[int]$c.operationalAttempts-gt3){throw 'gemini_model_acceptance_operational_error_invalid'}
            if([string]$c.failurePhase-cnotin@('tool_intent','tool_result')){throw 'gemini_model_acceptance_operational_error_invalid'}
            if($c.nonceRoundTrip-eq$true){throw 'gemini_model_acceptance_operational_error_invalid'}
        } else { throw 'gemini_model_acceptance_outcome_invalid' }
        $key=[string]$c.modelId+'|'+[string]$c.requestedModel+'|'+[string]$c.effort+'|'+[string]$c.cliEffort
        if(-not$actual.Add($key)){throw 'gemini_model_acceptance_duplicate_coverage'}
    }
    foreach($m in $ModelSet.models){if(@($coverage|Where-Object {$_.modelId-ceq$m.id-and$_.outcome-ceq'capability_pass'}).Count-lt1){throw 'gemini_model_acceptance_model_group_unproven'}}    if((($expected|Sort-Object)-join"`n")-cne((@($actual)|Sort-Object)-join"`n")){throw 'gemini_model_acceptance_coverage_mismatch'}
    return $r
}