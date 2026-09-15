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
    foreach ($entry in $Plan.models) { $definitions[$entry.providerId] = $entry.provider }
    $definitions['aicli_desktop_local'] = $Plan.models[0].provider
    # This legacy provider was recorded in tasks made by the older AICLI entry.
    if ($original -match '(?m)^\[model_providers\.aicli_ollama_qwen38_27b\]') {
        $definitions['aicli_ollama_qwen38_27b'] = $Plan.models[0].provider
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
    Copy-Item -LiteralPath (Join-Path $repo 'src\AiCliProfileManager\Support\ResolveDesktopEngine.ps1') -Destination (Join-Path $repo 'dist\ResolveDesktopEngine.ps1') -Force
    $result = [ordered]@{ status = 'built'; output = $output; activated = $false }
} elseif ($Mode -eq 'Enable') {
    $output = Join-Path $repo 'dist\desktop-bridge'
    $binary = Join-Path $output 'AiCli.CodexDesktopBridge.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'Run this script with -Mode Build first.' }
    $exporter = Join-Path $repo 'src\AiCliProfileManager\Support\GetDesktopModelPlan.ps1'
    $resolver = Join-Path $repo 'src\AiCliProfileManager\Support\ResolveDesktopEngine.ps1'
    $runtimeFiles = @('AiCli.CodexDesktopBridge.exe', 'AiCli.CodexDesktopBridge.dll', 'AiCli.CodexDesktopBridge.deps.json', 'AiCli.CodexDesktopBridge.runtimeconfig.json')
    $fingerprintText = (@($runtimeFiles | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $output $_)).Hash }) -join '') + (Get-FileHash -LiteralPath $exporter).Hash + (Get-FileHash -LiteralPath $resolver).Hash
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
    $installedResolver = Join-Path $release 'ResolveDesktopEngine.ps1'
    if (-not (Test-Path -LiteralPath $installedResolver)) { Copy-Item -LiteralPath $resolver -Destination $installedResolver }
    # Validate the installed discovery route before changing the desktop entry.
    $plan = & pwsh -NoProfile -File $installedExporter | ConvertFrom-Json -Depth 100
    if ($LASTEXITCODE -ne 0 -or @($plan.models).Count -eq 0) { throw 'Installed local model discovery did not return the configured models.' }
    Register-LocalProviders $plan
    $previous = if ($null -ne $state -and $current -eq $state.executable) { $state.previousUserValue } else { $current }
    $newState = [ordered]@{
        schemaVersion = 1
        executable = $installedExe
        previousUserValue = $previous
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
