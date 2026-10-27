function Set-AiCliVendorCredentialFromStdin {
    param([string]$Query, [string]$Secret)
    # Set targets a registered catalog entry; the value is one UTF-8 stdin line.
    $broker = Join-Path (Split-Path (Get-AiCliVendorBrokerPath) -Parent) 'Invoke-SecretBroker.ps1'
    $process = $null
    try {
        if (-not $Query -or -not $Secret -or $Secret.Length -gt 65536 -or $Secret -match '[\r\n\x00]') { throw 'invalid' }
        $start = [Diagnostics.ProcessStartInfo]::new('pwsh')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        foreach ($arg in @('-NoProfile','-NonInteractive','-File',$broker,'-Action','Set','-Query',$Query,
            '-AgentSecretFromStdin','-AuthorityFactor','Runtime','-Json')) { [void]$start.ArgumentList.Add($arg) }
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.StandardInput.WriteLineAsync($Secret).Wait(30000)) { throw 'timeout' }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(120000)) { throw 'timeout' }
        $receipt = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json -ErrorAction Stop
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $receipt.schema -cne 'pcconfig.secret-broker-result.v1' -or
            $receipt.action -cne 'set' -or $receipt.status -cne 'pass' -or $receipt.plaintext_returned -ne $false) { throw 'failed' }
    } catch { throw 'Password Center: migration_set_failed' }
    finally {
        $Secret = $null
        if ($process) {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(2000) }
            $process.Dispose()
        }
    }
}

function Test-AiCliMigrationSecretEqual {
    param([string]$Left, [string]$Right)
    $leftBytes = [Text.Encoding]::UTF8.GetBytes($Left)
    $rightBytes = [Text.Encoding]::UTF8.GetBytes($Right)
    try {
        return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            [Security.Cryptography.SHA256]::HashData($leftBytes), [Security.Cryptography.SHA256]::HashData($rightBytes))
    } finally {
        [Array]::Clear($leftBytes, 0, $leftBytes.Length)
        [Array]::Clear($rightBytes, 0, $rightBytes.Length)
    }
}

function Invoke-AiCliSecretMigration {
    <#
    .SYNOPSIS
      将旧本地密文引用迁移到密码中心；保留旧密文，改写前自动备份 Profile。
    .PARAMETER DryRun
      读取并比对凭据，报告计划，不写密码中心或 Profile。
    .EXAMPLE
      Import-Module AiCliProfileManager; Invoke-AiCliSecretMigration -DryRun
    #>
    [CmdletBinding()]
    param([switch]$DryRun)
    $vendors = Get-AiCliVendorRegistrations
    $paths = Get-AiCliAppPaths
    foreach ($file in @(Get-ChildItem -LiteralPath $paths.ProfilesDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $vendor = $null; $old = $null; $current = $null; $lock = $null; $reference = $null
        $row = [ordered]@{ profile_id=$file.BaseName; vendor=$null; action='none'; status='migration_failed' }
        try {
            $original = [IO.File]::ReadAllText($file.FullName)
            $profile = $original | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
            $reference = [string](Get-AiCliProperty $profile 'secretRef')
            if ($reference -notmatch '^[a-fA-F0-9]{32}$') { continue }
            $endpoint = [string](Get-AiCliProperty $profile 'endpoint')
            if (-not $endpoint) {
                $template = Get-AiCliProviderManifest -Id ([string](Get-AiCliProperty $profile 'templateId'))
                $endpoint = [string](Get-AiCliProperty $template 'endpoint')
            }
            $uri = $null
            $matches = @()
            if ([Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https') {
                $matches = @($vendors.Keys | Where-Object { $uri.DnsSafeHost -in @($vendors[$_].native_hosts) })
            }
            if ($matches.Count -ne 1) { $row.status='vendor_not_registered'; continue }
            $vendor = [string]$matches[0]; $row.vendor=$vendor; $row.action='migrate'
            $old = Get-AiCliSecret -SecretId $reference
            try { $current = Request-AiCliVendorCredential -Vendor $vendor -Endpoint $endpoint }
            catch {
                if ($_.Exception.Message -notmatch '^Password Center: (agent_secretref_credential_entry_missing|catalog_entry_not_found|database_entry_not_found)$') { throw }
                $row.action='set_and_migrate'
                if ($DryRun) { $row.status='dry_run'; continue }
                Set-AiCliVendorCredentialFromStdin -Query ([string]$vendors[$vendor].credential_ref) -Secret $old
                $current = Request-AiCliVendorCredential -Vendor $vendor -Endpoint $endpoint
            }
            if (-not (Test-AiCliMigrationSecretEqual -Left $old -Right $current)) { $row.status='value_differs'; continue }
            if ($DryRun) { $row.status='dry_run'; continue }
            $lock = Enter-AiCliFileLock -TargetPath $file.FullName
            if ([IO.File]::ReadAllText($file.FullName) -cne $original) { $row.status='profile_changed'; continue }
            $profile['secretRef'] = 'passwordcenter:' + $vendor
            Write-AiCliJsonFile -Path $file.FullName -Value $profile -SkipLock
            $row.status='migrated'
        } catch { $row.status = if ($_.Exception.Message -ceq 'Password Center: migration_set_failed') { 'set_failed' } else { 'migration_failed' } }
        finally {
            if ($lock) { Exit-AiCliFileLock -Lock $lock }
            $old=$null; $current=$null
            if ($reference -match '^[a-fA-F0-9]{32}$') { [pscustomobject]$row }
        }
    }
}
