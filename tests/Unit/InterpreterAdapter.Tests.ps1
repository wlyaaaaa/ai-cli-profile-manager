#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

$script:InterpreterTestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Get-Module AiCliProfileManager -All | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $script:InterpreterTestRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force

Describe 'Rust Open Interpreter adapter' {
    InModuleScope AiCliProfileManager {
        It 'derives the official path from the supported LocalAppData folder name' {
            Mock Get-AiCliKnownFolder { 'C:\Users\tester\AppData\Local' } -ParameterFilter { $Name -eq 'LocalAppData' }

            Get-AiCliInterpreterPreferredPath | Should -Be 'C:\Users\tester\AppData\Local\Programs\Open Interpreter\bin\interpreter.exe'
            Should -Invoke Get-AiCliKnownFolder -Times 1 -ParameterFilter { $Name -eq 'LocalAppData' }
        }

        It 'prefers the official Rust install path' {
            Mock Get-AiCliInterpreterPreferredPath {
                'C:\Users\tester\AppData\Local\Programs\Open Interpreter\bin\interpreter.exe'
            }
            Mock Test-Path { $true } -ParameterFilter {
                $LiteralPath -eq 'C:\Users\tester\AppData\Local\Programs\Open Interpreter\bin\interpreter.exe'
            }
            Mock Get-AiCliInterpreterVersionInfo {
                [pscustomobject]@{ Family = 'rust'; Version = '0.0.21'; Supported = $true; Raw = 'interpreter 0.0.21' }
            }
            Mock Resolve-AiCliLaunchExecutable { $null }

            $resolved = Resolve-AiCliInterpreterExecutable

            $resolved.FileName | Should -Be 'C:\Users\tester\AppData\Local\Programs\Open Interpreter\bin\interpreter.exe'
            $resolved.Kind | Should -Be 'official-rust'
            $resolved.Family | Should -Be 'rust'
        }

        It 'rejects the legacy Python CLI' {
            Mock Get-AiCliInterpreterPreferredPath { 'C:\missing\interpreter.exe' }
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'C:\missing\interpreter.exe' }
            Mock Resolve-AiCliLaunchExecutable {
                [pscustomobject]@{ FileName = 'C:\Python311\Scripts\interpreter.exe'; PrefixArgs = @(); Kind = 'path' }
            }
            Mock Get-AiCliInterpreterVersionInfo {
                [pscustomobject]@{
                    Family = 'legacy-python'; Version = '0.4.3'; Supported = $false
                    Raw = 'Open Interpreter 0.4.3 Developer Preview'
                }
            }

            { Resolve-AiCliInterpreterExecutable } | Should -Throw '*legacy Python*'
        }

        It 'builds Qwen Responses config without putting the secret in argv' {
            Mock Resolve-AiCliInterpreterExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\Open Interpreter\bin\interpreter.exe'
                    PrefixArgs = @(); Kind = 'official-rust'; Family = 'rust'; Version = '0.0.21'
                }
            }
            Mock Get-AiCliSecret { 'CANARY_OI_SECRET_123456' }
            $profile = [ordered]@{
                id = 'oi-qwen-paygo'; displayName = 'Qwen'; engine = 'interpreter'; provider = 'qwen'
                endpoint = 'https://dashscope.aliyuncs.com/compatible-mode/v1'
                wireApi = 'responses'; interpreterProviderId = 'aicli_qwen'
                models = [ordered]@{ primary = 'qwen3.7-max-2026-06-08' }
                requiresSecret = $true; secretConfigured = $true; secretRef = 'secret-ref'
            }

            $plan = Build-AiCliInterpreterLaunchPlan -MergedProfile $profile -ProjectPath 'C:\work'
            $argv = $plan.argumentList -join ' '

            $argv | Should -Not -Match 'CANARY_OI_SECRET_123456'
            $argv | Should -Not -Match '(?i)api[_-]?key'
            $argv | Should -Match 'model_provider="aicli_qwen"'
            $argv | Should -Match 'wire_api="responses"'
            $argv | Should -Match 'env_key="AICLI_OI_PROVIDER_KEY"'
            $argv | Should -Match 'shell_environment_policy\.exclude=\["AICLI_OI_PROVIDER_KEY"\]'
            $plan.environmentDelta.AICLI_OI_PROVIDER_KEY | Should -Be 'CANARY_OI_SECRET_123456'
            $plan.nonInteractiveArgumentList[0] | Should -Be 'exec'
            ($plan.nonInteractiveArgumentList -join ' ') | Should -Not -Match 'CANARY_OI_SECRET_123456'
        }

        It 'uses chat wire format for DeepSeek' {
            Mock Resolve-AiCliInterpreterExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\Open Interpreter\bin\interpreter.exe'
                    PrefixArgs = @(); Kind = 'official-rust'; Family = 'rust'; Version = '0.0.21'
                }
            }
            Mock Get-AiCliSecret { 'CANARY_OI_SECRET_654321' }
            $profile = [ordered]@{
                id = 'oi-deepseek'; displayName = 'DeepSeek'; engine = 'interpreter'; provider = 'deepseek'
                endpoint = 'https://api.deepseek.com/v1'; wireApi = 'chat'
                interpreterProviderId = 'aicli_deepseek'
                models = [ordered]@{ primary = 'deepseek-v4-pro' }
                requiresSecret = $true; secretConfigured = $true; secretRef = 'secret-ref'
            }

            $plan = Build-AiCliInterpreterLaunchPlan -MergedProfile $profile -ProjectPath 'C:\work'
            $argv = $plan.argumentList -join ' '

            $argv | Should -Match 'wire_api="chat"'
            $argv | Should -Match 'model="deepseek-v4-pro"'
            $argv | Should -Not -Match 'CANARY_OI_SECRET_654321'
        }

        It 'uses public Ollama defaults without a provider secret' {
            Mock Resolve-AiCliInterpreterExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\Open Interpreter\bin\interpreter.exe'
                    PrefixArgs = @(); Kind = 'official-rust'; Family = 'rust'; Version = '0.0.21'
                }
            }
            $profile = [ordered]@{
                id = 'oi-ollama'; displayName = 'Ollama'; engine = 'interpreter'; provider = 'ollama'
                endpoint = 'http://127.0.0.1:11434/v1'; wireApi = 'responses'
                interpreterProviderId = 'aicli_ollama'
                models = [ordered]@{ primary = 'qwen3-coder:30b' }
                requiresSecret = $false
            }

            $plan = Build-AiCliInterpreterLaunchPlan -MergedProfile $profile -ProjectPath 'C:\work'
            $argv = $plan.argumentList -join ' '

            $argv | Should -Match '127\.0\.0\.1:11434/v1'
            $argv | Should -Match 'wire_api="responses"'
            $argv | Should -Match 'model="qwen3-coder:30b"'
            $argv | Should -Not -Match 'env_key='
            $plan.environmentDelta.ContainsKey('AICLI_OI_PROVIDER_KEY') | Should -BeFalse
        }

        It 'blocks legacy auto-run and provider override flags' {
            { Assert-AiCliInterpreterNativeArgs -NativeArgList @('--auto_run') } | Should -Throw
            { Assert-AiCliInterpreterNativeArgs -NativeArgList @('--api_key', 'x') } | Should -Throw
            { Assert-AiCliInterpreterNativeArgs -NativeArgList @('-c', 'model_provider="other"') } | Should -Throw
        }

        It 'reports the supported Rust family and uses the real update command' {
            Mock Resolve-AiCliInterpreterExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\Open Interpreter\bin\interpreter.exe'
                    PrefixArgs = @(); Kind = 'official-rust'; Family = 'rust'; Version = '0.0.21'
                }
            }
            Mock Write-Host {}

            $info = Get-AiCliInstallSource -Component interpreter
            $info.found | Should -BeTrue
            $info.family | Should -Be 'rust'
            $info.version | Should -Be 'interpreter 0.0.21'

            Invoke-AiCliUpdateGuide -Component interpreter | Should -Be (Get-AiCliExitCode Success)
            Should -Invoke Write-Host -ParameterFilter { $Object -eq '  interpreter update' } -Times 1
            Should -Invoke Write-Host -ParameterFilter { [string]$Object -match 'interpreter update (status|now)' } -Times 0
        }

        It 'redacts the dedicated provider key used by the native view' {
            $safe = Protect-AiCliObject @{ AICLI_OI_PROVIDER_KEY = 'CANARY_OI_NATIVE_SECRET_123456' }

            $safe.AICLI_OI_PROVIDER_KEY | Should -Be '***REDACTED***'
            ($safe | ConvertTo-Json -Compress) | Should -Not -Match 'CANARY_OI_NATIVE_SECRET_123456'
        }
    }
}

Describe 'Rust Open Interpreter manifests' {
    It 'declares the expected wire APIs and public Ollama endpoint' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $qwen = Get-Content -LiteralPath (Join-Path $repoRoot 'data\providers\oi-qwen-paygo.json') -Raw | ConvertFrom-Json
        $deepseek = Get-Content -LiteralPath (Join-Path $repoRoot 'data\providers\oi-deepseek.json') -Raw | ConvertFrom-Json
        $ollama = Get-Content -LiteralPath (Join-Path $repoRoot 'data\providers\oi-ollama.json') -Raw | ConvertFrom-Json

        $qwen.wireApi | Should -Be 'responses'
        $deepseek.wireApi | Should -Be 'chat'
        $ollama.wireApi | Should -Be 'responses'
        $ollama.endpoint | Should -Be 'http://127.0.0.1:11434/v1'
        $ollama.models.primary | Should -Be 'qwen3-coder:30b'
        @($qwen, $deepseek) | ForEach-Object { $_.auth.envKey | Should -Be 'AICLI_OI_PROVIDER_KEY' }
    }
}
