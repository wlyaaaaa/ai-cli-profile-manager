#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Status','Install','UpdateModels','Disable','Freeze')][string]$Mode='Status',
    [string]$SourceRoot=(Split-Path -Parent $PSScriptRoot),
    [string]$AgyExecutable,
    [string]$BuildRoot,
    [string]$ModelSetPath,
    [string]$IsolationReceiptPath,
    [string]$ModelAcceptanceReceiptPath,
    [string]$PreparedCandidateDirectory
)
$ErrorActionPreference='Stop'
# Keep native command decoding deterministic in GUI/no-console and captured hosts.
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$module=Import-Module (Join-Path $SourceRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force -PassThru
if ($Mode -eq 'Status') {
    & $module {
        $d=Get-AiCliGeminiDeployment -VerifyFiles -IncludeDisabled
        $state=Get-AiCliGeminiIntegrationState
        $raw=Read-AiCliGeminiJson -Path (Get-AiCliGeminiPaths).Deployment -Optional
        $deploymentLifecycle=if($raw){[string](Get-AiCliProperty $raw 'lifecycle' 'unspecified')}else{'not-installed'}
        $deploymentEnabled=$null -ne $d -and $d.Enabled
        $frozen=$state.state -ceq 'frozen' -or $deploymentLifecycle -ceq 'frozen'
        [pscustomobject]@{installed=($null-ne$d);enabled=($null-ne$d-and$d.Enabled-and-not$frozen);lifecycle=$(if($frozen){'frozen'}else{$state.state});moduleLifecycle=$state.state;deploymentLifecycle=$deploymentLifecycle;deploymentEnabled=$deploymentEnabled;releaseId=$(if($d){$d.ReleaseId}else{$null});endpoint=$(if($d){$d.Endpoint}else{$null});desktopAcceptance=$(if($frozen){'not-passed-frozen'}else{'user-pending'})}
    }
    return
}
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'consumer_user_session_required' }
if ($Mode -in @('Disable','Freeze')) {
    & $module {
        param($Operation)
        Stop-AiCliGeminiBridge
        $paths=Get-AiCliGeminiPaths
        $lock=Enter-AiCliFileLock -TargetPath $paths.Lock -TimeoutMs 15000
        try {
            if (Test-Path -LiteralPath $paths.Deployment) {
                $d=Read-AiCliJsonFile -Path $paths.Deployment
                $d['enabled']=$false;$d['lastOperation']=$Operation
                if($Operation-eq'Freeze'){
                    $d['lifecycle']='frozen';$d['frozenUtc']=[DateTimeOffset]::UtcNow.ToString('o')
                    $d['freezeReason']='user_requested_freeze_daily_use_not_delivered'
                    $d['desktopAcceptance']='not-passed-frozen'
                }
                Write-AiCliJsonFile -Path $paths.Deployment -Value $d
            }
        } finally { Exit-AiCliFileLock -Lock $lock }
        [pscustomobject]@{enabled=$false;lifecycle=$(if($Operation-eq'Freeze'){'frozen'}else{'disabled'});consumerLoginUnchanged=$true}
    } $Mode
    return
}
# Check before invoking the CLI, compiling, validating live models or changing snapshots.
& $module { Assert-AiCliGeminiIntegrationActive }
. (Join-Path $PSScriptRoot 'GeminiModelData.ps1')
. (Join-Path $PSScriptRoot 'GeminiModelAcceptance.ps1')
if($PreparedCandidateDirectory){
    $PreparedCandidateDirectory=[IO.Path]::GetFullPath($PreparedCandidateDirectory)
$candidateItem=Get-Item -LiteralPath $PreparedCandidateDirectory -Force -ErrorAction Stop
    if(-not$candidateItem.PSIsContainer-or($candidateItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'gemini_prepared_candidate_invalid'}
$children=@(Get-ChildItem -LiteralPath $PreparedCandidateDirectory -Force)
    if(@($children|Where-Object {$_.PSIsContainer-or($_.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0}).Count){throw 'gemini_prepared_candidate_invalid'}
$candidateModelSet=Join-Path $PreparedCandidateDirectory 'gemini-models.json'
    if($ModelSetPath-and[IO.Path]::GetFullPath($ModelSetPath)-cne$candidateModelSet){throw 'gemini_prepared_model_set_mismatch'}
$ModelSetPath=$candidateModelSet
    if([string]::IsNullOrWhiteSpace($ModelAcceptanceReceiptPath)-or[string]::IsNullOrWhiteSpace($IsolationReceiptPath)){throw 'gemini_prepared_candidate_receipts_required'}
}
if(-not$ModelSetPath){$ModelSetPath=Join-Path $SourceRoot 'data\gemini-models.json'}
$modelSet=Read-AiCliGeminiModelSet -Path $ModelSetPath -SchemaPath (Join-Path $SourceRoot 'data\schemas\gemini-model-set.schema.json')
$sourceDeployment=& $module {Get-AiCliGeminiDeployment -VerifyFiles -IncludeDisabled}
if($Mode-eq'UpdateModels' -and ($null-eq$sourceDeployment -or $sourceDeployment.DriverProtocolVersion-ne2)){throw 'gemini_v2_driver_install_required'}
if(-not$AgyExecutable){$AgyExecutable=if($sourceDeployment){$sourceDeployment.Settings.AgyExecutable}else{(Get-Command agy -ErrorAction Stop).Source}}
$AgyExecutable=[IO.Path]::GetFullPath($AgyExecutable)
$approved=[string]$modelSet.cli.approvedSha256
if((Get-FileHash -LiteralPath $AgyExecutable -Algorithm SHA256).Hash.ToLowerInvariant()-cne$approved){throw 'antigravity_version_not_approved'}
$isolationReceiptExplicit=-not[string]::IsNullOrWhiteSpace($IsolationReceiptPath)
if(-not$isolationReceiptExplicit -and $sourceDeployment){$IsolationReceiptPath=[string]$sourceDeployment.Settings['IsolationReceiptPath']}
$needsIsolation=[string]::IsNullOrWhiteSpace($IsolationReceiptPath)-or-not(Test-Path -LiteralPath $IsolationReceiptPath -PathType Leaf)
if($Mode-eq'UpdateModels' -and $needsIsolation){throw 'isolation_verification_required'}
if($Mode-eq'UpdateModels' -and $sourceDeployment.Settings.AgySha256-cne$approved){throw 'model_update_cannot_change_cli_runtime'}
$pwsh=Join-Path $PSHOME 'pwsh.exe'
$interpreterHash=(Get-FileHash -LiteralPath $pwsh -Algorithm SHA256).Hash.ToLowerInvariant()
$dotnet=(Get-Command dotnet -ErrorAction Stop).Source
if($PreparedCandidateDirectory){
    $publish=$PreparedCandidateDirectory
}else{
    if (-not $BuildRoot) { $BuildRoot=Join-Path ([IO.Path]::GetTempPath()) ('aicli-gemini-build-'+[guid]::NewGuid().ToString('N')) }
    $BuildRoot=[IO.Path]::GetFullPath($BuildRoot)
    $publish=Join-Path $BuildRoot 'publish'
    if (Test-Path -LiteralPath $publish) { throw 'gemini_publish_directory_must_be_new' }
    $project=Join-Path $SourceRoot 'src\AiCliProfileManager\Support\GeminiBridge\GeminiBridge.csproj'
    if($Mode-eq'UpdateModels'){
        [IO.Directory]::CreateDirectory($publish)|Out-Null
        $oldDir=Split-Path -Parent $sourceDeployment.Executable
        Get-ChildItem -LiteralPath $oldDir -File|Where-Object {$_.Name-notin@('gemini-models.json','gemini-codex-catalog.json')}|ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $publish $_.Name)}
    }else{
        & $dotnet publish $project -c Release --self-contained false --artifacts-path (Join-Path $BuildRoot 'artifacts') -o $publish --nologo -v minimal
        if($LASTEXITCODE-ne0){throw 'gemini_publish_failed'}
    }
    $null=& (Join-Path $SourceRoot 'scripts\Build-GeminiCodexCatalog.ps1') -SourceRoot $SourceRoot -ModelSetPath $ModelSetPath -OutputRoot $publish -RuntimeBundle
}
$runtimeJson=& $dotnet (Join-Path $publish 'AiCli.GeminiResponsesBridge.dll') --describe-runtime
if($LASTEXITCODE-ne0){throw 'gemini_runtime_descriptor_failed'}
$runtime=($runtimeJson-join"`n")|ConvertFrom-Json
if($runtime.driverProtocolVersion-ne2){throw 'gemini_v2_driver_install_required'}
if(-not$needsIsolation){
    $receiptMatches=$false
    try {
        $existingReceipt=[IO.File]::ReadAllText([IO.Path]::GetFullPath($IsolationReceiptPath),[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
        $receiptMatches=($existingReceipt.schema-ceq'aicli.antigravity-isolation.v2' -and
            $existingReceipt.cliSha256-ceq$approved -and $existingReceipt.interpreterSha256-ceq$interpreterHash -and
            $existingReceipt.templateSha256-ceq[string]$runtime.isolationTemplateSha256 -and
            $existingReceipt.preToolDenialObserved-eq$true -and $existingReceipt.cleanupVerified-eq$true)
    } catch {$receiptMatches=$false}
    if(-not$receiptMatches){
        if($Mode-eq'UpdateModels' -or $isolationReceiptExplicit){throw 'isolation_receipt_mismatch'}
        $needsIsolation=$true;$IsolationReceiptPath=$null
    }
}
if($needsIsolation){
    if($Mode-ne'Install'){throw 'isolation_verification_required'}
    $IsolationReceiptPath=Join-Path $BuildRoot 'isolation-v2.json'
    $isolationRuntime=Join-Path $BuildRoot 'isolation-runtime';[IO.Directory]::CreateDirectory($isolationRuntime)|Out-Null
    $isolationSettings=Join-Path $BuildRoot 'isolation-settings.json'
    $isolationConfig=[ordered]@{AgyExecutable=$AgyExecutable;AgySha256=$approved;PowerShellExecutable=$pwsh;RuntimeDirectory=$isolationRuntime;Port=0;TurnTimeoutSeconds=600;IdleSeconds=900;MaxSessions=1;ModelCatalogPath=(Join-Path $publish 'gemini-models.json');IsolationReceiptPath=$IsolationReceiptPath}
    [IO.File]::WriteAllText($isolationSettings,($isolationConfig|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $verifyInfo=[Diagnostics.ProcessStartInfo]::new((Join-Path $publish 'AiCli.GeminiResponsesBridge.exe'));$verifyInfo.UseShellExecute=$false;$verifyInfo.CreateNoWindow=$true;$verifyInfo.RedirectStandardOutput=$true;$verifyInfo.RedirectStandardError=$true;$verifyInfo.ArgumentList.Add('--verify-isolation');$verifyInfo.ArgumentList.Add($isolationSettings);foreach($k in @('TEMP','TMP','TMPDIR')){$verifyInfo.Environment[$k]=$BuildRoot}
    $verify=[Diagnostics.Process]::Start($verifyInfo);$verifyOut=$verify.StandardOutput.ReadToEndAsync();$verifyErr=$verify.StandardError.ReadToEndAsync();if(-not$verify.WaitForExit(660000)){$verify.Kill($true);$verify.WaitForExit(5000)|Out-Null;throw 'isolation_verification_timeout'};if($verify.ExitCode-ne0){$null=$verifyOut.GetAwaiter().GetResult();$null=$verifyErr.GetAwaiter().GetResult();throw 'isolation_verification_failed'};$verify.Dispose()
    if(-not(Test-Path -LiteralPath $IsolationReceiptPath -PathType Leaf)){throw 'isolation_verification_receipt_missing'}
}
$receiptBytes=[IO.File]::ReadAllBytes($IsolationReceiptPath)
$receipt=[Text.Encoding]::UTF8.GetString($receiptBytes)|ConvertFrom-Json
if($receipt.schema-cne'aicli.antigravity-isolation.v2' -or $receipt.cliSha256-cne$approved -or $receipt.interpreterSha256-cne$interpreterHash -or
    $receipt.templateSha256-cne$runtime.isolationTemplateSha256 -or $receipt.preToolDenialObserved-ne$true -or $receipt.cleanupVerified-ne$true){throw 'isolation_receipt_mismatch'}
if ($LASTEXITCODE -ne 0) { throw 'gemini_publish_failed' }
$files=@(Get-ChildItem -LiteralPath $publish -File|Sort-Object Name|ForEach-Object {
    [ordered]@{path=$_.Name;size=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
if (-not(Test-Path -LiteralPath (Join-Path $publish 'AiCli.GeminiResponsesBridge.exe'))) { throw 'gemini_apphost_missing' }
$releaseText=($files|ConvertTo-Json -Depth 5 -Compress)
$releaseId=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($releaseText))).ToLowerInvariant().Substring(0,16)
$modelSetSha=(Get-FileHash -LiteralPath (Join-Path $publish 'gemini-models.json') -Algorithm SHA256).Hash.ToLowerInvariant()
$isolationReceiptSha=(Get-FileHash -LiteralPath $IsolationReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
if($ModelAcceptanceReceiptPath){
    $acceptancePath=[IO.Path]::GetFullPath($ModelAcceptanceReceiptPath)
    if(-not(Test-Path -LiteralPath $acceptancePath -PathType Leaf)){throw 'gemini_model_acceptance_missing'}
}else{
    $acceptancePath=Join-Path $BuildRoot 'model-acceptance.json'
    $null=& (Join-Path $SourceRoot 'scripts\Test-GeminiModelCandidate.ps1') -CandidateDirectory $publish -IsolationReceiptPath $IsolationReceiptPath -AgyExecutable $AgyExecutable -OutputReceiptPath $acceptancePath
}
$acceptance=Read-AiCliGeminiModelAcceptance -Path $acceptancePath -ModelSet $modelSet -CandidateReleaseId $releaseId -ModelSetSha256 $modelSetSha -CliSha256 $approved -IsolationReceiptSha256 $isolationReceiptSha
$acceptanceBytes=[IO.File]::ReadAllBytes($acceptancePath)
& $module {
    param($Publish,$Files,$ReleaseId,$Agy,$Approved,$Pwsh,$ExpectedRelease,$ReceiptBytes,$AcceptanceBytes,$Operation)
    $paths=Get-AiCliGeminiPaths
    [IO.Directory]::CreateDirectory($paths.Root)|Out-Null
    Assert-AiCliGeminiNormalPath $paths.Root -Directory
    $allocation=Enter-AiCliFileLock -TargetPath (Get-AiCliProxyGlobalLockTarget) -TimeoutMs 30000
    $stage=$null;$oldDeployment=$null;$oldSettings=$null;$oldReceipt=$null;$receiptPath=$null;$modelAcceptancePath=$null;$oldAcceptance=$null;$switched=$false;$wasEnabled=$false;$configurationChanged=$false;$oldStopped=$false
    try {
        $old=Get-AiCliGeminiDeployment -VerifyFiles -IncludeDisabled
        if (($old -and $old.ReleaseId -cne $ExpectedRelease) -or (-not $old -and $ExpectedRelease)) { throw 'gemini_deployment_changed_during_prepare' }
        $wasEnabled=$null -ne $old -and $old.Enabled
        if ($wasEnabled) { Stop-AiCliGeminiBridge; $oldStopped=$true }
        if (Test-Path -LiteralPath $paths.Deployment) { $oldDeployment=[IO.File]::ReadAllBytes($paths.Deployment) }
        if (Test-Path -LiteralPath $paths.Settings) { $oldSettings=[IO.File]::ReadAllBytes($paths.Settings) }
        # Existing endpoint identity is stable across releases and thread resume.
        $port=if($null -ne $old){$old.Port}else{Select-AiCliProxyPort -ProxyId antigravity -PreferPersisted}
        if (@(Get-AiCliTcpListeners -Port $port).Count -gt 0) { throw 'gemini_port_occupied' }
        $releases=Join-Path $paths.Root 'releases'
        [IO.Directory]::CreateDirectory($releases)|Out-Null
        Assert-AiCliGeminiNormalPath $releases -Directory
        $destination=Join-Path $releases $ReleaseId
        if (-not(Test-Path -LiteralPath $destination)) {
            $stage=Join-Path $releases ('.stage-'+[guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($stage)|Out-Null
            foreach($file in $Files) { Copy-Item -LiteralPath (Join-Path $Publish $file.path) -Destination (Join-Path $stage $file.path) }
            [IO.Directory]::Move($stage,$destination);$stage=$null
        }
        Assert-AiCliGeminiNormalPath $destination -Directory
        foreach($file in $Files) {
            $path=Join-Path $destination $file.path
            Assert-AiCliGeminiNormalPath $path
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) { throw 'gemini_release_readback_failed' }
        }
        if (-not(Test-Path -LiteralPath $paths.Token)) {
            $random=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
            $plain=[Text.Encoding]::UTF8.GetBytes([Convert]::ToHexString($random).ToLowerInvariant())
            try {
                $encrypted=[Security.Cryptography.ProtectedData]::Protect($plain,[Text.Encoding]::UTF8.GetBytes('aicli.gemini-local-token.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
                [IO.File]::WriteAllBytes($paths.Token,$encrypted)
            } finally { [Array]::Clear($random,0,$random.Length);[Array]::Clear($plain,0,$plain.Length) }
        }
        $null=Get-AiCliGeminiLocalToken
        $receiptPath=Join-Path $paths.Root 'isolation-v2.json'
        if(Test-Path -LiteralPath $receiptPath){Assert-AiCliGeminiNormalPath $receiptPath;$oldReceipt=[IO.File]::ReadAllBytes($receiptPath)}
        $configurationChanged=$true
        [IO.File]::WriteAllBytes($receiptPath,$ReceiptBytes)
        $modelAcceptancePath=Join-Path $paths.Root ('model-acceptance-'+$ReleaseId+'.json')
        if(Test-Path -LiteralPath $modelAcceptancePath){Assert-AiCliGeminiNormalPath $modelAcceptancePath;$oldAcceptance=[IO.File]::ReadAllBytes($modelAcceptancePath)}
        [IO.File]::WriteAllBytes($modelAcceptancePath,$AcceptanceBytes)
        $modelAcceptanceSha=(Get-FileHash -LiteralPath $modelAcceptancePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $settings=[ordered]@{AgyExecutable=$Agy;AgySha256=$Approved;PowerShellExecutable=$Pwsh;RuntimeDirectory=(Join-Path $paths.Root 'work');Port=$port;TurnTimeoutSeconds=600;IdleSeconds=900;MaxSessions=4;ModelCatalogPath=(Join-Path $destination 'gemini-models.json');IsolationReceiptPath=$receiptPath}
        Write-AiCliJsonFile -Path $paths.Settings -Value $settings
        $deployment=[ordered]@{
            schema='aicli.gemini-deployment.v1';enabled=$true;releaseId=$ReleaseId;port=$port;files=$Files;driverProtocolVersion=2;lastOperation=$Operation;modelAcceptanceFile=([IO.Path]::GetFileName($modelAcceptancePath));modelAcceptanceSha256=$modelAcceptanceSha
            settingsSha256=(Get-FileHash -LiteralPath $paths.Settings -Algorithm SHA256).Hash.ToLowerInvariant()
            previousRelease=$(if($old){$old.ReleaseId}else{$null});desktopAcceptance='user-pending'
        }
        Write-AiCliJsonFile -Path $paths.Deployment -Value $deployment
        $switched=$true
        $verified=Get-AiCliGeminiDeployment -VerifyFiles
        if ($verified.ReleaseId -cne $ReleaseId) { throw 'gemini_deployment_readback_failed' }
        $null=Start-AiCliGeminiBridge
        Save-AiCliProxyPort -ProxyId antigravity -Port $port
        [pscustomobject]@{installed=$true;releaseId=$ReleaseId;endpoint=$verified.Endpoint;consumerLoginUnchanged=$true;desktopAcceptance='user-pending'}
    } catch {
        # Failed validation or a busy old backend must not delete the existing
        # settings just because no rollback preimage has been captured yet.
        if($configurationChanged){
            if($switched){try{Stop-AiCliGeminiBridge}catch{throw 'gemini_failed_candidate_cleanup_required'}}
            if($null-ne$oldSettings){[IO.File]::WriteAllBytes($paths.Settings,$oldSettings)}
            elseif(Test-Path -LiteralPath $paths.Settings){Remove-Item -LiteralPath $paths.Settings -Force}
            if($null-ne$oldDeployment){[IO.File]::WriteAllBytes($paths.Deployment,$oldDeployment)}
            elseif(Test-Path -LiteralPath $paths.Deployment){Remove-Item -LiteralPath $paths.Deployment -Force}
            if($receiptPath){
                if($null-ne$oldReceipt){[IO.File]::WriteAllBytes($receiptPath,$oldReceipt)}
                elseif(Test-Path -LiteralPath $receiptPath){Remove-Item -LiteralPath $receiptPath -Force}
            }
            if($modelAcceptancePath){
                if($null-ne$oldAcceptance){[IO.File]::WriteAllBytes($modelAcceptancePath,$oldAcceptance)}
                elseif(Test-Path -LiteralPath $modelAcceptancePath){Remove-Item -LiteralPath $modelAcceptancePath -Force}
            }
        }
        if($oldStopped){try{$null=Start-AiCliGeminiBridge}catch{throw 'gemini_install_failed_and_previous_runtime_restart_failed'}}
        throw
    } finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
        Exit-AiCliFileLock -Lock $allocation
    }
} -Publish $publish -Files $files -ReleaseId $releaseId -Agy $AgyExecutable -Approved $approved -Pwsh $pwsh -ExpectedRelease $(if($sourceDeployment){$sourceDeployment.ReleaseId}else{$null}) -ReceiptBytes $receiptBytes -AcceptanceBytes $acceptanceBytes -Operation $Mode
