#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:BrokerSessionRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module AiCliProfileManager -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:BrokerSessionRepoRoot `
        'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'LocalGpuBroker clean-base module and profile contracts' {
    It 'loads the self-contained broker session module' {
        InModuleScope AiCliProfileManager {
            Get-Command Open-AiCliLocalGpuBrokerSession -ErrorAction Stop |
                Should -Not -BeNullOrEmpty
            Get-Command Write-AiCliLocalGpuBrokerAuthorityPrelude -ErrorAction Stop |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'defines exact 35B and 27B local routes without agent-acceptance fields' {
        $expected = [ordered]@{
            'codex-ollama-main.json' = [ordered]@{
                model = 'qwen-main-v1'; context = 262144; output = 8192
            }
            'codex-ollama-review.json' = [ordered]@{
                model = 'qwen-review-v1'; context = 131072; output = 8192
            }
        }
        foreach ($name in $expected.Keys) {
            $manifestPath = Join-Path $script:BrokerSessionRepoRoot "data\providers\$name"
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $route = $expected[$name]
            $session = $manifest.compatibility.localGpuBrokerSession

            $session.contractVersion | Should -Be 1
            $session.requiredForMachineRun | Should -BeTrue
            $session.managementOrigin | Should -BeExactly 'http://127.0.0.1:32100'
            $manifest.models.primary | Should -BeExactly $route.model
            @($manifest.models.candidates) | Should -Be @($route.model)
            $manifest.modelMetadata.($route.model).contextWindowTokens |
                Should -Be $route.context
            $manifest.modelMetadata.($route.model).outputWindowTokens |
                Should -Be $route.output
            $manifest.compatibility.minCliVersion | Should -Be '0.147.0'
            $manifest.PSObject.Properties.Name | Should -Not -Contain 'agentAcceptance'

            $catalogPath = Join-Path $script:BrokerSessionRepoRoot (
                'data\model-catalogs\' + [string]$manifest.codexModelCatalog
            )
            $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
            $catalogModel = @($catalog.models | Where-Object slug -CEQ $route.model)
            $catalogModel | Should -HaveCount 1
            $catalogModel[0].context_window | Should -Be $route.context

            InModuleScope AiCliProfileManager -Parameters @{ ManifestPath = $manifestPath } {
                $candidate = Get-Content -LiteralPath $ManifestPath -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 30
                { Assert-AiCliManifestCore -M $candidate } | Should -Not -Throw
            }
        }

        $schema = Get-Content -LiteralPath (Join-Path $script:BrokerSessionRepoRoot `
            'data\schemas\provider-manifest.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.compatibility.type | Should -Be 'object'
        $schema.additionalProperties | Should -BeFalse
    }

    It 'fails closed on optional, extended, or non-exact-loopback contracts' {
        InModuleScope AiCliProfileManager {
            $invalid = @(
                [ordered]@{ contractVersion = 1; requiredForMachineRun = $true; managementOrigin = 'http://localhost:32100' },
                [ordered]@{ contractVersion = 1; requiredForMachineRun = $false; managementOrigin = 'http://127.0.0.1:32100' },
                [ordered]@{ contractVersion = 1; requiredForMachineRun = $true; managementOrigin = 'http://127.0.0.1:32100'; headers = @{} }
            )
            foreach ($contract in $invalid) {
                {
                    Resolve-AiCliLocalGpuBrokerSessionConfiguration `
                        -Configuration $contract -Endpoint 'http://127.0.0.1:32100/v1'
                } | Should -Throw
            }
        }
    }

    It 'rejects any local Codex fallback model override' {
        InModuleScope AiCliProfileManager {
            $profile = Get-AiCliProviderManifest -Id 'codex-ollama-main'
            {
                Resolve-AiCliCodexModel -MergedProfile $profile `
                    -NativeArgs @('--fallback-model', 'qwen-main-v1')
            } | Should -Throw '*fallback*'
        }
    }
}

Describe 'LocalGpuBroker binding and secret boundary' {
    It 'publishes only header environment names into Codex configuration' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{
                id = 'codex-ollama-main'
                displayName = 'Codex local'
                endpoint = 'http://127.0.0.1:32100/v1'
                codexProviderId = 'aicli_ollama_main'
                models = [ordered]@{ primary = 'qwen-main-v1' }
                compatibility = [ordered]@{
                    localGpuBrokerSession = [ordered]@{
                        contractVersion = 1
                        requiredForMachineRun = $true
                        managementOrigin = 'http://127.0.0.1:32100'
                    }
                }
            }
            $arguments = [Collections.Generic.List[string]]::new()
            $toml = New-AiCliCodexProviderToml -MergedProfile $profile `
                -EnvKeyName 'AICLI_CODEX_PROVIDER_KEY'
            Add-AiCliCodexProviderOverrides -ArgumentList $arguments `
                -MergedProfile $profile -ProviderId 'aicli_ollama_main' `
                -EnvironmentKey 'AICLI_CODEX_PROVIDER_KEY'

            $toml | Should -Match 'X-LocalGpuBroker-Lease-Id'
            $toml | Should -Match 'AICLI_LOCAL_GPU_BROKER_CAPABILITY'
            $toml | Should -Not -Match 'CAPABILITY_CANARY'
            (@($arguments) -join "`n") | Should -Match 'X-LocalGpuBroker-Capability'
            (@($arguments) -join "`n") |
                Should -Match 'shell_environment_policy.exclude=.*AICLI_LOCAL_GPU_BROKER_CAPABILITY'
        }
    }

    It 'acquires, renews, and closes a verified normal session without capability output' {
        InModuleScope AiCliProfileManager {
            $script:BrokerCalls = [Collections.Generic.List[string]]::new()
            $leaseId = '1' * 32
            $instanceId = '2' * 32
            $capability = 'CAPABILITY_CANARY_1234567890_ABCDEF'
            Mock Invoke-AiCliLocalGpuBrokerHttp {
                $script:BrokerCalls.Add("$Method $Path") | Out-Null
                $base = [ordered]@{
                    schema = 'pcconfig.local-gpu-broker.ollama-session.v1'; ok = $true
                    broker_instance_id = $instanceId; lease_id = $leaseId
                    owner = 'aicli-machine-run'; owner_pid = [Environment]::ProcessId
                    owner_process_creation_token_sha256 = 'sha256:' + ('f' * 64)
                    owner_process_exit_detected_at = $null
                    binding_sha256 = [string]$Body.binding_sha256; state = 'acquired'
                    active_requests = 0; accepted_requests = 0; completed_requests = 0
                    accepted_model_requests = 0; completed_model_requests = 0
                    request_chain_sha256 = 'sha256:' + ('e' * 64)
                    acquired_at = 100.0; expires_at = 8000.0
                    released_at = $null; release_reason = $null
                }
                if ($Path -eq '/_gpu_broker/ollama-session/acquire') {
                    $base.capability = $capability
                } elseif ($Path -eq '/_gpu_broker/ollama-session/close') {
                    $base.state = 'released'; $base.accepted_requests = 1
                    $base.completed_requests = 1; $base.accepted_model_requests = 1
                    $base.completed_model_requests = 1; $base.released_at = 200.0
                    $base.release_reason = [string]$Body.reason
                    $base.request_chain_sha256 = 'sha256:' + ('d' * 64)
                }
                return $base
            }
            $plan = [pscustomobject]@{
                profileId = 'codex-ollama-main'; profileFingerprint = ('a' * 64)
                engine = 'codex'; model = 'qwen-main-v1'
                modelProvider = 'aicli_ollama_main'; endpoint = 'http://127.0.0.1:32100/v1'
                wire = 'responses'; machineRuntime = [ordered]@{
                    localGpuBrokerSession = [ordered]@{
                        contractVersion = 1; requiredForMachineRun = $true
                        managementOrigin = 'http://127.0.0.1:32100'
                    }
                }
            }

            $session = Open-AiCliLocalGpuBrokerSession -Plan $plan `
                -RequestText 'NORMAL TASK' -TimeoutMs 7200000
            $terminal = Complete-AiCliLocalGpuBrokerSession -Session $session -Reason normal

            @($script:BrokerCalls) | Should -Be @(
                'POST /_gpu_broker/ollama-session/acquire'
                'POST /_gpu_broker/ollama-session/renew'
                'POST /_gpu_broker/ollama-session/close'
            )
            $terminal.schema | Should -Be 'aicli.local-gpu-broker-session-receipt.v1'
            $terminal.verified | Should -BeTrue
            $terminal.release_reason | Should -Be 'normal'
            $terminal.owner_pid | Should -BeExactly ([Environment]::ProcessId)
            ($terminal | ConvertTo-Json -Depth 30 -Compress) |
                Should -Not -Match ([regex]::Escape($capability))
            $terminal.PSObject.Properties.Name | Should -Not -Contain 'capability'
        }
    }

    It 'writes one canonical sequence-one authority frame without capability material' {
        InModuleScope AiCliProfileManager {
            $observation = [ordered]@{
                schema = 'aicli.local-gpu-broker-binding-observation.v1'
                broker_instance_id = '2' * 32; lease_id = '3' * 32
                owner_pid = [Environment]::ProcessId
                binding_sha256 = 'sha256:' + ('4' * 64)
                binding_schema = 'aicli.local-gpu-broker-binding.v1'
                job_id = 'sha256:' + ('5' * 64); execution_id = '6' * 32
                request_sha256 = 'sha256:' + ('7' * 64)
                profile_id = 'codex-ollama-main'
                profile_fingerprint = 'sha256:' + ('8' * 64)
                model = 'qwen-main-v1'; model_provider = 'aicli_ollama_main'
                registry_source = [ordered]@{
                    schema = 'aicli.profile-registry-source.v1'
                    kind = 'bundled-provider-manifest'; id = 'codex-ollama-main'
                    relative_path = 'providers/codex-ollama-main.json'
                    sha256 = 'sha256:' + ('9' * 64)
                }
            }
            $observation.observation_sha256 = Get-AiCliLocalGpuBrokerTextSha256 `
                -Text ($observation | ConvertTo-Json -Depth 20 -Compress)
            $writer = [IO.StringWriter]::new()
            Write-AiCliLocalGpuBrokerAuthorityPrelude -Observation $observation -Writer $writer
            $raw = $writer.ToString()
            @($raw -split "`n" | Where-Object { $_ }) | Should -HaveCount 1
            $frame = $raw.TrimEnd("`r", "`n") | ConvertFrom-Json -AsHashtable -Depth 30
            @($frame.Keys) | Should -Be @(
                'schema', 'sequence', 'kind', 'observation_sha256', 'binding_observation'
            )
            $frame.schema | Should -BeExactly 'aicli.authority-prelude.v1'
            $frame.sequence | Should -BeExactly 1
            ($frame | ConvertTo-Json -Depth 30 -Compress) | Should -Not -Match '(?i)capability'
        }
    }

    It 'redacts every exact capability representation from real participant stdout, stderr, and final JSON' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $capability = 'Az09-_Capability_Exact_1234567890XYZQ'
            $utf8Bytes = [Text.Encoding]::UTF8.GetBytes($capability)
            $utf8Base64 = [Convert]::ToBase64String($utf8Bytes)
            $variants = @(
                $capability
                $utf8Base64
                $utf8Base64.Replace('+', '-').Replace('/', '_')
                $utf8Base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
                [Convert]::ToHexString($utf8Bytes).ToLowerInvariant()
                [Convert]::ToHexString($utf8Bytes)
                [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($capability))
            ) | Select-Object -Unique
            $participant = Join-Path $Work 'print-capability.ps1'
            @'
$raw = $env:AICLI_LOCAL_GPU_BROKER_CAPABILITY
$utf8Bytes = [Text.Encoding]::UTF8.GetBytes($raw)
$utf8Base64 = [Convert]::ToBase64String($utf8Bytes)
$variants = @(
    $raw
    $utf8Base64
    $utf8Base64.Replace('+', '-').Replace('/', '_')
    $utf8Base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [Convert]::ToHexString($utf8Bytes).ToLowerInvariant()
    [Convert]::ToHexString($utf8Bytes)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($raw))
) | Select-Object -Unique
[Console]::Out.WriteLine(($variants -join '|'))
[Console]::Error.WriteLine(($variants -join '|'))
'@ | Set-Content -LiteralPath $participant -Encoding utf8
            $captured = Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $participant) `
                -EnvironmentDelta @{ AICLI_LOCAL_GPU_BROKER_CAPABILITY = $capability } `
                -SecretValues @($capability) -CloseStdIn -TimeoutMs 5000
            $finalJson = $captured | ConvertTo-Json -Depth 30 -Compress
            foreach ($variant in $variants) {
                $captured.StdOut | Should -Not -Match ([regex]::Escape($variant))
                $captured.StdErr | Should -Not -Match ([regex]::Escape($variant))
                $finalJson | Should -Not -Match ([regex]::Escape($variant))
            }
            $captured.StdOut | Should -Match '\*\*\*REDACTED\*\*\*'
            $captured.StdErr | Should -Match '\*\*\*REDACTED\*\*\*'
        }
    }

    It 'redacts every exact capability representation from public output, protocol errors, and machine diagnostics' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $capability = 'Az09-_Capability_Exact_1234567890XYZQ'
            $utf8Bytes = [Text.Encoding]::UTF8.GetBytes($capability)
            $utf8Base64 = [Convert]::ToBase64String($utf8Bytes)
            $variants = @(
                $capability
                $utf8Base64
                $utf8Base64.Replace('+', '-').Replace('/', '_')
                $utf8Base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
                [Convert]::ToHexString($utf8Bytes).ToLowerInvariant()
                [Convert]::ToHexString($utf8Bytes)
                [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($capability))
            ) | Select-Object -Unique
            $participant = Join-Path $Work 'emit-capability-events.ps1'
            $eventFile = Join-Path $Work 'capability-machine-events.jsonl'
            @'
