#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$privateDir = Join-Path $PSScriptRoot 'Private'
$publicDir  = Join-Path $PSScriptRoot 'Public'

# Load private functions in dependency order
$privateOrder = @(
    'Brand.ps1',
    'Paths.ps1',
    'Redaction.ps1',
    'JsonStore.ps1',
    'ConsoleUi.ps1',
    'SecretStore.ps1',
    'ManifestService.ps1',
    'ProfileService.ps1',
    'ChildProcess.ps1',
    'LocalGpuBrokerSession.ps1',
    'MachineRuntime.ps1',
    'PortAllocator.ps1',
    'ProcessIdentity.ps1',
    'CodexAdapter.ps1',
    'ClaudeAdapter.ps1',
    'QwenCodeAdapter.ps1',
    'OpenCodeAdapter.ps1',
    'InterpreterAdapter.ps1',
    'ContextManagement.ps1',
    'ProxyService.ps1',
    'LaunchPlan.ps1',
    'RecoveryService.ps1',
    'AgentAcceptance.ps1',
    'DoctorService.ps1',
    'LiveTestService.ps1',
    'UpdateService.ps1',
    'HelpService.ps1',
    'CommandRouter.ps1'
)

foreach ($name in $privateOrder) {
    $path = Join-Path $privateDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing private module file: $path"
    }
    . $path
}

Get-ChildItem -LiteralPath $publicDir -Filter '*.ps1' -ErrorAction Stop | ForEach-Object {
    . $_.FullName
}

Export-ModuleMember -Function @(
    'Invoke-AiCli',
    'aicli',
    'Get-AiCliBrand',
    'Get-AiCliVersion',
    'Get-AiCliAppPaths'
)
