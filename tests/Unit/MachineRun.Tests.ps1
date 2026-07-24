#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Machine-facing profile runs' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Get-Module AiCliProfileManager -All | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
    }

    It 'captures a profile without exposing its launch environment' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine = 'codex'
                    fileName = 'C:\fake\codex.exe'
                    argumentList = @('exec', '--json', '-')
                    workingDirectory = $Work
                    environmentDelta = @{ OPENAI_API_KEY = 'CANARY_SECRET' }
                    removeEnvironment = @('ANTHROPIC_API_KEY')
                }
            }
            Mock Invoke-AiCliChildCapture {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'
                    StdErr = ''
                    TimedOut = $false
                    DurationMs = 123
                    OutputTruncated = $false
                    StepCount = 1
                    ToolCallCount = 0
                    EventsSeen = 2
                    EventProtocol = 'codex-jsonl'
                    LimitHit = $null
                    LimitsHard = $true
                    CleanupConfirmed = $true
                    CleanupMethod = 'none'
                }
            }

            $result = Invoke-AiCliProfileCapture -ProfileId 'local' -ProjectPath $Work `
                -NativeArgs @('exec', '--json', '-') -StdInText 'TASK' -TimeoutMs 9000 -MaxCaptureChars 4096

            $result.exitCode | Should -Be 0
            $result.stdout | Should -Match 'agent_message'
            $result.durationMs | Should -Be 123
            $result.limitEnforcement.timeout | Should -Be 'hard'
            $result.limitEnforcement.maxSteps | Should -Be 'hard'
            $result.limitEnforcement.maxToolCalls | Should -Be 'hard'
            $result.limitUsage.steps | Should -Be 1
            $result.limitUsage.toolCalls | Should -Be 0
            $result.limitUsage.protocol | Should -Be 'codex-jsonl'
            $result.limitUsage.stepDefinition | Should -Be 'distinct-thread-item-v1'
            $result.limitUsage.cleanupConfirmed | Should -BeTrue
            $result.eventProjection | Should -Be 'codex-public-v1'
            $result.limitHit | Should -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Not -Contain 'environmentDelta'
            ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'CANARY_SECRET'
            Should -Invoke Invoke-AiCliChildCapture -Times 1 -Exactly -ParameterFilter {
                $StdInText -eq 'TASK' -and $TimeoutMs -eq 9000 -and $MaxCaptureChars -eq 4096 -and
                $SandboxWorkspace -eq $Work -and $EventProtocol -eq 'codex-jsonl'
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
            $result.StepCount | Should -Be 4
            $result.ToolCallCount | Should -Be 2
            $result.EventsSeen | Should -Be 7
            $result.StdOut | Should -Match 'FINAL_PUBLIC'
            $result.StdOut | Should -Not -Match 'HIDDEN_COT_CANARY'
            $result.StdOut | Should -Not -Match 'PRIVATE_COMMAND'
            $result.StdOut | Should -Not -Match 'PRIVATE_OUTPUT'
            $result.StdErr | Should -Not -Match 'HIDDEN_STDERR_CANARY'
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
Start-Sleep -Seconds 5
[IO.File]::WriteAllText('$($marker.Replace("'", "''"))', 'escaped')
"@ | Set-Content -LiteralPath $scriptPath -Encoding utf8

            $result = Invoke-AiCliChildCapture -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile','-File',$scriptPath) -WorkingDirectory $Work `
                -EventProtocol codex-jsonl -MaxSteps 4 -MaxToolCalls 4 -TimeoutMs 300

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
                [pscustomobject]@{ FileName = 'C:\codex\codex.exe'; PrefixArgs = @(); Kind = 'native' }
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
        }
    }

    It 'grants a Codex npm package read-only without exposing the whole npm root' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Resolve-AiCliLaunchExecutable {
                [pscustomobject]@{ FileName = 'C:\codex\codex.exe'; PrefixArgs = @(); Kind = 'native' }
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
                [pscustomobject]@{ FileName = 'C:\codex\codex.exe'; PrefixArgs = @(); Kind = 'native' }
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
                    model = 'qwen-main-v1'
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
                    model = 'qwen-main-v1'
                }
            }
            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'PRIVATE_TASK_CANARY' `
                -Policy 'workspace-write' -MaxSteps 30 -MaxToolCalls 120
            try {
                ($runtime.ArgumentList -join ' ') | Should -Not -Match 'PRIVATE_TASK_CANARY'
                $runtime.StdInText | Should -Be ''
                $runtime.EnvironmentDelta.OPENCODE_CONFIG_CONTENT | Should -Match 'qwen-main-v1'
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
            Set-Content -LiteralPath $config -Value 'model = "qwen-main-v1"' -Encoding ascii
            $plan = [pscustomobject]@{
                engine = 'codex'
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @($entry, '--profile', 'aicli-local', 'exec', '-')
                workingDirectory = $Work
                environmentDelta = @{}
                machineRuntime = [ordered]@{ kind='codex'; configFiles=@($config) }
            }

            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'PRIVATE_TASK_CANARY' -Policy 'workspace-write'
            try {
                ($runtime.ArgumentList -join ' ') | Should -Not -Match 'PRIVATE_TASK_CANARY'
                $runtime.ArgumentList[-1] | Should -Match ([regex]::Escape((Join-Path $runtime.RuntimePath 'task.md')))
                ($runtime.ArgumentList -join ' ') | Should -Match '--disable multi_agent'
                ($runtime.ArgumentList -join ' ') | Should -Match '--disable multi_agent_v2'
                $runtime.StdInText | Should -Be ''
                Get-Content -Raw -LiteralPath (Join-Path $runtime.RuntimePath 'task.md') | Should -Be 'PRIVATE_TASK_CANARY'
                $runtime.ArgumentList[0] | Should -Be ([IO.Path]::GetFullPath($entry))
                Test-Path -LiteralPath (Join-Path $runtime.RuntimePath 'codex-package') | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $runtime.EnvironmentDelta.CODEX_HOME 'aicli-local.config.toml') | Should -BeTrue
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath -Workspace $Work
            }
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

    It 'uses the native Codex sandbox for an official cloud machine run' {
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
                machineRuntime = [ordered]@{
                    kind = 'codex'
                    configFiles = @()
                    sandboxBoundary = 'codex-native'
                }
            }

            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'TASK' -Policy 'read-only'
            try {
                $runtime.UseOuterSandbox | Should -BeFalse
                $runtime.StdInText | Should -Be 'TASK'
                $runtime.ArgumentList | Should -Not -Contain '--dangerously-bypass-approvals-and-sandbox'
                $runtime.ArgumentList | Should -Contain '--ignore-user-config'
                $runtime.ArgumentList | Should -Contain '--ignore-rules'
                $sandboxIndex = [Array]::IndexOf([string[]]$runtime.ArgumentList, '--sandbox')
                $sandboxIndex | Should -BeGreaterThan -1
                $runtime.ArgumentList[$sandboxIndex + 1] | Should -Be 'read-only'
                Test-Path -LiteralPath (Join-Path $runtime.RuntimePath 'task.md') | Should -BeFalse
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath -Workspace $Work
            }
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
            Mock Invoke-AiCliProfileCapture {
                [pscustomobject]@{
                    profileId = $ProfileId
                    engine = 'codex'
                    exitCode = 0
                    stdout = '{"ok":true}'
                    stderr = ''
                    timedOut = $false
                    durationMs = 10
                    outputTruncated = $false
                }
            }
            $oldIn = [Console]::In
            $oldOut = [Console]::Out
            $reader = [IO.StringReader]::new('PROMPT_FROM_STDIN')
            $writer = [IO.StringWriter]::new()
            try {
                [Console]::SetIn($reader)
                [Console]::SetOut($writer)
                $code = Invoke-AiCliRouter -Tokens @(
                    'run', 'local', '--project', 'C:\work', '--stdin', '--json', '--sandbox-policy', 'workspace-write',
                    '--timeout-seconds', '9', '--max-output-chars', '4096', '--',
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
            Should -Invoke Invoke-AiCliProfileCapture -Times 1 -Exactly -ParameterFilter {
                $ProfileId -eq 'local' -and
                $ProjectPath -eq 'C:\work' -and
                $StdInText -eq 'PROMPT_FROM_STDIN' -and
                $TimeoutMs -eq 9000 -and
                $MaxCaptureChars -eq 4096 -and
                $SandboxPolicy -eq 'workspace-write' -and
                $NativeArgs.Count -eq 3 -and
                $NativeArgs[0] -eq 'exec' -and
                $NativeArgs[2] -eq '-'
            }
        }
    }

    It 'rejects an empty machine task before launching an agent' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Invoke-AiCliProfileCapture { throw 'agent must not launch' }
            $oldIn = [Console]::In
            $oldOut = [Console]::Out
            $reader = [IO.StringReader]::new('')
            $writer = [IO.StringWriter]::new()
            try {
                [Console]::SetIn($reader)
                [Console]::SetOut($writer)
                $code = Invoke-AiCliRouter -Tokens @(
                    'run', 'local', '--project', $Work, '--stdin', '--json', '--sandbox-policy', 'workspace-write',
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
