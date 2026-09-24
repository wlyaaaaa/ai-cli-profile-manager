[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')]
    [string]$ProfileId,

    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$startedUtc = (Get-Date).ToUniversalTime()

function Get-FastProfileProperty {
    param($Value, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Assert-FastProfileNormalFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label 不存在: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label 不能是 reparse point: $Path"
    }
}

$sourceFull = [IO.Path]::GetFullPath($SourceRoot)
$repoRoot = @(& git -C $sourceFull rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or $repoRoot.Count -ne 1 -or
    [IO.Path]::GetFullPath([string]$repoRoot[0]) -cne $sourceFull) {
    throw "SourceRoot 必须是 Git 仓库根目录: $sourceFull"
}
$dirty = @(& git -C $sourceFull status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw '无法读取 Git 工作树状态。' }
if ($dirty.Count -gt 0) {
    throw '快速安装只接受 clean Git 提交；请先定向提交当前 Profile 变更。'
}
$commit = [string](@(& git -C $sourceFull rev-parse HEAD)[0]).Trim()
if ($commit -notmatch '^[a-f0-9]{40}$') { throw '无法固定 source commit。' }

$manifestPath = Join-Path $sourceFull "data\providers\$ProfileId.json"
Assert-FastProfileNormalFile -Path $manifestPath -Label 'Provider manifest'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 |
    ConvertFrom-Json -AsHashtable
if ([string](Get-FastProfileProperty $manifest 'id') -cne $ProfileId -or
    [string](Get-FastProfileProperty $manifest 'engine') -cne 'codex') {
    throw '快速安装仅接受 ID 闭合的 Codex Profile。'
}
if ([string](Get-FastProfileProperty $manifest 'transport') -cne 'responses' -or
    [bool](Get-FastProfileProperty $manifest 'flexible') -or
    [string](Get-FastProfileProperty $manifest 'defaultEffort') -cne 'max') {
    throw '快速安装要求 Responses、flexible=false、defaultEffort=max。'
}
$models = Get-FastProfileProperty $manifest 'models'
$primary = [string](Get-FastProfileProperty $models 'primary')
$candidates = @((Get-FastProfileProperty $models 'candidates') | Where-Object { $_ })
$reserved = @((Get-FastProfileProperty $models 'reserved') | Where-Object { $_ })
if ([string]::IsNullOrWhiteSpace($primary) -or $candidates.Count -ne 1 -or
    [string]$candidates[0] -cne $primary -or $reserved.Count -ne 0) {
    throw '快速安装要求单一 exact candidate、无 reserved/fallback。'
}
$catalogName = [string](Get-FastProfileProperty $manifest 'codexModelCatalog')
if ([string]::IsNullOrWhiteSpace($catalogName) -or
    [IO.Path]::GetFileName($catalogName) -cne $catalogName) {
    throw 'codexModelCatalog 必须是 data/model-catalogs 下的普通文件名。'
}
$catalogPath = Join-Path $sourceFull "data\model-catalogs\$catalogName"
Assert-FastProfileNormalFile -Path $catalogPath -Label 'Model catalog'
$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 |
    ConvertFrom-Json
$catalogModels = @($catalog.models)
if ($catalogModels.Count -ne 1 -or [string]$catalogModels[0].slug -cne $primary) {
    throw 'Model catalog 必须只包含与 Profile primary 完全一致的 exact model。'
}

$focusedTests = @(
    (Join-Path $sourceFull 'tests\Unit\Manifest.Tests.ps1'),
    (Join-Path $sourceFull 'tests\Unit\ExactCodexProfiles.Tests.ps1'),
    (Join-Path $sourceFull 'tests\Unit\Retirement.Tests.ps1'),
    (Join-Path $sourceFull 'tests\Unit\CommandRouter.Tests.ps1'),
    (Join-Path $sourceFull 'tests\Unit\SecurityRegression.Tests.ps1')
)
$testRunner = @'
$result = Invoke-Pester -Path $env:AICLI_FAST_TEST_PATH -Output None -PassThru
$summary = [pscustomobject]@{
    passed = $result.PassedCount
    failed = $result.FailedCount
    skipped = $result.SkippedCount
    notRun = $result.NotRunCount
}
Write-Output ('AICLI_FAST_PESTER_RESULT=' + ($summary | ConvertTo-Json -Compress))
if ($result.FailedCount -gt 0 -or $result.SkippedCount -gt 0 -or
    $result.NotRunCount -gt 0) { exit 1 }
'@
$encodedRunner = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($testRunner))
$focusedPassed = 0
$previousFastTestPath = $env:AICLI_FAST_TEST_PATH
try {
    foreach ($testPath in $focusedTests) {
        $env:AICLI_FAST_TEST_PATH = $testPath
        $testOutput = @(& pwsh -NoLogo -NoProfile -EncodedCommand $encodedRunner *>&1)
        $testExitCode = $LASTEXITCODE
        $marker = @($testOutput | Where-Object {
            [string]$_ -clike 'AICLI_FAST_PESTER_RESULT=*'
        } | Select-Object -Last 1)
        if ($marker.Count -ne 1) {
            throw "聚焦门禁未返回结构化结果: $([IO.Path]::GetFileName($testPath))"
        }
        $testResult = ([string]$marker[0]).Substring(
            'AICLI_FAST_PESTER_RESULT='.Length
        ) | ConvertFrom-Json
        if ($testExitCode -ne 0 -or [int]$testResult.failed -gt 0 -or
            [int]$testResult.skipped -gt 0 -or [int]$testResult.notRun -gt 0) {
            throw "聚焦门禁未通过: $([IO.Path]::GetFileName($testPath)) passed=$($testResult.passed) failed=$($testResult.failed) skipped=$($testResult.skipped) notRun=$($testResult.notRun)"
        }
        $focusedPassed += [int]$testResult.passed
    }
} finally {
    if ($null -eq $previousFastTestPath) {
        Remove-Item Env:AICLI_FAST_TEST_PATH -ErrorAction SilentlyContinue
    } else {
        $env:AICLI_FAST_TEST_PATH = $previousFastTestPath
    }
}

