# Zero-cost doctor checks with stable IDs.

function New-AiCliCheck {
    param(
        [string]$Id,
        [ValidateSet('通过','可用','可用但有限制','不可用')][string]$Status,
        [string]$Summary,
        [string]$NextStep = $null,
        [string]$Evidence = $null,
        [string]$Limitation = $null
    )
    $o = [ordered]@{ id = $Id; status = $Status; summary = $Summary }
    if ($NextStep) { $o.nextStep = $NextStep }
    if ($Evidence) { $o.evidence = $Evidence }
    if ($Limitation) { $o.limitation = $Limitation }
    return $o
}

function Invoke-AiCliDoctor {
    param(
        [string]$ProfileId,
        [switch]$Json
    )
    $checks = [System.Collections.Generic.List[object]]::new()

    # platform
    $os = [Environment]::OSVersion.VersionString
    $isWin = $env:OS -match 'Windows'
    $isWin11 = $isWin -and [Environment]::OSVersion.Version.Build -ge 22000
    $isX64 = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::X64
    $platformOk = $isWin11 -and $isX64
    $checks.Add((New-AiCliCheck -Id 'platform.windows' -Status $(if ($platformOk) { '通过' } else { '不可用' }) -Summary "OS: $os; architecture=$([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" -NextStep $(if (-not $platformOk) { '本产品仅支持 Windows 11 x64' }))) | Out-Null

    $psVer = $PSVersionTable.PSVersion
    $psOk = $psVer.Major -ge 7
    $checks.Add((New-AiCliCheck -Id 'platform.powershell' -Status $(if ($psOk) { '通过' } else { '不可用' }) -Summary "PowerShell $psVer" -NextStep $(if (-not $psOk) { '请安装 PowerShell 7: https://github.com/PowerShell/PowerShell/releases' }))) | Out-Null

    $codexResolved = Resolve-AiCliLaunchExecutable -Name 'codex'
    $codexEvidence = if ($codexResolved) { Get-AiCliResolvedCliVersionEvidence -Resolved $codexResolved } else { $null }
    $checks.Add((New-AiCliCheck -Id 'dep.codex' -Status $(if ($codexEvidence) { '通过' } else { '可用但有限制' }) -Summary $(if ($codexEvidence) { "Codex: $($codexEvidence.Kind) → $($codexEvidence.FileName)" } else { 'Codex 未安装或无法取得版本' }) -NextStep $(if (-not $codexEvidence) { 'npm install -g @openai/codex，或安装 Codex 桌面版' }))) | Out-Null
    if ($codexEvidence) {
        $checks.Add((New-AiCliCheck -Id 'dep.codex.version' -Status '通过' -Summary $codexEvidence.Version)) | Out-Null
    }

    $claudeResolved = Resolve-AiCliLaunchExecutable -Name 'claude'
    $claudeEvidence = if ($claudeResolved) { Get-AiCliResolvedCliVersionEvidence -Resolved $claudeResolved } else { $null }
    $checks.Add((New-AiCliCheck -Id 'dep.claude' -Status $(if ($claudeEvidence) { '通过' } else { '可用但有限制' }) -Summary $(if ($claudeEvidence) { "Claude Code: $($claudeEvidence.Kind) → $($claudeEvidence.FileName)" } else { 'Claude Code 未安装或无法取得版本' }) -NextStep $(if (-not $claudeEvidence) { 'irm https://claude.ai/install.ps1 | iex' }))) | Out-Null
    if ($claudeEvidence) {
        $checks.Add((New-AiCliCheck -Id 'dep.claude.version' -Status '通过' -Summary $claudeEvidence.Version)) | Out-Null
    }

    $ollama = Find-AiCliCommandPath 'ollama'
    $checks.Add((New-AiCliCheck -Id 'dep.ollama' -Status $(if ($ollama) { '通过' } else { '可用但有限制' }) -Summary $(if ($ollama) { "Ollama: $ollama" } else { 'Ollama 未安装（仅本地模型 Profile 需要）' }))) | Out-Null

    $oi = $null
    $oiError = $null
    try { $oi = Resolve-AiCliInterpreterExecutable } catch { $oiError = Protect-AiCliSecretText $_.Exception.Message }
    if ($oi) {
        $oiSummary = "Open Interpreter Rust $($oi.Version): $($oi.Kind) → $($oi.FileName)"
        $checks.Add((New-AiCliCheck -Id 'dep.interpreter' -Status '通过' -Summary $oiSummary)) | Out-Null
    } else {
        $oiSummary = if ($oiError) { "Open Interpreter 不受支持: $oiError" } else { 'Open Interpreter Rust 0.0.21+ 未安装（仅 oi-* Profile 需要）' }
        $checks.Add((New-AiCliCheck -Id 'dep.interpreter' -Status '可用但有限制' -Summary $oiSummary -NextStep '安装当前官方 Rust CLI: irm https://www.openinterpreter.com/install.ps1 | iex')) | Out-Null
    }

    # parent env conflicts (names only)
    $conflictNames = @()
    foreach ($v in ($script:AiCliClaudeProviderVars + $script:AiCliCodexProviderVars)) {
        if (Test-Path "Env:$v") {
            $val = (Get-Item "Env:$v").Value
            if (-not [string]::IsNullOrEmpty($val)) { $conflictNames += $v }
        }
    }
    if (@($conflictNames).Count -gt 0) {
        $checks.Add((New-AiCliCheck -Id 'env.parent.provider_vars' -Status '可用但有限制' -Summary ("父终端存在 Provider 变量: {0}" -f ($conflictNames -join ', ')) -Limitation '官方 Profile 会在子进程清除这些变量；其他终端不受影响' -NextStep 'aicli start 使用子进程隔离，无需改全局')) | Out-Null
    } else {
        $checks.Add((New-AiCliCheck -Id 'env.parent.provider_vars' -Status '通过' -Summary '父终端无第三方 Provider 变量')) | Out-Null
    }

    # settings conflict hints (field names only)
    $hints = Get-AiCliClaudeConflictSettingsHints -ProjectPath (Get-Location).Path
    if (@($hints).Count -gt 0) {
        foreach ($h in $hints) {
            $checks.Add((New-AiCliCheck -Id 'config.claude.settings_env' -Status '可用但有限制' -Summary ("可能影响 Provider 的配置层: {0}" -f $h.file) -Evidence (($h.fields -join ', ')) -NextStep '官方启动时检查 settings env 是否抢占订阅')) | Out-Null
        }
    } else {
        $checks.Add((New-AiCliCheck -Id 'config.claude.settings_env' -Status '通过' -Summary '未在用户 settings.json 发现 ANTHROPIC_* env 段')) | Out-Null
    }

    # proxies
    foreach ($proxyId in @('ccp','cliproxy')) {
        $exe = Get-AiCliProxyExecutable -ProxyId $proxyId
        $state = Get-AiCliProxyState -ProxyId $proxyId
        $idc = Test-AiCliProcessIdentity -State $state
        if ($idc.Match) {
            $hostOk = (Get-AiCliProperty $state 'host') -eq '127.0.0.1'
            $checks.Add((New-AiCliCheck -Id "proxy.$proxyId.running" -Status $(if ($hostOk) { '通过' } else { '不可用' }) -Summary ("运行中 port={0} host={1}" -f (Get-AiCliProperty $state 'port'), (Get-AiCliProperty $state 'host')))) | Out-Null
        } elseif ($exe) {
            $checks.Add((New-AiCliCheck -Id "proxy.$proxyId.running" -Status '可用但有限制' -Summary '已安装未运行' -NextStep "aicli proxy $proxyId start")) | Out-Null
        } else {
            $checks.Add((New-AiCliCheck -Id "proxy.$proxyId.running" -Status '可用但有限制' -Summary '未安装（仅 ChatGPT 代理 Profile 需要）' -NextStep "见 aicli proxy $proxyId install 与批准 SHA256 清单")) | Out-Null
        }
    }

    # Ollama public default. Non-default gateways belong in user Profiles.
    if ($ollama) {
        $ollamaOk = $false
        $ollamaSummary = $null
        foreach ($probe in @(
            @{ Url = 'http://127.0.0.1:11434/api/tags'; Label = '11434/api/tags' }
        )) {
            try {
                $tags = Invoke-RestMethod -Uri $probe.Url -TimeoutSec 2 -ErrorAction Stop
                $models = Get-AiCliProperty $tags 'models'
                if (-not $models) { $models = Get-AiCliProperty $tags 'data' }
                $count = @($models).Count
                $ollamaOk = $true
                $ollamaSummary = "Ollama 可达 $($probe.Label)，条目=$count"
                break
            } catch {}
        }
        if ($ollamaOk) {
            $checks.Add((New-AiCliCheck -Id 'ollama.service' -Status '通过' -Summary $ollamaSummary)) | Out-Null
        } else {
            $checks.Add((New-AiCliCheck -Id 'ollama.service' -Status '可用但有限制' -Summary 'Ollama 默认端点 11434 不可达' -NextStep '启动 Ollama，或在用户 Profile 中配置其他 loopback 端口')) | Out-Null
        }
    }

    # profile-specific
    if ($ProfileId) {
        try {
            $merged = Get-AiCliResolvedProfile -Id $ProfileId
            $checks.Add((New-AiCliCheck -Id 'profile.resolve' -Status '通过' -Summary ("解析 Profile: {0} / {1}" -f (Get-AiCliProperty $merged 'displayName'), (Get-AiCliProperty $merged 'id')))) | Out-Null
            $cfg = [bool](Get-AiCliProperty $merged 'configured')
            $checks.Add((New-AiCliCheck -Id 'profile.configured' -Status $(if ($cfg) { '通过' } else { '不可用' }) -Summary $(if ($cfg) { '配置就绪' } else { '未配置' }) -NextStep $(if (-not $cfg) { "aicli profile configure $(Get-AiCliProperty $merged 'templateId')" }))) | Out-Null
            $needs = $false
            $tmpl = $null
            try { $tmpl = Get-AiCliProviderManifest -Id (Get-AiCliProperty $merged 'templateId') } catch {}
            if (-not $tmpl) { try { $tmpl = Get-AiCliProviderManifest -Id $ProfileId } catch {} }
            if ($tmpl) { $needs = [bool](Get-AiCliProperty $tmpl 'requiresSecret' $false) }
            if ($needs) {
                $sc = [bool](Get-AiCliProperty $merged 'secretConfigured')
                $checks.Add((New-AiCliCheck -Id 'profile.secret' -Status $(if ($sc) { '通过' } else { '不可用' }) -Summary ("密钥: {0}" -f (Format-AiCliSecretPresence $sc)))) | Out-Null
            } else {
                $checks.Add((New-AiCliCheck -Id 'profile.secret' -Status '通过' -Summary '此 Profile 不需要本工具管理的 API Key（官方登录或本地）')) | Out-Null
            }
            $transport = Get-AiCliProperty $merged 'transport'
            $engine = Get-AiCliProperty $merged 'engine'
            $profileCliEvidence = Get-AiCliProfileCliIdentityEvidence -MergedProfile $merged
            $enginePath = if ($profileCliEvidence) { $profileCliEvidence.FileName } else { $null }
            $checks.Add((New-AiCliCheck -Id 'profile.engine_cli' -Status $(if ($enginePath) { '通过' } else { '不可用' }) -Summary $(if ($enginePath) { "目标 CLI 已找到: $engine" } else { "目标 CLI 未安装: $engine" }))) | Out-Null
            $minimumVersion = Test-AiCliProfileMinimumCliVersion -MergedProfile $merged -VersionEvidence $profileCliEvidence
            if ($minimumVersion.Required) {
                $versionSummary = if ($minimumVersion.Supported) {
                    "CLI $($minimumVersion.Actual) 满足最低版本 $($minimumVersion.Minimum)"
                } else {
                    "CLI 版本不满足要求：需要 $($minimumVersion.Minimum)+，实际 $($minimumVersion.Actual)"
                }
                $checks.Add((New-AiCliCheck -Id 'profile.engine_cli.minimum' `
                    -Status $(if ($minimumVersion.Supported) { '通过' } else { '不可用' }) `
                    -Summary $versionSummary `
                    -NextStep $(if (-not $minimumVersion.Supported) { "请将 $engine 更新到 $($minimumVersion.Minimum)+" }))) | Out-Null
            }
            if ($engine -eq 'codex' -and $transport -ne 'responses' -and (Get-AiCliProperty $merged 'provider') -ne 'openai' -and (Get-AiCliProperty $merged 'provider') -ne 'ollama') {
                # ollama uses --oss; third party must be responses
                if ($transport -ne 'responses') {
                    $checks.Add((New-AiCliCheck -Id 'profile.transport' -Status '不可用' -Summary "Codex 需要 responses，当前 $transport")) | Out-Null
                } else {
                    $checks.Add((New-AiCliCheck -Id 'profile.transport' -Status '通过' -Summary "transport=$transport")) | Out-Null
                }
            } else {
                $checks.Add((New-AiCliCheck -Id 'profile.transport' -Status '通过' -Summary "engine=$engine transport=$transport")) | Out-Null
            }
            $endpoint = Get-AiCliProperty $merged 'endpoint'
            if ($endpoint) {
                try {
                    Assert-AiCliEndpointSafe -Url $endpoint
                    $checks.Add((New-AiCliCheck -Id 'profile.endpoint' -Status '通过' -Summary "endpoint 校验通过（值不显示完整秘密）" -Evidence $endpoint)) | Out-Null
                } catch {
                    $checks.Add((New-AiCliCheck -Id 'profile.endpoint' -Status '不可用' -Summary $_.Exception.Message)) | Out-Null
                }
            }
            $localReadiness = Test-AiCliSelectedLocalProviderReadiness -MergedProfile $merged
            if ($localReadiness.Applicable) {
                $checks.Add((New-AiCliCheck -Id 'profile.local_provider_readiness' `
                    -Status $(if ($localReadiness.Ready) { '通过' } else { '不可用' }) `
                    -Summary $localReadiness.Summary `
                    -NextStep $(if (-not $localReadiness.Ready) { '恢复本机 loopback Provider 后重试；不要改写模型或全局配置。' }))) | Out-Null
            }
            $ver = Get-AiCliProperty $merged 'verification'
            if ($null -eq $ver) {
                $invalidated = Get-AiCliProperty $merged 'verificationInvalidation'
                $summary = if ($invalidated) { "旧 Live 证据已失效: $invalidated" } else { '尚未 Live Test' }
                $checks.Add((New-AiCliCheck -Id 'profile.verification' -Status '可用但有限制' -Summary $summary -NextStep "aicli test $ProfileId --live --level text --yes")) | Out-Null
            } else {
                $checks.Add((New-AiCliCheck -Id 'profile.verification' -Status $(Get-AiCliProperty $merged 'status') -Summary ("验证记录 level={0} result={1}" -f (Get-AiCliProperty $ver 'level'), (Get-AiCliProperty $ver 'result')))) | Out-Null
            }
            $status = Get-AiCliProperty $merged 'status'
            $proxyRef = Get-AiCliProperty $merged 'proxyRef'
            if ($proxyRef) {
                $st = Get-AiCliProxyState -ProxyId $proxyRef
                $ok = $st -and (Test-AiCliProcessIdentity -State $st).Match
                $checks.Add((New-AiCliCheck -Id 'profile.proxy_dep' -Status $(if ($ok) { '通过' } else { '不可用' }) -Summary $(if ($ok) { "代理 $proxyRef 就绪" } else { "代理 $proxyRef 未运行" }) -NextStep $(if (-not $ok) { "aicli proxy $proxyRef start" }))) | Out-Null
            }
        } catch {
            $checks.Add((New-AiCliCheck -Id 'profile.resolve' -Status '不可用' -Summary $_.Exception.Message -NextStep 'aicli profile list --available')) | Out-Null
        }
    }

    # aggregate
    $overall = '通过'
    foreach ($c in $checks) {
        if ($c.status -eq '不可用') { $overall = '不可用'; break }
        if ($c.status -eq '可用但有限制' -and $overall -ne '不可用') { $overall = '可用但有限制' }
        if ($c.status -eq '可用' -and $overall -eq '通过') { $overall = '可用' }
    }
    if ($ProfileId -and $overall -eq '通过') { $overall = '可用但有限制' } # no live test implied

    $result = New-AiCliResult -Command $(if ($ProfileId) { "doctor $ProfileId" } else { 'doctor' }) -OverallStatus $overall -Checks @($checks)
    if ($Json) {
        Write-AiCliJson $result
    } else {
        Write-AiCliDoctorText -Result $result
        if ($ProfileId) {
            Write-Host ''
            Write-Host "下一步：若静态检查通过，可显式运行 Live Test（可能消耗额度）："
            Write-Host "  aicli test $ProfileId --live --level text --yes"
        }
    }
    return (Get-AiCliExitCodeFromStatus $overall)
}