$raw = $env:AICLI_LOCAL_GPU_BROKER_CAPABILITY
$utf8Bytes = [Text.Encoding]::UTF8.GetBytes($raw)
$utf8Base64 = [Convert]::ToBase64String($utf8Bytes)
$variants = @(
    $raw
    $utf8Base64
    $utf8Base64.Replace('+', '-').Replace('/', '_')
    $utf8Base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [Convert]::ToHexString($utf8Bytes).ToLowerInvariant()
    [Convert]::ToHexString($utf8Bytes)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($raw))
) | Select-Object -Unique
$public = $variants -join '|'
[Console]::Out.WriteLine((@{ type = 'turn.started' } | ConvertTo-Json -Compress))
[Console]::Out.WriteLine((@{ type = 'item.updated'; item = @{ id = 'message-1'; type = 'agent_message'; text = $public } } | ConvertTo-Json -Depth 10 -Compress))
[Console]::Out.WriteLine((@{ type = 'item.completed'; item = @{ id = 'message-1'; type = 'agent_message'; text = $public } } | ConvertTo-Json -Depth 10 -Compress))
[Console]::Out.WriteLine((@{ type = 'turn.completed'; usage = @{ input_tokens = 1; cached_input_tokens = 0; output_tokens = 1; current_context_tokens = 2; context_window_tokens = 262144 } } | ConvertTo-Json -Depth 10 -Compress))
'@ | Set-Content -LiteralPath $participant -Encoding utf8

            $captured = Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $participant) `
                -EnvironmentDelta @{ AICLI_LOCAL_GPU_BROKER_CAPABILITY = $capability } `
                -SecretValues @($capability) -EventProtocol codex-jsonl `
                -MachineEventFile $eventFile -WritableWorkspace $Work `
                -CloseStdIn -TimeoutMs 5000

            $allPublic = @(
                $captured | ConvertTo-Json -Depth 30 -Compress
                Get-Content -LiteralPath $eventFile -Raw -Encoding utf8
            ) -join "`n"
            foreach ($variant in $variants) {
                $allPublic | Should -Not -Match ([regex]::Escape($variant))
            }
            $allPublic | Should -Match '\*\*\*REDACTED\*\*\*'

            $protocolParticipant = Join-Path $Work 'emit-capability-protocol-error.ps1'
            @'