$smokeOutput = @(& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $sourceFull 'scripts\Test-Release.ps1') *>&1)
if ($LASTEXITCODE -ne 0 -or ($smokeOutput -join "`n") -cnotmatch 'ALL SMOKE CHECKS PASSED') {
    throw '发行 smoke 未通过；未执行安装。'
}

$installOutput = @(& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $sourceFull 'scripts\Install.ps1') -SourceRoot $sourceFull -Force *>&1)
if ($LASTEXITCODE -ne 0) { throw '原子安装失败。' }

$shim = Join-Path $env:LOCALAPPDATA 'aicli\bin\aicli.ps1'
$listEnvelope = ((& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
    $shim profile list --available --json) -join "`n") | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw '安装后 profile list 回读失败。' }
$exactRows = @($listEnvelope.profiles | Where-Object { $_.id -ceq $ProfileId })
if ($exactRows.Count -ne 1 -or [string]$exactRows[0].model -cne $primary -or
    [string]$exactRows[0].wire -cne 'responses' -or
    [string]$exactRows[0].requestedEffort -cne 'max') {
    throw '安装后 exact Profile 回读未闭合。'
}
$showRaw = @(& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
    $shim profile show $ProfileId --json)
$showExitCode = $LASTEXITCODE
try { $showEnvelope = ($showRaw -join "`n") | ConvertFrom-Json }
catch { throw "安装后 profile show 未返回有效 JSON（exit=$showExitCode）。" }
$profile = $showEnvelope.profile
if ($null -eq $profile -or [string]$profile.id -cne $ProfileId -or
    [string]$profile.models.primary -cne $primary) {
    throw '安装后 profile show exact identity 回读未闭合。'
}
$verification = Get-FastProfileProperty $profile 'verification'

[pscustomobject]@{
    schemaVersion = 1
    mode = 'exact-codex-profile-fast-install'
    sourceCommit = $commit
    productVersion = [string]$showEnvelope.productVersion
    focusedTestsPassed = $focusedPassed
    releaseSmoke = 'pass'
    profileId = [string]$profile.id
    model = [string]$profile.models.primary
    wire = [string]$profile.transport
    requestedEffort = [string]$profile.defaultEffort
    effectiveEffort = [string]$exactRows[0].effectiveEffort
    configured = [bool]$profile.configured
    secretPresence = [string]$profile.secretConfigured
    profileFingerprint = [string]$profile.profileFingerprint
    currentProfileStatus = [string]$profile.status
    existingVerificationResult = [string](Get-FastProfileProperty $verification 'result')
    liveAcceptance = 'not-run-by-fast-installer'
    durationSeconds = [math]::Round(
        ((Get-Date).ToUniversalTime() - $startedUtc).TotalSeconds,
        2
    )
} | ConvertTo-Json -Depth 5
