#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('codex-qwen3-8-max-paygo')]
    [string]$ProfileId,
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\AiCliProfileManager.psd1')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ModulePath) -and -not $PSBoundParameters.ContainsKey('ModulePath')) {
    $ModulePath = 'AiCliProfileManager'
}
$module = Import-Module -Name $ModulePath -Force -PassThru
& $module {
    param([string]$Id)
    $profile = Get-AiCliResolvedProfile -Id $Id
    if ((Get-AiCliProperty $profile 'engine') -ne 'codex' -or
        (Get-AiCliProperty $profile 'provider') -ne 'qwen' -or
        (Get-AiCliProperty $profile 'transport') -ne 'responses' -or
        -not [bool](Get-AiCliProperty $profile 'secretConfigured' $false)) {
        throw 'The desktop cloud profile is not configured for Qwen Responses authentication.'
    }
    $secret = $null
    try {
        $secret = Get-AiCliSecret -SecretId ([string](Get-AiCliProperty $profile 'secretRef'))
        if ([string]::IsNullOrWhiteSpace($secret)) { throw 'The desktop cloud profile API key is empty.' }
        [Console]::Out.Write($secret)
    } finally {
        $secret = $null
    }
} -Id $ProfileId