$raw = $env:AICLI_LOCAL_GPU_BROKER_CAPABILITY
$utf8Bytes = [Text.Encoding]::UTF8.GetBytes($raw)
$utf8Base64 = [Convert]::ToBase64String($utf8Bytes)
$variants = @(
    $raw
    $utf8Base64
    $utf8Base64.Replace('+', '-').Replace('/', '_')
    $utf8Base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [Convert]::ToHexString($utf8Bytes).ToLowerInvariant()
    [Convert]::ToHexString($utf8Bytes)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($raw))
) | Select-Object -Unique
[Console]::Out.WriteLine((@{ type = ($variants -join '.') } | ConvertTo-Json -Compress))
'@ | Set-Content -LiteralPath $protocolParticipant -Encoding utf8
            $failed = Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $protocolParticipant) `
                -EnvironmentDelta @{ AICLI_LOCAL_GPU_BROKER_CAPABILITY = $capability } `
                -SecretValues @($capability) -EventProtocol codex-jsonl `
                -CloseStdIn -TimeoutMs 5000
            $failed.ExitCode | Should -Be 74
            $failedJson = $failed | ConvertTo-Json -Depth 30 -Compress
            foreach ($variant in $variants) {
                $failed.StdErr | Should -Not -Match ([regex]::Escape($variant))
                $failedJson | Should -Not -Match ([regex]::Escape($variant))
            }
        }
    }

    It 'extracts the frozen Toolkit runtime identity from a fake Codex JSONL process' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $participant = Join-Path $Work 'fake-runtime-identity.ps1'
            @'
[Console]::Out.WriteLine('{"type":"runtime.identity","model":"qwen-main-v1","model_provider":"aicli_ollama_main","cli_version":"0.147.0","permission":{"approval_policy":"never","requested_policy":"workspace-write","sandbox_boundary":"outer-codex","sandbox_type":"externalSandbox","permission_profile":":workspace-write"}}')
[Console]::Out.WriteLine('{"type":"turn.started"}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"STATIC_OK"}}')
[Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"current_context_tokens":2,"context_window_tokens":262144}}')
'@ | Set-Content -LiteralPath $participant -Encoding utf8

            $captured = Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $participant) `
                -EventProtocol codex-jsonl -CloseStdIn -TimeoutMs 5000

            $captured.ExitCode | Should -Be 0
            $captured.RuntimeIdentity.model | Should -BeExactly 'qwen-main-v1'
            $captured.RuntimeIdentity.model_provider | Should -BeExactly 'aicli_ollama_main'
            $captured.RuntimeIdentity.cli_version | Should -BeExactly '0.147.0'
            $captured.RuntimeIdentity.permission.permission_profile |
                Should -BeExactly ':workspace-write'
        }
    }
}

