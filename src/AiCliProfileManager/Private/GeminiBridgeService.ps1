function Read-AiCliGeminiJson {
    param([Parameter(Mandatory)][string]$Path,[switch]$Optional)
    if ($Optional -and -not(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $value=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 100
        if ($value -isnot [Collections.IDictionary]) { throw 'invalid_json_object' }
        return $value
    } catch { throw 'gemini_runtime_metadata_invalid' }
}
# Gemini uses the official consumer login only in the model child.
# This local token authenticates the loopback adapter, never a Google API.
$script:AiCliGeminiModuleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

# This checked-in module state is copied by normal installation/recovery.
# Old enabled deployment receipts must not reactivate a deliberately frozen route.
function Get-AiCliGeminiIntegrationState {
    $state=Read-AiCliGeminiJson -Path (Join-Path $script:AiCliGeminiModuleRoot 'Support\GeminiIntegrationState.json')
    if($state.schema -cne 'aicli.gemini-integration-state.v1' -or $state.state -cnotin @('experimental','frozen')){throw 'gemini_integration_state_invalid'}
    return $state
}
function Test-AiCliGeminiIntegrationFrozen { return (Get-AiCliGeminiIntegrationState).state -ceq 'frozen' }
function Assert-AiCliGeminiIntegrationActive {
    if(Test-AiCliGeminiIntegrationFrozen){throw 'gemini_integration_frozen'}
    $paths=Get-AiCliGeminiPaths
    $deployment=Read-AiCliGeminiJson -Path $paths.Deployment -Optional
    if($deployment -and [string](Get-AiCliProperty $deployment 'lifecycle') -ceq 'frozen'){throw 'gemini_integration_frozen'}
}
function Get-AiCliGeminiPaths {
    $root = Join-Path (Get-AiCliAppPaths).LocalRoot 'gemini'
    return [pscustomobject]@{
        Root=$root; Deployment=(Join-Path $root 'deployment.json')
        Settings=(Join-Path $root 'settings.json'); Token=(Join-Path $root 'local-token.dpapi')
        Process=(Join-Path $root 'process.json'); Lock=(Join-Path $root 'startup')
    }
}
function Assert-AiCliGeminiNormalPath {
    param([Parameter(Mandatory)][string]$Path,[switch]$Directory)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.PSIsContainer -ne $Directory.IsPresent) {
        throw 'gemini_runtime_path_invalid'
    }
}
function Get-AiCliGeminiDeployment {
    param([switch]$VerifyFiles,[switch]$IncludeDisabled)
    if(-not $IncludeDisabled -and (Test-AiCliGeminiIntegrationFrozen)){return $null}
    $paths=Get-AiCliGeminiPaths
    if (-not(Test-Path -LiteralPath $paths.Deployment -PathType Leaf)) { return $null }
    Assert-AiCliGeminiNormalPath $paths.Root -Directory
    Assert-AiCliGeminiNormalPath $paths.Deployment
    $d=Read-AiCliGeminiJson -Path $paths.Deployment
    if ((Get-AiCliProperty $d 'schema') -cne 'aicli.gemini-deployment.v1' -or
        (-not $IncludeDisabled -and (-not [bool](Get-AiCliProperty $d 'enabled' $false) -or [string](Get-AiCliProperty $d 'lifecycle') -ceq 'frozen'))) { return $null }
    $release=[string](Get-AiCliProperty $d 'releaseId')
    if ($release -cnotmatch '^[a-f0-9]{16}$') { throw 'gemini_release_identity_invalid' }
    $releaseRoot=Join-Path $paths.Root ('releases\'+$release)
    Assert-AiCliGeminiNormalPath (Join-Path $paths.Root 'releases') -Directory
    Assert-AiCliGeminiNormalPath $releaseRoot -Directory
    Assert-AiCliGeminiNormalPath $paths.Settings
    Assert-AiCliGeminiNormalPath $paths.Token
    $settings=Read-AiCliGeminiJson -Path $paths.Settings
    $port=[int](Get-AiCliProperty $settings 'Port')
    if ($port -lt 1024 -or $port -gt 49151 -or $port -ne [int](Get-AiCliProperty $d 'port')) { throw 'gemini_port_identity_invalid' }
    $exe=Join-Path $releaseRoot 'AiCli.GeminiResponsesBridge.exe'
    Assert-AiCliGeminiNormalPath $exe
    if ($VerifyFiles) {
        $files=@(Get-AiCliProperty $d 'files')
        if ($files.Count -lt 3 -or $files.Count -gt 30) { throw 'gemini_release_manifest_invalid' }
        $actual=@(Get-ChildItem -LiteralPath $releaseRoot -File -Recurse|ForEach-Object { $_.FullName.Substring($releaseRoot.Length+1) }|Sort-Object)
        $expected=@($files|ForEach-Object { [string](Get-AiCliProperty $_ 'path') }|Sort-Object)
        if (($actual -join "`n") -cne ($expected -join "`n")) { throw 'gemini_release_file_set_changed' }
        foreach($file in $files) {
            $name=[string](Get-AiCliProperty $file 'path')
            if ([IO.Path]::GetFileName($name) -cne $name -or $name -match '[:\\/]') { throw 'gemini_release_file_path_invalid' }
            $path=Join-Path $releaseRoot $name
            Assert-AiCliGeminiNormalPath $path
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string](Get-AiCliProperty $file 'sha256')) { throw 'gemini_release_hash_changed' }
        }
        if ((Get-FileHash -LiteralPath $paths.Settings -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string](Get-AiCliProperty $d 'settingsSha256')) { throw 'gemini_settings_changed' }
        if ([int](Get-AiCliProperty $d 'driverProtocolVersion' 1) -ge 2) {
            $acceptanceName=[string](Get-AiCliProperty $d 'modelAcceptanceFile')
            if ($acceptanceName -cne ('model-acceptance-'+$release+'.json')) { throw 'gemini_model_acceptance_identity_invalid' }
            $acceptancePath=Join-Path $paths.Root $acceptanceName
            Assert-AiCliGeminiNormalPath $acceptancePath
            $acceptanceHash=[string](Get-AiCliProperty $d 'modelAcceptanceSha256')
            if ($acceptanceHash -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $acceptancePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $acceptanceHash) { throw 'gemini_model_acceptance_hash_changed' }
            $acceptance=Read-AiCliGeminiJson -Path $acceptancePath
            if ($acceptance.schema -cne 'aicli.gemini-model-acceptance.v1' -or $acceptance.pass -ne $true -or $acceptance.candidateReleaseId -cne $release) { throw 'gemini_model_acceptance_invalid' }
            $modelSetPath=[string](Get-AiCliProperty $settings 'ModelCatalogPath')
            $expectedModelSetPath=Join-Path $releaseRoot 'gemini-models.json'
            if ($modelSetPath -cne $expectedModelSetPath) { throw 'gemini_model_set_path_mismatch' }
            Assert-AiCliGeminiNormalPath $modelSetPath
            if ((Get-FileHash -LiteralPath $modelSetPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$acceptance.modelSetSha256) { throw 'gemini_model_acceptance_model_set_mismatch' }
            if ([string]$acceptance.cliSha256 -cne [string](Get-AiCliProperty $settings 'AgySha256')) { throw 'gemini_model_acceptance_cli_mismatch' }
        }
    }
    return [pscustomobject]@{ Paths=$paths; Settings=$settings; Executable=$exe; ReleaseId=$release; Enabled=[bool](Get-AiCliProperty $d 'enabled' $false); DriverProtocolVersion=[int](Get-AiCliProperty $d 'driverProtocolVersion' 1); Port=$port; Endpoint="http://127.0.0.1:$port/v1" }
}
function Get-AiCliGeminiLocalToken {
    $path=(Get-AiCliGeminiPaths).Token
    Assert-AiCliGeminiNormalPath $path
    $protected=[IO.File]::ReadAllBytes($path)
    $plain=$null
    try {
        $plain=[Security.Cryptography.ProtectedData]::Unprotect($protected,[Text.Encoding]::UTF8.GetBytes('aicli.gemini-local-token.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $token=[Text.Encoding]::UTF8.GetString($plain)
        if ($token -cnotmatch '^[a-f0-9]{64}$') { throw 'gemini_local_token_invalid' }
        return $token
    } catch { throw 'gemini_local_token_unavailable' }
    finally { if ($null -ne $plain) { [Array]::Clear($plain,0,$plain.Length) } }
}
function Invoke-AiCliGeminiControl {
    param([Parameter(Mandatory)]$Deployment,[Parameter(Mandatory)][string]$Token,[ValidateSet('health','shutdown')][string]$Operation='health')
    $handler=[Net.Http.SocketsHttpHandler]::new();$handler.UseProxy=$false;$handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler,$true);$client.Timeout=[TimeSpan]::FromSeconds(2)
    $message=[Net.Http.HttpRequestMessage]::new($(if($Operation -eq 'health'){'GET'}else{'POST'}),"http://127.0.0.1:$($Deployment.Port)/$Operation")
    $message.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Token)
    try {
        $response=$client.SendAsync($message).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { return $null }
            $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($body.Length -gt 2048) { return $null }
            return ($body|ConvertFrom-Json -AsHashtable)
        } finally { $response.Dispose() }
    } catch { return $null }
    finally { $message.Dispose();$client.Dispose() }
}
function Test-AiCliGeminiProcessReceipt {
    param([Parameter(Mandatory)]$Deployment,$Receipt)
    if ($null -eq $Receipt -or (Get-AiCliProperty $Receipt 'schema') -cne 'aicli.gemini-process.v1') { return $null }
    $processId=[int](Get-AiCliProperty $Receipt 'pid')
    if ($processId -le 0) { return $null }
    $p=Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    try {
        # A reused PID after restart is a stale record, not an ownership claim.
        # No unrelated process is stopped; occupied ports are checked separately.
        if ($p.StartTime.ToUniversalTime().Ticks -ne [long](Get-AiCliProperty $Receipt 'startTicks') -or
            [string](Get-AiCliProperty $Receipt 'releaseId') -cne $Deployment.ReleaseId) {
            $p.Dispose();return $null
        }
        $image=$p.Path
        if (-not [string]::IsNullOrEmpty($image) -and
            -not [string]::Equals($image,$Deployment.Executable,[StringComparison]::OrdinalIgnoreCase)) {
            $p.Dispose();return $null
        }
        # Windows can hide an elevated same-user process image. Exact start time
        # alone is not sufficient: Start/Stop must also authenticate /health and
        # match its PID before reuse or shutdown, including this legacy case.
        return $p
    } catch { $p.Dispose();throw 'gemini_process_identity_unavailable' }
}
function Start-AiCliGeminiBridge {
    Assert-AiCliGeminiIntegrationActive
    # Discovery stays model-free. The native model process is only created by
    # an actual Responses request after this local adapter has started.
    $d=Get-AiCliGeminiDeployment -VerifyFiles
    if ($null -eq $d) { throw 'gemini_bridge_not_installed' }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'gemini_consumer_user_session_required' }
    $lock=Enter-AiCliFileLock -TargetPath $d.Paths.Lock -TimeoutMs 15000
    $localToken=$null
    try {
        $localToken=Get-AiCliGeminiLocalToken
        $receipt=Read-AiCliGeminiJson -Path $d.Paths.Process -Optional
        $old=Test-AiCliGeminiProcessReceipt -Deployment $d -Receipt $receipt
        if ($null -ne $old) {
            try {
                $health=Invoke-AiCliGeminiControl -Deployment $d -Token $localToken
                if ($null -ne $health -and $health.component -ceq 'aicli.gemini-responses' -and [int]$health.pid -eq $old.Id) { return $d }
                throw 'gemini_existing_process_unresponsive'
            } finally { $old.Dispose() }
        }
        if (@(Get-AiCliTcpListeners -Port $d.Port).Count -gt 0) { throw 'gemini_port_occupied_by_other_process' }
        # The short-lived native auth helper must not be the owner of a daemon's
        # output pipes. The independent shell host reads its own local token.
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -ErrorAction Stop).Source)
        $start.UseShellExecute=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
        $start.WorkingDirectory=$d.Paths.Root
        foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-File',
            (Join-Path $script:AiCliGeminiModuleRoot 'Support\GetDesktopGeminiToken.ps1'),'-ServiceHost','-ExpectedRelease',$d.ReleaseId)) { $start.ArgumentList.Add($arg) }
        $p=[Diagnostics.Process]::Start($start)
        $started=$false
        try {
            $deadline=[DateTime]::UtcNow.AddSeconds(12)
            do {
                $health=Invoke-AiCliGeminiControl -Deployment $d -Token $localToken
                if ($null -ne $health -and $health.component -ceq 'aicli.gemini-responses') {
                    $ready=Read-AiCliGeminiJson -Path $d.Paths.Process -Optional
                    $native=Test-AiCliGeminiProcessReceipt -Deployment $d -Receipt $ready
                    if($native){try{if([int]$health.pid -eq $native.Id){$started=$true;return $d}}finally{$native.Dispose()}}
                }
                if ($p.HasExited) { throw 'gemini_adapter_start_failed' }
                Start-Sleep -Milliseconds 100
            } while([DateTime]::UtcNow -lt $deadline)
            throw 'gemini_adapter_start_timed_out'
        } finally {
            if (-not $started -and -not $p.HasExited) { $p.Kill($true);[void]$p.WaitForExit(5000) }
            # Do not relay or retain raw provider diagnostics.
            $p.Dispose()
        }
    } finally { $localToken=$null; Exit-AiCliFileLock -Lock $lock }
}
function Stop-AiCliGeminiBridge {
    $d=Get-AiCliGeminiDeployment -IncludeDisabled
    if ($null -eq $d) { return }
    $lock=Enter-AiCliFileLock -TargetPath $d.Paths.Lock -TimeoutMs 15000
    try {
        $receipt=Read-AiCliGeminiJson -Path $d.Paths.Process -Optional
        $p=Test-AiCliGeminiProcessReceipt -Deployment $d -Receipt $receipt
        if ($null -eq $p) { return }
        try {
            $token=Get-AiCliGeminiLocalToken
            $health=Invoke-AiCliGeminiControl -Deployment $d -Token $token
            if ($null -eq $health -or $health.component -cne 'aicli.gemini-responses' -or [int]$health.pid -ne $p.Id) { throw 'gemini_existing_process_unresponsive' }
            $reply=Invoke-AiCliGeminiControl -Deployment $d -Token $token -Operation shutdown
            if ($null -eq $reply -or -not $reply.stopping) { throw 'gemini_shutdown_not_acknowledged' }
            if (-not $p.WaitForExit(20000)) { throw 'gemini_shutdown_cleanup_pending' }
        } finally { $token=$null;$p.Dispose() }
    } finally { Exit-AiCliFileLock -Lock $lock }
}
function Get-AiCliGeminiCodexSearchConfiguration {
    $pwsh=(Get-Command pwsh -ErrorAction Stop).Source
    return [ordered]@{
        command=$pwsh;args=@('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $script:AiCliGeminiModuleRoot 'Support\PublicWebSearchMcp.ps1'))
        enabled=$true;required=$true;enabled_tools=@('public_web_search');startup_timeout_sec=15;tool_timeout_sec=30
    }
}
function Get-AiCliDesktopGeminiModels {
    $d=Get-AiCliGeminiDeployment -VerifyFiles
    if ($null -eq $d) { return }
    $releaseRoot=Split-Path -Parent $d.Executable
    $setPath=Join-Path $releaseRoot 'gemini-models.json'
    $catalogPath=Join-Path $releaseRoot 'gemini-codex-catalog.json'
    if([string](Get-AiCliProperty $d.Settings 'ModelCatalogPath') -cne $setPath){throw 'gemini_model_set_path_mismatch'}
    Assert-AiCliGeminiNormalPath $setPath;Assert-AiCliGeminiNormalPath $catalogPath
    $set=Read-AiCliGeminiJson $setPath;$catalog=Read-AiCliGeminiJson $catalogPath
    if($set.schema -cne 'aicli.gemini-model-set.v1' -or $catalog.schema -cne 'aicli.gemini-runtime-catalog.v1' -or $set.defaultModel -cne $catalog.defaultModel){throw 'gemini_model_catalog_invalid'}
    $models=@($set.models);$entries=@($catalog.entries)
    if($models.Count -lt 1 -or $models.Count -ne $entries.Count){throw 'gemini_model_catalog_count_mismatch'}
    $helper=Join-Path $script:AiCliGeminiModuleRoot 'Support\GetDesktopGeminiToken.ps1';Assert-AiCliGeminiNormalPath $helper
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($definition in $models){
        $matching=@($entries|Where-Object {$_.modelId -ceq $definition.id})
        if($matching.Count-ne1){throw 'gemini_model_catalog_identity_mismatch'}
        $entry=$matching[0];$model=$entry.catalogModel
        if(-not$ids.Add($entry.model) -or $entry.profileId -cne $definition.profileId -or $entry.model -cne $definition.menuModel -or
            $entry.defaultEffort -cne $definition.defaultEffort -or $model.slug -cne $entry.model -or
            [long]$entry.contextWindow -ne [long]$definition.contextWindow -or [long]$model.context_window -ne [long]$definition.contextWindow -or
            [long]$model.auto_compact_token_limit -ne [long][math]::Floor([long]$definition.contextWindow*90/100) -or
            ((@($model.supported_reasoning_levels|ForEach-Object effort)-join ',') -cne (@($definition.efforts|ForEach-Object effort)-join ','))){throw 'gemini_model_catalog_projection_mismatch'}
        [ordered]@{
            profileId=$definition.profileId;model=$definition.menuModel;providerId='aicli_google_antigravity';routeProviderId='aicli_google_antigravity';kind='managed-proxy';adapterProtocol='gemini-fresh-transaction-v2'
            provider=[ordered]@{
                name='Google Antigravity';base_url=$d.Endpoint;wire_api='responses';requires_openai_auth=$false
                request_max_retries=0;stream_max_retries=0;stream_idle_timeout_ms=650000
                # Zero means indefinitely cached in native Codex. A positive minimal TTL
                # reruns the local readiness helper before model requests, including after idle exit.
                auth=[ordered]@{command=(Get-Command pwsh).Source;args=@('-NoLogo','-NoProfile','-NonInteractive','-File',$helper);timeout_ms=20000;refresh_interval_ms=1}
            }
            catalogModel=$model;catalogPath=$catalogPath;contextWindow=[long]$definition.contextWindow;defaultEffort=$definition.defaultEffort
            managedPublicWebSearch=(Get-AiCliGeminiCodexSearchConfiguration)
        }
    }
}

function Invoke-AiCliGeminiBridgeHost {
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{16}$')][string]$ExpectedRelease)
    Assert-AiCliGeminiIntegrationActive
    if([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem){throw 'gemini_consumer_user_session_required'}
    $d=Get-AiCliGeminiDeployment -VerifyFiles
    if($null-eq$d -or $d.ReleaseId-cne$ExpectedRelease){throw 'gemini_launch_release_changed'}
    $token=$null;$process=$null;$ready=$false;$start=$null
    try {
        $token=Get-AiCliGeminiLocalToken
        $start=[Diagnostics.ProcessStartInfo]::new($d.Executable)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.ArgumentList.Add('--settings');$start.ArgumentList.Add($d.Paths.Settings)
        foreach($key in @($start.Environment.Keys)) {
            if($key -match '^(OPENAI|ANTHROPIC|CODEX|AICLI|GEMINI|GOOGLE|VERTEX|GCLOUD|CLOUDSDK|DEEPSEEK|DASHSCOPE|ZHIPU|GLM|QWEN|AGENTS)(_|$)'){[void]$start.Environment.Remove($key)}
        }
        $start.Environment['AICLI_GEMINI_BRIDGE_TOKEN']=$token
        foreach($key in @('TEMP','TMP','TMPDIR')){$start.Environment[$key]=[string]$d.Settings.RuntimeDirectory}
        $start.WorkingDirectory=$d.Paths.Root
        $process=[Diagnostics.Process]::Start($start);$process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $deadline=[DateTime]::UtcNow.AddSeconds(12)
        do {
            if($process.HasExited){throw 'gemini_adapter_start_failed'}
            $health=Invoke-AiCliGeminiControl -Deployment $d -Token $token
            if($health -and $health.component-ceq'aicli.gemini-responses' -and [int]$health.pid-eq$process.Id){
                Write-AiCliJsonFile -Path $d.Paths.Process -Value ([ordered]@{schema='aicli.gemini-process.v1';pid=$process.Id;startTicks=$process.StartTime.ToUniversalTime().Ticks;releaseId=$d.ReleaseId})
                $ready=$true;break
            }
            Start-Sleep -Milliseconds 100
        }while([DateTime]::UtcNow-lt$deadline)
        if(-not$ready){throw 'gemini_adapter_start_timed_out'}
        $token=$null;$start.Environment.Remove('AICLI_GEMINI_BRIDGE_TOKEN')|Out-Null
        $process.WaitForExit()
    } finally {
        $token=$null
        if($null -ne $start){[void]$start.Environment.Remove('AICLI_GEMINI_BRIDGE_TOKEN')}
        if($process){if(-not$process.HasExited){$process.Kill($true);$process.WaitForExit(5000)|Out-Null};$process.Dispose()}
    }
}
