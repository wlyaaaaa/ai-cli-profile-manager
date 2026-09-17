#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Machine-facing profile runs' {
    It 'preserves Chinese text across redirected stdin and stdout' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'utf8-roundtrip.ps1'
            @'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$text = [Console]::In.ReadToEnd()
[Console]::Out.Write($text)
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $expected = "中文输入与输出必须保持 UTF-8`n"
            $result = Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $scriptPath) `
                -WorkingDirectory $Work -StdInText $expected -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -Be $expected
        }
    }

    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module AiCliProfileManager -All | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
    }

    It 'preserves only verified public runtime identity when a local key collides' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $path = Join-Path $Work 'runtime-identity-event.jsonl'
            $stream = [IO.FileStream]::new(
                $path,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::Read
            )
            try {
                $sequence = 0
                $ok = Write-AiCliMachineEvent -Stream $stream `
                    -Sequence ([ref]$sequence) -Kind 'runtime.identity' `
                    -Data @{
                        model = 'qwen3.6-35b:256k'
                        provider_id = 'aicli_ollama_main'
                        cli_version = '0.147.0'
                        unsafe_note = 'ollama'
                    } -SecretValues @('ollama') `
                    -VerifiedPublicRuntimeIdentity
                $ok | Should -BeTrue
            } finally {
                $stream.Dispose()
            }

            $event = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
            $event.provider_id | Should -BeExactly 'aicli_ollama_main'
            $event.unsafe_note | Should -BeExactly '***REDACTED***'
        }
    }

    It 'captures a profile without exposing its launch environment' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine = 'codex'
                    fileName = 'C:\fake\codex.exe'
                    argumentList = @('exec', '--json', '-')
                    workingDirectory = $Work
                    model = 'qwen3.6-35b:256k'
                    modelProvider = 'aicli_ollama_main'
                    environmentDelta = @{ OPENAI_API_KEY = 'CANARY_SECRET' }
                    removeEnvironment = @('ANTHROPIC_API_KEY')
                }
            }
            Mock Invoke-AiCliChildCapture {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = '{"type":"item.completed","item":{"type":"agent_message","text":"CANARY_SECRET done"}}'
                    StdErr = ''
                    TimedOut = $false
                    DurationMs = 123
                    OutputTruncated = $false
                    StepCount = 0
                    ToolCallCount = 0
                    EventsSeen = 2
                    EventProtocol = 'codex-jsonl'
                    LimitHit = $null
                    LimitsHard = $true
                    CleanupConfirmed = $true
                    CleanupMethod = 'none'
                    Usage = [ordered]@{
                        input_tokens = [long]123
                        cached_input_tokens = [long]45
                        output_tokens = [long]67
                    }
                    RuntimeIdentity = [ordered]@{
                        model = 'qwen3.6-35b:256k'
                        model_provider = 'aicli_ollama_main'
                        cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'
                            requested_policy = 'danger-full-access'
                            sandbox_boundary = 'codex-native'
                            sandbox_type = 'dangerFullAccess'
                            permission_profile = ':danger-full-access'
                        }
                    }
                }
            }

            $result = Invoke-AiCliProfileCapture -ProfileId 'local' -ProjectPath $Work `
                -NativeArgs @('exec', '--json', '-') -StdInText 'TASK' -TimeoutMs 9000 -MaxCaptureChars 4096

            $result.exitCode | Should -Be 0
            $result.stdout | Should -Match 'agent_message'
            $result.durationMs | Should -Be 123
            $result.model | Should -Be 'qwen3.6-35b:256k'
            $result.limitEnforcement.timeout | Should -Be 'hard'
            $result.limitEnforcement.maxSteps | Should -Be 'hard'
            $result.limitEnforcement.maxToolCalls | Should -Be 'hard'
            $result.limitUsage.steps | Should -Be 0
            $result.limitUsage.toolCalls | Should -Be 0
            $result.limitUsage.protocol | Should -Be 'codex-jsonl'
            $result.limitUsage.stepDefinition | Should -Be 'distinct-non-output-thread-item-v2'
            $result.limitUsage.cleanupConfirmed | Should -BeTrue
            ($result.usage | ConvertTo-Json -Compress) |
                Should -Be '{"input_tokens":123,"cached_input_tokens":45,"output_tokens":67}'
            $result.eventProjection | Should -Be 'codex-public-v1'
            $result.machineEventProjection | Should -Be 'disabled'
            $result.machineEventStatus | Should -Be 'disabled'
            $result.limitHit | Should -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Not -Contain 'environmentDelta'
            ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'CANARY_SECRET'
            $result.effortEvidence | Should -Be 'launch-plan'
            $result.attestedEffort | Should -BeNullOrEmpty
            Should -Invoke Invoke-AiCliChildCapture -Times 1 -Exactly -ParameterFilter {
                $StdInText -eq 'TASK' -and $TimeoutMs -eq 9000 -and $MaxCaptureChars -eq 4096 -and
                $SandboxWorkspace -eq $Work -and $EventProtocol -eq 'codex-jsonl' -and
                $SecretValues -contains 'CANARY_SECRET'
            }
        }
    }

    It 'counts Codex public events and never returns hidden reasoning text' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-safe-codex-events.ps1'
            @'
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"thread-1"}')
[Console]::Out.WriteLine('{"type":"turn.started","turn_id":"turn-1"}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"reason-1","type":"reasoning","text":"HIDDEN_COT_CANARY"}}')
[Console]::Out.WriteLine('{"type":"item.started","item":{"id":"tool-1","type":"command_execution","command":"PRIVATE_COMMAND"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"tool-1","type":"command_execution","aggregated_output":"PRIVATE_OUTPUT"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"web-1","type":"web_search","query":"PRIVATE_QUERY"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"FINAL_PUBLIC"}}')
[Console]::Error.WriteLine('HIDDEN_STDERR_CANARY')
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.LimitsHard | Should -BeTrue
            $result.StepCount | Should -Be 3
            $result.ToolCallCount | Should -Be 2
            $result.EventsSeen | Should -Be 7
            $result.StdOut | Should -Match 'FINAL_PUBLIC'
            $result.StdOut | Should -Not -Match 'HIDDEN_COT_CANARY'
            $result.StdOut | Should -Not -Match 'PRIVATE_COMMAND'
            $result.StdOut | Should -Not -Match 'PRIVATE_OUTPUT'
            $result.StdErr | Should -Not -Match 'HIDDEN_STDERR_CANARY'
            ($result.Usage | ConvertTo-Json -Compress) | Should -Be '{}'
        }
    }

    It 'does not spend the action-step budget on public agent messages' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-public-progress-with-one-action.ps1'
            @'
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"thread-1"}')
[Console]::Out.WriteLine('{"type":"turn.started","turn_id":"turn-1"}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"progress-1","type":"agent_message","text":"开始处理。"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"progress-2","type":"agent_message","text":"已完成公开检查。"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"reason-1","type":"reasoning","text":"HIDDEN_COT_CANARY"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-final","type":"agent_message","text":"FINAL_PUBLIC"}}')
[Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":3}}')
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MaxSteps 1 -MaxToolCalls 1 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.StepCount | Should -Be 1
            $result.LimitHit | Should -BeNullOrEmpty
            $result.StdOut | Should -Match 'FINAL_PUBLIC'
            $result.StdOut | Should -Not -Match 'HIDDEN_COT_CANARY'
        }
    }

    It 'streams a monotonic safe machine event projection without private event content' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-observer-codex-events.ps1'
            $eventFile = Join-Path $Work 'observer-events.jsonl'
            @'
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"019f98ff-110f-7390-8d7b-d85d70bba89f"}')
[Console]::Out.WriteLine('{"type":"turn.started","turn_id":"turn-private"}')
[Console]::Out.WriteLine('{"type":"item.started","item":{"id":"reason-1","type":"reasoning","text":"HIDDEN_COT_CANARY"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"reason-1","type":"reasoning","text":"HIDDEN_COT_CANARY"}}')
[Console]::Out.WriteLine('{"type":"item.started","item":{"id":"tool-1","type":"command_execution","command":"PRIVATE_COMMAND"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"tool-1","type":"command_execution","aggregated_output":"PRIVATE_OUTPUT"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"FINAL_PUBLIC"}}')
[Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":999}}')
[Console]::Error.WriteLine('HIDDEN_STDERR_CANARY')
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.MachineEventStatus | Should -Be 'ok'
            $result.MachineEventProjection | Should -Be 'aicli.machine-event.v1'
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            $events.Count | Should -BeGreaterThan 5
            $result.MachineEventCount | Should -Be $events.Count
            @($events.sequence) | Should -Be @(1..$events.Count)
            @($events.kind) | Should -Contain 'reasoning.activity'
            @($events.kind) | Should -Contain 'tool.activity'
            @($events.kind) | Should -Contain 'output.completed'
            ($events | ConvertTo-Json -Depth 10) | Should -Match 'FINAL_PUBLIC'
            ($events | ConvertTo-Json -Depth 10) | Should -Not -Match 'HIDDEN_COT_CANARY|PRIVATE_COMMAND|PRIVATE_OUTPUT|HIDDEN_STDERR_CANARY|turn-private'
        }
    }

    It 'recovers from non-terminal error events after a completed turn and exposes only safe usage' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-recoverable-codex-errors.ps1'
            $eventFile = Join-Path $Work 'recoverable-error-events.jsonl'
            @'
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"019f98ff-110f-7390-8d7b-d85d70bba89f"}')
[Console]::Out.WriteLine('{"type":"error","message":"Bearer RECOVERABLE_TOP_LEVEL_CANARY at C:\\private\\TOP_LEVEL_PATH"}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"error-1","type":"error","message":"RECOVERABLE_ITEM_CANARY"}}')
[Console]::Out.WriteLine('{"type":"item.started","item":{"id":"tool-1","type":"command_execution","command":"PRIVATE_COMMAND"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"tool-1","type":"command_execution","aggregated_output":"PRIVATE_OUTPUT"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"FINAL_AFTER_RECOVERY"}}')
[Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":1234,"cached_input_tokens":234,"output_tokens":56,"reasoning_output_tokens":7,"total_tokens":1531,"secret":"USAGE_SECRET_CANARY","nested":{"path":"C:\\private\\USAGE_PATH"}}}')
[Console]::Error.WriteLine('RECOVERABLE_RAW_STDERR_CANARY')
exit 0
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.StdErr | Should -Be ''
            $result.StdOut | Should -Match 'FINAL_AFTER_RECOVERY'
            ($result.Usage | ConvertTo-Json -Compress) |
                Should -Be (
                    '{"input_tokens":1234,"cached_input_tokens":234,"output_tokens":56,' +
                    '"reasoning_output_tokens":7,"total_tokens":1531}'
                )

            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            @($events.kind) | Should -Not -Contain 'run.failed'
            $completed = @($events | Where-Object kind -eq 'turn.completed')[-1]
            ($completed.usage | ConvertTo-Json -Compress) |
                Should -Be (
                    '{"input_tokens":1234,"cached_input_tokens":234,"output_tokens":56,' +
                    '"reasoning_output_tokens":7,"total_tokens":1531}'
                )

            $publicEnvelopeAndEvents = @(
                ($result | ConvertTo-Json -Depth 10 -Compress)
                (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8)
            ) -join "`n"
            $publicEnvelopeAndEvents | Should -Not -Match (
                'RECOVERABLE_TOP_LEVEL_CANARY|TOP_LEVEL_PATH|RECOVERABLE_ITEM_CANARY|' +
                'PRIVATE_COMMAND|PRIVATE_OUTPUT|RECOVERABLE_RAW_STDERR_CANARY|' +
                'USAGE_SECRET_CANARY|USAGE_PATH|nested'
            )
        }
    }

    It 'omits invalid and unknown usage fields without failing an otherwise completed run' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-invalid-codex-usage.ps1'
            @'
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"PUBLIC_DONE"}}')
[Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":-1,"output_tokens":4.5,"total_tokens":15,"other":"PRIVATE_USAGE_CANARY"}}')
exit 0
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MaxSteps 4 -MaxToolCalls 1 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            ($result.Usage | ConvertTo-Json -Compress) |
                Should -Be '{"input_tokens":12,"total_tokens":15}'
            ($result | ConvertTo-Json -Depth 10 -Compress) |
                Should -Not -Match 'cached_input_tokens|output_tokens|PRIVATE_USAGE_CANARY'
        }
    }

    It 'launches every Codex app-server harness with native danger-full-access' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $package = Join-Path $Work 'tool\node_modules\@openai\codex'
            $entry = Join-Path $package 'bin\codex.js'
            $native = Join-Path $package (
                'node_modules\@openai\codex-win32-x64\' +
                'vendor\x86_64-pc-windows-msvc\bin\codex.exe'
            )
            New-Item -ItemType Directory -Path (
                Split-Path -Parent $entry
            ), (
                Split-Path -Parent $native
            ) -Force | Out-Null
            Set-Content -LiteralPath $entry -Value '// stub' -Encoding ascii
            Set-Content -LiteralPath $native -Value 'native stub' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $package 'package.json') `
                -Value '{}' -Encoding ascii

            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine = 'codex'
                    fileName = (Get-Command node.exe).Source
                    argumentList = @($entry, 'exec', '--json', '-')
                    workingDirectory = $Work
                    environmentDelta = @{ AICLI_CODEX_PROVIDER_KEY = 'ollama' }
                    removeEnvironment = @()
                    model = 'qwen3.6-35b:256k'
                    modelProvider = 'aicli_ollama_main'
                    machineRuntime = [ordered]@{
                        kind = 'codex'
                        configFiles = @()
                        sandboxBoundary = 'outer-codex'
                    }
                }
            }
            Mock Invoke-AiCliChildCapture {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = ''
                    StdErr = ''
                    TimedOut = $false
                    DurationMs = 12
                    OutputTruncated = $false
                    StepCount = 0
                    ToolCallCount = 0
                    EventsSeen = 0
                    EventProtocol = 'codex-app-server'
                    LimitHit = $null
                    LimitsHard = $true
                    CleanupConfirmed = $true
                    CleanupMethod = 'none'
                    Usage = [ordered]@{}
                    RuntimeIdentity = [ordered]@{
                        model = 'qwen3.6-35b:256k'
                        model_provider = 'aicli_ollama_main'
                        cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'
                            requested_policy = 'danger-full-access'
                            sandbox_boundary = 'codex-native'
                            sandbox_type = 'dangerFullAccess'
                            permission_profile = ':danger-full-access'
                        }
                    }
                }
            }

            $result = Invoke-AiCliProfileCapture -ProfileId 'local' `
                -ProjectPath $Work -NativeArgs @('exec', '--json', '-') `
                -StdInText 'PRIVATE_TASK_CANARY' -SandboxPolicy danger-full-access

            # The local compatibility key happens to equal a substring of the
            # public Provider ID. Whole-receipt secret redaction must not erase
            # the already verified runtime identity or top-level launch identity.
            $result.runtimeIdentity.model | Should -BeExactly 'qwen3.6-35b:256k'
            $result.runtimeIdentity.model_provider | Should -BeExactly 'aicli_ollama_main'
            $result.modelProvider | Should -BeExactly 'aicli_ollama_main'

            Should -Invoke Invoke-AiCliChildCapture -Times 1 -Exactly `
                -ParameterFilter {
                    [string]::IsNullOrWhiteSpace([string]$SandboxWorkspace) -and
                    $SandboxPolicy -eq 'danger-full-access' -and
                    $EventProtocol -eq 'codex-app-server' -and
                    [string]::IsNullOrWhiteSpace($PrivateTaskPipeName)
                }
        }
    }

    It 'projects app-server context under the outer <Policy> contract without private payloads' -ForEach @(
        @{ Policy = 'read-only' }
        @{ Policy = 'workspace-write' }
    ) {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
            Policy = $Policy
        } {
            $caseSuffix = $Policy.Replace('-', '_')
            $fakeServer = Join-Path $Work "fake-codex-app-server-$caseSuffix.ps1"
            $bridgeConfig = Join-Path $Work "app-server-bridge-$caseSuffix.json"
            $eventFile = Join-Path $Work "app-server-events-$caseSuffix.jsonl"
            @'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/0.145.0 (test)","codexHome":"C:\\fake","platformFamily":"windows","platformOs":"windows"}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.145.0"},"model":"gpt-test","modelProvider":"openai","cwd":"C:\\fake","approvalPolicy":"never","approvalsReviewer":"user","sandbox":{"type":"readOnly","networkAccess":false}}}')
        }
        'turn/start' {
            if ([string]$message.params.input[0].text -ne '中文任务_PRIVATE_PROMPT_CANARY') {
                [Console]::Out.WriteLine('{"id":3,"error":{"code":-32602,"message":"invalid utf8 task"}}')
                [Console]::Out.Flush()
                continue
            }
            $sandbox = $message.params.sandboxPolicy
            if (
                [string]$sandbox.type -ne 'externalSandbox' -or
                [string]$sandbox.networkAccess -ne 'restricted'
            ) {
                [Console]::Out.WriteLine('{"id":3,"error":{"code":-32602,"message":"externalSandbox contract missing"}}')
                [Console]::Out.Flush()
                continue
            }
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","startedAtMs":1,"item":{"id":"reason-1","type":"reasoning","summary":["PRIVATE_REASONING_CANARY"]}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","startedAtMs":2,"item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_COMMAND_CANARY","aggregatedOutput":"PRIVATE_TOOL_OUTPUT_CANARY","status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","startedAtMs":2,"item":{"id":"command-2","type":"commandExecution","command":"PRIVATE_FAILED_COMMAND_CANARY","aggregatedOutput":"PRIVATE_FAILED_OUTPUT_CANARY","status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","startedAtMs":2,"item":{"id":"command-3","type":"commandExecution","command":"PRIVATE_DECLINED_COMMAND_CANARY","aggregatedOutput":"PRIVATE_DECLINED_OUTPUT_CANARY","status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":120,"cachedInputTokens":0,"outputTokens":5,"reasoningOutputTokens":3,"totalTokens":341,"secret":"PRIVATE_USAGE_CANARY"},"total":{"inputTokens":9999,"cachedInputTokens":0,"outputTokens":999,"reasoningOutputTokens":777,"totalTokens":11775},"modelContextWindow":262144}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","completedAtMs":3,"item":{"id":"reason-1","type":"reasoning","summary":["PRIVATE_REASONING_CANARY"]}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","completedAtMs":3,"item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_COMMAND_CANARY","aggregatedOutput":"PRIVATE_TOOL_OUTPUT_CANARY","status":"completed","exitCode":0,"durationMs":617}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","completedAtMs":3,"item":{"id":"command-2","type":"commandExecution","command":"PRIVATE_FAILED_COMMAND_CANARY","aggregatedOutput":"PRIVATE_FAILED_OUTPUT_CANARY","status":"failed","exitCode":9,"durationMs":731}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","completedAtMs":3,"item":{"id":"command-3","type":"commandExecution","command":"PRIVATE_DECLINED_COMMAND_CANARY","aggregatedOutput":"PRIVATE_DECLINED_OUTPUT_CANARY","status":"declined"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","completedAtMs":3,"item":{"id":"subagent-1","type":"subAgentActivity","summary":"PRIVATE_SUBAGENT_CANARY"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","startedAtMs":3,"item":{"id":"compact-1","type":"contextCompaction","history":"PRIVATE_HISTORY_CANARY"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","completedAtMs":4,"item":{"id":"compact-1","type":"contextCompaction","message":"PRIVATE_COMPACTION_CANARY"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","startedAtMs":5,"item":{"id":"message-1","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","completedAtMs":5,"item":{"id":"message-1","type":"agentMessage","text":"FINAL_PUBLIC"}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                taskFile = $null
                sandboxBoundary = 'outer-codex'
                sandboxPolicy = $Policy
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText '中文任务_PRIVATE_PROMPT_CANARY' `
                -PrivateTaskPipeName ('aicli-' + [guid]::NewGuid().ToString('N')) `
                -EventProtocol codex-app-server -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.StepCount | Should -Be 6
            $result.ToolCallCount | Should -Be 4
            ($result.Usage | ConvertTo-Json -Compress) | Should -Be (
                '{"input_tokens":9999,"output_tokens":999,"reasoning_output_tokens":777,' +
                '"total_tokens":11775,' +
                '"current_context_tokens":341,"context_window_tokens":262144}'
            )
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            $context = @($events | Where-Object kind -eq 'context.usage.updated')[-1]
            @($context.PSObject.Properties.Name | Sort-Object) | Should -Be @(
                'context_window_tokens',
                'current_tokens',
                'kind',
                'occurred_utc',
                'schema',
                'sequence'
            )
            $context.current_tokens | Should -Be 341
            $context.context_window_tokens | Should -Be 262144
            $compaction = @($events | Where-Object kind -eq 'context.compaction.completed')[-1]
            @($compaction.PSObject.Properties.Name | Sort-Object) | Should -Be @(
                'compaction_count',
                'kind',
                'occurred_utc',
                'schema',
                'sequence',
                'status'
            )
            $compaction.status | Should -Be 'completed'
            $compaction.compaction_count | Should -Be 1
            $subAgentActivity = @(
                $events |
                    Where-Object {
                        $_.kind -eq 'tool.activity' -and
                        $_.item_type -eq 'sub_agent_activity'
                    }
            )
            $subAgentActivity.Count | Should -Be 1
            $subAgentActivity[0].status | Should -Be 'completed'
            $commandActivity = @(
                $events |
                    Where-Object {
                        $_.kind -eq 'tool.activity' -and
                        $_.item_type -eq 'command_execution'
                    }
            )
            $commandActivity.Count | Should -Be 6
            @($commandActivity.command_status) | Should -Be @(
                'in_progress',
                'in_progress',
                'in_progress',
                'succeeded',
                'failed',
                'declined'
            )
            @($commandActivity[0].PSObject.Properties.Name | Sort-Object) |
                Should -Be @(
                    'command_status',
                    'events_seen',
                    'item_type',
                    'kind',
                    'occurred_utc',
                    'schema',
                    'sequence',
                    'status',
                    'steps',
                    'tool_calls'
                )
            $commandActivity[3].exit_code | Should -Be 0
            $commandActivity[3].duration_ms | Should -Be 617
            $commandActivity[4].exit_code | Should -Be 9
            $commandActivity[4].duration_ms | Should -Be 731
            $commandActivity[5].PSObject.Properties.Name |
                Should -Not -Contain 'exit_code'
            $commandActivity[5].PSObject.Properties.Name |
                Should -Not -Contain 'duration_ms'
            $turnCompleted = @($events | Where-Object kind -eq 'turn.completed')[-1]
            ($turnCompleted.usage | ConvertTo-Json -Compress) |
                Should -Be (
                    '{"input_tokens":9999,"output_tokens":999,' +
                    '"reasoning_output_tokens":777,"total_tokens":11775}'
                )
            $result.Usage.PSObject.Properties.Name |
                Should -Not -Contain 'cached_input_tokens'

            $public = @(
                ($result | ConvertTo-Json -Depth 10 -Compress)
                (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8)
            ) -join "`n"
            $public | Should -Match 'FINAL_PUBLIC'
            $public | Should -Not -Match (
                'PRIVATE_PROMPT_CANARY|PRIVATE_REASONING_CANARY|PRIVATE_COMMAND_CANARY|' +
                'PRIVATE_TOOL_OUTPUT_CANARY|PRIVATE_USAGE_CANARY|PRIVATE_HISTORY_CANARY|' +
                'PRIVATE_COMPACTION_CANARY|PRIVATE_SUBAGENT_CANARY|' +
                'PRIVATE_FAILED_COMMAND_CANARY|PRIVATE_FAILED_OUTPUT_CANARY|' +
                'PRIVATE_DECLINED_COMMAND_CANARY|PRIVATE_DECLINED_OUTPUT_CANARY|99999'
            )
        }
    }

    It 'fails closed on an unknown app-server notification without exposing its payload' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-unknown-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'unknown-app-server-bridge.json'
            $eventFile = Join-Path $Work 'unknown-app-server-events.jsonl'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/0.146.0 (test)","codexHome":"C:\\fake","platformFamily":"windows","platformOs":"windows"}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.146.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"future/privateNotification","params":{"prompt":"PRIVATE_UNKNOWN_NOTIFICATION_CANARY"}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                taskFile = $null
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.notification_unknown'
            $result.StdErr |
                Should -Be 'Codex app-server protocol validation failed (codex_appserver.notification_unknown).'
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            $events[-1].kind | Should -Be 'run.failed'
            $events[-1].error_category | Should -Be 'protocol_or_process_failure'
            $events[-1].error_code | Should -Be 'codex_appserver.notification_unknown'
            ($result | ConvertTo-Json -Depth 10 -Compress) |
                Should -Not -Match 'PRIVATE_UNKNOWN_NOTIFICATION_CANARY|future/privateNotification'
        }
    }

    It 'buffers complete context usage until the turn identity is confirmed' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-early-context-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'early-context-app-server-bridge.json'
            $eventFile = Join-Path $Work 'early-context-app-server-events.jsonl'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/0.145.0 (test)"}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.145.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"totalTokens":0},"total":{"totalTokens":0},"modelContextWindow":null}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":15,"cachedInputTokens":4,"outputTokens":2,"totalTokens":41,"secret":"PRIVATE_EARLY_USAGE_CANARY"},"total":{"totalTokens":99999},"modelContextWindow":258400}}}')
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":10,"totalTokens":40},"total":{"totalTokens":40},"modelContextWindow":null}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":"EARLY_USAGE_PUBLIC"}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.ErrorCode | Should -BeNullOrEmpty
            $result.Usage.current_context_tokens | Should -Be 41
            $result.Usage.context_window_tokens | Should -Be 258400
            $result.Usage.PSObject.Properties.Name | Should -Not -Contain 'input_tokens'
            $result.Usage.PSObject.Properties.Name | Should -Not -Contain 'cached_input_tokens'
            $result.Usage.PSObject.Properties.Name | Should -Not -Contain 'output_tokens'
            $result.Usage.PSObject.Properties.Name | Should -Not -Contain 'reasoning_output_tokens'
            $result.Usage.PSObject.Properties.Name | Should -Not -Contain 'total_tokens'
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            $contextEvents = @(
                $events | Where-Object kind -eq 'context.usage.updated'
            )
            $contextEvents.Count | Should -Be 1
            $contextEvents[0].current_tokens | Should -Be 41
            $contextEvents[0].context_window_tokens | Should -Be 258400
            (($result | ConvertTo-Json -Depth 10 -Compress) + "`n" +
                (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8)) |
                Should -Not -Match 'tokenUsage|modelContextWindow|PRIVATE_EARLY_USAGE_CANARY|99999'
        }
    }

    It 'fails closed before turn start for unsupported app-server <ReportedVersion>' -ForEach @(
        @{ ReportedVersion = '0.144.0' }
        @{ ReportedVersion = '0.145.0-alpha' }
    ) {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
            ReportedVersion = $ReportedVersion
        } {
            $fakeServer = Join-Path $Work 'fake-old-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'old-app-server-bridge.json'
            $serverSource = @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/__VERSION__ (test)","codexHome":"C:\\fake","platformFamily":"windows","platformOs":"windows"}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"__VERSION__"}}}')
        }
        'turn/start' {
            [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'MUST_NOT_START_TURN'), 'bad')
        }
    }
    [Console]::Out.Flush()
}
'@
            $serverSource.Replace('__VERSION__', $ReportedVersion) |
                Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                taskFile = $null
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Not -Be 0
            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.version_unsupported'
            $result.StdErr |
                Should -Be 'Codex app-server protocol validation failed (codex_appserver.version_unsupported).'
            Test-Path -LiteralPath (Join-Path $Work 'MUST_NOT_START_TURN') | Should -BeFalse
            ($result.Usage | ConvertTo-Json -Compress) | Should -Be '{}'
        }
    }

    It 'rejects native workspace-write when the thread receipt has no runtime workspace root' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-readonly-workspace-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'readonly-workspace-app-server-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/0.145.0 (test)","codexHome":"C:\\fake","platformFamily":"windows","platformOs":"windows"}}')
        }
        'initialized' {}
        'thread/start' {
            $response = [ordered]@{
                id = 2
                result = [ordered]@{
                    thread = [ordered]@{
                        id = '019f98ff-110f-7390-8d7b-d85d70bba89f'
                        cliVersion = '0.145.0'
                    }
                    model = 'gpt-test'
                    cwd = [string]$message.params.cwd
                    approvalPolicy = 'never'
                    sandbox = [ordered]@{
                        type = 'workspaceWrite'
                        networkAccess = $false
                    }
                    activePermissionProfile = [ordered]@{
                        id = ':workspace'
                        extends = $null
                    }
                    runtimeWorkspaceRoots = @()
                }
            }
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 20 -Compress))
        }
        'turn/start' {
            [IO.File]::WriteAllText(
                (Join-Path $PSScriptRoot 'MUST_NOT_START_MODEL_TURN'),
                'bad'
            )
            [Console]::Out.WriteLine('{"id":3,"error":{"code":-32602,"message":"turn must not start"}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'workspace-write'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.workspace_write_unavailable'
            $result.StdErr |
                Should -Be 'Codex app-server protocol validation failed (codex_appserver.workspace_write_unavailable).'
            Test-Path -LiteralPath (Join-Path $Work 'MUST_NOT_START_MODEL_TURN') |
                Should -BeFalse
            ($result.Usage | ConvertTo-Json -Compress) | Should -Be '{}'
        }
    }

    It 'rejects native workspace-write when its local command probe fails before model turn start' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-failed-write-probe-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'failed-write-probe-app-server-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/0.145.0 (test)","codexHome":"C:\\fake","platformFamily":"windows","platformOs":"windows"}}')
        }
        'initialized' {}
        'thread/start' {
            $response = [ordered]@{
                id = 2
                result = [ordered]@{
                    thread = [ordered]@{
                        id = '019f98ff-110f-7390-8d7b-d85d70bba89f'
                        cliVersion = '0.145.0'
                    }
                    model = 'gpt-test'
                    cwd = [string]$message.params.cwd
                    approvalPolicy = 'never'
                    sandbox = [ordered]@{
                        type = 'workspaceWrite'
                        writableRoots = @()
                        networkAccess = $false
                    }
                    activePermissionProfile = [ordered]@{
                        id = ':workspace'
                        extends = $null
                    }
                    runtimeWorkspaceRoots = @([string]$message.params.cwd)
                }
            }
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 20 -Compress))
        }
        'command/exec' {
            $response = [ordered]@{
                id = $message.id
                result = [ordered]@{
                    exitCode = 9
                    stdout = ''
                    stderr = 'write blocked'
                }
            }
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 20 -Compress))
        }
        'turn/start' {
            [IO.File]::WriteAllText(
                (Join-Path $PSScriptRoot 'MUST_NOT_START_AFTER_FAILED_PROBE'),
                'bad'
            )
            $response = [ordered]@{
                id = $message.id
                error = [ordered]@{ code = -32602; message = 'turn must not start' }
            }
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress))
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'workspace-write'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.workspace_write_unavailable'
            Test-Path -LiteralPath (Join-Path $Work 'MUST_NOT_START_AFTER_FAILED_PROBE') |
                Should -BeFalse
            ($result.Usage | ConvertTo-Json -Compress) | Should -Be '{}'
        }
    }

    It 'preflights native workspace-write before preserving the model turn sandbox contract' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-working-write-probe-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'working-write-probe-app-server-bridge.json'
            @'
