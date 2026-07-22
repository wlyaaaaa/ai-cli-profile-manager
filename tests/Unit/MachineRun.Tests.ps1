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
                    StdOut = '{"type":"item.completed"}'
                    StdErr = ''
                    TimedOut = $false
                    DurationMs = 123
                    OutputTruncated = $false
                }
            }

            $result = Invoke-AiCliProfileCapture -ProfileId 'local' -ProjectPath $Work `
                -NativeArgs @('exec', '--json', '-') -StdInText 'TASK' -TimeoutMs 9000 -MaxCaptureChars 4096

            $result.exitCode | Should -Be 0
            $result.stdout | Should -Be '{"type":"item.completed"}'
            $result.durationMs | Should -Be 123
            $result.limitEnforcement.timeout | Should -Be 'hard'
            $result.limitEnforcement.maxSteps | Should -Be 'not-enforced'
            $result.PSObject.Properties.Name | Should -Not -Contain 'environmentDelta'
            ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'CANARY_SECRET'
            Should -Invoke Invoke-AiCliChildCapture -Times 1 -Exactly -ParameterFilter {
                $StdInText -eq 'TASK' -and $TimeoutMs -eq 9000 -and $MaxCaptureChars -eq 4096 -and
                $SandboxWorkspace -eq $Work
            }
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
            $config = Join-Path $Work 'aicli-local.config.toml'
            New-Item -ItemType Directory -Path (Split-Path -Parent $entry) -Force | Out-Null
            Set-Content -LiteralPath $entry -Value '// stub' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $package 'package.json') -Value '{}' -Encoding ascii
            Set-Content -LiteralPath $config -Value 'model = "qwen-main-v1"' -Encoding ascii
            $plan = [pscustomobject]@{
                engine = 'codex'
                argumentList = @($entry, '--profile', 'aicli-local', 'exec', '-')
                workingDirectory = $Work
                environmentDelta = @{}
                machineRuntime = [ordered]@{ kind='codex'; configFiles=@($config) }
            }

            $runtime = Initialize-AiCliMachineRuntime -Plan $plan -StdInText 'TASK' -Policy 'workspace-write'
            try {
                $runtime.ArgumentList[0] | Should -Be (Join-Path $runtime.RuntimePath 'codex-package\bin\codex.js')
                Test-Path -LiteralPath (Join-Path $runtime.EnvironmentDelta.CODEX_HOME 'aicli-local.config.toml') | Should -BeTrue
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
}
