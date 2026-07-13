#Requires -Version 7.0
<#
.SYNOPSIS
  Preview or import recognized Qwen/DeepSeek credentials from OpenClaw.
.DESCRIPTION
  Default is preview-only. Use -Apply to write profiles; use -Force to replace an existing profile.
  A provider is imported only when its Base URL proves the expected vendor identity.
#>
param(
    [string]$OpenClawJson = (Join-Path $env:USERPROFILE '.openclaw\openclaw.json'),
    [string]$DataRoot,
    [switch]$Apply,
    [switch]$Force,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path $PSScriptRoot '..\src\AiCliProfileManager'
$module = Join-Path $moduleRoot 'AiCliProfileManager.psd1'
Import-Module $module -Force
foreach ($private in @('Brand','Paths','Redaction','JsonStore','ConsoleUi','SecretStore','ManifestService','ProfileService')) {
    . (Join-Path $moduleRoot "Private\$private.ps1")
}
if ($DataRoot) {
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    Set-AiCliDataRootOverride -Path $DataRoot
}

if (-not (Test-Path -LiteralPath $OpenClawJson)) {
    throw "找不到 OpenClaw 配置: $OpenClawJson"
}

$j = Get-Content -LiteralPath $OpenClawJson -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$providers = Get-AiCliProperty (Get-AiCliProperty $j 'models') 'providers'
if (-not $providers) { throw 'openclaw.json 缺少 models.providers' }

function Test-ExpectedProviderUrl {
    param([string]$Url, [ValidateSet('qwen','deepseek')][string]$Provider)
    try { $uri = [Uri]$Url } catch { return $false }
    if ($uri.Scheme -ne 'https') { return $false }
    if ($Provider -eq 'qwen') {
        return ($uri.Host -eq 'dashscope.aliyuncs.com' -or $uri.Host -match '\.maas\.aliyuncs\.com$')
    }
    return ($uri.Host -eq 'api.deepseek.com')
}

function Import-RecognizedProfile {
    param(
        [Parameter(Mandatory)][string]$TemplateId,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$SourceProviderId
    )
    $template = Get-AiCliProviderManifest -Id $TemplateId
    $existing = Get-AiCliUserProfile -Id $TemplateId
    if ($existing -and -not $Force) {
        Write-Host "SKIP $TemplateId — 已存在；如确需替换请加 -Force"
        return
    }
    if (-not $Apply -or $WhatIf) {
        Write-Host "PREVIEW $TemplateId ← OpenClaw provider '$SourceProviderId'（不会显示或写入密钥）"
        return
    }

    $oldSecret = if ($existing) { Get-AiCliProperty $existing 'secretRef' } else { $null }
    $newSecret = New-AiCliSecret -PlainText $Key -Label "$TemplateId-from-openclaw"
    $profile = [ordered]@{
        schemaVersion = 1
        id            = $TemplateId
        templateId    = $TemplateId
        displayName   = (Get-AiCliProperty $template 'displayName')
        region        = (Get-AiCliProperty $template 'region')
        plan          = (Get-AiCliProperty $template 'plan')
        endpoint      = (Get-AiCliProperty $template 'endpoint')
        models        = (Get-AiCliProperty $template 'models')
        secretRef     = $newSecret
        updatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        importedFrom  = "openclaw:$SourceProviderId"
    }
    try {
        Save-AiCliUserProfile -Profile $profile
    } catch {
        try { Remove-AiCliSecret -SecretId $newSecret } catch {}
        throw
    }
    if ($oldSecret -and $oldSecret -ne $newSecret -and
        -not (Test-AiCliSecretReferencedByAnotherProfile -SecretId $oldSecret -ExceptProfileId $TemplateId)) {
        Remove-AiCliSecret -SecretId $oldSecret
    }
    Write-Host "OK imported $TemplateId（密钥已用当前 Windows 用户 DPAPI 保护）"
}

$planned = 0
$qwen = Get-AiCliProperty $providers 'openai'
if ($qwen) {
    $qwenUrl = [string](Get-AiCliProperty $qwen 'baseUrl')
    $qwenKey = [string](Get-AiCliProperty $qwen 'apiKey')
    if (-not (Test-ExpectedProviderUrl -Url $qwenUrl -Provider qwen)) {
        Write-Host "SKIP providers.openai — Base URL 不能证明它是阿里云百炼，拒绝把未知/OpenAI Key 改送到千问。"
    } elseif ([string]::IsNullOrWhiteSpace($qwenKey)) {
        Write-Host 'SKIP Qwen — 无 API Key'
    } else {
        foreach ($templateId in @('claude-qwen-paygo','codex-qwen-paygo','oi-qwen-paygo')) {
            try {
                Import-RecognizedProfile -TemplateId $templateId -Key $qwenKey -SourceProviderId 'openai'
                $planned++
            } catch {
                if ($_.Exception.Message -match '未知 Profile 模板') { continue }
                throw
            }
        }
    }
}

$deepseek = Get-AiCliProperty $providers 'deepseek'
if ($deepseek) {
    $dsUrl = [string](Get-AiCliProperty $deepseek 'baseUrl')
    $dsKey = [string](Get-AiCliProperty $deepseek 'apiKey')
    if (-not (Test-ExpectedProviderUrl -Url $dsUrl -Provider deepseek)) {
        Write-Host 'SKIP DeepSeek — Base URL 不能证明它是 api.deepseek.com。'
    } elseif ([string]::IsNullOrWhiteSpace($dsKey)) {
        Write-Host 'SKIP DeepSeek — 无 API Key'
    } else {
        foreach ($templateId in @('claude-deepseek','oi-deepseek')) {
            try {
                Import-RecognizedProfile -TemplateId $templateId -Key $dsKey -SourceProviderId 'deepseek'
                $planned++
            } catch {
                if ($_.Exception.Message -match '未知 Profile 模板') { continue }
                throw
            }
        }
    }
}

Write-Host ''
if (-not $Apply -or $WhatIf) {
    Write-Host '当前为预览，没有修改任何 Profile。确认后运行：'
    Write-Host "  pwsh -File '$PSCommandPath' -Apply"
} else {
    Write-Host '下一步按实际已导入 Profile 执行：'
    Write-Host '  aicli doctor <profile-id>'
    Write-Host '  aicli test <profile-id> --live --level text --yes'
}
