#Requires -Version 7.0
param([string]$OutDir = (Join-Path $PSScriptRoot '..\dist'))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1')
$version = [string]$manifest.ModuleVersion
$stage = Join-Path $OutDir "stage-aicli-$version"
$zip = Join-Path $OutDir "ai-cli-profile-manager-$version-win-x64.zip"
$releaseManifestPath = Join-Path $OutDir "ai-cli-profile-manager-$version.sha256.json"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# Fail closed: a failed new build must not leave an older ZIP/hash pair that
# can be mistaken for the current release candidate.
foreach ($oldArtifact in @($zip, $releaseManifestPath)) {
    if (Test-Path -LiteralPath $oldArtifact) { Remove-Item -LiteralPath $oldArtifact -Force }
}
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

foreach ($dir in @('src','data','bin')) {
    Copy-Item -LiteralPath (Join-Path $root $dir) -Destination (Join-Path $stage $dir) -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'scripts') | Out-Null
foreach ($script in @('Install.ps1','Uninstall.ps1','Import-FromOpenClaw.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root "scripts\$script") -Destination (Join-Path $stage "scripts\$script") -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'docs') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'docs\user') -Destination (Join-Path $stage 'docs\user') -Recurse -Force
if (Test-Path -LiteralPath (Join-Path $root 'docs\compatibility')) {
    Copy-Item -LiteralPath (Join-Path $root 'docs\compatibility') -Destination (Join-Path $stage 'docs\compatibility') -Recurse -Force
}
foreach ($file in @('LICENSE','SECURITY.md','PRIVACY.md','THIRD_PARTY_NOTICES.md','README.md','CHANGELOG.md')) {
    $source = Join-Path $root $file
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $file) -Force
    }
}
$pdfSources = [ordered]@{
    'AI CLI Profile Manager 使用手册.pdf' = 'docs\user\AI CLI Profile Manager 使用手册.md'
    'Codex、Claude Code 与 Open Interpreter CLI 中文手册.pdf' = 'docs\user\Codex、Claude Code 与 Open Interpreter CLI 中文手册.md'
}
foreach ($pdfName in $pdfSources.Keys) {
    $pdfPath = Join-Path $root $pdfName
    if (-not (Test-Path -LiteralPath $pdfPath -PathType Leaf)) {
        throw "发行包缺少必需 PDF: $pdfName"
    }
    $markdownPath = Join-Path $root $pdfSources[$pdfName]
    $pdfAscii = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($pdfPath))
    $sourceText = [IO.File]::ReadAllText($markdownPath)
    $normalizedSource = $sourceText.Replace("`r`n", "`n").Replace("`r", "`n")
    $sourceBytes = [Text.UTF8Encoding]::new($false).GetBytes($normalizedSource)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $sourceHash = ([BitConverter]::ToString($sha.ComputeHash($sourceBytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    if ($pdfAscii -notmatch '/AICliSourceSHA256' -or $pdfAscii -notmatch [regex]::Escape($sourceHash)) {
        throw "发行 PDF 未绑定当前 canonical Markdown 的 SHA256，请重新生成并视觉验收: $pdfName"
    }
    if ($pdfAscii -match '(?i)/URI\s*\(\s*file:|C:(?:/|\\)Users(?:/|\\)|AppData(?:/|\\)Local(?:/|\\)Temp|_pdfbuild_tmp') {
        throw "发行 PDF 含本机路径、file URI 或临时标题: $pdfName"
    }
    Copy-Item -LiteralPath $pdfPath -Destination (Join-Path $stage $pdfName) -Force
}

foreach ($relative in @('AGENTS.md','docs\product','docs\plans','docs\research-inputs')) {
    if (Test-Path -LiteralPath (Join-Path $stage $relative)) {
        throw "发行包误含内部材料: $relative"
    }
}

$forbiddenSecretFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object {
    $_.Name -like '.env*' -or $_.Extension -in @('.pem','.key','.pfx','.p12','.kdbx')
})
if ($forbiddenSecretFiles.Count -gt 0) {
    throw "发行候选包含禁止的秘密容器类型：$($forbiddenSecretFiles[0].FullName)"
}

$secretPatterns = '(?i)(sk-[A-Za-z0-9_.-]{16,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|(?:ANTHROPIC|OPENAI|DASHSCOPE|DEEPSEEK)_API_KEY\s*[=:]\s*[^$\s])'
$leaks = @(Get-ChildItem -LiteralPath $stage -Recurse -File |
    Where-Object { $_.Extension -in @('.md','.ps1','.psm1','.psd1','.cmd','.json','.toml','.yaml','.yml','.txt') } |
    Select-String -Pattern $secretPatterns -ErrorAction SilentlyContinue)
if ($leaks.Count -gt 0) { throw "发行候选秘密扫描失败：$($leaks[0].Path)" }

$privatePatterns = '(?i)(C:\\Users\\[^\\/\s]+(?:\\|/)|[D-Z]:\\(?:Users|Projects|\.agents|PCConfig|Documents)(?:\\|/)|127\.0\.0\.1:(?!(?:11434|43197|43198|18765|8317)\b)\d{2,5})'
$privateHits = @(Get-ChildItem -LiteralPath $stage -Recurse -File |
    Where-Object { $_.Extension -in @('.md','.ps1','.psm1','.psd1','.cmd','.json','.toml','.yaml','.yml','.txt') } |
    Select-String -Pattern $privatePatterns -ErrorAction SilentlyContinue)
if ($privateHits.Count -gt 0) { throw "发行候选含本机私有路径或端口：$($privateHits[0].Path)" }

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$releaseManifest = [ordered]@{
    product  = 'AI CLI Profile Manager'
    version  = $version
    platform = 'Windows 11 x64 / PowerShell 7+'
    zip      = [IO.Path]::GetFileName($zip)
    sha256   = $hash
    builtUtc = (Get-Date).ToUniversalTime().ToString('o')
}
$releaseManifest | ConvertTo-Json | Set-Content -LiteralPath $releaseManifestPath -Encoding utf8
Write-Host "Built: $zip"
Write-Host "SHA256: $hash"
