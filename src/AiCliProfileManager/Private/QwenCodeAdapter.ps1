# Qwen Code local-agent adapter. Machine-only: aicli owns transient QWEN_HOME.

function Build-AiCliQwenCodeLaunchPlan {
    param(
        $MergedProfile,
        [string]$ProjectPath,
        [string[]]$NativeArgs = @()
    )
    $resolved = Resolve-AiCliLaunchExecutable -Name 'qwen'
    if (-not $resolved) { throw 'Qwen Code is not installed. Install @qwen-code/qwen-code first.' }
    $endpoint = [string](Get-AiCliProperty $MergedProfile 'endpoint')
    if (-not $endpoint) { $endpoint = 'http://127.0.0.1:32100/v1' }
    Assert-AiCliEndpointSafe -Url $endpoint
    $model = [string](Get-AiCliProperty (Get-AiCliProperty $MergedProfile 'models') 'primary')
    if (-not $model) { $model = 'qwen3.6-35b:256k' }
    $arguments = @((Get-AiCliProperty $resolved 'PrefixArgs') | ForEach-Object { [string]$_ })
    $arguments += @('--bare','--auth-type','openai','--model',$model,'--yolo','-p','','--output-format','json')
    $arguments += @($NativeArgs)
    return [pscustomobject]@{
        engine = 'qwen-code'
        profileId = [string](Get-AiCliProperty $MergedProfile 'id')
        fileName = [string](Get-AiCliProperty $resolved 'FileName')
        argumentList = @($arguments)
        versionArgumentList = @((Get-AiCliProperty $resolved 'PrefixArgs') | ForEach-Object { [string]$_ }) + @('--version')
        launcherKind = [string](Get-AiCliProperty $resolved 'Kind')
        workingDirectory = $ProjectPath
        environmentDelta = @{}
        removeEnvironment = @('OPENAI_API_KEY','OPENAI_BASE_URL','QWEN_API_KEY')
        configFiles = @()
        notes = @('Machine-only local agent; transient QWEN_HOME and outer Codex sandbox are mandatory.')
        model = $model
        machineOnly = $true
        machineRuntime = [ordered]@{ kind='qwen-code'; endpoint=$endpoint; model=$model }
    }
}
