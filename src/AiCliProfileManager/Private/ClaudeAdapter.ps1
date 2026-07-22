# Claude Code adapter: process-level env only, never writes user settings.json.

function Get-AiCliClaudeReservedArgs {
    # flags that would override our provider routing if present
    return @('--settings', '--setting-sources')
}

function Assert-AiCliClaudeNativeArgs {
    param([string[]]$NativeArgList)
    for ($i = 0; $i -lt @($NativeArgList).Count; $i++) {
        $a = $NativeArgList[$i]
        if ($a -in (Get-AiCliClaudeReservedArgs) -or $a.StartsWith('--settings=') -or $a.StartsWith('--setting-sources=')) {
            throw "参数 $a 与 aicli Provider 路由校验冲突。"
        }
    }
}

function Get-AiCliClaudeConflictSettingsHints {
    param([string]$ProjectPath)
    # Report files that may set env/provider without reading secret values
    $hints = @()
    $userRoot = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path (Get-AiCliKnownFolder UserProfile) '.claude' }
    $candidates = @(
        (Join-Path $userRoot 'settings.json'),
        (Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json'),
        (Join-Path $env:ProgramData 'ClaudeCode\managed-settings.json')
    )
    if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
        $candidates += @(
            (Join-Path $ProjectPath '.claude\settings.json'),
            (Join-Path $ProjectPath '.claude\settings.local.json')
        )
    }
    $managedDropIns = Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.d'
    if (Test-Path -LiteralPath $managedDropIns) {
        $candidates += @(Get-ChildItem -LiteralPath $managedDropIns -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    foreach ($user in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
      if (Test-Path -LiteralPath $user) {
        try {
            $raw = Get-Content -LiteralPath $user -Raw -Encoding utf8
            if ($raw -match 'ANTHROPIC_(API_KEY|BASE_URL|AUTH_TOKEN|MODEL|DEFAULT_(HAIKU|SONNET|OPUS)_MODEL)') {
                $hints += [ordered]@{ file = $user; fields = @('env/ANTHROPIC_*') }
            }
        } catch {}
      }
    }
    return $hints
}

function Assert-AiCliClaudeProviderSettingsClean {
    param([string]$ProjectPath)
    $conflicts = @(Get-AiCliClaudeConflictSettingsHints -ProjectPath $ProjectPath)
    if ($conflicts.Count -gt 0) {
        $files = ($conflicts | ForEach-Object { $_.file }) -join ', '
        throw "检测到会改写 Provider 的 Claude settings：$files。为避免请求发错服务，aicli 已停止启动；请移除其中 env.ANTHROPIC_* 后重试。"
    }
}

function Resolve-AiCliClaudeEffort {
    param($MergedProfile, [string]$Provider, [string[]]$NativeArgs)
    foreach ($a in $NativeArgs) {
        if ($a -eq '--effort' -or $a.StartsWith('--effort=')) {
            if ($a.StartsWith('--effort=')) { return $a.Substring(9) }
        }
    }
    for ($i = 0; $i -lt $NativeArgs.Count; $i++) {
        if ($NativeArgs[$i] -eq '--effort' -and $i + 1 -lt $NativeArgs.Count) { return $NativeArgs[$i + 1] }
    }
    $prefs = Get-AiCliProperty $MergedProfile 'preferences'
    $e = Get-AiCliProperty $prefs 'effort'
    if (-not $e) { $e = Get-AiCliProperty $MergedProfile 'defaultEffort' }
    if (-not $e) {
        switch ($Provider) {
            'deepseek' { return 'high' }   # DeepSeek: high|max
            'qwen' { return 'on' }         # DashScope: enable_thinking on/off（非多档）
            'anthropic' { return 'high' }
            default { return $null }
        }
    }
    return $e
}

function Build-AiCliClaudeLaunchPlan {
    param(
        $MergedProfile,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @(),
        [int]$ProxyPort = 0
    )
    Assert-AiCliClaudeNativeArgs -NativeArgList $NativeArgs
    $resolved = Resolve-AiCliLaunchExecutable -Name 'claude'
    if (-not $resolved) {
        $exe = Find-AiCliCommandPath -Name 'claude'
        if (-not $exe) { throw '未找到 claude。请安装 Claude Code：irm https://claude.ai/install.ps1 | iex' }
        $resolved = [ordered]@{ FileName = $exe; PrefixArgs = @(); Kind = 'native' }
    }

    $id = Get-AiCliProperty $MergedProfile 'id'
    $provider = Get-AiCliProperty $MergedProfile 'provider'
    $transport = Get-AiCliProperty $MergedProfile 'transport'
    $envDelta = @{}
    $removeEnv = @()
    $cliArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($resolved.PrefixArgs)) { $cliArgs.Add([string]$p) | Out-Null }
    $notes = @()
    $proxyRef = Get-AiCliProperty $MergedProfile 'proxyRef'
    $effort = Resolve-AiCliClaudeEffort -MergedProfile $MergedProfile -Provider $provider -NativeArgs $NativeArgs

    foreach ($v in $script:AiCliClaudeProviderVars) { $removeEnv += $v }
    Assert-AiCliClaudeProviderSettingsClean -ProjectPath $ProjectPath

    if ($provider -eq 'anthropic' -or $id -eq 'claude-official') {
        $notes += '官方 Claude：清除第三方 Provider 变量后使用原生登录。'
        $notes += '若 401：请先在终端运行 claude 完成登录（claude.ai 订阅）。'
        if ($effort) {
            $envDelta['CLAUDE_CODE_EFFORT_LEVEL'] = $effort
            $notes += "思考等级环境: CLAUDE_CODE_EFFORT_LEVEL=$effort"
        }
    }
    elseif ($transport -eq 'managed-proxy') {
        if ($ProxyPort -le 0) {
            throw "代理尚未运行或端口未知。请先: aicli proxy $proxyRef start"
        }
        $base = "http://127.0.0.1:$ProxyPort"
        $proxyMeta = Get-AiCliProxyRuntimeMeta -ProxyId $proxyRef
        $localKey = Get-AiCliProperty $proxyMeta 'localClientKey'
        if (-not $localKey) { $localKey = 'proxy' }
        $envDelta['ANTHROPIC_BASE_URL'] = $base
        # CLIProxyAPI accepts api-keys as Bearer / AUTH_TOKEN; clear conflicting key modes carefully
        $envDelta['ANTHROPIC_AUTH_TOKEN'] = $localKey
        $envDelta['ANTHROPIC_API_KEY'] = ''
        $model = Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary'
        if (-not $model) { $model = 'gpt-5.6-sol' }
        $envDelta['ANTHROPIC_MODEL'] = $model
        $envDelta['CLAUDE_CODE_SUBAGENT_MODEL'] = $model
        $envDelta['CLAUDE_CODE_ALWAYS_ENABLE_EFFORT'] = '1'
        $envDelta['CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY'] = '3'
        $envDelta['ENABLE_TOOL_SEARCH'] = 'false'
        $envDelta['CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY'] = '1'
        $envDelta['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'] = '1'
        $cliArgs.Add('--model') | Out-Null
        $cliArgs.Add($model) | Out-Null
        $notes += "通过受管代理 $proxyRef 访问 ChatGPT/Codex（第三方；Tibo 演示路线，非 OpenAI 官方背书）。"
        $notes += "Base URL: $base  模型: $model"
        $notes += '已设置 Tibo 风格 env：SUBAGENT_MODEL / ALWAYS_ENABLE_EFFORT / MAX_TOOL_USE_CONCURRENCY=3'
    }
    elseif ($provider -eq 'ollama' -or $id -eq 'claude-ollama') {
        $endpoint = Get-AiCliProperty $MergedProfile 'endpoint'
        if (-not $endpoint) { $endpoint = 'http://127.0.0.1:11434' }
        # Claude's Ollama integration uses the base host; user Profiles may
        # supply a non-default loopback port and an optional /v1 suffix.
        $anthropicBase = $endpoint -replace '/v1/?$', ''
        $envDelta['ANTHROPIC_AUTH_TOKEN'] = 'ollama'
        $envDelta['ANTHROPIC_API_KEY'] = ''
        $envDelta['ANTHROPIC_BASE_URL'] = $anthropicBase
        $model = Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary'
        if (-not $model) { $model = 'qwen3:8b' }
        $envDelta['ANTHROPIC_MODEL'] = $model
        $envDelta['ANTHROPIC_DEFAULT_OPUS_MODEL'] = $model
        $envDelta['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $model
        $envDelta['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = $model
        $envDelta['ANTHROPIC_SMALL_FAST_MODEL'] = $model
        $envDelta['CLAUDE_CODE_SUBAGENT_MODEL'] = $model
        $envDelta['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'] = '1'
        $cliArgs.Add('--model') | Out-Null
        $cliArgs.Add($model) | Out-Null
        $notes += "Ollama 本机网关: $anthropicBase"
        $notes += "模型: $model"
    }
    else {
        $endpoint = Get-AiCliProperty $MergedProfile 'endpoint'
        if (-not $endpoint) { throw "Profile $id 缺少 endpoint" }
        Assert-AiCliEndpointSafe -Url $endpoint
        $envDelta['ANTHROPIC_BASE_URL'] = $endpoint
        if ((Get-AiCliProperty $MergedProfile 'secretRef')) {
            $secret = Get-AiCliSecret -SecretId (Get-AiCliProperty $MergedProfile 'secretRef')
            $envDelta['ANTHROPIC_API_KEY'] = $secret
        } elseif ([bool](Get-AiCliProperty $MergedProfile 'requiresSecret' $true)) {
            $tid = Get-AiCliProperty $MergedProfile 'templateId'
            if (-not $tid) { $tid = $id }
            throw "Profile $id 需要 API Key。请运行: aicli profile configure $tid"
        }
        $model = Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary'
        if ($model) {
            $null = Assert-AiCliModelId -Model $model
            $envDelta['ANTHROPIC_MODEL'] = $model
            $envDelta['ANTHROPIC_DEFAULT_OPUS_MODEL'] = $model
            $envDelta['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $model
            $cliArgs.Add('--model') | Out-Null
            $cliArgs.Add($model) | Out-Null
        }
        $small = Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'small'
        if ($small) {
            $envDelta['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = $small
            $envDelta['ANTHROPIC_SMALL_FAST_MODEL'] = $small
            $envDelta['CLAUDE_CODE_SUBAGENT_MODEL'] = $small
        }
        $envDelta['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'] = '1'
        if ($provider -eq 'deepseek' -and $effort) {
            # DeepSeek Anthropic: output_config.effort high|max；CLI 侧常用 CLAUDE_CODE_EFFORT_LEVEL
            $envDelta['CLAUDE_CODE_EFFORT_LEVEL'] = $effort
            $notes += "DeepSeek 思考: effort=$effort（文档: high/max；agent 可能自动 max）"
        }
        elseif ($provider -eq 'qwen') {
            # DashScope hybrid thinking is enable_thinking bool — not multi-tier via Claude Code effort
            $notes += '千问思考: DashScope 多为 enable_thinking 开关，不是 Codex 六档 effort。'
            if ($effort -in @('off','false','0','disabled')) {
                $notes += '当前偏好关闭思考（上游是否尊重取决于模型/网关）。'
            } else {
                $notes += '当前偏好开启思考（默认）。'
            }
            if ($effort -and $effort -notin @('off','false','0','disabled','on','true','1','enabled')) {
                $envDelta['CLAUDE_CODE_EFFORT_LEVEL'] = $effort
                $notes += "已透传 CLAUDE_CODE_EFFORT_LEVEL=$effort（不等价原生 Claude effort）"
            }
        }
        elseif ($effort) {
            $envDelta['CLAUDE_CODE_EFFORT_LEVEL'] = $effort
        }
        $dest = Get-AiCliProperty $MergedProfile 'dataDestination'
        if ($dest) { $notes += "数据去向：$dest" }
        $notes += "Anthropic Messages 兼容端点: $endpoint"
        $notes += '仅注入子进程环境，不写全局 settings.json。'
    }

    foreach ($a in $NativeArgs) { $cliArgs.Add($a) | Out-Null }

    return [pscustomobject]@{
        engine            = 'claude'
        profileId         = $id
        fileName          = [string](Get-AiCliProperty $resolved 'FileName')
        argumentList      = @($cliArgs.ToArray())
        versionArgumentList = @((Get-AiCliProperty $resolved 'PrefixArgs') | ForEach-Object { [string]$_ }) + @('--version')
        launcherKind      = [string](Get-AiCliProperty $resolved 'Kind')
        workingDirectory  = $ProjectPath
        environmentDelta  = $envDelta
        removeEnvironment = @($removeEnv)
        configFiles       = @()
        notes             = @($notes)
        proxyRef          = $proxyRef
        effort            = $effort
        machineRuntime    = [ordered]@{ kind='claude' }
    }
}