$probeSeen = $false
$expectedCwd = ''
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            if (-not [bool]$message.params.capabilities.experimentalApi) {
                [Console]::Out.WriteLine('{"id":1,"error":{"code":-32602,"message":"experimental workspace profile unavailable"}}')
                [Console]::Out.Flush()
                continue
            }
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/0.145.0 (test)","codexHome":"C:\\fake","platformFamily":"windows","platformOs":"windows"}}')
        }
        'initialized' {}
        'thread/start' {
            if (
                [string]$message.params.permissions -ne ':workspace' -or
                $null -ne $message.params.sandbox -or
                @($message.params.runtimeWorkspaceRoots).Count -ne 1 -or
                [string]$message.params.runtimeWorkspaceRoots[0] -ne
                    [string]$message.params.cwd
            ) {
                [Console]::Out.WriteLine('{"id":2,"error":{"code":-32602,"message":"named workspace root missing"}}')
                [Console]::Out.Flush()
                continue
            }
            $expectedCwd = [string]$message.params.cwd
            $response = [ordered]@{
                id = 2
                result = [ordered]@{
                    thread = [ordered]@{
                        id = '019f98ff-110f-7390-8d7b-d85d70bba89f'
                        cliVersion = '0.145.0'
                    }
                    model = 'gpt-test'
                    cwd = $expectedCwd
                    approvalPolicy = 'never'
                    sandbox = [ordered]@{
                        type = 'workspaceWrite'
                        writableRoots = @()
                        networkAccess = $false
                    }
                    activePermissionProfile = [ordered]@{
                        id = ':workspace'
                        extends = $null
                    }
                    runtimeWorkspaceRoots = @($expectedCwd)
                }
            }
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 20 -Compress))
        }
        'command/exec' {
            $sandbox = $message.params.sandboxPolicy
            $nonce = [string]$message.params.env.AICLI_WRITE_PROBE_NONCE
            $probePath = [string]$message.params.env.AICLI_WRITE_PROBE_PATH
            $valid = (
                [string]$message.params.cwd -eq $expectedCwd -and
                $null -eq $message.params.permissionProfile -and
                [string]$sandbox.type -eq 'workspaceWrite' -and
                @($sandbox.writableRoots).Count -eq 1 -and
                [string]$sandbox.writableRoots[0] -eq $expectedCwd -and
                $sandbox.networkAccess -eq $false -and
                $sandbox.excludeTmpdirEnvVar -eq $false -and
                $sandbox.excludeSlashTmp -eq $false -and
                [long]$message.params.timeoutMs -eq 5000 -and
                [int]$message.params.outputBytesCap -eq 4096 -and
                -not [string]::IsNullOrWhiteSpace($nonce) -and
                $probePath.StartsWith($expectedCwd, [StringComparison]::OrdinalIgnoreCase)
            )
            $probeSeen = $valid
            $response = [ordered]@{
                id = $message.id
                result = [ordered]@{
                    exitCode = $(if ($valid) { 0 } else { 9 })
                    stdout = $(if ($valid) { $nonce } else { '' })
                    stderr = $(if ($valid) { '' } else { 'invalid probe contract' })
                }
            }
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 20 -Compress))
        }
        'turn/start' {
            $sandbox = $message.params.sandboxPolicy
            $validTurn = (
                $probeSeen -and
                [string]$message.params.approvalPolicy -eq 'never' -and
                [string]$message.params.permissions -eq ':workspace' -and
                $null -eq $message.params.sandboxPolicy -and
                @($message.params.runtimeWorkspaceRoots).Count -eq 1 -and
                [string]$message.params.runtimeWorkspaceRoots[0] -eq $expectedCwd
            )
            if (-not $validTurn) {
                $response = [ordered]@{
                    id = $message.id
                    error = [ordered]@{ code = -32602; message = 'invalid turn sandbox' }
                }
                [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress))
                [Console]::Out.Flush()
                continue
            }
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_WORKSPACE_COMMAND_CANARY","status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_WORKSPACE_COMMAND_CANARY","status":"completed","exitCode":0,"durationMs":4}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"total":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"modelContextWindow":262144}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":"WRITE_PROBE_PUBLIC"}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'workspace-write'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.ErrorCode | Should -BeNullOrEmpty
            $result.StdOut | Should -Match 'WRITE_PROBE_PUBLIC'
            ($result | ConvertTo-Json -Depth 10 -Compress) |
                Should -Not -Match 'PRIVATE_WORKSPACE_COMMAND_CANARY|declined'
            Get-ChildItem -LiteralPath $Work -Filter '.aicli-write-probe-*.tmp' |
                Should -BeNullOrEmpty
        }
    }

    It 'accepts a newer app-server only when its runtime protocol remains compatible' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-future-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'future-app-server-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/0.146.0 (test)","codexHome":"C:\\fake","platformFamily":"windows","platformOs":"windows"}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.146.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"total":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"modelContextWindow":262144}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":"FUTURE_COMPATIBLE_PUBLIC"}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.StdOut | Should -Match 'FUTURE_COMPATIBLE_PUBLIC'
            $result.Usage.current_context_tokens | Should -Be 40
            $result.Usage.context_window_tokens | Should -Be 262144
        }
    }

    It 'fails closed when a completed app-server turn has no real context snapshot' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-missing-context-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'missing-context-app-server-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/0.146.0 (test)","codexHome":"C:\\fake","platformFamily":"windows","platformOs":"windows"}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.146.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":"MUST_NOT_SUCCEED"}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Not -Be 0
            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.context_usage_incomplete'
            $result.StdErr |
                Should -Be 'Codex app-server protocol validation failed (codex_appserver.context_usage_incomplete).'
            ($result.Usage | ConvertTo-Json -Compress) | Should -Be '{}'
        }
    }

    It 'fails closed when a completed app-server turn still has an unfinished item' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-unfinished-item-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'unfinished-item-app-server-bridge.json'
            $eventFile = Join-Path $Work 'unfinished-item-events.jsonl'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"Codex Desktop/0.146.0 (test)","codexHome":"C:\\fake","platformFamily":"windows","platformOs":"windows"}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.146.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"total":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"modelContextWindow":262144}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"reason-1","type":"reasoning","summary":["PRIVATE_UNFINISHED_ITEM_CANARY"]}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8

            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Not -Be 0
            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.item_unfinished'
            $result.StdErr |
                Should -Be 'Codex app-server protocol validation failed (codex_appserver.item_unfinished).'
            ($result | ConvertTo-Json -Depth 10 -Compress) |
                Should -Not -Match 'PRIVATE_UNFINISHED_ITEM_CANARY'
            $events = @(
                Get-Content -LiteralPath $eventFile -Encoding utf8 |
                    ConvertFrom-Json
            )
            $failed = @($events | Where-Object kind -eq 'run.failed')[-1]
            $failed.error_code | Should -Be 'codex_appserver.item_unfinished'
            $failed.item_type | Should -Be 'reasoning'
        }
    }

    It 'accepts multiple superseded Codex <CliVersion> public messages before a completed final' -ForEach @(
        @{ CliVersion = '0.145.0' }
        @{ CliVersion = '0.147.0' }
        @{ CliVersion = '99.0.0' }
    ) {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
            CliVersion = $CliVersion
        } {
            $versionTag = $CliVersion.Replace('.', '-')
            $fakeServer = Join-Path $Work "fake-superseded-message-$versionTag-app-server.ps1"
            $bridgeConfig = Join-Path $Work "superseded-message-$versionTag-app-server-bridge.json"
            $eventFile = Join-Path $Work "superseded-message-$versionTag-events.jsonl"
            @'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"__CLI_VERSION__"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":3,"totalTokens":41},"total":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":3,"totalTokens":41},"modelContextWindow":262144}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"reason-public","type":"reasoning","summary":[]}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"reason-public","type":"reasoning","summary":["PRIVATE_ENRICHED_REASONING_CANARY"]}}}')
            [Console]::Out.WriteLine('{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"reason-public","summaryIndex":0,"delta":"正在核对公开配置。"}}')
            [Console]::Out.WriteLine('{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"reason-public","delta":"继续核对公开路径。"}}')
            [Console]::Out.WriteLine('{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"reason-public","summaryIndex":0,"delta":"公开摘要包含 PUBLIC_SECRET_CANARY。"}}')
            $longSummary = [ordered]@{
                method = 'item/reasoning/summaryTextDelta'
                params = [ordered]@{
                    threadId = '019f98ff-110f-7390-8d7b-d85d70bba89f'
                    turnId = '019f98ff-110f-7390-8d7b-d85d70bba890'
                    itemId = 'reason-public'
                    summaryIndex = 0
                    delta = ('长' * 2001)
                }
            }
            [Console]::Out.WriteLine(($longSummary | ConvertTo-Json -Depth 10 -Compress))
            [Console]::Out.WriteLine('{"method":"item/reasoning/textDelta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"reason-public","delta":"PRIVATE_RAW_REASONING_CANARY"}}')
            [Console]::Out.WriteLine('{"method":"item/reasoning/summaryPartAdded","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"reason-public","summaryPart":"PRIVATE_UNKNOWN_SUMMARY_PART_CANARY"}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"reason-public","type":"reasoning","summary":["PUBLIC_SUMMARY_SOURCE_CANARY"]}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-idempotent","type":"commandExecution","command":"PRIVATE_IDEMPOTENT_COMMAND_CANARY","status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-idempotent","type":"commandExecution","command":"PRIVATE_IDEMPOTENT_COMMAND_CANARY","status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-idempotent","type":"commandExecution","command":"PRIVATE_IDEMPOTENT_COMMAND_CANARY","status":"completed","exitCode":0,"durationMs":1}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-progress","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/agentMessage/delta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"message-progress","delta":"正在"}}')
            [Console]::Out.WriteLine('{"method":"item/agentMessage/delta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"message-progress","delta":"检查 acceptance.md"}}')
            [Console]::Out.WriteLine('{"method":"item/agentMessage/delta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"message-progress","delta":"。"}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-progress-2","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/agentMessage/delta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"message-progress-2","delta":"校验已通过。"}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-final","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/agentMessage/delta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"message-final","delta":"文件"}}')
            [Console]::Out.WriteLine('{"method":"item/agentMessage/delta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"message-final","delta":"已更新"}}')
            [Console]::Out.WriteLine('{"method":"item/agentMessage/delta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"message-final","delta":"。"}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-final","type":"agentMessage","text":"FINAL_PUBLIC"}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@.Replace('__CLI_VERSION__', $CliVersion) |
                Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MachineEventFile $eventFile -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000 `
                -SecretValues @('PUBLIC_SECRET_CANARY')

            $result.ExitCode | Should -Be 0
            $result.StepCount | Should -Be 2
            $result.ToolCallCount | Should -Be 1
            $result.StdOut | Should -Match 'FINAL_PUBLIC'
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            $reasoningSummary = @($events | Where-Object kind -eq 'reasoning.summary.delta')
            $reasoningSummary.Count | Should -Be 4
            @($reasoningSummary[0..2].public_text) | Should -Be @(
                '正在核对公开配置。'
                '继续核对公开路径。'
                '公开摘要包含 ***REDACTED***。'
            )
            $reasoningSummary[0].summary_group | Should -Be 1
            $reasoningSummary[0].summary_index | Should -Be 0
            $reasoningSummary[1].summary_group | Should -Be 1
            $reasoningSummary[1].summary_index | Should -Be 0
            $reasoningSummary[2].summary_group | Should -Be 1
            $reasoningSummary[2].summary_index | Should -Be 0
            $reasoningSummary[0].PSObject.Properties.Name | Should -Not -Contain 'public_text_truncated'
            $reasoningSummary[3].public_text.Length | Should -Be 2000
            $reasoningSummary[3].public_text_truncated | Should -BeTrue
            $deltas = @($events | Where-Object kind -eq 'output.delta')
            $deltas.Count | Should -Be 3
            @($deltas.public_text) | Should -Be @(
                '正在检查 acceptance.md。',
                '校验已通过。',
                '文件已更新。'
            )
            @($events | Where-Object kind -eq 'output.completed').Count | Should -Be 1
            @($events | Where-Object kind -eq 'tool.activity').Count | Should -Be 2
            (($result | ConvertTo-Json -Depth 10 -Compress) + "`n" +
                (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8)) |
                Should -Not -Match 'PRIVATE_RAW_REASONING_CANARY|PRIVATE_UNKNOWN_SUMMARY_PART_CANARY|PUBLIC_SUMMARY_SOURCE_CANARY|PRIVATE_IDEMPOTENT_COMMAND_CANARY|PRIVATE_ENRICHED_REASONING_CANARY'
        }
    }

    It 'rejects unsafe agent-message supersession for <CaseName>' -ForEach @(
        @{
            CaseName = 'a missing later final message'
            CliVersion = '0.145.0'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-orphan","type":"agentMessage","text":""}}}'
            )
        }
        @{
            CaseName = 'an orphan message started after the completed final'
            CliVersion = '0.145.0'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-final","type":"agentMessage","text":""}}}',
                '{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-final","type":"agentMessage","text":"FINAL_PUBLIC"}}}',
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-late-orphan","type":"agentMessage","text":""}}}'
            )
        }
    ) {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
            CliVersion = $CliVersion
            NotificationLines = $NotificationLines
        } {
            $fakeServer = Join-Path $Work 'fake-unsafe-supersession-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'unsafe-supersession-app-server-bridge.json'
            $notificationScript = @(
                $NotificationLines | ForEach-Object {
                    "[Console]::Out.WriteLine('" +
                        ([string]$_).Replace("'", "''") +
                        "')"
                }
            ) -join "`n            "
            $serverSource = @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"__CLI_VERSION__"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":3,"totalTokens":41},"total":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":3,"totalTokens":41},"modelContextWindow":262144}}}')
            __NOTIFICATIONS__
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@
            $serverSource.Replace('__CLI_VERSION__', $CliVersion).
                Replace('__NOTIFICATIONS__', $notificationScript) |
                Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.item_unfinished'
        }
    }

    It 'fails closed on cross-thread or invalid item lifecycle notifications' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-cross-thread-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'cross-thread-app-server-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.145.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"WRONG_PRIVATE_THREAD","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"compact-1","type":"contextCompaction","history":"PRIVATE_CROSS_THREAD_CANARY"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Not -Be 0
            ($result | ConvertTo-Json -Depth 10 -Compress) |
                Should -Not -Match 'WRONG_PRIVATE_THREAD|PRIVATE_CROSS_THREAD_CANARY'
        }
    }

    It 'accepts one completion-only sub-agent point event and rejects a duplicate' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-duplicate-subagent-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'duplicate-subagent-app-server-bridge.json'
            $eventFile = Join-Path $Work 'duplicate-subagent-events.jsonl'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.145.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"subagent-1","type":"subAgentActivity"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"subagent-1","type":"subAgentActivity","summary":"PRIVATE_DUPLICATE_SUBAGENT_CANARY"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MachineEventFile $eventFile -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.item_completed_duplicate'
            $result.StdErr |
                Should -Be 'Codex app-server protocol validation failed (codex_appserver.item_completed_duplicate).'
            $result.StepCount | Should -Be 1
            $result.ToolCallCount | Should -Be 1
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            @(
                $events |
                    Where-Object {
                        $_.kind -eq 'tool.activity' -and
                        $_.item_type -eq 'sub_agent_activity'
                    }
            ).Count | Should -Be 1
            (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8) |
                Should -Not -Match 'PRIVATE_DUPLICATE_SUBAGENT_CANARY'
        }
    }

    It 'keeps regular and completion-only item counters independent for a shared id' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-shared-item-id-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'shared-item-id-app-server-bridge.json'
            $eventFile = Join-Path $Work 'shared-item-id-events.jsonl'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.145.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"total":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"modelContextWindow":262144}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"shared-1","type":"reasoning","summary":["PRIVATE_SHARED_REASONING_CANARY"]}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"shared-1","type":"reasoning","summary":["PRIVATE_SHARED_REASONING_CANARY"]}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"shared-1","type":"subAgentActivity","summary":"PRIVATE_SHARED_SUBAGENT_CANARY"}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MachineEventFile $eventFile -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            $result.ErrorCode | Should -BeNullOrEmpty
            $result.StepCount | Should -Be 2
            $result.ToolCallCount | Should -Be 1
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            @(
                $events |
                    Where-Object {
                        $_.kind -eq 'reasoning.activity' -and
                        $_.item_type -eq 'reasoning'
                    }
            ).Count | Should -Be 2
            @(
                $events |
                    Where-Object {
                        $_.kind -eq 'tool.activity' -and
                        $_.item_type -eq 'sub_agent_activity'
                    }
            ).Count | Should -Be 1
            $public = @(
                ($result | ConvertTo-Json -Depth 10 -Compress)
                (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8)
            ) -join "`n"
            $public | Should -Not -Match (
                'PRIVATE_SHARED_REASONING_CANARY|PRIVATE_SHARED_SUBAGENT_CANARY|' +
                'codex_appserver.item_type_changed'
            )
        }
    }

    It 'rejects completion-first command execution with a safe lifecycle code' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-completion-first-command-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'completion-first-command-app-server-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.145.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_COMMAND_CANARY","status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.item_completed_without_start'
            $result.StdErr |
                Should -Be 'Codex app-server protocol validation failed (codex_appserver.item_completed_without_start).'
            ($result | ConvertTo-Json -Depth 10 -Compress) |
                Should -Not -Match 'PRIVATE_COMMAND_CANARY'
        }
    }

    It 'fails closed instead of auto-approving a command approval request' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-command-approval-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'command-approval-app-server-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            if ([string]$message.params.approvalPolicy -ne 'never') {
                [Console]::Out.WriteLine('{"id":2,"error":{"code":-32602,"message":"approval policy drift"}}')
                [Console]::Out.Flush()
                continue
            }
            $response = [ordered]@{
                id = 2
                result = [ordered]@{
                    thread = [ordered]@{
                        id = '019f98ff-110f-7390-8d7b-d85d70bba89f'
                        cliVersion = '0.145.0'
                    }
                    model = 'gpt-test'
                    cwd = [string]$message.params.cwd
                    approvalPolicy = 'never'
                    sandbox = [ordered]@{
                        type = 'workspaceWrite'
                        writableRoots = @()
                        networkAccess = $false
                    }
                    activePermissionProfile = [ordered]@{
                        id = ':workspace'
                        extends = $null
                    }
                    runtimeWorkspaceRoots = @([string]$message.params.cwd)
                }
            }
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 20 -Compress))
        }
        'command/exec' {
            $nonce = [string]$message.params.env.AICLI_WRITE_PROBE_NONCE
            $response = [ordered]@{
                id = $message.id
                result = [ordered]@{
                    exitCode = 0
                    stdout = $nonce
                    stderr = ''
                }
            }
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 20 -Compress))
        }
        'turn/start' {
            if ([string]$message.params.approvalPolicy -ne 'never') {
                [Console]::Out.WriteLine('{"id":3,"error":{"code":-32602,"message":"approval policy drift"}}')
                [Console]::Out.Flush()
                continue
            }
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_APPROVAL_COMMAND_CANARY","status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"id":44,"method":"item/commandExecution/requestApproval","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","itemId":"command-1","startedAtMs":1,"command":"PRIVATE_APPROVAL_COMMAND_CANARY","cwd":"C:\\PRIVATE_APPROVAL_CWD_CANARY"}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'workspace-write'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.server_request_unsupported'
            $result.StdErr |
                Should -Be 'Codex app-server protocol validation failed (codex_appserver.server_request_unsupported).'
            ($result | ConvertTo-Json -Depth 10 -Compress) |
                Should -Not -Match 'PRIVATE_APPROVAL_COMMAND_CANARY|PRIVATE_APPROVAL_CWD_CANARY'
        }
    }

    It 'reports the precise lifecycle code for <CaseName>' -ForEach @(
        @{
            CaseName = 'a missing item identity'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"type":"reasoning","summary":["PRIVATE_IDENTITY_CANARY"]}}}'
            )
            ExpectedCode = 'codex_appserver.item_identity_invalid'
        }
        @{
            CaseName = 'an exact item start replay after completion'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_COMPLETED_REPLAY_CANARY","status":"inProgress"}}}',
                '{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_COMPLETED_REPLAY_CANARY","status":"completed","exitCode":0,"durationMs":1}}}',
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_COMPLETED_REPLAY_CANARY","status":"inProgress"}}}'
            )
            ExpectedCode = 'codex_appserver.item_started_duplicate'
        }
        @{
            CaseName = 'a completion with a changed type'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"item-1","type":"reasoning"}}}',
                '{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"item-1","type":"commandExecution","command":"PRIVATE_TYPE_CHANGE_CANARY"}}}'
            )
            ExpectedCode = 'codex_appserver.item_type_changed'
        }
        @{
            CaseName = 'an agent-message delta scoped to the wrong turn'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":""}}}',
                '{"method":"item/agentMessage/delta","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"WRONG_PRIVATE_TURN","itemId":"message-1","delta":"PRIVATE_WRONG_TURN_DELTA_CANARY"}}'
            )
            ExpectedCode = 'codex_appserver.notification_scope_invalid'
        }
        @{
            CaseName = 'a non-terminal turn completion status'
            NotificationLines = @(
                '{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}'
            )
            ExpectedCode = 'codex_appserver.turn_status_invalid'
        }
        @{
            CaseName = 'a started-first sub-agent point event'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"subagent-1","type":"subAgentActivity","summary":"PRIVATE_SUBAGENT_START_CANARY"}}}'
            )
            ExpectedCode = 'codex_appserver.item_started_unexpected'
        }
        @{
            CaseName = 'an unknown command execution status'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_UNKNOWN_STATUS_CANARY","status":"futureStatus"}}}'
            )
            ExpectedCode = 'codex_appserver.command_status_invalid'
        }
        @{
            CaseName = 'a non-string command execution status'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_STATUS_TYPE_CANARY","status":{"private":"PRIVATE_STATUS_OBJECT_CANARY"}}}}'
            )
            ExpectedCode = 'codex_appserver.command_status_invalid'
        }
        @{
            CaseName = 'a non-integer command exit code'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_EXIT_CODE_CANARY","status":"inProgress","exitCode":"PRIVATE_EXIT_CODE_VALUE_CANARY"}}}'
            )
            ExpectedCode = 'codex_appserver.command_metric_invalid'
        }
        @{
            CaseName = 'a negative command duration'
            NotificationLines = @(
                '{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"command-1","type":"commandExecution","command":"PRIVATE_DURATION_CANARY","status":"inProgress","durationMs":-1}}}'
            )
            ExpectedCode = 'codex_appserver.command_metric_invalid'
        }
    ) {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
            NotificationLines = $NotificationLines
            ExpectedCode = $ExpectedCode
        } {
            $fakeServer = Join-Path $Work 'fake-precise-lifecycle-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'precise-lifecycle-app-server-bridge.json'
            $notificationScript = @(
                $NotificationLines | ForEach-Object {
                    "[Console]::Out.WriteLine('" +
                        ([string]$_).Replace("'", "''") +
                        "')"
                }
            ) -join "`n            "
            $serverSource = @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.145.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            __NOTIFICATIONS__
        }
    }
    [Console]::Out.Flush()
}
'@
            $serverSource.Replace('__NOTIFICATIONS__', $notificationScript) |
                Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be $ExpectedCode
            $result.StdErr |
                Should -Be "Codex app-server protocol validation failed ($ExpectedCode)."
            ($result | ConvertTo-Json -Depth 10 -Compress) |
                Should -Not -Match 'PRIVATE_.*_CANARY'
        }
    }

    It 'rejects duplicate compaction completion and never double-counts it' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-duplicate-compaction-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'duplicate-compaction-app-server-bridge.json'
            $eventFile = Join-Path $Work 'duplicate-compaction-events.jsonl'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.145.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"compact-1","type":"contextCompaction"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"compact-1","type":"contextCompaction"}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"compact-1","type":"contextCompaction","history":"PRIVATE_DUPLICATE_CANARY"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MachineEventFile $eventFile -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Not -Be 0
            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.item_completed_duplicate'
            $result.StdErr |
                Should -Be 'Codex app-server protocol validation failed (codex_appserver.item_completed_duplicate).'
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            @($events | Where-Object kind -eq 'context.compaction.completed').Count |
                Should -Be 1
            (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8) |
                Should -Not -Match 'PRIVATE_DUPLICATE_CANARY'
        }
    }

    It 'confirms owned app-server descendants even when the original root exits first' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-early-exit-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'early-exit-app-server-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' {
            [Console]::Out.WriteLine('{"id":1,"result":{}}')
        }
        'initialized' {}
        'thread/start' {
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.145.0"}}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"total":{"inputTokens":10,"cachedInputTokens":2,"outputTokens":1,"totalTokens":40},"modelContextWindow":262144}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":"PUBLIC_DONE"}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
            [Console]::Out.Flush()
            exit 0
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'read-only'
                model = 'gpt-test'
                minimumCliVersion = '0.145.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 8000

            $result.ExitCode | Should -Be 0
            $result.CleanupConfirmed | Should -BeTrue
            $result.StdOut | Should -Match 'PUBLIC_DONE'
            $result.StdErr | Should -BeNullOrEmpty
        }
    }

    It 'fails closed when non-terminal error events lack later completion evidence' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-unresolved-codex-error.ps1'
            $eventFile = Join-Path $Work 'unresolved-error-events.jsonl'
            @'
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"019f98ff-110f-7390-8d7b-d85d70bba89f"}')
[Console]::Out.WriteLine('{"type":"error","message":"UNRESOLVED_ERROR_CANARY"}')
exit 0
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MachineEventFile $eventFile `
                -MaxSteps 4 -MaxToolCalls 1 -TimeoutMs 5000

            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Be 'Codex reported an upstream failure.'
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            $events[-1].kind | Should -Be 'run.failed'
            $events[-1].error_category | Should -Be 'upstream_error'
            (($result | ConvertTo-Json -Depth 10 -Compress) + "`n" +
                (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8)) |
                Should -Not -Match 'UNRESOLVED_ERROR_CANARY'
        }
    }

    It 'keeps a final nonzero process exit terminal after an otherwise completed turn' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-nonzero-after-completion.ps1'
            $eventFile = Join-Path $Work 'nonzero-after-completion-events.jsonl'
            @'
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"PUBLIC_BEFORE_NONZERO"}}')
[Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}')
exit 9
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MachineEventFile $eventFile `
                -MaxSteps 4 -MaxToolCalls 1 -TimeoutMs 5000

            $result.ExitCode | Should -Be 9
            $result.StdErr | Should -Be 'Codex process failed without a public error event.'
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            $events[-1].kind | Should -Be 'run.failed'
            $events[-1].error_category | Should -Be 'protocol_or_process_failure'
        }
    }

    It 'drops an invalid private thread identifier from every public projection' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-private-thread-id.ps1'
            $eventFile = Join-Path $Work 'private-thread-events.jsonl'
            @'
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"C:\\private\\PRIVATE_THREAD_TOKEN"}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"PUBLIC_DONE"}}')
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MachineEventFile $eventFile `
                -MaxSteps 4 -MaxToolCalls 1 -TimeoutMs 5000

            $public = $result.StdOut + "`n" + (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8)
            $public | Should -Not -Match 'PRIVATE_THREAD_TOKEN|C:\\private'
            $public | Should -Match 'PUBLIC_DONE'
        }
    }

    It 'fails closed on upstream failure events without exposing their private messages' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-private-upstream-errors.ps1'
            $eventFile = Join-Path $Work 'private-upstream-error-events.jsonl'
            @'
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"019f98ff-110f-7390-8d7b-d85d70bba89f"}')
[Console]::Out.WriteLine('{"type":"turn.started","turn_id":"turn-private"}')
[Console]::Out.WriteLine('{"type":"turn.failed","error":{"message":"Bearer UPSTREAM_BEARER_CANARY at C:\\private\\PRIVATE_ERROR_PATH; command PRIVATE_COMMAND_CANARY"}}')
[Console]::Out.WriteLine('{"type":"error","message":"Bearer SECOND_ERROR_CANARY"}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"error-1","type":"error","message":"C:\\private\\THIRD_ERROR_CANARY"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"MUST_NOT_FOLLOW_TERMINAL"}}')
[Console]::Error.WriteLine('RAW_STDERR_CANARY')
exit 0
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Be 'Codex reported an upstream failure.'
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            $terminalEvents = @(
                $events | Where-Object { $_.kind -in @('turn.failed','run.failed','limit.hit') }
            )
            $terminalEvents.Count | Should -Be 1
            $terminalEvents[0].kind | Should -Be 'run.failed'
            $terminalEvents[0].error_category | Should -Be 'upstream_error'
            $events[-1].kind | Should -Be 'run.failed'
            $result.MachineEventCount | Should -Be $events.Count

            $publicEnvelopeAndEvents = @(
                ($result | ConvertTo-Json -Depth 10 -Compress)
                (Get-Content -LiteralPath $eventFile -Raw -Encoding utf8)
            ) -join "`n"
            $publicEnvelopeAndEvents | Should -Not -Match (
                'UPSTREAM_BEARER_CANARY|PRIVATE_ERROR_PATH|PRIVATE_COMMAND_CANARY|' +
                'SECOND_ERROR_CANARY|THIRD_ERROR_CANARY|RAW_STDERR_CANARY|' +
                'MUST_NOT_FOLLOW_TERMINAL'
            )
        }
    }

    It 'treats every path on a drive as inside that drive root' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Work))
            $pathOnDrive = Join-Path $driveRoot 'aicli-drive-root-boundary\events.jsonl'
            $nestedCurrentDirectory = Join-Path $Work 'nested\current'
            New-Item -ItemType Directory -Path $nestedCurrentDirectory -Force | Out-Null
            $originalCurrentDirectory = [Environment]::CurrentDirectory

            try {
                [Environment]::CurrentDirectory = $nestedCurrentDirectory
                Test-AiCliPathWithinRoot -Path $pathOnDrive -Root $driveRoot |
                    Should -BeTrue
            } finally {
                [Environment]::CurrentDirectory = $originalCurrentDirectory
            }
        }
    }

    It 'rejects an unsafe machine event path before starting a child' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            {
                Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                    -ArgumentList @('-NoProfile','-Command','exit 0') `
                    -EventProtocol codex-jsonl `
                    -MachineEventFile 'relative-events.jsonl' -TimeoutMs 1000
            } | Should -Throw '*绝对路径*'
        }
    }

    It 'rejects an event file inside a workspace-write root before starting a child' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $eventFile = Join-Path $Work 'workspace-events.jsonl'
            {
                Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                    -ArgumentList @('-NoProfile','-Command','exit 0') `
                    -EventProtocol codex-jsonl -MachineEventFile $eventFile `
                    -WritableWorkspace $Work -SandboxPolicy workspace-write -TimeoutMs 1000
            } | Should -Throw '*可写 workspace*'
        }
    }

    It 'holds an exclusive writer while the child is running' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $workspace = Join-Path $Work 'exclusive-workspace'
            New-Item -ItemType Directory -Path $workspace | Out-Null
            $scriptPath = Join-Path $workspace 'attempt-event-injection.ps1'
            $eventFile = Join-Path $Work 'exclusive-events.jsonl'
            $marker = Join-Path $workspace 'exclusive-result.txt'
            @'
