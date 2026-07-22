# OpenCode local-agent adapter. Machine-only and plugin-free.

function Build-AiCliOpenCodeLaunchPlan {
    param(
        $MergedProfile,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @()
    )
    $resolved = Resolve-AiCliLaunchExecutable -Name 'opencode'
    if (-not $resolved) { throw 'OpenCode is not installed.' }
    $endpoint = [string](Get-AiCliProperty $MergedProfile 'endpoint')
    if (-not $endpoint) { $endpoint = 'http://127.0.0.1:32100/v1' }
    Assert-AiCliEndpointSafe -Url $endpoint
    $model = [string](Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary')
    if (-not $model) { $model = 'qwen-main-v1' }
    $arguments = @((Get-AiCliProperty $resolved 'PrefixArgs') | ForEach-Object { [string]$_ })
    $arguments += @('run','--pure','--format','json','--model',"aicli_ollama/$model",'--dir',$ProjectPath,'--auto')
    $arguments += @($NativeArgs)
    return [pscustomobject]@{
        engine = 'opencode'
        profileId = [string](Get-AiCliProperty $MergedProfile 'id')
        fileName = [string](Get-AiCliProperty $resolved 'FileName')
        argumentList = @($arguments)
        versionArgumentList = @((Get-AiCliProperty $resolved 'PrefixArgs') | ForEach-Object { [string]$_ }) + @('--version')
        launcherKind = [string](Get-AiCliProperty $resolved 'Kind')
        workingDirectory = $ProjectPath
        environmentDelta = @{}
        removeEnvironment = @('OPENAI_API_KEY','OPENAI_BASE_URL','OPENCODE_CONFIG','OPENCODE_CONFIG_DIR')
        configFiles = @()
        notes = @('Machine-only local agent; pure mode, transient config, and outer Codex sandbox are mandatory.')
        model = $model
        machineOnly = $true
        machineRuntime = [ordered]@{ kind='opencode'; endpoint=$endpoint; model=$model }
    }
}
