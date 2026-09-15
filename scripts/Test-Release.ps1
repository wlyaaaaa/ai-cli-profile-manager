#Requires -Version 7.0
param(
    [string]$DataRoot = (Join-Path ([IO.Path]::GetTempPath()) ("aicli-test-" + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$module = Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1'
Get-Module -Name AiCliProfileManager -All | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module $module -Force
$sourceModuleRoot = (Resolve-Path (Split-Path $module -Parent)).Path
$sourceModule = Get-Module -Name AiCliProfileManager -All |
    Where-Object { $_.ModuleBase -eq $sourceModuleRoot } |
    Select-Object -First 1
if (-not $sourceModule) { throw '未能解析当前源码模块。' }

$failed = 0
function Assert-True($cond, $msg) {
    if (-not $cond) { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:failed++ }
    else { Write-Host "OK: $msg" -ForegroundColor Green }
}

New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
Write-Host "DataRoot=$DataRoot"

# Source/CI smoke must not install, log in to, or call dynamic upstream CLIs.
# Deterministic PATH shims exercise native/eject plan construction on a clean
# windows-latest runner; real Provider connectivity is a separate explicit Live test.
$oldProcessPath = $env:PATH
$stubBin = Join-Path $DataRoot 'cli-stubs'
New-Item -ItemType Directory -Force -Path $stubBin | Out-Null
[IO.File]::WriteAllLines((Join-Path $stubBin 'codex.cmd'), @('@echo off', 'echo codex-cli 0.0.0-test-stub'))
[IO.File]::WriteAllLines((Join-Path $stubBin 'claude.cmd'), @('@echo off', 'echo 0.0.0-test-stub'))
$env:PATH = "$stubBin;$oldProcessPath"

$code = Invoke-AiCli -Tokens @('version') -DataRoot $DataRoot
Assert-True ($code -eq 0) 'version exit 0'

$code = Invoke-AiCli -Tokens @('profile','list','--available','--json') -DataRoot $DataRoot
Assert-True ($code -eq 0) 'profile list --available'

$exactProfiles = & $sourceModule {
    $all = Import-AiCliProviderManifests
    @($all.Values | Where-Object {
        ($_.engine -eq 'codex') -and
        ($_.provider -in @('qwen','deepseek','ollama')) -and
        (-not [bool](Get-AiCliProperty $_ 'hidden' $false))
    } | ForEach-Object {
        [pscustomobject]@{
            id = [string]$_.id
            model = [string]$_.models.primary
            transport = [string]$_.transport
            requestedEffort = [string]$_.defaultEffort
            effectiveEffort = [string](Resolve-AiCliCodexEffectiveEffort -MergedProfile $_ -RequestedEffort ([string]$_.defaultEffort))
            candidateCount = @($_.models.candidates).Count
            flexible = [bool]$_.flexible
        }
    })
}
$requiredExactProfiles = @(
    [pscustomobject]@{ id = 'codex-qwen3-7-max-paygo'; model = 'qwen3.7-max-2026-06-08'; effectiveEffort = 'xhigh' },
    [pscustomobject]@{ id = 'codex-qwen3-8-max-paygo'; model = 'qwen3.8-max'; effectiveEffort = 'xhigh' },
    [pscustomobject]@{ id = 'codex-deepseek'; model = 'deepseek-v4-flash'; effectiveEffort = 'max' },
    [pscustomobject]@{ id = 'codex-deepseek-v4-pro'; model = 'deepseek-v4-pro'; effectiveEffort = 'max' },
    [pscustomobject]@{ id = 'codex-ollama-main'; model = 'aicli-qwen3.8-27b-256k:2026-09-15'; effectiveEffort = 'max' },
    [pscustomobject]@{ id = 'codex-ollama-qwen3-8-27b'; model = 'aicli-qwen3.8-27b-256k:2026-09-15'; effectiveEffort = 'max' },
    [pscustomobject]@{ id = 'codex-ollama-qwen3-6-35b-abliterated'; model = 'aicli-qwen3.6-35b-abliterated-256k:2026-09-15'; effectiveEffort = 'max' },
    [pscustomobject]@{ id = 'codex-ollama-qwen3-8-27b-abliterated'; model = 'aicli-qwen3.8-27b-abliterated-256k:2026-09-15'; effectiveEffort = 'max' },
    [pscustomobject]@{ id = 'codex-ollama-review'; model = 'qwen-main-v1'; effectiveEffort = 'max' }
)
foreach ($expected in $requiredExactProfiles) {
    $actual = @($exactProfiles | Where-Object id -eq $expected.id)
    Assert-True ($actual.Count -eq 1) "exact profile $($expected.id) is discoverable once"
    if ($actual.Count -eq 1) {
        Assert-True (
            $actual[0].model -eq $expected.model -and
            $actual[0].transport -eq 'responses' -and
            $actual[0].requestedEffort -eq 'max' -and
            $actual[0].effectiveEffort -eq $expected.effectiveEffort -and
            $actual[0].candidateCount -eq 1 -and
            -not $actual[0].flexible
        ) "exact profile $($expected.id) seals model, Responses, max and no fallback"
    }
}

$code = Invoke-AiCli -Tokens @('doctor','--json') -DataRoot $DataRoot
Assert-True ($code -in 0,3,4) "doctor exit=$code"

$code = Invoke-AiCli -Tokens @('help','compare') -DataRoot $DataRoot
Assert-True ($code -eq 0) 'help compare'

$code = Invoke-AiCli -Tokens @('native','codex-official') -DataRoot $DataRoot
Assert-True ($code -eq 0) 'native codex-official'

$code = Invoke-AiCli -Tokens @('native','claude-official') -DataRoot $DataRoot
Assert-True ($code -eq 0) 'native claude-official'

$code = Invoke-AiCli -Tokens @('profile','show','codex-official','--json') -DataRoot $DataRoot
Assert-True ($code -eq 0) 'profile show official'

# usage error
$code = Invoke-AiCli -Tokens @('nope') -DataRoot $DataRoot
Assert-True ($code -eq 2) 'unknown command exit 2'

# test requires --live
$code = Invoke-AiCli -Tokens @('test','codex-official') -DataRoot $DataRoot
Assert-True ($code -eq 2 -or $code -eq 4) 'test without --live fails'

# update-check is deliberately offline in this source/CI smoke.  Keep the
# real CommandRouter path, but replace only this process' REST command with a
# fail-closed seam: unavailable official metadata must remain Limited/exit 3,
# never be turned into a fabricated current/latest result.
$offlineRestCalls = [System.Collections.Generic.List[string]]::new()
$offlineRestMethod = {
    [CmdletBinding()]
    param(
        [string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutSec,
        [int]$MaximumRedirection,
        [hashtable]$Headers
    )
    $offlineRestCalls.Add($Uri)
    throw 'Test-Release offline seam: official metadata unavailable'
}.GetNewClosure()
$previousRestFunction = Get-Command Invoke-RestMethod -CommandType Function -ErrorAction SilentlyContinue
$previousRestScript = if ($previousRestFunction) { $previousRestFunction.ScriptBlock } else { $null }
Set-Item Function:\Invoke-RestMethod -Value $offlineRestMethod -Force
try {
    $previousConsoleOut = [Console]::Out
    $updateCheckOutput = $null
    $updateCheckWriter = [IO.StringWriter]::new([Globalization.CultureInfo]::InvariantCulture)
    try {
        [Console]::SetOut($updateCheckWriter)
        $code = Invoke-AiCli -Tokens @('update','check','--json') -DataRoot $DataRoot
        $updateCheckOutput = $updateCheckWriter.ToString()
    } finally {
        [Console]::SetOut($previousConsoleOut)
        $updateCheckWriter.Dispose()
    }
} finally {
    if ($previousRestFunction) {
        Set-Item Function:\Invoke-RestMethod -Value $previousRestScript -Force
    } else {
        Remove-Item Function:\Invoke-RestMethod -Force -ErrorAction SilentlyContinue
    }
}
$updateCheckResult = $null
try { $updateCheckResult = $updateCheckOutput.Trim() | ConvertFrom-Json } catch {}
Assert-True (
    $code -eq 3 -and
    $updateCheckResult -and
    $updateCheckResult.overallStatus -eq '可用但有限制'
) 'offline update check remains Limited / exit 3'
Write-Host ("offline update check metadata calls intercepted={0}" -f $offlineRestCalls.Count)

# eject
$ejectOut = Join-Path $DataRoot 'eject-codex-official'
$code = Invoke-AiCli -Tokens @('eject','codex-official','--output',$ejectOut) -DataRoot $DataRoot
Assert-True ($code -eq 0) 'eject'
Assert-True (Test-Path (Join-Path $ejectOut 'start.ps1')) 'eject start.ps1'
$ejectText = Get-Content (Join-Path $ejectOut 'start.ps1') -Raw
Assert-True ($ejectText -notmatch 'sk-[A-Za-z0-9]{10}') 'eject no sk- canary pattern'

# port parse unit-ish
. (Join-Path $root 'src\AiCliProfileManager\Private\Brand.ps1')
. (Join-Path $root 'src\AiCliProfileManager\Private\Paths.ps1')
. (Join-Path $root 'src\AiCliProfileManager\Private\PortAllocator.ps1')
$sample = @'
Protocol tcp Dynamic Port Range
---------------------------------
Start Port      : 49152
Number of Ports : 16384
'@
$ranges = Parse-AiCliNetshRanges -Text $sample -Kind dynamicport
Assert-True ($ranges.Count -ge 1 -and $ranges[0].Start -eq 49152) 'parse netsh dynamic EN'

# Chinese-ish labels
$sampleZh = "起始端口 : 49152`n端口数 : 16384"
$rangesZh = Parse-AiCliNetshRanges -Text $sampleZh -Kind dynamicport
Assert-True ($rangesZh.Count -ge 1) 'parse netsh dynamic ZH labels'

Write-Host ''
if ($failed -gt 0) {
    $env:PATH = $oldProcessPath
    Write-Host "FAILED: $failed" -ForegroundColor Red
    exit 1
}
$env:PATH = $oldProcessPath
Write-Host 'ALL SMOKE CHECKS PASSED' -ForegroundColor Green
exit 0