param([string]$EventFile, [string]$Marker)
try {
    [IO.File]::AppendAllText($EventFile, "FORGED_EVENT`n")
    [IO.File]::WriteAllText($Marker, 'write_succeeded')
} catch {
    [IO.File]::WriteAllText($Marker, 'write_blocked')
}
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"019f98ff-110f-7390-8d7b-d85d70bba89f"}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"PUBLIC_DONE"}}')
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath,$eventFile,$marker) `
                -WorkingDirectory $workspace -WritableWorkspace $workspace `
                -SandboxPolicy workspace-write -EventProtocol codex-jsonl `
                -MachineEventFile $eventFile -MaxSteps 4 -MaxToolCalls 1 -TimeoutMs 5000

            $result.ExitCode | Should -Be 0
            (Get-Content -LiteralPath $marker -Raw) | Should -Be 'write_blocked'
            (Get-Content -LiteralPath $eventFile -Raw) | Should -Not -Match 'FORGED_EVENT'
        }
    }

    It 'ends the machine event stream with an explicit timeout limit event' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-timeout-events.ps1'
            $eventFile = Join-Path $Work 'timeout-events.jsonl'
            @'
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"019f98ff-110f-7390-8d7b-d85d70bba89f"}')
Start-Sleep -Seconds 5
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MachineEventFile $eventFile `
                -MaxSteps 4 -MaxToolCalls 1 -TimeoutMs 250

            $result.TimedOut | Should -BeTrue
            $events = @(Get-Content -LiteralPath $eventFile -Encoding utf8 | ConvertFrom-Json)
            $events[-1].kind | Should -Be 'limit.hit'
            $events[-1].limit | Should -Be 'timeout'
            $events[-1].status | Should -Be 'blocked'
            $result.MachineEventCount | Should -Be $events.Count
        }
    }

    It 'kills the complete Codex process tree when a tool-call hard limit is exceeded' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $marker = Join-Path $Work 'must-not-exist.txt'
            $grandchildPath = Join-Path $Work 'write-late-marker.ps1'
            @'
