#Requires -Version 7.2

$ErrorActionPreference = 'Stop'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$mode = [string]$args[0]
$forwardedArgs = @($args | Select-Object -Skip 1)

if ($mode -eq '--fake-passthrough') {
    if ($env:AICLI_TEST_ARGS_FILE) {
        $captured = [ordered]@{ args = @($forwardedArgs) } | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText($env:AICLI_TEST_ARGS_FILE, $captured, $utf8NoBom)
    }
    [Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())
    [Console]::OpenStandardOutput().Flush()
    exit 23
}

if ($mode -eq '--fake-app-server-stuck') {
    Start-Sleep -Milliseconds 300
    $pidPath = $env:AICLI_TEST_CHILD_PID_FILE
    if (-not $pidPath) { exit 31 }

    $childExe = Join-Path $PSHOME 'pwsh.exe'
    $childStart = [Diagnostics.ProcessStartInfo]::new()
    $childStart.FileName = $childExe
    $childStart.UseShellExecute = $false
    $childStart.ArgumentList.Add('-NoProfile')
    $childStart.ArgumentList.Add('-Command')
    $childStart.ArgumentList.Add('Start-Sleep -Seconds 600')
    $child = [Diagnostics.Process]::Start($childStart)
    if ($null -eq $child) { exit 32 }
    [IO.File]::WriteAllText($pidPath, $child.Id.ToString([Globalization.CultureInfo]::InvariantCulture), $utf8NoBom)

    while ($null -ne [Console]::In.ReadLine()) { }
    exit 0
}

if ($mode -ne '--fake-app-server') { exit 30 }

$script:clientReplyRaw = $null
$script:openAiChild = [ordered]@{
    threadId = ''
    sessionId = ''
    model = ''
    effort = ''
    cwd = ''
    turnId = ''
    ephemeral = $true
    finalText = 'CHILD_OK'
    finalMessageId = 'openai-child-final'
}

function Write-FakeRpcLine {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Message)
    $line = $Message | ConvertTo-Json -Depth 100 -Compress
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
    return $line
}

