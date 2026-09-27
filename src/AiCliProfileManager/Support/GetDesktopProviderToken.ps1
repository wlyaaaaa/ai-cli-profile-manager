#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfileId,
    [Parameter(Mandatory)][string]$ClientPath,
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\AiCliProfileManager.psd1')
)
$ErrorActionPreference = 'Stop'
# auth.command's stdout belongs only to the already running native client.
$self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -Property ParentProcessId,CreationDate
$parent = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $self.ParentProcessId) -Property ExecutablePath,CreationDate,ProcessId
if (-not $parent -or $parent.CreationDate -gt $self.CreationDate -or
    -not [string]::Equals([IO.Path]::GetFullPath([string]$parent.ExecutablePath), [IO.Path]::GetFullPath($ClientPath), [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($ClientPath) -cne 'codex.exe' -or -not [Console]::IsOutputRedirected) {
    throw 'Desktop token delivery requires its actual native Codex parent and private stdout pipe.'
}
if (-not (Test-Path -LiteralPath $ModulePath) -and -not $PSBoundParameters.ContainsKey('ModulePath')) { $ModulePath = 'AiCliProfileManager' }
$module = Import-Module -Name $ModulePath -Force -PassThru
& $module {
    param([string]$Id)
    $profile = Get-AiCliResolvedProfile -Id $Id
    if ((Get-AiCliProperty $profile 'engine') -ne 'codex' -or
        (Get-AiCliProperty $profile 'transport') -ne 'responses' -or
        -not (Get-AiCliVendorSecretRef -Profile $profile)) { throw 'Unsupported native vendor authentication.' }
    $secret = $null
    try {
        $secret = Get-AiCliProfileSecret -Profile $profile -Desktop
        [Console]::Out.Write($secret)
    } finally { $secret = $null }
} -Id $ProfileId