param([Parameter(Mandatory)][string]$Marker)
Start-Sleep -Milliseconds 1200
[IO.File]::WriteAllText($Marker, 'escaped')
'@ | Set-Content -LiteralPath $grandchildPath -Encoding utf8
            $scriptPath = Join-Path $Work 'emit-over-budget-codex-events.ps1'
            @"
`$psi = [Diagnostics.ProcessStartInfo]::new()
`$psi.FileName = '$((Get-Command pwsh.exe).Source.Replace("'", "''"))'
`$psi.UseShellExecute = `$false
`$psi.CreateNoWindow = `$true
foreach (`$argument in @('-NoProfile','-File','$($grandchildPath.Replace("'", "''"))','$($marker.Replace("'", "''"))')) {
    [void]`$psi.ArgumentList.Add(`$argument)
}
[void][Diagnostics.Process]::Start(`$psi)
[Console]::Out.WriteLine('{"type":"turn.started","turn_id":"turn-1"}')
[Console]::Out.WriteLine('{"type":"item.started","item":{"id":"tool-1","type":"command_execution"}}')
Start-Sleep -Seconds 5
"@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MaxSteps 4 -MaxToolCalls 0 -TimeoutMs 10000

            $result.ExitCode | Should -Be 75
            $result.LimitHit | Should -Be 'maxToolCalls'
            $result.ToolCallCount | Should -Be 1
            $result.LimitsHard | Should -BeTrue
            $result.CleanupConfirmed | Should -BeTrue
            Start-Sleep -Milliseconds 1600
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
    }

    It 'returns counted hard-limit evidence after killing a timed-out Codex process tree' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $marker = Join-Path $Work 'timeout-must-not-exist.txt'
            $scriptPath = Join-Path $Work 'emit-timeout-codex-events.ps1'
            @"
