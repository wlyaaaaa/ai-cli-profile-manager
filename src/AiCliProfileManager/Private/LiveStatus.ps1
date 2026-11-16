# Project-page projection: verification metadata only; never launch a provider.
function Write-AiCliLiveJson {
    param([string]$Path, $Value, [switch]$Compress)
    $json = $Value | ConvertTo-Json -Depth 12 -Compress:$Compress
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -ceq $json) { return }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try { [IO.File]::WriteAllText($tmp,$json,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($tmp,$Path,$true) }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp } }
}

function Update-AiCliLiveStatus {
    param([string]$SourceRoot, [string]$InstalledRoot, [string]$OutputRoot)
    $paths = Get-AiCliAppPaths
    $configPath = Join-Path $paths.LocalRoot 'live-source.json'
    if (-not $SourceRoot -and -not (Test-Path -LiteralPath $configPath)) { return }
    if ($SourceRoot) { Write-AiCliLiveJson -Path $configPath -Value @{ source = $SourceRoot; output = $(if ($OutputRoot) { $OutputRoot } else { $paths.LocalRoot }) } }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $SourceRoot = $config.source; $OutputRoot = $config.output
    $now = [DateTimeOffset]::UtcNow
    $at = $now.ToString('o')
    $settings = if (Test-Path -LiteralPath $paths.SettingsFile) { Get-Content -LiteralPath $paths.SettingsFile -Raw | ConvertFrom-Json -AsHashtable -DateKind String } else { @{} }
    $known = $settings['verification'] -is [System.Collections.IDictionary]
    $verification = if ($known) { $settings['verification'] } else { @{} }
    $rows = @($verification.GetEnumerator() | ForEach-Object {
        $r = $_.Value
        [ordered]@{ profile = $_.Key; at = $r.timestampUtc; level = $r.level; result = $r.result
            version = $r.productVersion; text_pass = ($r['textPass'] -is [bool] -and $r['textPass']); agent_pass = ($r['agentPass'] -is [bool] -and $r['agentPass'])
            state_text = $(switch ($r.result) { pass { '通过' } fail { '未通过' } limited { '有限制' } default { '未记录状态' } }) }
    } | Sort-Object { [DateTimeOffset]::Parse($_.at) } -Descending)
    $publicRows = @($rows | ForEach-Object { $r = [ordered]@{}; foreach ($k in $_.Keys) { if ($k -ne 'profile') { $r[$k] = $_[$k] } }; $r })
    if (-not $InstalledRoot) {
        $installed = Get-Module -ListAvailable AiCliProfileManager | Sort-Object Version -Descending | Select-Object -First 1
        if ($installed) { $InstalledRoot = Split-Path -Parent $installed.Path }
    }
    $version = if ($InstalledRoot) { [string](Import-PowerShellDataFile (Join-Path $InstalledRoot 'AiCliProfileManager.psd1')).ModuleVersion } else { $null }
    $files = @(git -C $SourceRoot ls-files --cached --others --exclude-standard -- 'src/AiCliProfileManager')
    if ($LASTEXITCODE -ne 0) { throw '无法读取项目源文件清单' }
    $matched = 0
    foreach ($f in $files) {
        $target = if ($InstalledRoot) { Join-Path $InstalledRoot $f.Substring('src/AiCliProfileManager/'.Length) } else { $null }
        if ($target -and (Test-Path -LiteralPath $target -PathType Leaf) -and
            (Get-FileHash -LiteralPath (Join-Path $SourceRoot $f)).Hash -eq (Get-FileHash -LiteralPath $target).Hash) { $matched++ }
    }
    $agents = @($rows | Where-Object level -eq 'agent')
    $text = @($rows | Where-Object text_pass)
    $passed = @($agents | Where-Object agent_pass)
    $current = @($passed | Where-Object version -eq $version)
    $summary = '{0} 个留有记录：最后一次回话通过 {1} 个；做过实战的 {2} 个里通过 {3} 个' -f $rows.Count,$text.Count,$agents.Count,$passed.Count
    $profiles = if (Test-Path -LiteralPath $paths.ProfilesDir) { @(Get-ChildItem -LiteralPath $paths.ProfilesDir -Filter '*.json' -File).Count } else { 0 }
    $displayTime = { param($t,$format='MM-dd HH:mm') [DateTimeOffset]::Parse($t).ToOffset([TimeSpan]::FromHours(8)).ToString($format) }
    $metrics = [ordered]@{
        installed = $(if ($version) { "$version；程序文件 $matched/$($files.Count) 与所登记源码一致" } else { $null })
        profiles = $profiles; results = $summary
        current_agent = $(if ($version -and $current.Count -eq 0) { 0 } else { $null })
        latest_test = $(if ($rows.Count) { "$(& $displayTime $rows[0].at)；$(switch ($rows[0].level) { agent {'实战'} text {'回话'} tool {'工具'} all {'回话和工具'} default {'未记录层级'} })；$($rows[0].state_text)" } else { $null })
        latest_agent = $(if ($agents.Count) { "$(& $displayTime $agents[0].at)；$(if ($agents[0].version -eq $version) { '同版本，身份有效性未复核' } else { '旧版' })" } else { $null })
        tested7 = @($rows | Where-Object { $t = [DateTimeOffset]::Parse($_.at); $t -le $now -and $t -ge $now.AddDays(-7) }).Count
        tested30 = @($rows | Where-Object { $t = [DateTimeOffset]::Parse($_.at); $t -le $now -and $t -ge $now.AddDays(-30) }).Count
        last_text_pass = $(if ($text.Count) { & $displayTime $text[0].at 'MM-dd HH:mm:ss' } else { $null })
        last_agent_pass = $(if ($passed.Count) { & $displayTime $passed[0].at 'MM-dd HH:mm:ss' } else { $null })
        bridge_installed = $null
    }
    if (-not $known) { foreach ($k in @('results','current_agent','tested7','tested30')) { $metrics[$k] = $null } }
    $bridgePath = Join-Path $paths.LocalRoot 'desktop/state.json'
    if (Test-Path -LiteralPath $bridgePath) {
        $bridge = Get-Content -LiteralPath $bridgePath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        $metrics.bridge_installed = & $displayTime $bridge.updatedUtc 'MM-dd HH:mm:ss'
    }
    $reportPath = Join-Path $OutputRoot 'live-tests.json'
    $report = @{ v = 1; scope = '每个配置只保留最后一次测试；不是累计次数或当前可用性'; records = $rows }
    Write-AiCliLiveJson -Path $reportPath -Value $report
    $artifacts = @()
    if ($rows.Count) { $artifacts = @(@{ at = $rows[0].at; kind = 'report'; title = '各配置最后一次测试'; status = 'completed'; public = 'owner'; open = @{ source = 'aicli.tests' } }) }
    Write-AiCliLiveJson -Path (Join-Path $OutputRoot 'live.json') -Value @{
        v = 1; at = $at; scope = '本机留存的各配置最后一次实测；不读取会话、失败正文或账号数据'
        metrics = $metrics; public = @{ results = $metrics.results }; records = $rows; public_records = $publicRows; artifacts = $artifacts
    }
}
