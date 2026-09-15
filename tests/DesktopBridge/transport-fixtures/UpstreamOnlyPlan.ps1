#Requires -Version 7.2
param([switch]$UpstreamOnly)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

if (-not $UpstreamOnly) {
    [Console]::Error.WriteLine('fixture local plan failure')
    exit 17
}

$plan = [ordered]@{
    schemaVersion = 1
    codexHome = $env:AICLI_TEST_PLAN_HOME
    upstreamFileName = $env:AICLI_TEST_PLAN_PWSH
    upstreamPrefixArgs = @(
        '-NoProfile',
        '-File',
        $env:AICLI_TEST_FAKE_CODEX_SCRIPT,
        '--fake-passthrough'
    )
    models = @()
}
$plan | ConvertTo-Json -Depth 10 -Compress
