#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BridgePath,
    [Parameter(Mandatory)][string]$PlanPath
)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100
$official = @($plan.upstreamModels)
$managed = @($plan.models | ForEach-Object { [string]$_.model })
$added = @($official | Where-Object { $_.visibility -eq 'list' } | Select-Object -Last 1)[0]
if ($official.Count -lt 2 -or $managed.Count -eq 0 -or $null -eq $added) { throw 'A real native engine plan with official and managed models is required.' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('aicli-live-catalog-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$fixture = Join-Path $root 'plan.json'
$plan.codexHome = Join-Path $root 'home'
$null = New-Item -ItemType Directory -Path $plan.codexHome
[IO.File]::WriteAllText((Join-Path $plan.codexHome 'config.toml'), ('model = "' + $official[0].slug + '"'), $utf8)
$plan.upstreamModels = @($official | Where-Object { $_.slug -ne $added.slug })
[IO.File]::WriteAllText($fixture, ($plan | ConvertTo-Json -Compress -Depth 100), $utf8)
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = [IO.Path]::GetFullPath($BridgePath)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardInputEncoding = $utf8
$start.StandardOutputEncoding = $utf8
$start.StandardErrorEncoding = $utf8
$start.Environment['AICLI_DESKTOP_PLAN_FILE'] = $fixture
$start.Environment['CODEX_HOME'] = $plan.codexHome
$start.ArgumentList.Add('app-server')
$start.ArgumentList.Add('--stdio')
$process = $null
function Invoke-NativeRequest([int]$Id, [string]$Method, [hashtable]$Parameters) {
    $line = @{jsonrpc='2.0';id=$Id;method=$Method;params=$Parameters} | ConvertTo-Json -Compress -Depth 30
    $process.StandardInput.WriteLine($line)
    $process.StandardInput.Flush()
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        $line = $process.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(20)).GetAwaiter().GetResult()
        if ($null -eq $line) { throw 'Native engine closed before replying.' }
        $response = $line | ConvertFrom-Json -Depth 100
        if ($null -ne $response.id -and [string]$response.id -eq [string]$Id) {
            if ($null -ne $response.error) { throw ('Native request failed: ' + $response.error.message) }
            return $response.result
        }
    }
    throw 'Native request timed out.'
}
try {
    $process = [Diagnostics.Process]::Start($start)
    $errors = $process.StandardError.ReadToEndAsync()
    $originalPid = $process.Id
    $null = Invoke-NativeRequest 1 'initialize' @{clientInfo=@{name='aicli-native-catalog-test';version='1'}}
    $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"initialized"}')
    $process.StandardInput.Flush()
    $before = Invoke-NativeRequest 2 'model/list' @{includeHidden=$true;limit=100}
    if ($before.data.model -contains $added.slug) { throw 'Added model already existed in the negative baseline.' }
    $plan.upstreamModels = $official
    $plan.models = @() # An official refresh cannot discard the startup managed set.
    [IO.File]::WriteAllText($fixture, ($plan | ConvertTo-Json -Compress -Depth 100), $utf8)
    $after = Invoke-NativeRequest 3 'model/list' @{includeHidden=$true;limit=100}
    if ($after.data.model -notcontains $added.slug) { throw 'New model did not appear in the same process.' }
    foreach ($id in $managed) {
        $old = @($before.data | Where-Object model -eq $id)
        $new = @($after.data | Where-Object model -eq $id)
        if ($old.Count -ne 1 -or $new.Count -ne 1 -or
            ($old[0] | ConvertTo-Json -Depth 100 -Compress) -cne ($new[0] | ConvertTo-Json -Depth 100 -Compress)) {
            throw ('Managed model metadata changed: ' + $id)
        }
    }
    if ($process.HasExited -or $process.Id -ne $originalPid) { throw 'Bridge process continuity failed.' }
    [pscustomobject]@{
        status = 'pass'
        nativeEngine = $plan.upstreamFileName
        sameBridgeProcess = $true
        addedModel = $added.slug
        beforeCount = @($before.data).Count
        afterCount = @($after.data).Count
        managedModelsPreserved = $managed.Count
        modelGenerationRequests = 0
        desktopRestarted = $false
    } | ConvertTo-Json -Compress
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        $process.Dispose()
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