[Console]::Out.WriteLine('{"type":"turn.started","turn_id":"turn-1"}')
[Console]::Out.WriteLine('{"type":"item.started","item":{"id":"tool-1","type":"command_execution"}}')
Start-Sleep -Seconds 20
[IO.File]::WriteAllText('$($marker.Replace("'", "''"))', 'escaped')
"@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MaxSteps 4 -MaxToolCalls 4 -TimeoutMs 5000

            # Allow cold interpreter startup; this still checks an actual killed tree.
            # The next test independently enforces the short absolute wall deadline.
            $result.DurationMs | Should -BeLessThan 10000
            $result.TimedOut | Should -BeTrue
            $result.LimitHit | Should -Be 'timeout'
            $result.LimitsHard | Should -BeTrue
            $result.StepCount | Should -Be 1
            $result.ToolCallCount | Should -Be 1
            $result.CleanupConfirmed | Should -BeTrue
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
    }

    It 'enforces the wall deadline even while Codex continuously emits valid JSONL' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $marker = Join-Path $Work 'continuous-stream-must-not-exist.txt'
            $scriptPath = Join-Path $Work 'emit-continuous-codex-events.ps1'
            @"
for (`$i = 0; `$i -lt 50000; `$i++) {
    [Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"reason-' + `$i + '","type":"reasoning","text":"x"}}')
}
[IO.File]::WriteAllText('$($marker.Replace("'", "''"))', 'escaped')
"@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MaxSteps 100000 -MaxToolCalls 100000 -TimeoutMs 200

            $result.TimedOut | Should -BeTrue
            $result.LimitHit | Should -Be 'timeout'
            $result.LimitsHard | Should -BeTrue
            $result.DurationMs | Should -BeLessThan 3000
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
    }

    It 'fails closed on an unknown Codex item type' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $marker = Join-Path $Work 'unknown-event-must-not-exist.txt'
            $scriptPath = Join-Path $Work 'emit-unknown-codex-item.ps1'
            @"
[Console]::Out.WriteLine('{"type":"item.started","item":{"id":"future-1","type":"future_unclassified_action"}}')
Start-Sleep -Seconds 2
[IO.File]::WriteAllText('$($marker.Replace("'", "''"))', 'escaped')
"@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MaxSteps 8 -MaxToolCalls 8 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.LimitsHard | Should -BeFalse
            $result.CleanupConfirmed | Should -BeTrue
            $result.StdErr | Should -Match 'unknown item type'
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
    }

    It 'counts and fails closed if Codex emits a collab call while multi-agent is disabled' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $scriptPath = Join-Path $Work 'emit-forbidden-collab-item.ps1'
            @'
