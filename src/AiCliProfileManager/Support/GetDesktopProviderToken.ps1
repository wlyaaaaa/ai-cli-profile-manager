#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('codex-qwen3-8-max-paygo','codex-glm-5-3','codex-glm-5-3-flash','codex-deepseek-flash')]
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
    if ((Get-AiCliProperty $profile 'provider') -eq 'glm' -and
        -not [bool](Get-AiCliProperty $profile 'secretConfigured' $false)) {
        $broker = 'C:\ProgramData\PCConfig\AuthorityHost\tools\Invoke-SecretBroker.ps1'
        if (-not (Test-Path -LiteralPath $broker -PathType Leaf)) {
            throw 'The Password Center GLM blind-injection route is unavailable.'
        }
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = 'pwsh'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($arg in @(
            '-NoProfile', '-NonInteractive', '-File', $broker,
            '-Action', 'AgentSecretRef',
            '-Query', 'aicli-glm-codex-profile-import',
            '-Json'
        )) { $start.ArgumentList.Add($arg) }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                $process.Kill($true)
                [void]$process.WaitForExit(2000)
                throw 'Password Center GLM blind injection timed out.'
            }
            [void]$stdout.GetAwaiter().GetResult()
            [void]$stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) {
                throw 'Password Center rejected the GLM blind-injection target.'
            }
        } finally { $process.Dispose() }
        $profile = Get-AiCliResolvedProfile -Id $Id
    }
    if ((Get-AiCliProperty $profile 'engine') -ne 'codex' -or
        (Get-AiCliProperty $profile 'provider') -notin @('qwen','glm','deepseek') -or
        (Get-AiCliProperty $profile 'transport') -ne 'responses' -or
        -not [bool](Get-AiCliProperty $profile 'secretConfigured' $false)) {
        throw 'The desktop cloud profile is not configured for approved Responses authentication.'
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