Describe 'LocalGpuBroker trusted app-server runtime identity' {
    It 'emits a canonical identity only after an exact actual thread/start model and provider match' {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $script:BrokerSessionRepoRoot
        } {
            $fakeServer = Join-Path $Work 'fake-identity-app-server.ps1'
            $bridgeConfig = Join-Path $Work 'identity-app-server-bridge.json'
            @'
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $message = $line | ConvertFrom-Json -AsHashtable -Depth 100
    switch ([string]$message.method) {
        'initialize' { [Console]::Out.WriteLine('{"id":1,"result":{}}') }
        'initialized' {}
        'thread/start' {
            if ([string]$message.params.model -ne 'qwen-main-v1') {
                [Console]::Out.WriteLine('{"id":2,"error":{"code":-32602,"message":"model was not injected"}}')
                break
            }
            [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"019f98ff-110f-7390-8d7b-d85d70bba89f","cliVersion":"0.147.0"},"model":"qwen-main-v1","modelProvider":"aicli_ollama_main"}}')
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"thread/tokenUsage/updated","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","tokenUsage":{"last":{"inputTokens":1,"cachedInputTokens":0,"outputTokens":1,"totalTokens":2},"modelContextWindow":262144}}}')
            [Console]::Out.WriteLine('{"method":"item/started","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":""}}}')
            [Console]::Out.WriteLine('{"method":"item/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turnId":"019f98ff-110f-7390-8d7b-d85d70bba890","item":{"id":"message-1","type":"agentMessage","text":"STATIC_IDENTITY_OK"}}}')
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
                sandboxBoundary = 'outer-codex'
                sandboxPolicy = 'workspace-write'
                expectedModel = 'qwen-main-v1'
                expectedModelProvider = 'aicli_ollama_main'
                requireRuntimeIdentity = $true
                minimumCliVersion = '0.147.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot `
                'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $captured = Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'STATIC TASK' `
                -EventProtocol codex-app-server -CloseStdIn -TimeoutMs 5000 `
                -RequireRuntimeIdentity `
                -ExpectedRuntimeModel 'qwen-main-v1' `
                -ExpectedRuntimeModelProvider 'aicli_ollama_main'

            $captured.ExitCode | Should -Be 0
            $captured.RuntimeIdentity.model | Should -BeExactly 'qwen-main-v1'
            $captured.RuntimeIdentity.model_provider |
                Should -BeExactly 'aicli_ollama_main'
            $captured.RuntimeIdentity.cli_version | Should -BeExactly '0.147.0'
            $captured.StdOut | Should -Match 'STATIC_IDENTITY_OK'
        }
    }

    It 'fails before turn/start when actual thread/start identity is <Case>' -ForEach @(
        @{ Case = 'missing'; ActualProvider = $null; ExpectedCode = 'codex_appserver.runtime_identity_missing' }
        @{ Case = 'mismatched'; ActualProvider = 'wrong_provider'; ExpectedCode = 'codex_appserver.runtime_identity_mismatch' }
    ) {
        InModuleScope AiCliProfileManager -Parameters @{
            Work = $TestDrive
            RepoRoot = $script:BrokerSessionRepoRoot
            Case = $Case
            ActualProvider = $ActualProvider
            ExpectedCode = $ExpectedCode
        } {
            $fakeServer = Join-Path $Work "fake-$Case-identity-app-server.ps1"
            $bridgeConfig = Join-Path $Work "$Case-identity-app-server-bridge.json"
            $methodLog = Join-Path $Work "$Case-identity-methods.log"
            $escapedLog = $methodLog.Replace("'", "''")
            $providerStatement = if ($null -eq $ActualProvider) {
                ''
            } else {
                "`$result.modelProvider = '$ActualProvider'"
            }
            @"
