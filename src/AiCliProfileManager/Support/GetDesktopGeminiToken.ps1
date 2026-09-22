#Requires -Version 7.2
[CmdletBinding()]
param([string]$ModulePath=(Join-Path $PSScriptRoot '..\AiCliProfileManager.psd1'),[switch]$ServiceHost,[string]$ExpectedRelease)
$ErrorActionPreference='Stop'
$module=Import-Module -Name $ModulePath -Force -PassThru
if($ServiceHost){ & $module {param($release) Invoke-AiCliGeminiBridgeHost -ExpectedRelease $release} $ExpectedRelease;return }
& $module {
    $null=Start-AiCliGeminiBridge
    $token=$null
    try { $token=Get-AiCliGeminiLocalToken;[Console]::Out.Write($token) }
    finally { $token=$null }
}
