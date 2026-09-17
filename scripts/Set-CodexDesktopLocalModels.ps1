#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Build', 'Enable', 'Disable')][string]$Mode = 'Status',
    [string]$InstallRoot,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$module = Import-Module (Join-Path $repo 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force -PassThru
$paths = Get-AiCliAppPaths
if (-not $InstallRoot) { $InstallRoot = Join-Path $paths['LocalRoot'] 'desktop' }
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$statePath = Join-Path $InstallRoot 'state.json'
$state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
$current = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
$utf8 = [Text.UTF8Encoding]::new($false)

function Write-State($Value) {
    [IO.Directory]::CreateDirectory($InstallRoot) | Out-Null
    $temporary = $statePath + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), $utf8)
        [IO.File]::Move($temporary, $statePath, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Set-UserDesktopEntry([AllowNull()][string]$Value) {
    # Environment.SetEnvironmentVariable(User) performs its own long broadcast
    # to every window. Write the same user setting, then use our bounded notice.
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        if ([string]::IsNullOrEmpty($Value)) { $key.DeleteValue('CODEX_CLI_PATH', $false) }
        else { $key.SetValue('CODEX_CLI_PATH', $Value, [Microsoft.Win32.RegistryValueKind]::String) }
    } finally { $key.Dispose() }
}

function Invoke-Utf8JsonPowerShellFile {
    param([Parameter(Mandatory)][string]$Path)

    $pwsh = Get-Command pwsh -ErrorAction Stop
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwsh.Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # PowerShell-to-PowerShell native pipes still pass through the parent
    # process decoder. Pin both redirected streams to UTF-8 so Chinese model
    # instructions cannot be decoded with the Windows ACP and consume JSON
    # delimiter bytes.
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', [IO.Path]::GetFullPath($Path))) {
        [void]$start.ArgumentList.Add([string]$arg)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            throw 'Desktop discovery process timed out.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw ('Desktop discovery failed: ' + $stderr.Trim())
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            throw ('Desktop discovery wrote unexpected stderr: ' + $stderr.Trim())
        }
        try {
            return $stdout | ConvertFrom-Json -Depth 100
        }
        catch {
            throw ('Desktop discovery returned invalid UTF-8 JSON: ' + $_.Exception.Message)
        }
    }
    finally { $process.Dispose() }
}