while (`$null -ne (`$line = [Console]::In.ReadLine())) {
    `$message = `$line | ConvertFrom-Json -AsHashtable -Depth 100
    [IO.File]::AppendAllText('$escapedLog', ([string]`$message.method + "``n"))
    switch ([string]`$message.method) {
        'initialize' { [Console]::Out.WriteLine('{"id":1,"result":{}}') }
        'initialized' {}
        'thread/start' {
            `$result = [ordered]@{
                thread = [ordered]@{
                    id = '019f98ff-110f-7390-8d7b-d85d70bba89f'
                    cliVersion = '0.147.0'
                }
                model = 'qwen-main-v1'
            }
            $providerStatement
            [Console]::Out.WriteLine((@{ id = 2; result = `$result } | ConvertTo-Json -Depth 10 -Compress))
        }
        'turn/start' {
            [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"inProgress"}}}')
            [Console]::Out.WriteLine('{"method":"turn/completed","params":{"threadId":"019f98ff-110f-7390-8d7b-d85d70bba89f","turn":{"id":"019f98ff-110f-7390-8d7b-d85d70bba890","items":[],"status":"completed"}}}')
        }
    }
    [Console]::Out.Flush()
}
"@ | Set-Content -LiteralPath $fakeServer -Encoding utf8
            $config = [ordered]@{
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @('-NoProfile', '-File', $fakeServer)
                workingDirectory = $Work
                sandboxBoundary = 'outer-codex'
                sandboxPolicy = 'workspace-write'
                expectedModel = 'qwen-main-v1'
                expectedModelProvider = 'aicli_ollama_main'
                requireRuntimeIdentity = $true
                minimumCliVersion = '0.147.0'
            }
            [IO.File]::WriteAllText(
                $bridgeConfig,
                ($config | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $bridge = Join-Path $RepoRoot `
                'src\AiCliProfileManager\Support\CodexAppServerBridge.ps1'
            $captured = Invoke-AiCliChildCapture `
                -FileName (Get-Command pwsh.exe).Source `
                -ArgumentList @('-NoProfile', '-File', $bridge, '-ConfigPath', $bridgeConfig) `
                -WorkingDirectory $Work -StdInText 'STATIC TASK' `
                -EventProtocol codex-app-server -CloseStdIn -TimeoutMs 5000 `
                -RequireRuntimeIdentity `
                -ExpectedRuntimeModel 'qwen-main-v1' `
                -ExpectedRuntimeModelProvider 'aicli_ollama_main'

            $captured.ExitCode | Should -Be 74
            $captured.ErrorCode | Should -BeExactly $ExpectedCode
            @(Get-Content -LiteralPath $methodLog -ErrorAction SilentlyContinue) |
                Should -Not -Contain 'turn/start'
            $captured.RuntimeIdentity | Should -BeNullOrEmpty
        }
    }

    It 'injects the trusted local model and provider expectations into the app-server bridge config' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $package = Join-Path $Work 'tool\node_modules\@openai\codex'
            $entry = Join-Path $package 'bin\codex.js'
            $native = Join-Path $package (
                'node_modules\@openai\codex-win32-x64\' +
                'vendor\x86_64-pc-windows-msvc\bin\codex.exe'
            )
            New-Item -ItemType Directory -Path (
                Split-Path -Parent $entry
            ), (Split-Path -Parent $native) -Force | Out-Null
            Set-Content -LiteralPath $entry -Value '// stub' -Encoding ascii
            Set-Content -LiteralPath $native -Value 'native stub' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $package 'package.json') `
                -Value '{}' -Encoding ascii
            $plan = [pscustomobject]@{
                engine = 'codex'
                fileName = (Get-Command pwsh.exe).Source
                argumentList = @(
                    $entry, '-c', 'model="qwen-main-v1"',
                    'exec', '--json', '-'
                )
                workingDirectory = $Work
                environmentDelta = @{}
                model = 'qwen-main-v1'
                modelProvider = 'aicli_ollama_main'
                machineRuntime = [ordered]@{
                    kind = 'codex'; configFiles = @()
                    sandboxBoundary = 'outer-codex'
                    localGpuBrokerSession = [ordered]@{
                        contractVersion = 1
                        requiredForMachineRun = $true
                        managementOrigin = 'http://127.0.0.1:32100'
                    }
                }
            }

            $runtime = Initialize-AiCliMachineRuntime -Plan $plan `
                -StdInText 'STATIC TASK' -Policy workspace-write
            try {
                $bridgeConfig = Get-Content -LiteralPath $runtime.ArgumentList[-1] `
                    -Raw -Encoding utf8 | ConvertFrom-Json
                $bridgeConfig.requireRuntimeIdentity | Should -BeTrue
                $bridgeConfig.expectedModel | Should -BeExactly 'qwen-main-v1'
                $bridgeConfig.expectedModelProvider |
                    Should -BeExactly 'aicli_ollama_main'
                $bridgeConfig.minimumCliVersion | Should -BeExactly '0.147.0'
            } finally {
                Remove-AiCliMachineRuntime -RuntimePath $runtime.RuntimePath `
                    -Workspace $Work
            }
        }
    }
}