while ($null -ne ($requestLine = [Console]::In.ReadLine())) {
    $request = $requestLine | ConvertFrom-Json -AsHashtable
    if (-not $request.Contains('method') -and [string]$request.id -eq 'server-openai-child') {
        if ($env:AICLI_TEST_OPENAI_CHILD_RESULT_FILE) {
            [IO.File]::WriteAllText(
                $env:AICLI_TEST_OPENAI_CHILD_RESULT_FILE,
                ($request | ConvertTo-Json -Depth 100 -Compress),
                $utf8NoBom)
        }
        continue
    }
    switch ([string]$request.method) {
        'test/startup' {
            $catalogArg = @($forwardedArgs | Where-Object { $_ -like 'model_catalog_json=*' } | Select-Object -Last 1)
            $catalog = $null
            if ($catalogArg.Count) {
                $path = ([string]$catalogArg[0]).Substring('model_catalog_json='.Length) | ConvertFrom-Json
                $catalog = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            }
            $null = Write-FakeRpcLine @{ id = $request.id; result = @{ startupInstructions = $catalog.models[0].base_instructions } }
        }
        'thread/start' {
            $provider = [string]$request.params.modelProvider
            $model = [string]$request.params.model
            $cwd = [string]$request.params.cwd
            $openAiToolPresent = @($request.params.dynamicTools | Where-Object { [string]$_.name -eq 'openai_child' }).Count -eq 1
            if ($provider -eq 'openai') {
                $script:openAiChild.threadId = if ($model -eq 'gpt-6-astra') { 'astra-child-thread' } else { 'openai-child-thread' }
                $script:openAiChild.sessionId = if ($model -eq 'gpt-6-astra') { 'astra-child-session' } else { 'openai-child-session' }
                $script:openAiChild.model = $model
                $script:openAiChild.cwd = $cwd
                $script:openAiChild.ephemeral = [bool]$request.params.ephemeral
                $null = Write-FakeRpcLine ([ordered]@{
                    method = 'thread/started'
                    params = @{ thread = @{
                        id = $script:openAiChild.threadId
                        sessionId = $script:openAiChild.sessionId
                        modelProvider = 'openai'
                        model = $model
                        cwd = $cwd
                        ephemeral = $script:openAiChild.ephemeral
                    } }
                })
                $threadId = $script:openAiChild.threadId
                $sessionId = $script:openAiChild.sessionId
            }
            else {
                $threadId = if ($provider -eq 'aicli_deepseek_flash') { 'deep-thread' } else { 'thread-started' }
                $sessionId = $threadId
            }
            $null = Write-FakeRpcLine ([ordered]@{
                jsonrpc = '2.0'
                id = $request.id
                result = @{
                    modelProvider = $provider
                    model = $model
                    openAiChildToolPresent = $openAiToolPresent
                    thread = @{
                        id = $threadId
                        sessionId = $sessionId
                        modelProvider = $provider
                        model = $model
                        cwd = $cwd
                        ephemeral = if ($provider -eq 'openai') { $script:openAiChild.ephemeral } else { $false }
                    }
                }
            })
            if ($provider -ne 'openai' -and $openAiToolPresent -and $env:AICLI_TEST_OPENAI_CHILD_RESULT_FILE) {
                $agentType = if ($env:AICLI_TEST_OPENAI_CHILD_AGENT_TYPE) { $env:AICLI_TEST_OPENAI_CHILD_AGENT_TYPE } else { 'openai_child' }
                $childModel = if ($env:AICLI_TEST_OPENAI_CHILD_MODEL) { $env:AICLI_TEST_OPENAI_CHILD_MODEL } else { 'gpt-5.6-luna' }
                $childEffort = if ($env:AICLI_TEST_OPENAI_CHILD_EFFORT) { $env:AICLI_TEST_OPENAI_CHILD_EFFORT } else { 'high' }
                $null = Write-FakeRpcLine ([ordered]@{
                    jsonrpc = '2.0'
                    id = 'server-openai-child'
                    method = 'item/tool/call'
                    params = @{
                        callId = 'call-openai-child'
                        threadId = $threadId
                        turnId = 'parent-turn'
                        tool = 'openai_child'
                        namespace = $null
                        arguments = @{
                            agent_type = $agentType
                            model = $childModel
                            reasoning_effort = $childEffort
                            task_name = 'provider_route_probe'
                            message = 'Return CHILD_OK.'
                        }
                    }
                })
            }
        }
        'turn/start' {
            if ([string]$request.params.threadId -eq [string]$script:openAiChild.threadId -and $script:openAiChild.threadId) {
                $script:openAiChild.turnId = 'openai-child-turn'
                $script:openAiChild.effort = [string]$request.params.effort
                $null = Write-FakeRpcLine ([ordered]@{
                    jsonrpc = '2.0'
                    id = $request.id
                    result = @{ turn = @{ id = $script:openAiChild.turnId; status = 'inProgress' } }
                })
                $null = Write-FakeRpcLine ([ordered]@{
                    method = 'item/completed'
                    params = @{
                        threadId = $script:openAiChild.threadId
                        turnId = $script:openAiChild.turnId
                        item = @{ id = $script:openAiChild.finalMessageId; type = 'agentMessage'; text = $script:openAiChild.finalText; phase = 'final_answer' }
                    }
                })
                $null = Write-FakeRpcLine ([ordered]@{
                    method = 'turn/completed'
                    params = @{ threadId = $script:openAiChild.threadId; turn = @{ id = $script:openAiChild.turnId; status = 'completed' } }
                })
            }
            else {
                $null = Write-FakeRpcLine ([ordered]@{ jsonrpc='2.0'; id=$request.id; result=@{ turn=@{ id='turn-started'; status='inProgress' } } })
            }
        }
        'thread/read' {
            if ([string]$request.params.threadId -eq [string]$script:openAiChild.threadId -and $script:openAiChild.threadId) {
                $path = if ($script:openAiChild.ephemeral) { $null } else { 'E:\fixture\rollout-protected.jsonl' }
                $null = Write-FakeRpcLine ([ordered]@{
                    jsonrpc = '2.0'
                    id = $request.id
                    result = @{ thread = @{
                        id = $script:openAiChild.threadId
                        sessionId = $script:openAiChild.sessionId
                        modelProvider = 'openai'
                        model = $script:openAiChild.model
                        reasoningEffort = $script:openAiChild.effort
                        cwd = $script:openAiChild.cwd
                        ephemeral = $script:openAiChild.ephemeral
                        path = $path
                        turns = @(@{
                            id = $script:openAiChild.turnId
                            status = 'completed'
                            items = @(@{
                                id = $script:openAiChild.finalMessageId
                                type = 'agentMessage'
                                text = $script:openAiChild.finalText
                                phase = 'final_answer'
                            })
                        })
                    } }
                })
            }
            else {
                $null = Write-FakeRpcLine ([ordered]@{
                    jsonrpc = '2.0'
                    id = 'server-need-client'
                    method = 'server/need_input'
                    params = @{ prompt = 'reply' }
                })
                $replyLine = [Console]::In.ReadLine()
                if ($null -eq $replyLine) { exit 41 }
                $reply = $replyLine | ConvertFrom-Json -AsHashtable
                if ($reply.id -ne 'server-need-client') { exit 42 }
                $script:clientReplyRaw = $replyLine

                $null = Write-FakeRpcLine ([ordered]@{
                    jsonrpc = '2.0'
                    id = $request.id
                    result = @{
                        modelProvider = 'aicli_desktop_local'
                        model = 'local-model'
                        clientReplyRaw = $script:clientReplyRaw
                        thread = @{
                            id = 'thread-1'
                            modelProvider = 'aicli_desktop_local'
                            model = 'local-model'
                        }
                    }
                })
            }
        }
        'thread/resume' {
            if ($request.params.modelProvider -ne 'aicli_desktop_local') {
                $null = Write-FakeRpcLine ([ordered]@{
                    jsonrpc = '2.0'
                    id = $request.id
                    error = @{ code = -32000; message = 'router did not select local provider' }
                })
                continue
            }
            $response = [ordered]@{
                jsonrpc = '2.0'
                id = $request.id
                result = @{
                    modelProvider = 'aicli_desktop_local'
                    model = 'local-model'
                    clientReplyRaw = $script:clientReplyRaw
                    thread = @{
                        id = 'thread-1'
                        modelProvider = 'aicli_desktop_local'
                        model = 'local-model'
                    }
                }
            }
            $null = Write-FakeRpcLine $response
        }
        'test/deepseek-events' {
            $threadId = 'deep-thread'
            $turnId = 'deep-turn'
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/started'; params = @{ threadId = $threadId; turnId = $turnId; item = @{ id = 'reason-a'; type = 'reasoning'; summary = @(); content = @() } } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/reasoning/textDelta'; params = @{ threadId = $threadId; turnId = $turnId; itemId = 'reason-a'; contentIndex = 0; delta = '第一段思考' } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/reasoning/textDelta'; params = @{ threadId = $threadId; turnId = $turnId; itemId = 'reason-a'; contentIndex = 0; delta = '继续思考' } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/completed'; params = @{ threadId = $threadId; turnId = $turnId; item = @{ id = 'reason-a'; type = 'reasoning'; summary = @(); content = @('第一段完整思考') } } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/started'; params = @{ threadId = $threadId; turnId = $turnId; item = @{ id = 'progress-a'; type = 'agentMessage'; text = '' } } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/agentMessage/delta'; params = @{ threadId = $threadId; turnId = $turnId; itemId = 'progress-a'; delta = '进度输出' } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/completed'; params = @{ threadId = $threadId; turnId = $turnId; item = @{ id = 'progress-a'; type = 'agentMessage'; text = '进度输出' } } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/started'; params = @{ threadId = $threadId; turnId = $turnId; item = @{ id = 'reason-b'; type = 'reasoning'; summary = @(); content = @() } } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/reasoning/textDelta'; params = @{ threadId = $threadId; turnId = $turnId; itemId = 'reason-b'; contentIndex = 0; delta = '第二段思考' } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/completed'; params = @{ threadId = $threadId; turnId = $turnId; item = @{ id = 'reason-b'; type = 'reasoning'; summary = @(); content = @('第二段思考') } } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'item/completed'; params = @{ threadId = $threadId; turnId = $turnId; item = @{ id = 'message-final'; type = 'agentMessage'; text = 'FINAL' } } })
            $null = Write-FakeRpcLine ([ordered]@{ method = 'turn/completed'; params = @{ threadId = $threadId; turn = @{ id = $turnId; status = 'completed' } } })
            $null = Write-FakeRpcLine ([ordered]@{ jsonrpc = '2.0'; id = $request.id; result = @{ ok = $true } })
        }
        'client/notice' {
            $null = Write-FakeRpcLine ([ordered]@{
                jsonrpc = '2.0'
                method = 'engine/notice'
                params = @{ text = $request.params.text; receivedRaw = $requestLine }
            })
        }
        'ping' {
            $response = [ordered]@{
                jsonrpc = '2.0'
                id = $request.id
                result = @{ echo = 'pong'; receivedRaw = $requestLine }
            }
            $responseLine = $response | ConvertTo-Json -Depth 100 -Compress
            if ($env:AICLI_TEST_EXPECTED_LINE_FILE) {
                [IO.File]::WriteAllText($env:AICLI_TEST_EXPECTED_LINE_FILE, $responseLine, $utf8NoBom)
            }
            [Console]::Out.WriteLine($responseLine)
            [Console]::Out.Flush()
        }
        default {
            if ($request.Contains('id')) {
                $null = Write-FakeRpcLine ([ordered]@{
                    jsonrpc = '2.0'
                    id = $request.id
                    result = @{}
                })
            }
        }
    }
}

exit 0
