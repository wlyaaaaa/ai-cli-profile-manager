#Requires -Version 7.0
[CmdletBinding()]
param([string]$SourceRoot = (Split-Path -Parent $PSScriptRoot), [string]$PrivateContract, [string]$OutputRoot, [switch]$StaticOnly)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Split-Path -Parent $PSScriptRoot
Get-Module AiCliProfileManager -All | Remove-Module -Force
Import-Module (Join-Path $root 'src/AiCliProfileManager/AiCliProfileManager.psd1') -Force
$module = Get-Module AiCliProfileManager
if (-not $StaticOnly) {
    & $module { param($source,$output) Update-AiCliLiveStatus -SourceRoot $source -OutputRoot $output } $SourceRoot $OutputRoot
}
$files = @(git -c core.quotepath=false -C $root ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw '无法读取项目文件清单' }
$docs = 0; $code = 0; $docFiles = 0; $codeFiles = 0
foreach ($f in $files) {
    $ext = [IO.Path]::GetExtension($f)
    if ($ext -eq '.md') { $docFiles++; $docs += ([IO.File]::ReadAllText((Join-Path $root $f)) -replace '\s','').Length }
    elseif ($f -notlike 'tests/fixtures/*' -and ($ext -in @('.ps1','.psm1','.py','.cs','.cjs','.js') -or $f -eq 'src/AiCliProfileManager/AiCliProfileManager.psd1')) {
        $codeFiles++; $code += [IO.File]::ReadAllLines((Join-Path $root $f)).Length
    }
}
$path = Join-Path $root 'docs/live.snapshot.json'
$old = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -DateKind String } else { @{} }
$value = [ordered]@{ v = 1; at = $old.at; scope = '自有文档和代码规模不计第三方、历史夹具、JSON 数据、PDF 或生成物；Git 文件总数统计全部已跟踪文件'
    metrics = @{ doc_files = $docFiles; code_files = $codeFiles; tracked_files = @(git -C $root ls-files).Count }
    size = @{ at = $old.at; docs_chars = $docs; code_lines = $code } }
if ($old.scope -ne $value.scope -or $old.size.docs_chars -ne $docs -or $old.size.code_lines -ne $code -or $old.metrics.doc_files -ne $docFiles -or $old.metrics.code_files -ne $codeFiles -or $old.metrics.tracked_files -ne $value.metrics.tracked_files) {
    $value.at = $value.size.at = [DateTimeOffset]::UtcNow.ToString('o')
    & $module { param($p,$v) Write-AiCliLiveJson -Path $p -Value $v -Compress } $path $value
}
if ($PrivateContract) { [IO.File]::WriteAllText($PrivateContract,[IO.File]::ReadAllText((Join-Path $root 'docs/live.contract.json')).Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false)) }