Describe 'LocalGpuBroker machine-run timeout ordering' {
    It 'routes the static Toolkit ABI without enabling step or tool budgets' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            Mock Invoke-AiCliProfileCapture {
                [pscustomobject]@{
                    profileId = $ProfileId; engine = 'codex'; model = 'qwen-main-v1'
                    exitCode = 0; stdout = ''; stderr = ''; timedOut = $false
                    durationMs = 1; outputTruncated = $false; usage = @{}
                }
            }
            $eventFile = Join-Path $Work 'toolkit-events.jsonl'
            $oldOut = [Console]::Out
            $writer = [IO.StringWriter]::new()
            try {
                [Console]::SetOut($writer)
                $code = Invoke-AiCliRouter -StdInText 'STATIC TASK' -Tokens @(
                    'run', 'codex-ollama-main', '--project', $Work,
                    '--stdin', '--json', '--sandbox-policy', 'workspace-write',
                    '--max-output-chars', '1000000', '--authority-prelude-stdout',
                    '--timeout-seconds', '7200', '--watchdog-only',
                    '--event-file', $eventFile, '--', 'exec', '--json', '-'
                )
            } finally {
                [Console]::SetOut($oldOut)
            }

            $code | Should -Be 0
            Should -Invoke Invoke-AiCliProfileCapture -Times 1 -Exactly `
                -ParameterFilter {
                    $ProfileId -eq 'codex-ollama-main' -and
                    $StdInText -eq 'STATIC TASK' -and
                    $TimeoutMs -eq 7200000 -and
                    $MaxCaptureChars -eq 1000000 -and
                    $SandboxPolicy -eq 'workspace-write' -and
                    $WatchdogOnly -and $AuthorityPreludeStdout -and
                    -not $EnforceStepLimit -and -not $EnforceToolCallLimit -and
                    $MachineEventFile -eq $eventFile -and
                    @($NativeArgs) -join "`n" -eq "exec`n--json`n-"
                }
        }
    }

    It 'flushes the prelude before participant start and closes timeout before tree kill' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:Order = [Collections.Generic.List[string]]::new()
            $capability = 'CAPABILITY_MACHINE_CANARY_1234567890'
            $session = [ordered]@{
                LeaseId = '3' * 32; Capability = $capability
                BrokerInstanceId = '4' * 32; BindingSha256 = 'sha256:' + ('5' * 64)
                ManagementOrigin = 'http://127.0.0.1:32100'; OwnerPid = [Environment]::ProcessId
                OwnerProcessCreationTokenSha256 = 'sha256:' + ('c' * 64)
                CloseRequested = $false; CloseReason = $null; CloseResponse = $null
                BindingSource = [ordered]@{
                    schema = 'aicli.local-gpu-broker-binding.v1'
                    job_id = 'sha256:' + ('7' * 64); execution_id = '8' * 32
                    request_sha256 = 'sha256:' + ('9' * 64)
                    profile_id = 'codex-ollama-main'
                    profile_fingerprint = 'sha256:' + ('a' * 64)
                    model = 'qwen-main-v1'; model_provider = 'aicli_ollama_main'
                    registry_source = [ordered]@{
                        schema = 'aicli.profile-registry-source.v1'; kind = 'bundled-provider-manifest'
                        id = 'codex-ollama-main'; relative_path = 'providers/codex-ollama-main.json'
                        sha256 = 'sha256:' + ('b' * 64)
                    }
                }
                BindingObservation = [ordered]@{
                    schema = 'aicli.local-gpu-broker-binding-observation.v1'
                    broker_instance_id = '4' * 32; lease_id = '3' * 32
                    owner_pid = [Environment]::ProcessId
                    binding_sha256 = 'sha256:' + ('5' * 64)
                    binding_schema = 'aicli.local-gpu-broker-binding.v1'
                    job_id = 'sha256:' + ('7' * 64); execution_id = '8' * 32
                    request_sha256 = 'sha256:' + ('9' * 64)
                    profile_id = 'codex-ollama-main'
                    profile_fingerprint = 'sha256:' + ('a' * 64)
                    model = 'qwen-main-v1'; model_provider = 'aicli_ollama_main'
                    registry_source = [ordered]@{
                        schema = 'aicli.profile-registry-source.v1'; kind = 'bundled-provider-manifest'
                        id = 'codex-ollama-main'; relative_path = 'providers/codex-ollama-main.json'
                        sha256 = 'sha256:' + ('b' * 64)
                    }
                    observation_sha256 = 'sha256:' + ('d' * 64)
                }
            }
            $observationSource = [ordered]@{}
            foreach ($key in $session.BindingObservation.Keys | Where-Object {
                $_ -cne 'observation_sha256'
            }) {
                $observationSource[$key] = $session.BindingObservation[$key]
            }
            $session.BindingObservation.observation_sha256 = `
                Get-AiCliLocalGpuBrokerTextSha256 `
                    -Text ($observationSource | ConvertTo-Json -Depth 20 -Compress)
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine = 'codex'; profileId = 'codex-ollama-main'
                    profileFingerprint = ('a' * 64); fileName = 'C:\fake\codex.exe'
                    argumentList = @('exec','--json','-'); workingDirectory = $Work
                    model = 'qwen-main-v1'; modelProvider = 'aicli_ollama_main'
                    endpoint = 'http://127.0.0.1:32100/v1'; wire = 'responses'
                    environmentDelta = @{}; removeEnvironment = @()
                    machineRuntime = [ordered]@{ localGpuBrokerSession = [ordered]@{
                        contractVersion = 1; requiredForMachineRun = $true
                        managementOrigin = 'http://127.0.0.1:32100'
                    }}
                }
            }
            Mock Initialize-AiCliMachineRuntime {
                [pscustomobject]@{
                    RuntimePath = (Join-Path $Work '.runtime'); FileName = 'C:\fake\codex.exe'
                    ArgumentList = @('exec','--json','-'); EnvironmentDelta = @{}
                    StdInText = 'TASK'; UseOuterSandbox = $true; EventProtocol = 'codex-jsonl'
                    AdditionalReadRoots = @(); PrivateTaskPipeName = $null
                }
            }
            Mock Open-AiCliLocalGpuBrokerSession { return $session }
            Mock Write-AiCliLocalGpuBrokerAuthorityPrelude { $script:Order.Add('prelude') | Out-Null }
            Mock New-AiCliLocalGpuBrokerBeforeStopAction {
                $state = $Session; $order = $script:Order
                return { param($Reason, $Process) $order.Add('close') | Out-Null; $state.CloseRequested = $true; $state.CloseReason = $Reason }.GetNewClosure()
            }
            Mock Invoke-AiCliChildCapture {
                $script:Order.Add('participant-start') | Out-Null
                & $BeforeProcessTreeStop 'timeout' $null
                $script:Order.Add('tree-kill') | Out-Null
                [pscustomobject]@{
                    ExitCode = 69; StdOut = ''; StdErr = 'timeout'; TimedOut = $true
                    DurationMs = 10; OutputTruncated = $false; StepCount = 0; ToolCallCount = 0
                    EventsSeen = 0; EventProtocol = 'codex-jsonl'; LimitHit = 'timeout'
                    LimitsHard = $true; CleanupConfirmed = $true
                    CleanupMethod = 'job-object-tree-confirmed'; Usage = @{}
                    RuntimeIdentity = [ordered]@{
                        model = 'qwen-main-v1'; model_provider = 'aicli_ollama_main'
                        cli_version = '0.147.0'; permission = [ordered]@{
                            approval_policy = 'never'; requested_policy = 'workspace-write'
                            sandbox_boundary = 'outer-codex'; sandbox_type = 'externalSandbox'
                            permission_profile = ':workspace-write'
                        }
                    }
                }
            }
            Mock Complete-AiCliLocalGpuBrokerSession {
                $script:Order.Add('terminal') | Out-Null
                [pscustomobject][ordered]@{
                    schema = 'aicli.local-gpu-broker-session-receipt.v1'; verified = $true
                    broker_schema = 'pcconfig.local-gpu-broker.ollama-session.v1'
                    broker_instance_id = '4' * 32; lease_id = '3' * 32
                    owner = 'aicli-machine-run'; owner_pid = [Environment]::ProcessId
                    binding_sha256 = 'sha256:' + ('5' * 64); state = 'released'
                    active_requests = 0; accepted_requests = 0; completed_requests = 0
                    accepted_model_requests = 0; completed_model_requests = 0
                    request_chain_sha256 = 'sha256:' + ('6' * 64)
                    release_reason = [string]$Reason; close_reason_requested = [string]$Reason
                }
            }
            Mock Remove-AiCliMachineRuntime {}

            $result = Invoke-AiCliProfileCapture -ProfileId 'codex-ollama-main' `
                -ProjectPath $Work -StdInText 'TASK' -TimeoutMs 7200000 `
                -SandboxPolicy workspace-write -WatchdogOnly -AuthorityPreludeStdout

            @($script:Order) | Should -Be @(
                'prelude', 'participant-start', 'close', 'tree-kill', 'terminal'
            )
            $result.localGpuBrokerSession.release_reason | Should -Be 'timeout'
            $result.budgetMode | Should -Be 'watchdog-only'
            Should -Invoke Invoke-AiCliChildCapture -Times 1 -Exactly `
                -ParameterFilter {
                    $RequireRuntimeIdentity -and
                    $ExpectedRuntimeModel -ceq 'qwen-main-v1' -and
                    $ExpectedRuntimeModelProvider -ceq 'aicli_ollama_main'
                }
            ($result | ConvertTo-Json -Depth 30 -Compress) |
                Should -Not -Match ([regex]::Escape($capability))
        }
    }

    It 'redacts exact close-failure variants from Router JSON and still clears session state and runtime' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $script:FinalizationOrder = [Collections.Generic.List[string]]::new()
            $capability = 'Az09-_Capability_Exact_1234567890XYZQ' + [char]0x0F80
            $utf8Bytes = [Text.Encoding]::UTF8.GetBytes($capability)
            $utf8Base64 = [Convert]::ToBase64String($utf8Bytes)
            $variants = @(
                $capability
                $utf8Base64
                $utf8Base64.Replace('+', '-').Replace('/', '_')
                $utf8Base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
                [Convert]::ToHexString($utf8Bytes).ToLowerInvariant()
                [Convert]::ToHexString($utf8Bytes)
                [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($capability))
            ) | Select-Object -Unique
            $variants | Should -HaveCount 7
            $script:CloseFailureMessage = 'close-failed|' + ($variants -join '|')
            $session = [ordered]@{
                LeaseId = '3' * 32
                Capability = $capability
                CloseRequested = $false
                CloseReason = $null
                BindingObservation = [ordered]@{}
            }
            Mock Build-AiCliLaunchPlan {
                [pscustomobject]@{
                    engine = 'codex'; profileId = 'codex-ollama-main'
                    profileFingerprint = ('a' * 64); fileName = 'C:\fake\codex.exe'
                    argumentList = @('exec','--json','-'); workingDirectory = $Work
                    model = 'qwen-main-v1'; modelProvider = 'aicli_ollama_main'
                    endpoint = 'http://127.0.0.1:32100/v1'; wire = 'responses'
                    environmentDelta = @{}; removeEnvironment = @()
                    machineRuntime = [ordered]@{ localGpuBrokerSession = [ordered]@{
                        contractVersion = 1; requiredForMachineRun = $true
                        managementOrigin = 'http://127.0.0.1:32100'
                    }}
                }
            }
            Mock Initialize-AiCliMachineRuntime {
                [pscustomobject]@{
                    RuntimePath = (Join-Path $Work '.runtime'); FileName = 'C:\fake\codex.exe'
                    ArgumentList = @('exec','--json','-')
                    EnvironmentDelta = @{ AICLI_TEST = 'bound' }
                    StdInText = 'TASK'; UseOuterSandbox = $true
                    EventProtocol = 'codex-jsonl'; AdditionalReadRoots = @()
                    PrivateTaskPipeName = $null
                }
            }
            Mock Open-AiCliLocalGpuBrokerSession { return $session }
            Mock Assert-AiCliLocalGpuBrokerBindingObservation {}
            Mock Set-AiCliLocalGpuBrokerSessionEnvironment {}
            Mock New-AiCliLocalGpuBrokerBeforeStopAction { return $null }
            Mock Invoke-AiCliChildCapture {
                [pscustomobject]@{
                    ExitCode = 0; StdOut = ''; StdErr = ''; TimedOut = $false
                    DurationMs = 10; OutputTruncated = $false; StepCount = 1
                    ToolCallCount = 0; EventsSeen = 2; EventProtocol = 'codex-jsonl'
                    LimitHit = $null; LimitsHard = $true; CleanupConfirmed = $true
                    CleanupMethod = 'normal'; Usage = @{}
                    RuntimeIdentity = [ordered]@{
                        model = 'qwen-main-v1'; model_provider = 'aicli_ollama_main'
                        cli_version = '0.147.0'; permission = [ordered]@{
                            approval_policy = 'never'; requested_policy = 'workspace-write'
                            sandbox_boundary = 'outer-codex'; sandbox_type = 'externalSandbox'
                            permission_profile = ':workspace-write'
                        }
                    }
                }
            }
            Mock Complete-AiCliLocalGpuBrokerSession {
                $script:FinalizationOrder.Add('complete') | Out-Null
                throw [InvalidOperationException]::new($script:CloseFailureMessage)
            }
            Mock Clear-AiCliLocalGpuBrokerSessionEnvironment {
                $script:FinalizationOrder.Add('clear') | Out-Null
            }
            Mock Remove-AiCliMachineRuntime {
                $script:FinalizationOrder.Add('runtime-remove') | Out-Null
            }

            $oldOut = [Console]::Out
            $writer = [IO.StringWriter]::new()
            try {
                [Console]::SetOut($writer)
                $code = Invoke-AiCliRouter -StdInText 'TASK' -Tokens @(
                    'run', 'codex-ollama-main', '--project', $Work,
                    '--stdin', '--json', '--sandbox-policy', 'workspace-write',
                    '--timeout-seconds', '7200', '--watchdog-only'
                )
            } finally {
                [Console]::SetOut($oldOut)
            }

            $code | Should -Be (Get-AiCliExitCode Unavailable)
            @($script:FinalizationOrder) | Should -Be @(
                'complete', 'clear', 'runtime-remove'
            )
            Should -Invoke Clear-AiCliLocalGpuBrokerSessionEnvironment `
                -Times 1 -Exactly
            Should -Invoke Remove-AiCliMachineRuntime -Times 1 -Exactly
            $json = $writer.ToString()
            $payload = $json | ConvertFrom-Json -Depth 30
            $payload.overallStatus | Should -Be '不可用'
            $payload.error.category | Should -BeExactly 'invalid_run'
            $payload.error.summary | Should -Match '\*\*\*REDACTED\*\*\*'
            foreach ($variant in $variants) {
                $json | Should -Not -Match ([regex]::Escape($variant))
            }
        }
    }
}
