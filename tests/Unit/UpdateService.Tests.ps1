#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

$script:UpdateServiceTestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Get-Module AiCliProfileManager -All | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $script:UpdateServiceTestRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force

Describe 'Update source and stable-version checks' {
    InModuleScope AiCliProfileManager {
        It 'rejects a non-map source result instead of silently adapting it' {
            Mock Get-AiCliInstallSource { [pscustomobject]@{ found = $true; source = 'npm'; version = '0.150.1' } }
            { Invoke-AiCliUpdateCheck -Component codex -Json } | Should -Throw '*Install source must return a map*'
        }

        It 'recognizes the native Claude installer channel from its resolved path' {
            $resolved = [pscustomobject]@{
                FileName = 'C:\Users\tester\.local\bin\claude.exe'
                PrefixArgs = @()
                Kind = 'native'
            }

            Get-AiCliInstallChannel -Resolved $resolved | Should -Be 'native-installer'
        }

        It 'binds Codex harness source, native path, and version to one resolved npm runtime' {
            $entry = 'C:\Users\tester\AppData\Roaming\npm\node_modules\@openai\codex\bin\codex.js'
            $native = 'C:\Users\tester\AppData\Roaming\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\bin\codex.exe'
            Mock Resolve-AiCliLaunchExecutable {
                [pscustomobject]@{
                    FileName = 'C:\Program Files\nodejs\node.exe'
                    PrefixArgs = @($entry)
                    Kind = 'npm-node'
                }
            } -ParameterFilter { $Name -eq 'codex' -and $PreferNpmCodex }
            Mock Resolve-AiCliCodexNativeRuntimeFromEntry {
                [pscustomobject]@{ NativeExecutable = $native }
            } -ParameterFilter { $EntryPath -eq $entry }
            Mock Get-AiCliResolvedCliVersionEvidence {
                param($Resolved)
                [pscustomobject]@{
                    FileName = $Resolved.FileName
                    PrefixArgs = @($Resolved.PrefixArgs)
                    Kind = $Resolved.Kind
                    Version = 'codex-cli 0.149.1'
                }
            }
            Mock Find-AiCliCommandPath { throw 'bare PATH lookup must not be used for the update record' }

            $info = Get-AiCliInstallSource -Component codex

            $info.source | Should -Be 'npm'
            $info.runtimeRole | Should -Be 'aicli-codex-harness'
            $info.runtimeKind | Should -Be 'npm-native'
            $info.path | Should -Be $native
            $info.version | Should -Be 'codex-cli 0.149.1'
            Should -Invoke Resolve-AiCliCodexNativeRuntimeFromEntry -Times 1 -Exactly
            Should -Invoke Find-AiCliCommandPath -Times 0 -Exactly
        }

        It 'reports an available stable npm update instead of passing the local-only check' {
            Mock Get-AiCliInstallSource {
                [ordered]@{ found = $true; source = 'npm'; version = 'codex-cli 0.149.1'; path = 'C:\npm\codex.exe' }
            }
            Mock Invoke-RestMethod {
                [pscustomobject]@{ version = '0.150.0' }
            } -ParameterFilter { $Uri -eq 'https://registry.npmjs.org/@openai%2fcodex/latest' }
            $script:capturedUpdateResult = $null
            Mock Write-AiCliJson { param($Object) $script:capturedUpdateResult = $Object }

            $exit = Invoke-AiCliUpdateCheck -Component codex -Json
            $component = @($script:capturedUpdateResult.components)[0]

            $exit | Should -Be (Get-AiCliExitCode Limited)
            $script:capturedUpdateResult.overallStatus | Should -Be '可用但有限制'
            $component.latestVersion | Should -Be '0.150.0'
            $component.updateState | Should -Be 'update-available'
            $component.updateAvailable | Should -BeTrue
        }

        It 'reports an unavailable official metadata query as unknown rather than passing' {
            Mock Get-AiCliInstallSource {
                [ordered]@{ found = $true; source = 'npm'; version = 'codex-cli 0.149.1'; path = 'C:\npm\codex.exe' }
            }
            Mock Invoke-RestMethod { throw 'network unavailable' }
            $script:capturedUpdateResult = $null
            Mock Write-AiCliJson { param($Object) $script:capturedUpdateResult = $Object }

            $exit = Invoke-AiCliUpdateCheck -Component codex -Json
            $component = @($script:capturedUpdateResult.components)[0]

            $exit | Should -Be (Get-AiCliExitCode Limited)
            $script:capturedUpdateResult.overallStatus | Should -Be '可用但有限制'
            $component.updateState | Should -Be 'unknown'
            $component.updateAvailable | Should -BeNullOrEmpty
            $component.updateNote | Should -Match '不能判定是否最新'
        }

        It 'does not compare a prerelease runtime as though it were the stable channel' {
            Mock Get-AiCliInstallSource {
                [ordered]@{ found = $true; source = 'npm'; version = 'codex-cli 0.150.0-alpha.8'; path = 'C:\npm\codex.exe' }
            }
            Mock Invoke-RestMethod {
                [pscustomobject]@{ version = '0.149.1' }
            } -ParameterFilter { $Uri -eq 'https://registry.npmjs.org/@openai%2fcodex/latest' }
            $script:capturedUpdateResult = $null
            Mock Write-AiCliJson { param($Object) $script:capturedUpdateResult = $Object }

            $exit = Invoke-AiCliUpdateCheck -Component codex -Json
            $component = @($script:capturedUpdateResult.components)[0]

            $exit | Should -Be (Get-AiCliExitCode Limited)
            $component.updateState | Should -Be 'channel-different'
            $component.updateAvailable | Should -BeNullOrEmpty
            $component.updateNote | Should -Match '预发行版本'
        }

        It 'returns success only when the installed stable version equals official stable metadata' {
            Mock Get-AiCliInstallSource {
                [ordered]@{ found = $true; source = 'npm'; version = 'codex-cli 0.150.0'; path = 'C:\npm\codex.exe' }
            }
            Mock Invoke-RestMethod {
                [pscustomobject]@{ version = '0.150.0' }
            } -ParameterFilter { $Uri -eq 'https://registry.npmjs.org/@openai%2fcodex/latest' }
            $script:capturedUpdateResult = $null
            Mock Write-AiCliJson { param($Object) $script:capturedUpdateResult = $Object }

            $exit = Invoke-AiCliUpdateCheck -Component codex -Json
            $component = @($script:capturedUpdateResult.components)[0]

            $exit | Should -Be (Get-AiCliExitCode Success)
            $script:capturedUpdateResult.overallStatus | Should -Be '通过'
            $component.updateState | Should -Be 'current'
            $component.updateAvailable | Should -BeFalse
        }

        It 'reports a missing optional component as not installed without querying a different channel' {
            Mock Get-AiCliInstallSource {
                [ordered]@{ found = $false; source = 'missing'; version = 'n/a' }
            }
            Mock Invoke-RestMethod { throw 'not expected for a missing component' }
            $script:capturedUpdateResult = $null
            Mock Write-AiCliJson { param($Object) $script:capturedUpdateResult = $Object }

            $exit = Invoke-AiCliUpdateCheck -Component codex -Json
            $component = @($script:capturedUpdateResult.components)[0]

            $exit | Should -Be (Get-AiCliExitCode Success)
            $component.updateState | Should -Be 'not-installed'
            $component.updateAvailable | Should -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'treats malformed stable metadata as unknown rather than current' {
            Mock Get-AiCliInstallSource {
                [ordered]@{ found = $true; source = 'npm'; version = 'codex-cli 0.149.1'; path = 'C:\npm\codex.exe' }
            }
            Mock Invoke-RestMethod {
                [pscustomobject]@{ version = 'release-candidate' }
            } -ParameterFilter { $Uri -eq 'https://registry.npmjs.org/@openai%2fcodex/latest' }
            $script:capturedUpdateResult = $null
            Mock Write-AiCliJson { param($Object) $script:capturedUpdateResult = $Object }

            $exit = Invoke-AiCliUpdateCheck -Component codex -Json
            $component = @($script:capturedUpdateResult.components)[0]

            $exit | Should -Be (Get-AiCliExitCode Limited)
            $component.updateState | Should -Be 'unknown'
            $component.updateAvailable | Should -BeNullOrEmpty
        }

        It 'does not recommend a downgrade when the installed stable is higher than published metadata' {
            Mock Get-AiCliInstallSource {
                [ordered]@{ found = $true; source = 'npm'; version = 'codex-cli 0.151.0'; path = 'C:\npm\codex.exe' }
            }
            Mock Invoke-RestMethod {
                [pscustomobject]@{ version = '0.150.0' }
            } -ParameterFilter { $Uri -eq 'https://registry.npmjs.org/@openai%2fcodex/latest' }
            $script:capturedUpdateResult = $null
            Mock Write-AiCliJson { param($Object) $script:capturedUpdateResult = $Object }

            $exit = Invoke-AiCliUpdateCheck -Component codex -Json
            $component = @($script:capturedUpdateResult.components)[0]

            $exit | Should -Be (Get-AiCliExitCode Limited)
            $component.updateState | Should -Be 'channel-different'
            $component.updateAvailable | Should -BeNullOrEmpty
            $component.updateNote | Should -Match '高于'
        }

        It 'keeps a resolved runtime with no version evidence unknown' {
            $entry = 'C:\Users\tester\AppData\Roaming\npm\node_modules\@openai\codex\bin\codex.js'
            $native = 'C:\Users\tester\AppData\Roaming\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\bin\codex.exe'
            Mock Resolve-AiCliLaunchExecutable {
                [pscustomobject]@{ FileName = 'C:\Program Files\nodejs\node.exe'; PrefixArgs = @($entry); Kind = 'npm-node' }
            } -ParameterFilter { $Name -eq 'codex' -and $PreferNpmCodex }
            Mock Resolve-AiCliCodexNativeRuntimeFromEntry { [pscustomobject]@{ NativeExecutable = $native } }
            Mock Get-AiCliResolvedCliVersionEvidence { $null }

            $info = Get-AiCliInstallSource -Component codex

            $info.source | Should -Be 'npm'
            $info.path | Should -Be $native
            $info.version | Should -Be 'unknown'
            $info.note | Should -Match '无法取得'
        }

        It 'does not use npm metadata for a Claude native-installer channel' {
            Mock Invoke-RestMethod { throw 'npm metadata must not be queried for native installer' }

            $metadata = Get-AiCliOfficialStableMetadata -Component claude -Source native-installer

            $metadata.state | Should -Be 'unknown'
            $metadata.note | Should -Match '固定官方稳定版元数据'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'rejects draft or prerelease metadata even with a stable-looking version' -ForEach @(
            @{ Flag = 'prerelease' },
            @{ Flag = 'draft' }
        ) {
            param($Flag)
            $response = [ordered]@{ version = '0.150.0'; prerelease = $false; draft = $false }
            $response[$Flag] = $true
            Mock Invoke-RestMethod { [pscustomobject]$response }

            $metadata = Get-AiCliOfficialStableMetadata -Component codex -Source npm

            $metadata.state | Should -Be 'unknown'
            $metadata.note | Should -Match '草稿或预发行'
        }

        It 'accepts the official Rust Open Interpreter release only with a Windows x64 artifact' {
            Mock Invoke-RestMethod {
                [pscustomobject]@{
                    tag_name = 'rust-v0.0.40'; prerelease = $false; draft = $false
                    assets = @([pscustomobject]@{ name = 'open-interpreter-package-x86_64-pc-windows-msvc.tar.zst' })
                }
            } -ParameterFilter { $Uri -eq 'https://api.github.com/repos/openinterpreter/openinterpreter/releases/latest' }

            $metadata = Get-AiCliOfficialStableMetadata -Component interpreter -Source official-rust

            $metadata.state | Should -Be 'available'
            $metadata.latestVersion | Should -Be '0.0.40'
        }

        It 'leaves non-Rust or non-Windows Open Interpreter release metadata unknown' -ForEach @(
            @{ Tag = 'v0.4.3'; Assets = @([pscustomobject]@{ name = 'open-interpreter-package-x86_64-pc-windows-msvc.tar.gz' }) },
            @{ Tag = 'rust-v0.0.40'; Assets = @([pscustomobject]@{ name = 'open-interpreter-package-x86_64-unknown-linux-musl.tar.gz' }) }
        ) {
            param($Tag, $Assets)
            Mock Invoke-RestMethod {
                [pscustomobject]@{ tag_name = $Tag; prerelease = $false; draft = $false; assets = $Assets }
            } -ParameterFilter { $Uri -eq 'https://api.github.com/repos/openinterpreter/openinterpreter/releases/latest' }

            $metadata = Get-AiCliOfficialStableMetadata -Component interpreter -Source official-rust

            $metadata.state | Should -Be 'unknown'
            $metadata.note | Should -Match 'Rust Windows x64'
        }
    }
}