function Test-ProtectedBridgeApproval {
    param(
        [Parameter(Mandatory)][string]$ReleaseDirectory,
        [string]$RegistryPath = (Join-Path (
            [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::CommonApplicationData
            )
        ) 'PCConfig\AuthorityHost\registries\aicli_desktop_bridge.json')
    )

    try {
        $releaseDirectory = [IO.Path]::GetFullPath($ReleaseDirectory)
        $releaseId = Split-Path $releaseDirectory -Leaf
        if ($releaseId -cnotmatch '^[a-f0-9]{16}$' -or
            -not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
            return $false
        }
        $registryFile = Get-Item -LiteralPath $RegistryPath -Force
        if ($registryFile.Length -lt 2 -or $registryFile.Length -gt 65536 -or
            ($registryFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $registry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 20
        if ([string]$registry.schema -cne
                'pcconfig.aicli-desktop-bridge-allowlist.v1') {
            return $false
        }
        $matches = @($registry.releases | Where-Object {
            [string]$_.release_id -ceq $releaseId
        })
        if ($matches.Count -ne 1) { return $false }
        $approved = $matches[0]
        $approvedRoot = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables(
                [string]$approved.install_root
            )
        )
        if (-not [string]::Equals(
                $approvedRoot,
                $releaseDirectory,
                [StringComparison]::OrdinalIgnoreCase
            ) -or @($approved.files).Count -ne 7) {
            return $false
        }
        $releaseItem = Get-Item -LiteralPath $releaseDirectory -Force
        if (($releaseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $actualFiles = @(Get-ChildItem -LiteralPath $releaseDirectory `
            -Recurse -File -Force | ForEach-Object {
                $_.FullName.Substring($releaseDirectory.Length + 1)
            } | Sort-Object)
        $approvedFiles = @($approved.files | ForEach-Object {
            [string]$_.path
        } | Sort-Object)
        if (($actualFiles -join "`n") -cne ($approvedFiles -join "`n")) {
            return $false
        }
        foreach ($file in @($approved.files)) {
            $relative = [string]$file.path
            if ([string]::IsNullOrWhiteSpace($relative) -or
                [IO.Path]::IsPathRooted($relative) -or
                $relative -match '(^|[\\/])\.\.([\\/]|$)' -or
                [long]$file.size -lt 1 -or
                [string]$file.sha256 -cnotmatch '^[a-f0-9]{64}$') {
                return $false
            }
            $candidate = [IO.Path]::GetFullPath(
                (Join-Path $releaseDirectory $relative)
            )
            if (-not $candidate.StartsWith(
                    $releaseDirectory.TrimEnd('\') + '\',
                    [StringComparison]::OrdinalIgnoreCase
                ) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                return $false
            }
            $cursor = Split-Path $candidate -Parent
            while (-not [string]::Equals(
                    $cursor,
                    $releaseDirectory,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                if (-not $cursor.StartsWith(
                        $releaseDirectory.TrimEnd('\') + '\',
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                    return $false
                }
                $directoryItem = Get-Item -LiteralPath $cursor -Force
                if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return $false
                }
                $cursor = Split-Path $cursor -Parent
            }
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $item.Length -ne [long]$file.size -or
                (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                    [string]$file.sha256) {
                return $false
            }
        }
        return $true
    }
    catch { return $false }
}
function Notify-EnvironmentChange {
    if (-not ('AiCliDesktopEnvironmentNotice' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AiCliDesktopEnvironmentNotice {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, UIntPtr wparam,
        string lparam, uint flags, uint timeout, out UIntPtr result);
}
'@
    }
    $result = [UIntPtr]::Zero
    # Broadcast applies the timeout to each top-level window. Keep a hung
    # unrelated window from holding installation open for minutes.
    [void][AiCliDesktopEnvironmentNotice]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 100, [ref]$result)
}

function Register-LocalProviders($Plan) {
    $path = Join-Path $Plan.codexHome 'config.toml'
    $original = [IO.File]::ReadAllText($path)
    $updated = $original
    $definitions = [ordered]@{}
    $localModels = @($Plan.models | Where-Object { $_.kind -eq 'local' })
    if ($localModels.Count -eq 0) { return }
    foreach ($entry in $localModels) { $definitions[$entry.providerId] = $entry.provider }
    $definitions['aicli_desktop_local'] = $localModels[0].provider
    # This legacy provider was recorded in tasks made by the older AICLI entry.
    if ($original -match '(?m)^\[model_providers\.aicli_ollama_qwen38_27b\]') {
        $definitions['aicli_ollama_qwen38_27b'] = $localModels[0].provider
    }
    foreach ($id in $definitions.Keys) {
        $definition = $definitions[$id]
        $pattern = '(?ms)^\[model_providers\.' + [regex]::Escape($id) + '\][^\r\n]*\r?\n.*?(?=^\[|\z)'
        $match = [regex]::Match($updated, $pattern)
        if ($match.Success) {
            $url = [regex]::Match($match.Value, '(?m)^base_url\s*=\s*"([^"]+)"').Groups[1].Value
            if ($url.TrimEnd('/') -ne ([string]$definition.base_url).TrimEnd('/')) { throw "Existing desktop provider endpoint differs: $id" }
            if ($updated -match ('(?m)^\[model_providers\.' + [regex]::Escape($id) + '\.')) { throw "Existing desktop provider has additional settings: $id" }
            $key = [regex]::Match($match.Value, '(?m)^env_key\s*=\s*"([^"]+)"').Groups[1].Value
            if ($key -and $key -ne 'AICLI_CODEX_PROVIDER_KEY') { throw "Existing desktop provider uses a separate credential: $id" }
            if ($match.Value -match '(?m)^(?:auth|experimental_bearer_token|http_headers)\s*=') { throw "Existing desktop provider has custom authentication: $id" }
        }
        $name = if ($id -eq 'aicli_desktop_local') { 'AICLI local models' } else { [string]$definition.name }
        $body = "[model_providers.$id]`r`nname = $($name | ConvertTo-Json -Compress)`r`nbase_url = $([string]$definition.base_url | ConvertTo-Json -Compress)`r`nwire_api = `"responses`"`r`nrequires_openai_auth = false`r`n`r`n"
        if ($match.Success) { $updated = $updated.Substring(0, $match.Index) + $body + $updated.Substring($match.Index + $match.Length) }
        else { $updated = $updated.TrimEnd() + "`r`n`r`n" + $body }
    }
    if ($updated -ceq $original) { return }
    $backupRoot = Join-Path $InstallRoot 'backups'
    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null
    $backup = Join-Path $backupRoot ('config-before-desktop-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '.toml')
    [IO.File]::WriteAllText($backup, $original, $utf8)
    if ([IO.File]::ReadAllText($path) -cne $original) { throw 'Codex configuration changed concurrently; no configuration was overwritten.' }
    $temporary = $path + '.aicli-desktop-' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $updated, $utf8)
        [IO.File]::Move($temporary, $path, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    if ([IO.File]::ReadAllText($path) -cne $updated) { throw 'Desktop provider registration readback failed.' }
}

if ($Mode -eq 'Build') {
    $project = Join-Path $repo 'src\AiCliProfileManager\Support\DesktopBridge\DesktopBridge.csproj'
    $output = Join-Path $repo 'dist\desktop-bridge'
    $artifacts = Join-Path $repo 'dist\desktop-build'
    & dotnet publish $project -c Release -o $output --self-contained false --artifacts-path $artifacts --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Desktop bridge build failed.' }
    Copy-Item -LiteralPath (Join-Path $repo 'src\AiCliProfileManager\Support\GetDesktopModelPlan.ps1') -Destination (Join-Path $repo 'dist\GetDesktopModelPlan.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $repo 'src\AiCliProfileManager\Support\GetDesktopProviderToken.ps1') -Destination (Join-Path $repo 'dist\GetDesktopProviderToken.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $repo 'src\AiCliProfileManager\Support\ResolveDesktopEngine.ps1') -Destination (Join-Path $repo 'dist\ResolveDesktopEngine.ps1') -Force
    $result = [ordered]@{ status = 'built'; output = $output; activated = $false }
} elseif ($Mode -eq 'Enable') {
    $output = Join-Path $repo 'dist\desktop-bridge'
    $binary = Join-Path $output 'AiCli.CodexDesktopBridge.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'Run this script with -Mode Build first.' }
    $exporter = Join-Path $repo 'src\AiCliProfileManager\Support\GetDesktopModelPlan.ps1'
    $tokenHelper = Join-Path $repo 'src\AiCliProfileManager\Support\GetDesktopProviderToken.ps1'
    $resolver = Join-Path $repo 'src\AiCliProfileManager\Support\ResolveDesktopEngine.ps1'
    $runtimeFiles = @('AiCli.CodexDesktopBridge.exe', 'AiCli.CodexDesktopBridge.dll', 'AiCli.CodexDesktopBridge.deps.json', 'AiCli.CodexDesktopBridge.runtimeconfig.json')
    $fingerprintText = (@($runtimeFiles | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $output $_)).Hash }) -join '') + (Get-FileHash -LiteralPath $exporter).Hash + (Get-FileHash -LiteralPath $tokenHelper).Hash + (Get-FileHash -LiteralPath $resolver).Hash
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($fingerprintText))).ToLowerInvariant().Substring(0, 16)
    $release = Join-Path $InstallRoot "releases\$hash"
    $bridge = Join-Path $release 'bridge'
    $installedExe = Join-Path $bridge 'AiCli.CodexDesktopBridge.exe'
    [IO.Directory]::CreateDirectory($bridge) | Out-Null
    foreach ($name in $runtimeFiles) {
        $source = Join-Path $output $name
        $destination = Join-Path $bridge $name
        if (Test-Path -LiteralPath $destination) {
            if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) { throw 'Installed bridge version differs from the build.' }
        } else { Copy-Item -LiteralPath $source -Destination $destination }
    }
    $installedExporter = Join-Path $release 'GetDesktopModelPlan.ps1'
    if (-not (Test-Path -LiteralPath $installedExporter)) { Copy-Item -LiteralPath $exporter -Destination $installedExporter }
    $installedTokenHelper = Join-Path $release 'GetDesktopProviderToken.ps1'
    if (-not (Test-Path -LiteralPath $installedTokenHelper)) { Copy-Item -LiteralPath $tokenHelper -Destination $installedTokenHelper }
    $installedResolver = Join-Path $release 'ResolveDesktopEngine.ps1'
    if (-not (Test-Path -LiteralPath $installedResolver)) { Copy-Item -LiteralPath $resolver -Destination $installedResolver }
    # The protected PCConfig allowlist is the trust source for a desktop bridge.
    # Do not switch CODEX_CLI_PATH or mutate Codex config until this exact
    # content-addressed release is registered and installed there.
    if (-not (Test-ProtectedBridgeApproval -ReleaseDirectory $release)) {
        throw 'Desktop bridge release is not approved by the protected PCConfig allowlist. Register and install the exact release before enabling it.'
    }
    # Validate the installed discovery route before changing the desktop entry.
    $plan = Invoke-Utf8JsonPowerShellFile -Path $installedExporter
    if (@($plan.models).Count -eq 0) { throw 'Installed local model discovery did not return the configured models.' }
    Register-LocalProviders $plan
    $previous = if ($null -ne $state -and $current -eq $state.executable) { $state.previousUserValue } else { $current }
    $previousManagedExecutable = if (
        $null -ne $state -and
        $state.enabled -and
        -not [string]::IsNullOrWhiteSpace([string]$state.executable) -and
        [IO.Path]::GetFullPath([string]$state.executable) -ne
            [IO.Path]::GetFullPath($installedExe)
    ) {
        [string]$state.executable
    }
    elseif ($null -ne $state) {
        [string]$state.previousManagedExecutable
    }
    else { '' }
    $managedRotationCandidates = @()
    if ($null -ne $state) {
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$state.previousManagedExecutable
            )) {
            $managedRotationCandidates += [string]$state.previousManagedExecutable
        }
        foreach ($candidate in @($state.managedRotationCandidates)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $managedRotationCandidates += [string]$candidate
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($previousManagedExecutable)) {
        $managedRotationCandidates = @(
            $previousManagedExecutable
        ) + @(
            $managedRotationCandidates | Where-Object {
                [IO.Path]::GetFullPath($_) -ne
                    [IO.Path]::GetFullPath($previousManagedExecutable)
            }
        )
    }
    $newState = [ordered]@{
        schemaVersion = 2
        executable = $installedExe
        previousUserValue = $previous
        previousManagedExecutable = $previousManagedExecutable
        managedRotationCandidates = @($managedRotationCandidates)
        enabled = $true
        updatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-State $newState
    Set-UserDesktopEntry $installedExe
    if ([Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User') -ne $installedExe) { throw 'Desktop entry readback failed.' }
    Notify-EnvironmentChange
    $result = [ordered]@{ status = 'enabled'; executable = $installedExe; restartRequired = $true; models = @($plan.models | ForEach-Object { $_.catalogModel.display_name }) }
} elseif ($Mode -eq 'Disable') {
    if ($null -eq $state -or -not $state.enabled) {
        $result = [ordered]@{ status = 'already_disabled'; changed = $false }
    } else {
        if ($current -ne $state.executable) { throw 'CODEX_CLI_PATH was changed separately; no environment value was overwritten.' }
        Set-UserDesktopEntry $state.previousUserValue
        $state.enabled = $false
        $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
        Write-State $state
        Notify-EnvironmentChange
        $result = [ordered]@{ status = 'disabled'; restoredPreviousEntry = $true; restartRequired = $true }
    }
} else {
    $result = [ordered]@{
        status = if ($null -ne $state -and $state.enabled -and $current -eq $state.executable) { 'enabled' } else { 'disabled' }
        executable = if ($null -ne $state) { $state.executable } else { $null }
        currentDesktopEntry = $current
        installationExists = $null -ne $state -and (Test-Path -LiteralPath $state.executable -PathType Leaf)
    }
}
if ($Json) { $result | ConvertTo-Json -Depth 8 -Compress } else { [pscustomobject]$result | Format-List }