[Console]::Out.WriteLine('{"type":"item.started","item":{"id":"collab-1","type":"collab_tool_call","prompt":"PRIVATE_SUBAGENT_TASK"}}')
Start-Sleep -Seconds 2
'@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MaxSteps 8 -MaxToolCalls 8 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ToolCallCount | Should -Be 1
            $result.LimitsHard | Should -BeFalse
            $result.StdErr | Should -Match 'collab'
            $result.StdOut | Should -Not -Match 'PRIVATE_SUBAGENT_TASK'
        }
    }

    It 'wraps a child with the Codex workspace sandbox and disables external network' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Resolve-AiCliLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\codex\codex.exe'
                    PrefixArgs = @()
                    Kind = 'npm-node'
                    SandboxHelperPath = (Get-Command pwsh.exe).Source
                }
            }
            $workspace = Join-Path $Work 'workspace'
            $toolRoot = Join-Path $Work 'tool'
            New-Item -ItemType Directory -Path $workspace, $toolRoot -Force | Out-Null
            $agent = Join-Path $toolRoot 'agent.exe'
            Set-Content -LiteralPath $agent -Value 'stub' -Encoding ascii

            $wrapped = ConvertTo-AiCliSandboxedCommand -FileName $agent `
                -ArgumentList @('--flag', 'value with spaces') -Workspace $workspace -Policy 'workspace-write'

            $wrapped.FileName | Should -Be 'C:\codex\codex.exe'
            $wrapped.ArgumentList | Should -Be @(
                'sandbox', '-P', ':workspace', '-C', ([IO.Path]::GetFullPath($workspace)),
                '--sandbox-state-readable-root', ([IO.Path]::GetFullPath($toolRoot)),
                '--sandbox-state-disable-network', '--',
                ([IO.Path]::GetFullPath($agent)), '--flag', 'value with spaces'
            )
            Should -Invoke Resolve-AiCliLaunchExecutable -Times 1 -Exactly `
                -ParameterFilter { $Name -eq 'codex' -and $PreferNpmCodex }
        }
    }

    It 'grants a Codex npm package read-only without exposing the whole npm root' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Resolve-AiCliLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\codex\codex.exe'
                    PrefixArgs = @()
                    Kind = 'npm-node'
                    SandboxHelperPath = (Get-Command pwsh.exe).Source
                }
            }
            $workspace = Join-Path $Work 'workspace'
            $package = Join-Path $Work 'npm\node_modules\@openai\codex'
            $entry = Join-Path $package 'bin\codex.js'
            New-Item -ItemType Directory -Path $workspace, (Split-Path -Parent $entry) -Force | Out-Null
            Set-Content -LiteralPath $entry -Value '// stub' -Encoding ascii

            $wrapped = ConvertTo-AiCliSandboxedCommand -FileName 'C:\Program Files\nodejs\node.exe' `
                -ArgumentList @($entry, 'exec') -Workspace $workspace -Policy 'workspace-write'

            $roots = for ($index = 0; $index -lt $wrapped.ArgumentList.Count; $index++) {
                if ($wrapped.ArgumentList[$index] -eq '--sandbox-state-readable-root') {
                    $wrapped.ArgumentList[$index + 1]
                }
            }
            $roots | Should -Contain ([IO.Path]::GetFullPath($package))
            $roots | Should -Not -Contain ([IO.Path]::GetFullPath((Join-Path $Work 'npm')))
        }
    }

    It 'maps a read-only machine policy to the read-only outer sandbox' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Resolve-AiCliLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\codex\codex.exe'
                    PrefixArgs = @()
                    Kind = 'npm-node'
                    SandboxHelperPath = (Get-Command pwsh.exe).Source
                }
            }

            $wrapped = ConvertTo-AiCliSandboxedCommand -FileName 'C:\tools\agent.exe' `
                -Workspace $Work -Policy 'read-only'

            $wrapped.ArgumentList[2] | Should -Be ':read-only'
        }
    }

    It 'runs read-only agents from a disposable writable runtime with the source workspace read-only' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $source = Join-Path $Work 'source'
            $runtime = Join-Path $Work 'runtime'
            $tmp = Join-Path $runtime 'tmp'
            $tool = Join-Path $Work 'tool\agent.exe'
            New-Item -ItemType Directory -Path $source, $tmp, (Split-Path -Parent $tool) -Force | Out-Null
            Set-Content -LiteralPath $tool -Value 'stub' -Encoding ascii
            Mock Get-Command { [pscustomobject]@{ Source = (Join-Path $PSHOME 'pwsh.exe') } }
            Mock ConvertTo-AiCliSandboxedCommand {
                [pscustomobject]@{
                    FileName = (Get-Command pwsh).Source
                    ArgumentList = @('-NoProfile','-Command','exit 0')
                }
            }

            $result = Invoke-AiCliChildCapture -FileName $tool -ArgumentList @('--flag') `
                -EnvironmentDelta @{ TEMP = $tmp } -WorkingDirectory $source `
                -SandboxWorkspace $source -SandboxPolicy 'read-only' -TimeoutMs 1000

            $result.ExitCode | Should -Be 0
            Should -Invoke ConvertTo-AiCliSandboxedCommand -Times 1 -Exactly -ParameterFilter {
                $Workspace -eq $runtime -and $Policy -eq 'workspace-write' -and $AdditionalReadRoots -contains $source
            }
        }
    }

    It 'creates and removes a private Qwen machine runtime inside the workspace' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $plan = [pscustomobject]@{
                engine = 'qwen-code'
                argumentList = @('-p', '', '--output-format', 'json')
                workingDirectory = $Work
                environmentDelta = @{}
                machineRuntime = [ordered]@{
                    kind = 'qwen-code'
                    endpoint = 'http://127.0.0.1:32100/v1'
                    model = 'qwen3.6-35b:256k'
                }
            }
            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'TASK' `
                -Policy 'workspace-write' -MaxSteps 30 -MaxToolCalls 120
            try {
                Test-Path -LiteralPath (Join-Path $runtime.RuntimePath 'settings.json') | Should -BeTrue
                $runtime.EnvironmentDelta.QWEN_HOME | Should -Be $runtime.RuntimePath
                $runtime.EnvironmentDelta.TEMP | Should -Be (Join-Path $runtime.RuntimePath 'tmp')
                $runtime.StdInText | Should -Be 'TASK'
                $runtime.RuntimePath | Should -BeLike "$([IO.Path]::GetFullPath($Work))*"
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath -Workspace $Work
            }
            Test-Path -LiteralPath $runtime.RuntimePath | Should -BeFalse
        }
    }

    It 'creates and removes an isolated OI home inside the disposable machine runtime' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $plan = [pscustomobject]@{
                engine = 'interpreter'
                fileName = (Get-Command pwsh).Source
                argumentList = @('exec')
                workingDirectory = $Work
                environmentDelta = @{
                    INTERPRETER_HOME = 'C:\parent\interpreter-home'
                    CODEX_HOME = 'C:\parent\codex-home'
                }
            }
            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'TASK' `
                -Policy 'workspace-write' -MaxSteps 30 -MaxToolCalls 120
            $isolatedInterpreterHome = Join-Path $runtime.RuntimePath 'interpreter-home'
            try {
                $runtime.EnvironmentDelta.INTERPRETER_HOME | Should -Be $isolatedInterpreterHome
                $runtime.EnvironmentDelta.CODEX_HOME | Should -Be $isolatedInterpreterHome
                Test-Path -LiteralPath $isolatedInterpreterHome -PathType Container | Should -BeTrue
                $runtime.RuntimePath | Should -BeLike "$([IO.Path]::GetFullPath($Work))*"
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath -Workspace $Work
            }
            Test-Path -LiteralPath $isolatedInterpreterHome | Should -BeFalse
        }
    }

    It 'waits for a child that outlives its parent before removing a known runtime directory' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $runtimePath = Join-Path $Work '.aicli-runtime-delayed-release'
            $lockPath = Join-Path $runtimePath 'held.lock'
            $readyPath = Join-Path $Work 'runtime-lock-ready.txt'
            $childScript = Join-Path $Work 'hold-runtime-lock.ps1'
            $parentScript = Join-Path $Work 'start-runtime-lock-holder.ps1'
            New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
            @'
param([string]$LockPath, [string]$ReadyPath)
$stream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
[IO.File]::WriteAllText($ReadyPath, 'ready')
Start-Sleep -Milliseconds 1500
$stream.Dispose()
'@ | Set-Content -LiteralPath $childScript -Encoding utf8
            @'
