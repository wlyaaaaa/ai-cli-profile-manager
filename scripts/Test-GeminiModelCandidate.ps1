#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CandidateDirectory,[Parameter(Mandatory)][string]$IsolationReceiptPath,[string]$AgyExecutable,[string]$OutputReceiptPath,[int]$PerRequestTimeoutSeconds=360,[Alias('MaxLocationAttempts')][ValidateRange(1,3)][int]$MaxOperationalAttempts=1)
$ErrorActionPreference='Stop'
if([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem){throw 'consumer_user_session_required'}
$SourceRoot=Split-Path -Parent $PSScriptRoot
$freezeModule=Import-Module (Join-Path $SourceRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force -PassThru
& $freezeModule { Assert-AiCliGeminiIntegrationActive }
. (Join-Path $PSScriptRoot 'GeminiModelData.ps1')
$CandidateDirectory=[IO.Path]::GetFullPath($CandidateDirectory);$IsolationReceiptPath=[IO.Path]::GetFullPath($IsolationReceiptPath)
function Assert-Normal([string]$Path,[switch]$Directory){$i=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;if(($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or$i.PSIsContainer-ne$Directory.IsPresent){throw 'candidate_path_invalid'}}
Assert-Normal $CandidateDirectory -Directory;Assert-Normal $IsolationReceiptPath
$modelPath=Join-Path $CandidateDirectory 'gemini-models.json';$runtimeCatalog=Join-Path $CandidateDirectory 'gemini-codex-catalog.json';$exe=Join-Path $CandidateDirectory 'AiCli.GeminiResponsesBridge.exe';$dll=Join-Path $CandidateDirectory 'AiCli.GeminiResponsesBridge.dll'
foreach($x in @($modelPath,$runtimeCatalog,$exe,$dll)){Assert-Normal $x}
$set=Read-AiCliGeminiModelSet -Path $modelPath -SchemaPath (Join-Path $SourceRoot 'data\schemas\gemini-model-set.schema.json')
if(@($set.models|Where-Object {-not[bool]$_.supportsPublicSummary}).Count){throw 'candidate_public_summary_required'}
if(-not$AgyExecutable){$AgyExecutable=(Get-Command agy -ErrorAction Stop).Source};$AgyExecutable=[IO.Path]::GetFullPath($AgyExecutable);Assert-Normal $AgyExecutable
$cliHash=(Get-FileHash $AgyExecutable -Algorithm SHA256).Hash.ToLowerInvariant();if($cliHash-cne[string]$set.cli.approvedSha256){throw 'candidate_cli_identity_mismatch'}
$dotnet=(Get-Command dotnet -ErrorAction Stop).Source;$runtimeRaw=@(& $dotnet $dll --describe-runtime 2>$null);if($LASTEXITCODE-ne0){throw 'candidate_runtime_descriptor_failed'};$runtime=($runtimeRaw-join"`n")|ConvertFrom-Json
if([int]$runtime.driverProtocolVersion-ne2-or[string]$runtime.modelSetSchema-cne'aicli.gemini-model-set.v1'){throw 'candidate_driver_protocol_mismatch'}
$iso=Get-Content $IsolationReceiptPath -Raw -Encoding utf8|ConvertFrom-Json;$pwsh=Join-Path $PSHOME 'pwsh.exe';$pwshHash=(Get-FileHash $pwsh -Algorithm SHA256).Hash.ToLowerInvariant()
if($iso.schema-cne'aicli.antigravity-isolation.v2'-or$iso.cliSha256-cne$cliHash-or$iso.interpreterSha256-cne$pwshHash-or$iso.templateSha256-cne[string]$runtime.isolationTemplateSha256-or$iso.preToolDenialObserved-ne$true-or$iso.cleanupVerified-ne$true){throw 'candidate_isolation_receipt_mismatch'}
$files=@(Get-ChildItem $CandidateDirectory -File|Sort-Object Name|ForEach-Object {[ordered]@{path=$_.Name;size=$_.Length;sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}});$releaseText=$files|ConvertTo-Json -Depth 5 -Compress;$releaseId=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($releaseText))).ToLowerInvariant().Substring(0,16)
$modelSetSha=(Get-FileHash $modelPath -Algorithm SHA256).Hash.ToLowerInvariant();$isolationSha=(Get-FileHash $IsolationReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant();if(-not$OutputReceiptPath){$OutputReceiptPath=Join-Path (Split-Path $CandidateDirectory -Parent) ('gemini-model-acceptance-'+$releaseId+'.json')};$OutputReceiptPath=[IO.Path]::GetFullPath($OutputReceiptPath)
$run=Join-Path ([IO.Path]::GetTempPath()) ('aicli-gemini-candidate-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($run)|Out-Null;$runtimeDir=Join-Path $run 'runtime';[IO.Directory]::CreateDirectory($runtimeDir)|Out-Null
$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();$port=([Net.IPEndPoint]$l.LocalEndpoint).Port;$l.Stop();$settingsPath=Join-Path $run 'settings.json';$settings=[ordered]@{AgyExecutable=$AgyExecutable;AgySha256=$cliHash;PowerShellExecutable=$pwsh;RuntimeDirectory=$runtimeDir;Port=$port;TurnTimeoutSeconds=$PerRequestTimeoutSeconds;IdleSeconds=900;MaxSessions=1;ModelCatalogPath=$modelPath;IsolationReceiptPath=$IsolationReceiptPath};[IO.File]::WriteAllText($settingsPath,($settings|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$token=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant();$process=$null;$client=$null;$coverage=[Collections.Generic.List[object]]::new();$identities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$allowedOperationalErrors=@('google_location_not_supported','google_connection_failed');
$failureReceiptPath=$OutputReceiptPath+'.failure.json';$script:AcceptanceModel=$null;$script:AcceptanceEffort=$null;$script:AcceptancePhase='startup';$script:AcceptanceSummaryEvents=0
function New-Body([string]$Model,[string]$Effort,[object[]]$InputItems,[object[]]$Tools,[string]$ToolChoice,[bool]$Stream){[ordered]@{model=$Model;instructions='Synthetic candidate acceptance only. Never invent the virtual nonce. Use visible_summary only for public progress, never hidden reasoning.';input=@($InputItems);tools=@($Tools);tool_choice=$ToolChoice;parallel_tool_calls=$false;reasoning=@{effort=$Effort;summary='detailed'};stream=$Stream;store=$false}}
function Invoke-Json($Body){$m=[Net.Http.HttpRequestMessage]::new('POST',"http://127.0.0.1:$port/v1/responses");$m.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token);$m.Content=[Net.Http.StringContent]::new(($Body|ConvertTo-Json -Depth 60 -Compress),[Text.Encoding]::UTF8,'application/json');try{$r=$client.SendAsync($m).GetAwaiter().GetResult();$text=$r.Content.ReadAsStringAsync().GetAwaiter().GetResult();if(-not$r.IsSuccessStatusCode){$code='candidate_http_failure';try{$j=$text|ConvertFrom-Json;$code=[string]$j.error.code}catch{};throw $code};return $text}finally{$m.Dispose()}}
function Read-Stream([string]$Text){$events=[Collections.Generic.List[object]]::new();foreach($line in ($Text -split"`r?`n")){if($line.StartsWith('data: ')){try{$events.Add(($line.Substring(6)|ConvertFrom-Json -Depth 80))}catch{throw 'candidate_sse_json_invalid'}}};$script:AcceptanceSummaryEvents=@($events|Where-Object {$_.type -eq 'response.reasoning_summary_text.delta'}|Where-Object {-not[string]::IsNullOrWhiteSpace([string]$_.delta)}).Count;$failed=$events|Where-Object {$_.type -eq 'response.failed'}|Select-Object -Last 1;if($failed){throw ([string]$failed.response.error.code)};$completed=$events|Where-Object {$_.type -eq 'response.completed'}|Select-Object -Last 1;if(-not$completed){throw 'candidate_response_completed_missing'};[pscustomobject]@{Events=$events;Response=$completed.response}}
function Read-Health{$m=[Net.Http.HttpRequestMessage]::new('GET',"http://127.0.0.1:$port/health");$m.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token);try{$r=$client.SendAsync($m).GetAwaiter().GetResult();if(-not$r.IsSuccessStatusCode){throw 'candidate_health_failed'};return($r.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json -Depth 30)}finally{$m.Dispose()}}
try{
    $psi=[Diagnostics.ProcessStartInfo]::new($exe);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.ArgumentList.Add('--settings');$psi.ArgumentList.Add($settingsPath);$psi.Environment['AICLI_GEMINI_BRIDGE_TOKEN']=$token;foreach($k in @('TEMP','TMP','TMPDIR')){$psi.Environment[$k]=$run}
    $process=[Diagnostics.Process]::Start($psi);$stderrTask=$process.StandardError.ReadToEndAsync();$startupTask=$process.StandardOutput.ReadLineAsync();if(-not$startupTask.Wait(20000)){throw 'candidate_bridge_start_timeout'};$startup=$startupTask.Result|ConvertFrom-Json;if($startup.component-cne'aicli.gemini-responses'-or@($startup.addresses)-notcontains"http://127.0.0.1:$port"){throw 'candidate_bridge_identity_mismatch'}
    $handler=[Net.Http.SocketsHttpHandler]::new();$handler.UseProxy=$false;$client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds($PerRequestTimeoutSeconds+30)
    foreach($definition in $set.models){foreach($mapping in $definition.efforts){
        $script:AcceptanceModel=[string]$mapping.model;$script:AcceptanceEffort=[string]$mapping.effort;$script:AcceptanceSummaryEvents=0
        $clock=[Diagnostics.Stopwatch]::StartNew();$nonce=[guid]::NewGuid().ToString('N');$tool=[ordered]@{type='function';name='read_nonce';description='Synthetic candidate acceptance virtual function';parameters=@{type='object';properties=@{};additionalProperties=$false}}
        $firstInput=@([ordered]@{role='user';content='这是候选模型验收。请先用简短中文公开说明准备读取测试随机值，然后调用 read_nonce。不要猜值。'})
        $script:AcceptancePhase='tool_intent';$script:AcceptanceSummaryEvents=0
        try{$stream=Read-Stream (Invoke-Json (New-Body ([string]$mapping.model) ([string]$mapping.effort) $firstInput @($tool) 'required' $true))}
        catch{
            $code=[string]$_.Exception.Message;if($code-cnotin$allowedOperationalErrors){throw};$health=$null;try{$health=Read-Health}catch{};$attempts=[int]$(if($health){$health.backend.StartupAttempts}else{1})
            $coverage.Add([ordered]@{modelId=$definition.id;menuModel=$definition.menuModel;requestedModel=$mapping.model;effort=$mapping.effort;cliEffort=$mapping.cliEffort;outcome='allowed_operational_error';errorCode=$code;failurePhase='tool_intent';operationalAttempts=$attempts;summaryObserved=$false;toolIntentVerified=$false;nonceRoundTrip=$false;freshTransactionsVerified=$false;seconds=[math]::Round($clock.Elapsed.TotalSeconds,2)})
            continue
        }
        $summaryDeltas=@($stream.Events|Where-Object {$_.type -eq 'response.reasoning_summary_text.delta'}|ForEach-Object {[string]$_.delta}|Where-Object {-not[string]::IsNullOrWhiteSpace($_)});if($summaryDeltas.Count-lt1){throw 'candidate_public_summary_missing'}
        $calls=@($stream.Response.output|Where-Object {$_.type-eq'function_call'-and$_.name-eq'read_nonce'});if($calls.Count-ne1){throw 'candidate_tool_intent_invalid'};$call=$calls[0];$h1=Read-Health;$identity1=[string]$h1.backend.TransportIdentity;if([string]::IsNullOrWhiteSpace($identity1)-or-not$identities.Add($identity1)){throw 'candidate_transport_identity_reused'}
        $history=@($firstInput[0],$call,[ordered]@{type='function_call_output';call_id=$call.call_id;output=$nonce});$script:AcceptancePhase='tool_result'
        try{$finalText=Invoke-Json (New-Body ([string]$mapping.model) ([string]$mapping.effort) $history @($tool) 'none' $false);$final=$finalText|ConvertFrom-Json -Depth 80}
        catch{
            $code=[string]$_.Exception.Message;if($code-cnotin$allowedOperationalErrors){throw};$health=$null;try{$health=Read-Health}catch{};$attempts=[int]$(if($health){$health.backend.StartupAttempts}else{1})
            $coverage.Add([ordered]@{modelId=$definition.id;menuModel=$definition.menuModel;requestedModel=$mapping.model;effort=$mapping.effort;cliEffort=$mapping.cliEffort;outcome='allowed_operational_error';errorCode=$code;failurePhase='tool_result';operationalAttempts=$attempts;summaryObserved=$true;toolIntentVerified=$true;nonceRoundTrip=$false;freshTransactionsVerified=$false;seconds=[math]::Round($clock.Elapsed.TotalSeconds,2)})
            continue
        }
        if($final.status-cne'completed'){throw 'candidate_final_response_incomplete'}
        $answer=(@($final.output|Where-Object {$_.type -eq 'message'}|ForEach-Object {$_.content|Where-Object {$_.type -eq 'output_text'}|ForEach-Object {$_.text}})-join'');if(-not$answer.Contains($nonce,[StringComparison]::Ordinal)){throw 'candidate_nonce_roundtrip_failed'};$h2=Read-Health;$identity2=[string]$h2.backend.TransportIdentity;if([string]::IsNullOrWhiteSpace($identity2)-or-not$identities.Add($identity2)){throw 'candidate_transport_identity_reused'}
        $coverage.Add([ordered]@{modelId=$definition.id;menuModel=$definition.menuModel;requestedModel=$mapping.model;effort=$mapping.effort;cliEffort=$mapping.cliEffort;outcome='capability_pass';errorCode=$null;failurePhase=$null;operationalAttempts=0;summaryObserved=$true;toolIntentVerified=$true;nonceRoundTrip=$true;freshTransactionsVerified=($identity1-cne$identity2);seconds=[math]::Round($clock.Elapsed.TotalSeconds,2)})
    }}
    foreach($definition in $set.models){if(@($coverage|Where-Object {$_.modelId-ceq$definition.id-and$_.outcome-ceq'capability_pass'}).Count-lt1){throw 'candidate_model_group_has_no_capability_pass'}}    $expected=@($set.models|ForEach-Object {$m=$_;@($m.efforts|ForEach-Object {$m.id+'|'+$_.model+'|'+$_.effort})});$actual=@($coverage|ForEach-Object {$_.modelId+'|'+$_.requestedModel+'|'+$_.effort});if((($expected|Sort-Object)-join"`n")-cne(($actual|Sort-Object)-join"`n")){throw 'candidate_acceptance_coverage_incomplete'}
    $receipt=[ordered]@{schema='aicli.gemini-model-acceptance.v1';pass=$true;candidateReleaseId=$releaseId;modelSetSha256=$modelSetSha;cliSha256=$cliHash;isolationReceiptSha256=$isolationSha;driverProtocolVersion=2;verifiedUtc=[DateTimeOffset]::UtcNow.ToString('O');coverage=@($coverage|ForEach-Object {$_})}
    $parent=Split-Path $OutputReceiptPath -Parent;[IO.Directory]::CreateDirectory($parent)|Out-Null;$tmp=$OutputReceiptPath+'.new-'+[guid]::NewGuid().ToString('N');try{[IO.File]::WriteAllText($tmp,($receipt|ConvertTo-Json -Depth 12)+"`n",[Text.UTF8Encoding]::new($false));[IO.File]::Move($tmp,$OutputReceiptPath,$true)}finally{if(Test-Path $tmp){Remove-Item $tmp -Force}};$receipt
}catch{
    $raw=[string]$_.Exception.Message
    $safeCode=if($raw -cmatch '^[a-z0-9_:-]{1,120}$'){$raw}else{$_.Exception.GetType().Name}
    $backend=$null
    if($client){try{$backend=(Read-Health).backend}catch{}}
    $failure=[ordered]@{
        schema='aicli.gemini-model-acceptance-failure.v1';pass=$false;candidateReleaseId=$releaseId;modelSetSha256=$modelSetSha
        requestedModel=$script:AcceptanceModel;effort=$script:AcceptanceEffort;phase=$script:AcceptancePhase;errorCode=$safeCode
        summaryEvents=[int]$script:AcceptanceSummaryEvents
        backend=$(if($backend){[ordered]@{phase=$backend.Phase;failure=$backend.Failure;hints=@($backend.Hints);startupAttempts=$backend.StartupAttempts;recoveryAttempts=$backend.RecoveryAttempts;terminal=$backend.Terminal}}else{$null})
        observedUtc=[DateTimeOffset]::UtcNow.ToString('O')
    }
    try{[IO.File]::WriteAllText($failureReceiptPath,($failure|ConvertTo-Json -Depth 10)+"`n",[Text.UTF8Encoding]::new($false))}catch{}
    throw
}finally{
    if($client){try{$m=[Net.Http.HttpRequestMessage]::new('POST',"http://127.0.0.1:$port/shutdown");$m.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token);$null=$client.SendAsync($m).GetAwaiter().GetResult();$m.Dispose()}catch{};$client.Dispose()}
    if($process){try{if(-not$process.WaitForExit(8000)){$process.Kill($true);$process.WaitForExit(5000)|Out-Null}}catch{};$process.Dispose()}
    $token=$null
    if(Test-Path $runtimeDir){$sessions=@(Get-ChildItem -LiteralPath $runtimeDir -Directory -Filter 'session_*' -ErrorAction SilentlyContinue);if($sessions.Count){throw 'candidate_runtime_cleanup_incomplete'}}
    if(Test-Path $run){Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue}
}