function Read-AiCliDiagnosticJson {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 2097152 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Diagnostic metadata must be a bounded regular file.'
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
}

function Get-AiCliRuntimeDiagnostics {
    param([string]$BridgeRegistry = '')
    $moduleRoot = Get-AiCliModuleRoot
    $paths = Get-AiCliAppPaths
    $manifest = Join-Path $moduleRoot 'AiCliProfileManager.psd1'
    $desktop = [ordered]@{
        configuration_state = 'not_configured'
        enabled = $null
        release_id = $null
        installation_state = 'not_checked'
        running_process_loaded = 'unknown'
        end_to_end = 'unknown'
        files = @()
    }
    $statePath = Join-Path $paths.LocalRoot 'desktop\state.json'
    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = Read-AiCliDiagnosticJson -Path $statePath
            $enabled = Get-AiCliProperty $state 'enabled'
            $exe = Get-AiCliProperty $state 'executable'
            if ($enabled -isnot [bool] -or $exe -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($exe)) {
                throw 'Invalid desktop state shape.'
            }
            $releaseRoot = Split-Path -Parent (Split-Path -Parent $exe)
            $releaseId = Split-Path -Leaf $releaseRoot
            if ($releaseId -cnotmatch '^[0-9a-f]{16}$') { throw 'Invalid release identity.' }
            $expectedRoot = Join-Path $paths.LocalRoot ('desktop\releases\' + $releaseId)
            $expectedExe = Join-Path $expectedRoot 'bridge\AiCli.CodexDesktopBridge.exe'
            if (-not [string]::Equals([IO.Path]::GetFullPath($exe),[IO.Path]::GetFullPath($expectedExe),[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Desktop executable is outside the managed release.'
            }
            $desktop.configuration_state = 'configured'
            $desktop.enabled = $enabled
            $desktop.release_id = $releaseId
            $desktop.installation_state = 'registry_not_supplied'
            if (-not [string]::IsNullOrWhiteSpace($BridgeRegistry)) {
                $registry = Read-AiCliDiagnosticJson -Path $BridgeRegistry
                if ((Get-AiCliProperty $registry 'schema') -cne 'pcconfig.aicli-desktop-bridge-allowlist.v1') {
                    throw 'Unsupported bridge registry schema.'
                }
                $matches = @($registry.releases | Where-Object release_id -CEQ $releaseId)
                if ($matches.Count -ne 1) {
                    $desktop.installation_state = 'unregistered'
                } else {
                    $files = @($matches[0].files)
                    if ($files.Count -ne 7) { throw 'Incomplete bridge manifest.' }
                    $checks = [Collections.Generic.List[object]]::new()
                    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach ($file in $files) {
                        $relative = [string]$file.path
                        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or
                            $relative.Contains(':') -or -not $names.Add($relative) -or
                            [string]$file.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
                            $file.size -isnot [ValueType] -or $file.size -lt 0) {
                            throw 'Invalid bridge manifest entry.'
                        }
                        $path = [IO.Path]::GetFullPath((Join-Path $expectedRoot $relative))
                        $rootFull = [IO.Path]::GetFullPath($expectedRoot).TrimEnd('\')
                        if (-not $path.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid file scope.' }
                        $regular = Test-Path -LiteralPath $path -PathType Leaf
                        $current = $path
                        while ($regular -and $current.Length -ge $rootFull.Length) {
                            if ((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint) { $regular = $false; break }
                            $current = Split-Path -Parent $current
                        }
                        $sizeMatch = $regular -and (Get-Item -LiteralPath $path).Length -eq $file.size
                        $hashMatch = $sizeMatch -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $file.sha256
                        $checks.Add([ordered]@{path=$relative; regular_file=$regular; size_match=$sizeMatch; sha256_match=$hashMatch})
                    }
                    $desktop.files = $checks.ToArray()
                    $desktop.installation_state = if (@($checks | Where-Object { -not $_.sha256_match }).Count -eq 0) { 'verified' } else { 'mismatch' }
                }
            }
        } catch {
            $desktop.installation_state = 'invalid_or_unavailable'
            if ($desktop.configuration_state -eq 'not_configured') { $desktop.configuration_state = 'invalid' }
            $desktop.error = 'diagnostic_metadata_invalid_or_unavailable'
        }
    }
    return [ordered]@{
        schema = 'aicli.runtime-diagnostics.v1'
        write_mode = 'zero_write'
        network_performed = $false
        model_invoked = $false
        credentials_read = $false
        module = [ordered]@{root=$moduleRoot; version=(Get-AiCliVersion); manifest_sha256=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()}
        desktop = $desktop
    }
}
