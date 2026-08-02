# Third-party context metadata and loss-aware client compaction policy.

function Get-AiCliModelMetadataEntry {
    param(
        $MergedProfile,
        [string]$Model
    )
    if ([string]::IsNullOrWhiteSpace($Model)) { return $null }
    $metadata = Get-AiCliProperty $MergedProfile 'modelMetadata'
    if ($null -eq $metadata) { return $null }
    return (Get-AiCliProperty $metadata $Model)
}

function Resolve-AiCliClaudePlanModel {
    param(
        $Plan,
        $MergedProfile
    )
    $selected = $null
    $arguments = @((Get-AiCliProperty $Plan 'argumentList') | ForEach-Object { [string]$_ })
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = [string]$arguments[$index]
        if ($argument -eq '--model' -and $index + 1 -lt $arguments.Count) {
            $selected = [string]$arguments[$index + 1]
            $index++
            continue
        }
        if ($argument.StartsWith('--model=')) {
            $selected = $argument.Substring('--model='.Length)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($selected)) { return $selected }

    $environment = Get-AiCliProperty $Plan 'environmentDelta'
    $selected = [string](Get-AiCliProperty $environment 'ANTHROPIC_MODEL')
    if (-not [string]::IsNullOrWhiteSpace($selected)) { return $selected }
    return [string](Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary')
}

function Assert-AiCliContextManagedPlanVersion {
    param(
        $Plan,
        $MergedProfile
    )
    $compatibility = Get-AiCliProperty $MergedProfile 'compatibility'
    $minimum = [string](Get-AiCliProperty $compatibility 'minCliVersion')
    if ([string]::IsNullOrWhiteSpace($minimum)) { return }

    $versionArguments = @((Get-AiCliProperty $Plan 'versionArgumentList') | ForEach-Object { [string]$_ })
    if ($versionArguments.Count -eq 0 -or $versionArguments[-1] -ne '--version') {
        throw '上下文管理 Profile 缺少可验证的 CLI 版本入口。'
    }
    $prefix = if ($versionArguments.Count -gt 1) {
        @($versionArguments[0..($versionArguments.Count - 2)])
    } else {
        @()
    }
    $resolved = [ordered]@{
        FileName = [string](Get-AiCliProperty $Plan 'fileName')
        PrefixArgs = @($prefix)
        Kind = [string](Get-AiCliProperty $Plan 'launcherKind')
    }
    Assert-AiCliProfileMinimumCliVersion -MergedProfile $MergedProfile -Resolved $resolved
}

function Add-AiCliPlanRemovedEnvironment {
    param(
        [Parameter(Mandatory)]$Plan,
        [string[]]$Names
    )
    $remove = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @((Get-AiCliProperty $Plan 'removeEnvironment') | ForEach-Object { [string]$_ }) + @($Names)) {
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $remove.Contains($name)) {
            $remove.Add($name) | Out-Null
        }
    }
    $Plan.removeEnvironment = @($remove)
}

function Apply-AiCliContextManagementPolicy {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$MergedProfile
    )
    $engine = [string](Get-AiCliProperty $Plan 'engine')
    $provider = [string](Get-AiCliProperty $MergedProfile 'provider')

    if ($engine -eq 'claude' -and $provider -ne 'anthropic') {
        $model = Resolve-AiCliClaudePlanModel -Plan $Plan -MergedProfile $MergedProfile
        $metadata = Get-AiCliModelMetadataEntry -MergedProfile $MergedProfile -Model $model
        if ($null -eq $metadata) {
            # Unknown third-party models keep Claude Code's own conservative
            # behavior and cannot inherit a previous model's window policy.
            $contextControls = @(
                'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
                'CLAUDE_CODE_AUTO_COMPACT_WINDOW',
                'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE',
                'DISABLE_AUTO_COMPACT',
                'DISABLE_COMPACT'
            )
            $environment = Get-AiCliProperty $Plan 'environmentDelta'
            if ($environment -is [System.Collections.IDictionary]) {
                foreach ($name in $contextControls) { $environment.Remove($name) }
            }
            Add-AiCliPlanRemovedEnvironment -Plan $Plan -Names $contextControls
            $Plan.notes = @((Get-AiCliProperty $Plan 'notes')) + @(
                "未知第三方模型不猜上下文窗口: $model；已清除继承的压缩控制变量并使用 Claude Code 保守默认。"
            )
            return $Plan
        }
        Assert-AiCliContextManagedPlanVersion -Plan $Plan -MergedProfile $MergedProfile
        $contextWindow = [long](Get-AiCliProperty $metadata 'contextWindowTokens')
        $autoCompactWindow = [long](Get-AiCliProperty $metadata 'autoCompactWindowTokens')
        $environment = Get-AiCliProperty $Plan 'environmentDelta'
        if ($null -eq $environment) { $environment = @{}; $Plan.environmentDelta = $environment }
        $environment['CLAUDE_CODE_MAX_CONTEXT_TOKENS'] = [string]$contextWindow
        $environment['CLAUDE_CODE_AUTO_COMPACT_WINDOW'] = [string]$autoCompactWindow
        Add-AiCliPlanRemovedEnvironment -Plan $Plan -Names @(
            'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE',
            'DISABLE_AUTO_COMPACT',
            'DISABLE_COMPACT'
        )
        $Plan.notes = @((Get-AiCliProperty $Plan 'notes')) + @(
            "第三方模型上下文窗口: $contextWindow tokens；自动压缩按真实窗口计算。",
            '客户端压缩属于有损摘要：不要为省上下文主动 /compact；先落盘状态，压缩后重读项目规则、当前 Skill 与 diff。'
        )
        return $Plan
    }

    if ($engine -eq 'opencode') {
        $runtime = Get-AiCliProperty $Plan 'machineRuntime'
        $model = [string](Get-AiCliProperty $runtime 'model')
        $metadata = Get-AiCliModelMetadataEntry -MergedProfile $MergedProfile -Model $model
        if ($null -eq $metadata) {
            throw "OpenCode 模型缺少受管 context metadata: $model"
        }
        Assert-AiCliContextManagedPlanVersion -Plan $Plan -MergedProfile $MergedProfile
        $runtime['modelMetadata'] = $metadata
        $Plan.notes = @((Get-AiCliProperty $Plan 'notes')) + @(
            'OpenCode 使用受管模型窗口和晚压缩保护；prune 关闭，压缩后必须重读项目规则、当前 Skill 与 diff。'
        )
    }
    return $Plan
}
