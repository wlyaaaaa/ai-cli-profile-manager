[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BridgePath
)

$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.0

$testContainer = {
    param(
        [string]$BridgePath,
        [string]$FakeCodexPath,
        [string]$UpstreamOnlyPlanPath
    )

    BeforeAll {
        $script:BridgePath = [IO.Path]::GetFullPath($BridgePath)
        $script:FakeCodexPath = [IO.Path]::GetFullPath($FakeCodexPath)
        $script:UpstreamOnlyPlanPath = [IO.Path]::GetFullPath($UpstreamOnlyPlanPath)
        $script:PowerShellPath = (Get-Command pwsh -ErrorAction Stop).Source
        $script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

        function New-DesktopBridgePlan {
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][ValidateSet('--fake-app-server', '--fake-passthrough', '--fake-app-server-stuck')][string]$Mode,
                [ValidateSet('None', 'Valid', 'DeepSeek', 'Invalid')][string]$ModelState = 'None'
            )

            $codexHome = Join-Path $Root 'codex-home'
            New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

            $models = @()
            if ($ModelState -eq 'Valid') {
                $models = @([ordered]@{
                    model = 'local-model'
                    providerId = 'aicli_ollama_local'
                    routeProviderId = 'aicli_desktop_local'
                    kind = 'local'
                    provider = [ordered]@{
                        name = 'Ollama'
                        base_url = 'http://127.0.0.1:11434/v1'
                        wire_api = 'responses'
                        requires_openai_auth = $false
                    }
                    catalogModel = [ordered]@{
                        slug = 'local-model'
                        display_name = 'Local Model'
                        description = 'Transport fixture model'
                        base_instructions = 'Use skills and tools from the model catalog.'
                        context_window = 4096
                        effective_context_window_percent = 95
                        default_reasoning_level = 'high'
                        supported_reasoning_levels = @([ordered]@{ effort = 'high'; description = 'High' })
                        input_modalities = @('text')
                        supports_personality = $false
                    }
                    catalogPath = Join-Path $codexHome 'catalog.json'
                    contextWindow = 4096
                    defaultEffort = 'high'
                })
            }
            elseif ($ModelState -eq 'DeepSeek') {
                $models = @([ordered]@{
                    profileId = 'codex-deepseek-flash'
                    model = 'deepseek-flash'
                    providerId = 'aicli_deepseek_flash'
                    routeProviderId = 'aicli_deepseek_flash'
                    kind = 'cloud'
                    provider = [ordered]@{
                        name = 'DeepSeek Flash'
                        base_url = 'https://api.deepseek.com/v1'
                        wire_api = 'responses'
                        requires_openai_auth = $false
                    }
                    catalogModel = [ordered]@{
                        slug = 'deepseek-flash'
                        display_name = 'DeepSeek Flash'
                        description = 'DeepSeek transport fixture'
                        base_instructions = 'Keep public reasoning summaries visible.'
                        context_window = 1048576
                        effective_context_window_percent = 95
                        default_reasoning_level = 'max'
                        supported_reasoning_levels = @([ordered]@{ effort = 'max'; description = 'Max' })
                        input_modalities = @('text')
                        supports_personality = $false
                    }
                    catalogPath = Join-Path $codexHome 'deepseek-catalog.json'
                    contextWindow = 1048576
                    defaultEffort = 'max'
                })
            }
            elseif ($ModelState -eq 'Invalid') {
                $models = @([ordered]@{
                    model = 'broken-model'
                    providerId = 'aicli_ollama_broken'
                    provider = [ordered]@{}
                })
            }

            $plan = [ordered]@{
                schemaVersion = 1
                codexHome = $codexHome
                upstreamFileName = $script:PowerShellPath
                upstreamPrefixArgs = @('-NoProfile', '-File', $script:FakeCodexPath, $Mode)
                models = $models
            }
            $planPath = Join-Path $Root 'plan.json'
            $json = $plan | ConvertTo-Json -Depth 100 -Compress
            [IO.File]::WriteAllText($planPath, $json, $script:Utf8NoBom)
            return [pscustomobject]@{ Path = $planPath; CodexHome = $codexHome; Root = $Root }
        }

        function New-BridgeProcess {
            param(
                [Parameter(Mandatory)][string]$Executable,
                [Parameter(Mandatory)][AllowEmptyString()][string]$PlanPath,
                [Parameter(Mandatory)][string[]]$Arguments,
                [hashtable]$Environment = @{}
            )

            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $Executable
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.StandardInputEncoding = $script:Utf8NoBom
            $startInfo.StandardOutputEncoding = $script:Utf8NoBom
            $startInfo.StandardErrorEncoding = $script:Utf8NoBom
            if ([string]::IsNullOrWhiteSpace($PlanPath)) {
                $null = $startInfo.Environment.Remove('AICLI_DESKTOP_PLAN_FILE')
            }
            else {
                $startInfo.Environment['AICLI_DESKTOP_PLAN_FILE'] = $PlanPath
            }
            foreach ($entry in $Environment.GetEnumerator()) {
                $startInfo.Environment[$entry.Key] = [string]$entry.Value
            }
            foreach ($argument in $Arguments) {
                $startInfo.ArgumentList.Add($argument)
            }

            $process = [Diagnostics.Process]::Start($startInfo)
            if ($null -eq $process) { throw 'Desktop bridge did not start.' }
            return $process
        }

        function Write-BridgeLine {
            param([Parameter(Mandatory)][Diagnostics.Process]$Process, [Parameter(Mandatory)][string]$Line)
            $Process.StandardInput.WriteLine($Line)
            $Process.StandardInput.Flush()
        }

        function Read-BridgeLine {
            param([Parameter(Mandatory)][Diagnostics.Process]$Process)
            $task = $Process.StandardOutput.ReadLineAsync()
            $line = $task.WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
            if ($null -eq $line) { throw 'Desktop bridge stdout closed before returning a JSON-RPC line.' }
            return $line
        }

        function Stop-BridgeProcess {
            param([Diagnostics.Process]$Process)
            if ($null -eq $Process) { return }
            try {
                if (-not $Process.HasExited) {
                    $Process.Kill($true)
                    $null = $Process.WaitForExit(5000)
                }
            }
            catch { }
            $Process.Dispose()
        }

        function New-TestRoot {
            $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            return $root
        }

        function Read-ProcessBytes {
            param([Parameter(Mandatory)][Diagnostics.Process]$Process)
            $capture = [IO.MemoryStream]::new()
            try {
                $copyTask = $Process.StandardOutput.BaseStream.CopyToAsync($capture)
                $null = $copyTask.WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
                return ,$capture.ToArray()
            }
            finally { $capture.Dispose() }
        }
    }

    Describe 'Codex desktop bridge stdio transport' {
        It 'routes app-server after global option values and hides internal replies while passing requests and server replies' {
            $root = New-TestRoot
            $plan = New-DesktopBridgePlan -Root $root -Mode '--fake-app-server' -ModelState Valid
            $expectedLinePath = Join-Path $root 'expected-ping.json'
            $process = $null
            try {
                $arguments = @(
                    '--config', 'model=local-model',
                    '--profile', 'desktop-test',
                    '-p', 'second-profile',
                    '--enable', 'feature-a',
                    '--disable=feature-b',
                    '--add-dir', (Join-Path $root 'directory with spaces'),
                    'app-server', '--stdio'
                )
                $process = New-BridgeProcess -Executable $script:BridgePath -PlanPath $plan.Path -Arguments $arguments -Environment @{
                    AICLI_TEST_EXPECTED_LINE_FILE = $expectedLinePath
                }

                Write-BridgeLine $process '{"id":"startup-check","method":"test/startup","params":{}}'
                $startup = (Read-BridgeLine $process) | ConvertFrom-Json
                $startup.result.startupInstructions | Should -Be 'Use skills and tools from the model catalog.'

                Write-BridgeLine $process '{"jsonrpc":"2.0","id":7,"method":"thread/resume","params":{"threadId":"thread-1"}}'
                $serverRequestLine = Read-BridgeLine $process
                $serverRequest = $serverRequestLine | ConvertFrom-Json
                $serverRequest.method | Should -Be 'server/need_input'
                $serverRequest.id | Should -Be 'server-need-client'

                $clientReply = '{"jsonrpc":"2.0","id":"server-need-client","result":{"accepted":true}}'
                Write-BridgeLine $process $clientReply
                $resumeLine = Read-BridgeLine $process
                $resume = $resumeLine | ConvertFrom-Json
                $resume.id | Should -Be 7
                $resume.result.modelProvider | Should -Be 'aicli_desktop_local'
                $resume.result.clientReplyRaw | Should -Be $clientReply

                $clientNotification = '{"jsonrpc":"2.0", "method":"client/notice", "params":{"text":"雪"}}'
                Write-BridgeLine $process $clientNotification
                $upstreamNotification = (Read-BridgeLine $process) | ConvertFrom-Json
                $upstreamNotification.method | Should -Be 'engine/notice'
                $upstreamNotification.params.receivedRaw | Should -Be $clientNotification

                $pingRequest = '{"jsonrpc":"2.0", "id":"id-雪", "method":"ping", "params":{"text":"雪"}}'
                Write-BridgeLine $process $pingRequest
                $pingLine = Read-BridgeLine $process
                $ping = $pingLine | ConvertFrom-Json
                $ping.id | Should -Be 'id-雪'
                $ping.result.echo | Should -Be 'pong'
                $ping.result.receivedRaw | Should -Be $pingRequest
                $pingLine | Should -Be (Get-Content -LiteralPath $expectedLinePath -Raw -Encoding utf8)

                $process.StandardInput.Close()
                $process.WaitForExit(10000) | Should -BeTrue
                $process.ExitCode | Should -Be 0
                $process.StandardError.ReadToEnd() | Should -Not -Match '__aicli_desktop_internal_'
            }
            finally { Stop-BridgeProcess $process }
        }

        It 'keeps one DeepSeek reasoning presentation alive across visible output' {
            $root = New-TestRoot
            $plan = New-DesktopBridgePlan -Root $root -Mode '--fake-app-server' -ModelState DeepSeek
            $process = $null
            try {
                $process = New-BridgeProcess -Executable $script:BridgePath -PlanPath $plan.Path -Arguments @('app-server', '--stdio')

                Write-BridgeLine $process '{"jsonrpc":"2.0","id":"deep-start","method":"thread/start","params":{"model":"deepseek-flash","config":{}}}'
                $started = (Read-BridgeLine $process) | ConvertFrom-Json
                $started.id | Should -Be 'deep-start'
                $started.result.modelProvider | Should -Be 'aicli_deepseek_flash'
                $started.result.thread.id | Should -Be 'deep-thread'

                Write-BridgeLine $process '{"jsonrpc":"2.0","id":"deep-events","method":"test/deepseek-events","params":{}}'
                $events = @(1..13 | ForEach-Object { (Read-BridgeLine $process) | ConvertFrom-Json })

                $events[0].method | Should -Be 'item/started'
                $events[0].params.item.id | Should -Be 'reason-a'
                $events[1].method | Should -Be 'item/reasoning/summaryPartAdded'
                $events[1].params.itemId | Should -Be 'reason-a'
                $events[1].params.summaryIndex | Should -Be 0
                $events[2].method | Should -Be 'item/reasoning/summaryTextDelta'
                $events[2].params.itemId | Should -Be 'reason-a'
                $events[2].params.delta | Should -Be '第一段思考'
                $events[3].method | Should -Be 'item/reasoning/summaryTextDelta'
                $events[3].params.itemId | Should -Be 'reason-a'
                $events[3].params.delta | Should -Be '继续思考'

                $events[4].method | Should -Be 'item/started'
                $events[4].params.item.type | Should -Be 'agentMessage'
                $events[5].method | Should -Be 'item/agentMessage/delta'
                $events[6].method | Should -Be 'item/completed'
                $events[6].params.item.type | Should -Be 'agentMessage'
                @($events[0..6] | Where-Object { $_.method -eq 'item/completed' -and $_.params.item.type -eq 'reasoning' }).Count | Should -Be 0

                $events[7].method | Should -Be 'item/reasoning/summaryPartAdded'
                $events[7].params.itemId | Should -Be 'reason-a'
                $events[7].params.summaryIndex | Should -Be 1
                $events[8].method | Should -Be 'item/reasoning/summaryTextDelta'
                $events[8].params.itemId | Should -Be 'reason-a'
                $events[8].params.delta | Should -Be '第二段思考'
                @($events | Where-Object { $_.method -eq 'item/started' -and $_.params.item.type -eq 'reasoning' }).Count | Should -Be 1

                $events[9].method | Should -Be 'item/completed'
                $events[9].params.item.type | Should -Be 'agentMessage'
                $events[10].method | Should -Be 'item/completed'
                $events[10].params.item.type | Should -Be 'reasoning'
                $events[10].params.item.id | Should -Be 'reason-a'
                @($events[10].params.item.summary).Count | Should -Be 2
                $events[10].params.item.summary[1] | Should -Be '第二段思考'
                $events[11].method | Should -Be 'turn/completed'
                $events[12].id | Should -Be 'deep-events'
                $events[12].result.ok | Should -BeTrue

                $process.StandardInput.Close()
                $process.WaitForExit(10000) | Should -BeTrue
                $process.ExitCode | Should -Be 0
            }
            finally { Stop-BridgeProcess $process }
        }

        It 'passes non-app-server bytes and the upstream exit code without text decoding' {
            $root = New-TestRoot
            $plan = New-DesktopBridgePlan -Root $root -Mode '--fake-passthrough'
            $argsFile = Join-Path $root 'args.json'
            $process = $null
            try {
                $process = New-BridgeProcess -Executable $script:BridgePath -PlanPath $plan.Path -Arguments @('--version') -Environment @{
                    AICLI_TEST_ARGS_FILE = $argsFile
                }
                $payload = [byte[]]@(0x00, 0xff, 0x0a, 0x0d, 0x80, 0x41, 0xe9)
                $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
                $process.StandardInput.Close()
                $output = Read-ProcessBytes $process
                $process.WaitForExit(10000) | Should -BeTrue
                [Convert]::ToBase64String($output) | Should -Be ([Convert]::ToBase64String($payload))
                $process.ExitCode | Should -Be 23
                $capturedArgs = Get-Content -LiteralPath $argsFile -Raw -Encoding utf8 | ConvertFrom-Json
                @($capturedArgs.args).Count | Should -Be 1
                $capturedArgs.args[0] | Should -Be '--version'
            }
            finally { Stop-BridgeProcess $process }
        }

        It 'keeps debug app-server transparent because debug is the first subcommand' {
            $root = New-TestRoot
            $plan = New-DesktopBridgePlan -Root $root -Mode '--fake-passthrough'
            $argsFile = Join-Path $root 'args.json'
            $process = $null
            try {
                $process = New-BridgeProcess -Executable $script:BridgePath -PlanPath $plan.Path -Arguments @('debug', 'app-server') -Environment @{
                    AICLI_TEST_ARGS_FILE = $argsFile
                }
                $payload = [byte[]]@(0x00, 0xf1, 0x0a, 0x42)
                $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
                $process.StandardInput.Close()
                $output = Read-ProcessBytes $process
                $process.WaitForExit(10000) | Should -BeTrue
                [Convert]::ToBase64String($output) | Should -Be ([Convert]::ToBase64String($payload))
                $process.ExitCode | Should -Be 23
                $capturedArgs = Get-Content -LiteralPath $argsFile -Raw -Encoding utf8 | ConvertFrom-Json
                @($capturedArgs.args).Count | Should -Be 2
                $capturedArgs.args[0] | Should -Be 'debug'
                $capturedArgs.args[1] | Should -Be 'app-server'
            }
            finally { Stop-BridgeProcess $process }
        }

        It 'resolves ordinary commands without loading the local model catalog' {
            $root = New-TestRoot
            $bridgeCopyRoot = Join-Path $root 'bridge-copy'
            $bridgeDirectory = Join-Path $bridgeCopyRoot 'debug'
            New-Item -ItemType Directory -Path $bridgeDirectory -Force | Out-Null
            $sourceDirectory = Split-Path -Parent $script:BridgePath
            Get-ChildItem -LiteralPath $sourceDirectory -File | Copy-Item -Destination $bridgeDirectory

            $planScript = Join-Path $bridgeCopyRoot 'GetDesktopModelPlan.ps1'
            Copy-Item -LiteralPath $script:UpstreamOnlyPlanPath -Destination $planScript
            $codexHome = Join-Path $root 'upstream-only-home'
            New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
            $argsFile = Join-Path $root 'args.json'
            $process = $null
            try {
                $process = New-BridgeProcess -Executable (Join-Path $bridgeDirectory (Split-Path -Leaf $script:BridgePath)) -PlanPath '' -Arguments @('--version') -Environment @{
                    AICLI_TEST_PLAN_HOME = $codexHome
                    AICLI_TEST_PLAN_PWSH = $script:PowerShellPath
                    AICLI_TEST_FAKE_CODEX_SCRIPT = $script:FakeCodexPath
                    AICLI_TEST_ARGS_FILE = $argsFile
                }
                $payload = [byte[]]@(0x51, 0x00, 0xfe, 0x0a)
                $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
                $process.StandardInput.Close()
                $output = Read-ProcessBytes $process
                $process.WaitForExit(15000) | Should -BeTrue
                [Convert]::ToBase64String($output) | Should -Be ([Convert]::ToBase64String($payload))
                $process.ExitCode | Should -Be 23
                $process.StandardError.ReadToEnd() | Should -Not -Match 'Local desktop model discovery failed'
            }
            finally { Stop-BridgeProcess $process }
        }

        It 'continues upstream requests when local router initialization fails' {
            $root = New-TestRoot
            $plan = New-DesktopBridgePlan -Root $root -Mode '--fake-app-server' -ModelState Invalid
            $process = $null
            try {
                $process = New-BridgeProcess -Executable $script:BridgePath -PlanPath $plan.Path -Arguments @('app-server')
                Write-BridgeLine $process '{"jsonrpc":"2.0","id":"fallback-ping","method":"ping","params":{}}'
                $response = (Read-BridgeLine $process) | ConvertFrom-Json
                $response.id | Should -Be 'fallback-ping'
                $response.result.echo | Should -Be 'pong'
                $process.StandardInput.Close()
                $process.WaitForExit(10000) | Should -BeTrue
                $process.StandardError.ReadToEnd() | Should -Match 'upstream Codex engine only'
            }
            finally { Stop-BridgeProcess $process }
        }

        It 'closes a descendant process when the app-server client reaches EOF' {
            $root = New-TestRoot
            $plan = New-DesktopBridgePlan -Root $root -Mode '--fake-app-server-stuck'
            $pidPath = Join-Path $root 'child.pid'
            $process = $null
            try {
                $process = New-BridgeProcess -Executable $script:BridgePath -PlanPath $plan.Path -Arguments @('app-server') -Environment @{
                    AICLI_TEST_CHILD_PID_FILE = $pidPath
                }
                $process.StandardInput.Close()
                $process.WaitForExit(12000) | Should -BeTrue
                Test-Path -LiteralPath $pidPath | Should -BeTrue
                $childPid = [int](Get-Content -LiteralPath $pidPath -Raw)
                $childExited = $false
                for ($attempt = 0; $attempt -lt 50; $attempt++) {
                    try {
                        $child = [Diagnostics.Process]::GetProcessById($childPid)
                        try { if ($child.HasExited) { $childExited = $true; break } }
                        finally { $child.Dispose() }
                    }
                    catch [ArgumentException] { $childExited = $true; break }
                    Start-Sleep -Milliseconds 100
                }
                $childExited | Should -BeTrue
            }
            finally { Stop-BridgeProcess $process }
        }
    }
}

$container = New-PesterContainer -ScriptBlock $testContainer -Data @{
    BridgePath = [IO.Path]::GetFullPath($BridgePath)
    FakeCodexPath = Join-Path $PSScriptRoot 'transport-fixtures/FakeCodex.ps1'
    UpstreamOnlyPlanPath = Join-Path $PSScriptRoot 'transport-fixtures/UpstreamOnlyPlan.ps1'
}
Invoke-Pester -Container $container -CI