param([string]$ChildScript, [string]$LockPath, [string]$ReadyPath)
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = Join-Path $PSHOME 'pwsh.exe'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
foreach ($argument in @('-NoProfile','-File',$ChildScript,'-LockPath',$LockPath,'-ReadyPath',$ReadyPath)) {
    [void]$psi.ArgumentList.Add($argument)
}
[void][Diagnostics.Process]::Start($psi)
'@ | Set-Content -LiteralPath $parentScript -Encoding utf8
            $parent = [Diagnostics.ProcessStartInfo]::new()
            $parent.FileName = Join-Path $PSHOME 'pwsh.exe'
            $parent.UseShellExecute = $false
            $parent.CreateNoWindow = $true
            foreach ($argument in @('-NoProfile','-File',$parentScript,'-ChildScript',$childScript,'-LockPath',$lockPath,'-ReadyPath',$readyPath)) {
                [void]$parent.ArgumentList.Add($argument)
            }
            $parentProcess = [Diagnostics.Process]::Start($parent)
            try {
                $parentProcess.WaitForExit()
                $deadline = [Diagnostics.Stopwatch]::StartNew()
                while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and $deadline.ElapsedMilliseconds -lt 3000) {
                    Start-Sleep -Milliseconds 25
                }
                Test-Path -LiteralPath $readyPath -PathType Leaf | Should -BeTrue

                { Remove-AiCliMachineRuntime -RuntimePath $runtimePath -Workspace $Work `
                    -WaitForReleaseMs 0 } | Should -Throw

                $initialCleanup = Remove-AiCliMachineRuntime -RuntimePath $runtimePath -Workspace $Work `
                    -WaitForReleaseMs 0 -PassThru
                $initialCleanup.Removed | Should -BeFalse
                $initialCleanup.Reason | Should -Be 'runtime-directory-busy'
                $initialCleanup.RuntimeId | Should -Be '.aicli-runtime-delayed-release'
                $initialCleanup.RuntimePath | Should -Be $runtimePath

                $cleanup = Remove-AiCliMachineRuntime -RuntimePath $runtimePath -Workspace $Work `
                    -WaitForReleaseMs 5000 -PassThru

                $cleanup.Removed | Should -BeTrue
                $cleanup.Attempts | Should -BeGreaterThan 1
                Test-Path -LiteralPath $runtimePath | Should -BeFalse
            } finally {
                $parentProcess.Dispose()
                if (Test-Path -LiteralPath $runtimePath) {
                    Start-Sleep -Milliseconds 1000
                    Remove-AiCliMachineRuntime -RuntimePath $runtimePath -Workspace $Work `
                        -WaitForReleaseMs 5000 | Out-Null
                }
            }
        }
    }

    It 'preserves the timeout receipt when runtime cleanup remains unconfirmed' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $runtimePath = Join-Path $Work '.aicli-runtime-cleanup-mismatch'
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine = 'qwen-code'; profileFingerprint = ('a' * 64)
                    workingDirectory = $Work; environmentDelta = @{}; removeEnvironment = @()
                    model = 'qwen3.6-35b:256k'; modelProvider = 'aicli_ollama_main'; wire = 'responses'
                    effort = $null; effectiveEffort = $null
                }
            }
            Mock Initialize-AiCliMachineRuntime {
                [pscustomobject]@{
                    FileName = 'C:\fake\qwen.exe'; TargetFileName = 'C:\fake\qwen.exe'
                    ArgumentList = @('exec'); WorkingDirectory = $Work; EnvironmentDelta = @{}
                    StdInText = 'TASK'; UseOuterSandbox = $false; EventProtocol = 'none'
                    RuntimePath = $runtimePath; AdditionalReadRoots = @(); PrivateTaskPipeName = $null
                    WebSearchEnabled = $false
                }
            }
            Mock Invoke-AiCliChildCapture {
                [pscustomobject]@{
                    ExitCode = (Get-AiCliExitCode Unavailable); StdOut = ''; StdErr = 'timeout'
                    TimedOut = $true; DurationMs = 120000; OutputTruncated = $false
                    StepCount = 0; ToolCallCount = 0; WebSearchCount = 0; EventsSeen = 0
                    EventProtocol = 'none'; LimitHit = 'timeout'; LimitsHard = $false
                    CleanupConfirmed = $true; CleanupMethod = 'dotnet-kill-tree'
                    MachineEventProjection = 'disabled'; MachineEventStatus = 'disabled'
                    MachineEventCount = 0; MachineEventSequenceStart = 0; MachineEventSequenceEnd = 0
                    ThreadId = $null; SessionId = $null; TurnId = $null; AbortRequested = $false
                    Usage = @{}; RuntimeIdentity = $null
                }
            }
            Mock Remove-AiCliMachineRuntime {
                [pscustomobject]@{
                    Removed = $false; Reason = 'runtime-directory-busy'; Attempts = 3; WaitedMs = 10000
                    RuntimeId = '.aicli-runtime-cleanup-mismatch'; RuntimePath = $runtimePath
                }
            }

            $receipt = Invoke-AiCliProfileCapture -ProfileId 'qwen-test' -ProjectPath $Work `
                -StdInText 'TASK' -TimeoutMs 120000 -MaxCaptureChars 4096 `
                -SandboxPolicy 'read-only' -MaxSteps 20 -MaxToolCalls 0

            $receipt.exitCode | Should -Be (Get-AiCliExitCode Unavailable)
            $receipt.timedOut | Should -BeTrue
            $receipt.limitHit | Should -Be 'timeout'
            $receipt.limitEnforcement.timeout | Should -Be 'failed-closed'
            $receipt.limitUsage.cleanupConfirmed | Should -BeFalse
            $receipt.limitUsage.cleanupMethod | Should -Be 'dotnet-kill-tree+runtime-directory-busy'
            $receipt.runtimeCleanup.Removed | Should -BeFalse
            $receipt.runtimeCleanup.Reason | Should -Be 'runtime-directory-busy'
            $receipt.runtimeCleanup.RuntimeId | Should -Be '.aicli-runtime-cleanup-mismatch'
            $receipt.runtimeCleanup.RuntimePath | Should -Be $runtimePath
            Should -Invoke Remove-AiCliMachineRuntime -Times 1 -Exactly -ParameterFilter {
                $RuntimePath -eq $runtimePath -and $Workspace -eq $Work -and
                $WaitForReleaseMs -eq 10000 -and $PassThru
            }
        }
    }

    It 'turns OpenCode stdin into a private attachment instead of argv text' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $plan = [pscustomobject]@{
                engine = 'opencode'
                argumentList = @('run', '--pure', '--format', 'json')
                workingDirectory = $Work
                environmentDelta = @{}
                machineRuntime = [ordered]@{
                    kind = 'opencode'
                    endpoint = 'http://127.0.0.1:32100/v1'
                    model = 'qwen3.6-35b:256k'
                    modelMetadata = [ordered]@{
                        contextWindowTokens = 262144
                        inputWindowTokens = 262144
                        outputWindowTokens = 8192
                        compactionReserveTokens = 20000
                        preserveRecentTokens = 16384
                        tailTurns = 4
                    }
                }
            }
            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'PRIVATE_TASK_CANARY' `
                -Policy 'workspace-write' -MaxSteps 30 -MaxToolCalls 120
            try {
                ($runtime.ArgumentList -join ' ') | Should -Not -Match 'PRIVATE_TASK_CANARY'
                $runtime.StdInText | Should -Be ''
                $openCodeConfig = $runtime.EnvironmentDelta.OPENCODE_CONFIG_CONTENT | ConvertFrom-Json -Depth 30
                $openCodeConfig.model | Should -Be 'aicli_ollama/qwen3.6-35b:256k'
                $openCodeConfig.small_model | Should -Be 'aicli_ollama/qwen3.6-35b:256k'
                @($openCodeConfig.enabled_providers) | Should -Be @('aicli_ollama')
                $openCodeConfig.share | Should -Be 'disabled'
                $openCodeConfig.provider.aicli_ollama.models.'qwen3.6-35b:256k'.limit.context | Should -Be 262144
                $openCodeConfig.provider.aicli_ollama.models.'qwen3.6-35b:256k'.limit.input | Should -Be 262144
                $openCodeConfig.provider.aicli_ollama.models.'qwen3.6-35b:256k'.limit.output | Should -Be 8192
                $openCodeConfig.compaction.auto | Should -BeTrue
                $openCodeConfig.compaction.prune | Should -BeFalse
                $openCodeConfig.compaction.reserved | Should -Be 20000
                $openCodeConfig.compaction.tail_turns | Should -Be 4
                $openCodeConfig.compaction.preserve_recent_tokens | Should -Be 16384
                $openCodeConfig.agent.compaction.model | Should -Be 'aicli_ollama/qwen3.6-35b:256k'
                $openCodeConfig.agent.build.steps | Should -Be 30
                ($runtime.EnvironmentDelta.OPENCODE_CONFIG_CONTENT) | Should -Not -Match 'dashscope|deepseek|api\.openai'
                Get-Content -Raw -LiteralPath (Join-Path $runtime.RuntimePath 'task.md') | Should -Be 'PRIVATE_TASK_CANARY'
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath -Workspace $Work
            }
        }
    }

    It 'isolates Codex package and profile files inside its machine runtime' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $package = Join-Path $Work 'tool\node_modules\@openai\codex'
            $entry = Join-Path $package 'bin\codex.js'
            $native = Join-Path $package 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
            $config = Join-Path $Work 'aicli-local.config.toml'
            New-Item -ItemType Directory -Path (Split-Path -Parent $entry), (Split-Path -Parent $native) -Force | Out-Null
            Set-Content -LiteralPath $entry -Value '// stub' -Encoding ascii
            Set-Content -LiteralPath $native -Value 'native stub' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $package 'package.json') -Value '{}' -Encoding ascii
            Set-Content -LiteralPath $config -Value 'model = "qwen3.6-35b:256k"' -Encoding ascii
            $plan = [pscustomobject]@{
                engine = 'codex'
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @(
                    $entry,
                    '--profile',
                    'aicli-local',
                    '-c',
                    'model="qwen3.6-35b:256k"',
                    'exec',
                    '--json',
                    '-'
                )
                workingDirectory = $Work
                environmentDelta = @{}
                machineRuntime = [ordered]@{ kind='codex'; configFiles=@($config) }
            }

            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'PRIVATE_TASK_CANARY' -Policy 'workspace-write'
            try {
                ($runtime.ArgumentList -join ' ') | Should -Not -Match 'PRIVATE_TASK_CANARY'
                $runtime.UseOuterSandbox | Should -BeTrue
                $runtime.FileName | Should -Be (Get-Command pwsh.exe).Source
                $runtime.EventProtocol | Should -Be 'codex-app-server'
                $bridgeConfig = Get-Content -LiteralPath $runtime.ArgumentList[-1] -Raw |
                    ConvertFrom-Json
                $bridgeConfig.PSObject.Properties.Name | Should -Not -Contain 'taskFile'
                $bridgeConfig.sandboxBoundary | Should -Be 'outer-codex'
                $bridgeConfig.sandboxPolicy | Should -Be 'workspace-write'
                ($bridgeConfig.argumentList -join ' ') | Should -Match '--disable multi_agent'
                ($bridgeConfig.argumentList -join ' ') | Should -Match '--disable multi_agent_v2'
                ($bridgeConfig.argumentList -join ' ') | Should -Match 'app-server --stdio'
                $bridgeConfig.argumentList | Should -Not -Contain '--profile'
                $bridgeConfig.argumentList | Should -Not -Contain 'aicli-local'
                $bridgeConfig.argumentList | Should -Contain '-c'
                $bridgeConfig.argumentList | Should -Contain 'model="qwen3.6-35b:256k"'
                $bridgeConfig.fileName | Should -Be ([IO.Path]::GetFullPath($native))
                $runtime.StdInText | Should -Be 'PRIVATE_TASK_CANARY'
                $runtime.PrivateTaskPipeName | Should -Match '^aicli-[a-f0-9]{32}$'
                Test-Path -LiteralPath (Join-Path $runtime.RuntimePath 'task.md') | Should -BeFalse
                $persistedText = @(
                    Get-ChildItem -LiteralPath $runtime.RuntimePath -Recurse -File |
                        ForEach-Object {
                            try { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop }
                            catch { '' }
                        }
                ) -join "`n"
                $persistedText | Should -Not -Match 'PRIVATE_TASK_CANARY'
                $bridgeConfig.argumentList | Should -Not -Contain ([IO.Path]::GetFullPath($entry))
                Test-Path -LiteralPath (Join-Path $runtime.RuntimePath 'codex-package') | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $runtime.EnvironmentDelta.CODEX_HOME 'aicli-local.config.toml') | Should -BeTrue
                $runtime.EnvironmentDelta.CODEX_MANAGED_PACKAGE_ROOT |
                    Should -Be ([IO.Path]::GetFullPath($package))
                $runtime.EnvironmentDelta.CODEX_MANAGED_BY_NPM | Should -Be '1'
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath -Workspace $Work
            }
        }
    }

    It 'rejects an unknown Codex machine sandbox boundary before launch' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $package = Join-Path $Work 'tool\node_modules\@openai\codex'
            $entry = Join-Path $package 'bin\codex.js'
            $native = Join-Path $package (
                'node_modules\@openai\codex-win32-x64\' +
                'vendor\x86_64-pc-windows-msvc\bin\codex.exe'
            )
            New-Item -ItemType Directory -Path (
                Split-Path -Parent $entry
            ), (
                Split-Path -Parent $native
            ) -Force | Out-Null
            Set-Content -LiteralPath $entry -Value '// stub' -Encoding ascii
            Set-Content -LiteralPath $native -Value 'native stub' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $package 'package.json') `
                -Value '{}' -Encoding ascii
            $plan = [pscustomobject]@{
                engine = 'codex'
                fileName = (Get-Command node.exe).Source
                argumentList = @($entry, 'exec', '--json', '-')
                workingDirectory = $Work
                environmentDelta = @{}
                machineRuntime = [ordered]@{
                    kind = 'codex'
                    configFiles = @()
                    sandboxBoundary = 'future-unknown-boundary'
                }
            }

            {
                Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'TASK' `
                    -Policy workspace-write
            } | Should -Throw '*Unsupported Codex machine sandbox boundary*'
            @(
                Get-ChildItem -LiteralPath $Work -Directory `
                    -Filter '.aicli-runtime-*' -Force
            ).Count | Should -Be 0
        }
    }

    It 'rejects any lower permission on the universal Codex harness route' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine = 'codex'; workingDirectory = $Work
                    machineRuntime = [ordered]@{ kind = 'codex' }
                }
            }
            Mock Initialize-AiCliMachineRuntime { throw 'must not initialize' }
            {
                Invoke-AiCliProfileCapture -ProfileId 'future-codex-model' `
                    -ProjectPath $Work -StdInText 'TASK' -SandboxPolicy workspace-write
            } | Should -Throw '*danger-full-access*'
            Should -Invoke Initialize-AiCliMachineRuntime -Times 0 -Exactly -Scope It
        }
    }

    It 'injects canonical machine arguments when a Codex harness caller supplies none' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine = 'codex'; fileName = 'C:\fake\codex.exe'
                    argumentList = @('--profile', 'aicli-future')
                    workingDirectory = $Work; environmentDelta = @{}; removeEnvironment = @()
                    model = 'future-model'; modelProvider = 'future_provider'
                }
            }
            Mock Initialize-AiCliMachineRuntime {
                @($Plan.argumentList) | Should -Be @('--profile', 'aicli-future', 'exec', '--json', '-')
                [pscustomobject]@{
                    FileName = 'C:\fake\codex.exe'; ArgumentList = @('bridge')
                    WorkingDirectory = $Work; EnvironmentDelta = @{}; StdInText = 'TASK'
                    UseOuterSandbox = $false; EventProtocol = 'codex-app-server'
                    RuntimePath = $Work; AdditionalReadRoots = @(); PrivateTaskPipeName = $null
                }
            }
            Mock Remove-AiCliMachineRuntime {}
            Mock Invoke-AiCliChildCapture {
                [pscustomobject]@{
                    ExitCode = 0; StdOut = ''; StdErr = ''; TimedOut = $false
                    DurationMs = 1; OutputTruncated = $false; LimitsHard = $true
                    CleanupConfirmed = $true; Usage = @{}
                    RuntimeIdentity = [ordered]@{
                        model = 'future-model'; model_provider = 'future_provider'; cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'; requested_policy = 'danger-full-access'
                            sandbox_boundary = 'codex-native'; sandbox_type = 'dangerFullAccess'
                            permission_profile = ':danger-full-access'
                        }
                    }
                }
            }

            { Invoke-AiCliProfileCapture -ProfileId 'future' -ProjectPath $Work -StdInText 'TASK' } |
                Should -Not -Throw
        }
    }

    It 'rejects a lower permission runtime identity even when model identity matches' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine = 'codex'; fileName = 'C:\fake\codex.exe'
                    argumentList = @('exec', '--json', '-')
                    workingDirectory = $Work; environmentDelta = @{}; removeEnvironment = @()
                    model = 'future-model'; modelProvider = 'future_provider'
                }
            }
            Mock Invoke-AiCliChildCapture {
                [pscustomobject]@{
                    ExitCode = 0; StdOut = ''; StdErr = ''; TimedOut = $false
                    DurationMs = 1; OutputTruncated = $false; LimitsHard = $true
                    CleanupConfirmed = $true; Usage = @{}
                    RuntimeIdentity = [ordered]@{
                        model = 'future-model'; model_provider = 'future_provider'; cli_version = '0.147.0'
                        permission = [ordered]@{
                            approval_policy = 'never'; requested_policy = 'read-only'
                            sandbox_boundary = 'codex-native'; sandbox_type = 'readOnly'
                            permission_profile = ':read-only'
                        }
                    }
                }
            }

            { Invoke-AiCliProfileCapture -ProfileId 'future' -ProjectPath $Work `
                    -NativeArgs @('exec', '--json', '-') -StdInText 'TASK' } |
                Should -Throw '*verified danger-full-access*'
        }
    }

    It 'copies only the official Codex auth file into the disposable machine home' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $package = Join-Path $Work 'tool\node_modules\@openai\codex'
            $entry = Join-Path $package 'bin\codex.js'
            $native = Join-Path $package 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
            $realHome = Join-Path $Work 'real-codex-home'
            $auth = Join-Path $realHome 'auth.json'
            New-Item -ItemType Directory -Path (Split-Path -Parent $entry), (Split-Path -Parent $native), $realHome -Force | Out-Null
            Set-Content -LiteralPath $entry -Value '// stub' -Encoding ascii
            Set-Content -LiteralPath $native -Value 'native stub' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $package 'package.json') -Value '{}' -Encoding ascii
            Set-Content -LiteralPath $auth -Value '{"auth":"test-only"}' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $realHome 'config.toml') -Value 'must_not_copy = true' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $realHome 'AGENTS.md') -Value 'must not copy' -Encoding utf8
            New-Item -ItemType Directory -Path (Join-Path $realHome 'sessions') -Force | Out-Null

            $plan = [pscustomobject]@{
                engine = 'codex'
                fileName = (Get-Command node.exe).Source
                argumentList = @($entry, 'exec', '--json', '-')
                workingDirectory = $Work
                environmentDelta = @{}
                machineRuntime = [ordered]@{
                    kind = 'codex'
                    configFiles = @()
                    authSourceFile = $auth
                }
            }

            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'TASK' -Policy 'workspace-write'
            try {
                $machineHome = $runtime.EnvironmentDelta.CODEX_HOME
                Test-Path -LiteralPath (Join-Path $machineHome 'auth.json') | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $machineHome 'config.toml') | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $machineHome 'AGENTS.md') | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $machineHome 'sessions') | Should -BeFalse
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath -Workspace $Work
            }
        }
    }

    It 'uses native danger-full-access for every Codex harness model' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $package = Join-Path $Work 'tool\node_modules\@openai\codex'
            $entry = Join-Path $package 'bin\codex.js'
            $native = Join-Path $package 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
            New-Item -ItemType Directory -Path (Split-Path -Parent $entry), (Split-Path -Parent $native) -Force | Out-Null
            Set-Content -LiteralPath $entry -Value '// stub' -Encoding ascii
            Set-Content -LiteralPath $native -Value 'native stub' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $package 'package.json') -Value '{}' -Encoding ascii
            $plan = [pscustomobject]@{
                engine = 'codex'
                fileName = (Get-Command node.exe).Source
                argumentList = @(
                    $entry, 'exec', '--json', '--ephemeral',
                    '--dangerously-bypass-approvals-and-sandbox', '-'
                )
                workingDirectory = $Work
                environmentDelta = @{}
                model = 'future-model'
                modelProvider = 'future_provider'
                machineRuntime = [ordered]@{
                    kind = 'codex'
                    configFiles = @()
                    sandboxBoundary = 'codex-native'
                }
            }

            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'TASK' -Policy 'danger-full-access'
            try {
                $runtime.UseOuterSandbox | Should -BeFalse
                $runtime.StdInText | Should -Be 'TASK'
                $runtime.PrivateTaskPipeName | Should -BeNullOrEmpty
                $runtime.EventProtocol | Should -Be 'codex-app-server'
                $bridgeConfig = Get-Content -LiteralPath $runtime.ArgumentList[-1] -Raw |
                    ConvertFrom-Json
                $bridgeConfig.PSObject.Properties.Name | Should -Not -Contain 'taskFile'
                $bridgeConfig.sandboxBoundary | Should -Be 'codex-native'
                $bridgeConfig.sandboxPolicy | Should -Be 'danger-full-access'
                $bridgeConfig.requireRuntimeIdentity | Should -BeTrue
                $bridgeConfig.expectedModel | Should -BeExactly 'future-model'
                $bridgeConfig.expectedModelProvider | Should -BeExactly 'future_provider'
                $bridgeConfig.minimumCliVersion | Should -Be '0.147.0'
                $bridgeArgs = @($bridgeConfig.argumentList)
                $bridgeArgs | Should -Not -Contain '--dangerously-bypass-approvals-and-sandbox'
                ($bridgeArgs -join ' ') | Should -Match '--disable multi_agent'
                ($bridgeArgs -join ' ') | Should -Match '--disable multi_agent_v2'
                ($bridgeArgs -join ' ') | Should -Match 'app-server --stdio'
                Test-Path -LiteralPath (Join-Path $runtime.RuntimePath 'task.md') | Should -BeFalse
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath -Workspace $Work
            }
        }
    }

    It 'requires the named danger-full-access profile receipt before starting a model turn' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $fakeServer = Join-Path $Work 'fake-missing-danger-profile-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'missing-danger-profile-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' { [Console]::Out.WriteLine('{"id":1,"result":{}}') }
        'initialized' {}
        'thread/start' {
            if ([string]$message.params.permissions -ne ':danger-full-access' -or
                $null -ne $message.params.sandbox) {
                [Console]::Out.WriteLine('{"id":2,"error":{"code":-32602,"message":"named danger profile not requested"}}')
                [Console]::Out.Flush()
                continue
            }
            $response = [ordered]@{
                id = 2
                result = [ordered]@{
                    thread = [ordered]@{
                        id = '019f98ff-110f-7390-8d7b-d85d70bba89f'
                        cliVersion = '0.147.0'
                    }
                    model = 'future-model'
                    modelProvider = 'future_provider'
                    approvalPolicy = 'never'
                    sandbox = [ordered]@{ type = 'dangerFullAccess' }
                }
            }
            [Console]::Out.WriteLine(($response | ConvertTo-Json -Depth 20 -Compress))
        }
        'turn/start' {
            [IO.File]::WriteAllText(
                (Join-Path $PSScriptRoot 'MUST_NOT_START_MISSING_PERMISSION_PROFILE'),
                'bad'
            )
            [Console]::Out.WriteLine('{"id":3,"error":{"code":-32602,"message":"turn must not start"}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'danger-full-access'
                model = 'future-model'
                expectedModel = 'future-model'
                expectedModelProvider = 'future_provider'
                requireRuntimeIdentity = $true
                minimumCliVersion = '0.147.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'TASK' -EventProtocol codex-app-server `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000

            $result.ExitCode | Should -Be 74
            $result.ErrorCode | Should -Be 'codex_appserver.runtime_identity_mismatch'
            Test-Path -LiteralPath (Join-Path $Work 'MUST_NOT_START_MISSING_PERMISSION_PROFILE') |
                Should -BeFalse
        }
    }

    It 'serves managed public search through dynamicTools and projects only safe lifecycle evidence' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $root
        } {
            $supportRoot = Join-Path $Work 'search-bridge-support'
            New-Item -ItemType Directory -Force -Path $supportRoot | Out-Null
            Copy-Item -LiteralPath (
                Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            ) -Destination (Join-Path $supportRoot 'CodexAppServerBridge.ps1')
            Copy-Item -LiteralPath (Join-Path $RepoRoot 'src\AiCliProfileManager\Support\CodexProcessJob.cs') -Destination (Join-Path $supportRoot 'CodexProcessJob.cs')
            @'
function Get-BridgePublicWebSearchToolSpec {
    [pscustomobject][ordered]@{
        type='function'; name='public_web_search'; description='test'
        inputSchema=[pscustomobject][ordered]@{
            type='object'; additionalProperties=$false; required=@('query')
            properties=[pscustomobject][ordered]@{ query=[pscustomobject]@{ type='string' } }
        }
    }
}
function Invoke-BridgePublicWebSearch {
    param($Arguments)
    if ([string]$Arguments.query -ne 'PRIVATE_QUERY_CANARY') { throw 'bad query' }
    [pscustomobject][ordered]@{
        success=$true
        contentItems=@([pscustomobject][ordered]@{
            type='inputText'; text='{"provider":"bing-rss-v1","resultCount":1}'
        })
    }
}
'@ | Set-Content -LiteralPath (Join-Path $supportRoot 'PublicWebSearch.ps1') -Encoding utf8
            $fakeServer = Join-Path $Work 'fake-dynamic-search-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'dynamic-search-bridge.json'
            $eventFile = Join-Path $Work 'dynamic-search-events.jsonl'
            @'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' { [Console]::Out.WriteLine('{"id":1,"result":{}}') }
        'initialized' {}
        'thread/start' {
            $tool = @($message.params.dynamicTools)[0]
            if (@($message.params.dynamicTools).Count -ne 1 -or
                [string]$tool.type -ne 'function' -or
                [string]$tool.name -ne 'public_web_search') {
                [Console]::Out.WriteLine('{"id":2,"error":{"code":-32602,"message":"dynamic tool missing"}}')
                continue
            }
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.147.0"},"model":"qwen3.6-35b:256k","modelProvider":"aicli_ollama_main","approvalPolicy":"never","sandbox":{"type":"dangerFullAccess"},"activePermissionProfile":{"id":":danger-full-access"}}}')
        }
        'turn/start' {
            if ($null -ne $message.params.dynamicTools) {
                [Console]::Out.WriteLine('{"id":3,"error":{"code":-32602,"message":"dynamicTools must be thread-scoped"}}')
                continue
            }
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"search-1","type":"dynamicToolCall","tool":"public_web_search","arguments":{"query":"PRIVATE_QUERY_CANARY"},"status":"inProgress","success":null}}}')
            [Console]::Out.WriteLine('{"id":91,"method":"item/tool/call","params":{"arguments":{"query":"PRIVATE_QUERY_CANARY"},"callId":"search-call-1","threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","tool":"public_web_search","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890"}}')
            [Console]::Out.Flush()
            $toolResponse = [Console]::In.ReadLine() | ConvertFrom-Json
            if ($toolResponse.id -ne 91 -or -not $toolResponse.result.success) { exit 92 }
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"search-1","type":"dynamicToolCall","tool":"public_web_search","arguments":{"query":"PRIVATE_QUERY_CANARY"},"contentItems":[{"type":"inputText","text":"PRIVATE_RESULT_CANARY"}],"status":"completed","success":true}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":"SEARCH_OK"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":1,"cachedInputTokens":0,"outputTokens":1,"reasoningOutputTokens":0,"totalTokens":2},"total":{"inputTokens":1,"cachedInputTokens":0,"outputTokens":1,"reasoningOutputTokens":0,"totalTokens":2},"modelContextWindow":262144}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
'@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'codex-native'
                sandboxPolicy = 'danger-full-access'
                expectedModel = 'qwen3.6-35b:256k'
                expectedModelProvider = 'aicli_ollama_main'
                requireRuntimeIdentity = $true
                minimumCliVersion = '0.147.0'
                webSearchEnabled = $true
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )

            $captured = Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @(
                    '-NoProfile', '-File',
                    (Join-Path $supportRoot 'CodexAppServerBridge.ps1'),
                    '-ConfigPath', $bridgeConfig
                ) `
                -WorkingDirectory $Work -StdInText 'SEARCH TASK' `
                -EventProtocol codex-app-server -MachineEventFile $eventFile `
                -MaxSteps 8 -MaxToolCalls 4 -TimeoutMs 5000 `
                -RequireRuntimeIdentity `
                -ExpectedRuntimeModel 'qwen3.6-35b:256k' `
                -ExpectedRuntimeModelProvider 'aicli_ollama_main'

            $captured.ExitCode | Should -Be 0
            $captured.ToolCallCount | Should -Be 1
            $captured.WebSearchCount | Should -Be 1
            $captured.StdOut | Should -Match 'SEARCH_OK'
            ($captured | ConvertTo-Json -Depth 20 -Compress) |
                Should -Not -Match 'PRIVATE_QUERY_CANARY|PRIVATE_RESULT_CANARY'
            $events = @(Get-Content -LiteralPath $eventFile | ConvertFrom-Json)
            $searchEvents = @($events | Where-Object {
                $_.kind -eq 'tool.activity' -and $_.item_type -eq 'web_search'
            })
            $searchEvents.Count | Should -Be 2
            @($searchEvents.status) | Should -Be @('started', 'completed')
            @($searchEvents.tool_name | Select-Object -Unique) |
                Should -Be @('public_web_search')
            @($searchEvents.search_provider | Select-Object -Unique) |
                Should -Be @('bing-rss-v1')
            ($events | ConvertTo-Json -Depth 20 -Compress) |
                Should -Not -Match 'PRIVATE_QUERY_CANARY|PRIVATE_RESULT_CANARY'
        }
    }

    It 'isolates Claude settings and enables autonomous execution only inside the outer sandbox' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $plan = [pscustomobject]@{
                engine = 'claude'
                argumentList = @('-p')
                workingDirectory = $Work
                environmentDelta = @{ CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = '1' }
                machineRuntime = [ordered]@{ kind='claude' }
            }

            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'TASK' -Policy 'workspace-write'
            try {
                Test-Path -LiteralPath $runtime.EnvironmentDelta.CLAUDE_CONFIG_DIR | Should -BeTrue
                $runtime.EnvironmentDelta.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB | Should -Be '0'
                $runtime.ArgumentList | Should -Contain '--max-turns'
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath -Workspace $Work
            }
        }
    }

    It 'routes stdin and native arguments through run and emits one JSON envelope' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliResolvedProfile { [ordered]@{ id = 'local'; engine = 'codex' } }
            Mock New-AiCliRecoverableRun {
                [pscustomobject]@{ runId = ('d' * 32); status = 'pending' }
            }
            Mock Invoke-AiCliRecoverableRun {
                [pscustomobject]@{
                    runId = ('d' * 32)
                    status = 'completed'
                    resumeSupported = $false
                    resumeReason = 'terminal_completed'
                    receipt = [pscustomobject]@{
                        profileId = 'local'
                        engine = 'codex'
                        exitCode = 0
                        stdout = '{"ok":true}'
                        stderr = ''
                        timedOut = $false
                        durationMs = 10
                        outputTruncated = $false
                        usage = [ordered]@{
                            input_tokens = [long]21
                            cached_input_tokens = [long]8
                            output_tokens = [long]5
                        }
                    }
                }
            }
            $oldIn = [Console]::In
            $oldOut = [Console]::Out
            $reader = [IO.StringReader]::new('PROMPT_FROM_STDIN')
            $writer = [IO.StringWriter]::new()
            try {
                [Console]::SetIn($reader)
                [Console]::SetOut($writer)
                $eventFile = Join-Path (Split-Path -Parent $TestDrive) `
                    ('router-events-{0}.jsonl' -f (Split-Path -Leaf $TestDrive))
                $code = Invoke-AiCliRouter -Tokens @(
                    'run', 'local', '--project', $TestDrive, '--stdin', '--json', '--sandbox-policy', 'danger-full-access',
                    '--timeout-seconds', '9', '--max-output-chars', '4096', '--event-file', $eventFile, '--',
                    'exec', '--json', '-'
                )
            } finally {
                [Console]::SetIn($oldIn)
                [Console]::SetOut($oldOut)
                $reader.Dispose()
            }

            $code | Should -Be 0
            $payload = $writer.ToString() | ConvertFrom-Json
            $payload.command | Should -Be 'run'
            $payload.run.stdout | Should -Be '{"ok":true}'
            ($payload.run.usage | ConvertTo-Json -Compress) |
                Should -Be '{"input_tokens":21,"cached_input_tokens":8,"output_tokens":5}'
            Should -Invoke New-AiCliRecoverableRun -Times 1 -Exactly -ParameterFilter {
                $ProfileId -eq 'local' -and
                $ProjectPath -eq $TestDrive -and
                $TaskText -eq 'PROMPT_FROM_STDIN' -and
                $TimeoutMs -eq 9000 -and
                $MaxCaptureChars -eq 4096 -and
                $ConsumerEventFile -eq $eventFile
            }
            Should -Invoke Invoke-AiCliRecoverableRun -Times 1 -Exactly -ParameterFilter {
                $RunId -eq ('d' * 32) -and
                $InitialTaskText -eq 'PROMPT_FROM_STDIN'
            }
        }
    }

    It 'rejects an empty machine task before launching an agent' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Get-AiCliResolvedProfile { [ordered]@{ id = 'local'; engine = 'codex' } }
            Mock Invoke-AiCliProfileCapture { throw 'agent must not launch' }
            $oldIn = [Console]::In
            $oldOut = [Console]::Out
            $reader = [IO.StringReader]::new('')
            $writer = [IO.StringWriter]::new()
            try {
                [Console]::SetIn($reader)
                [Console]::SetOut($writer)
                $code = Invoke-AiCliRouter -Tokens @(
                    'run', 'local', '--project', $Work, '--stdin', '--json', '--sandbox-policy', 'danger-full-access',
                    '--', 'exec', '--json', '-'
                )
            } finally {
                [Console]::SetIn($oldIn)
                [Console]::SetOut($oldOut)
                $reader.Dispose()
            }

            $code | Should -Be 2
            ($writer.ToString() | ConvertFrom-Json).error.summary | Should -Match 'stdin'
            Should -Invoke Invoke-AiCliProfileCapture -Times 0 -Exactly
        }
    }
}
