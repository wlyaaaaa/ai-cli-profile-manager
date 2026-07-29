#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ChildEnvironmentRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module AiCliProfileManager -All |
        Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:ChildEnvironmentRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}

Describe 'Machine child environment isolation' {
    It 'uses a small parent allowlist and applies the explicit environment delta last' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $probePath = Join-Path $Work 'machine-environment-probe.ps1'
            @'
$observed = [ordered]@{
    systemRootPresent = -not [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable('SystemRoot')
    )
    pathPresent = -not [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable('PATH')
    )
    parentNoisePresent = $null -ne [Environment]::GetEnvironmentVariable(
        'AICLI_PARENT_NOISE_CANARY'
    )
    unrelatedProviderSecretPresent = $null -ne [Environment]::GetEnvironmentVariable(
        'ANTHROPIC_API_KEY'
    )
    rustLogPresent = $null -ne [Environment]::GetEnvironmentVariable('RUST_LOG')
    rustBacktracePresent = $null -ne [Environment]::GetEnvironmentVariable(
        'RUST_BACKTRACE'
    )
    codexLogPresent = $null -ne [Environment]::GetEnvironmentVariable('CODEX_LOG')
    nodeDebugPresent = $null -ne [Environment]::GetEnvironmentVariable('NODE_DEBUG')
    nodeOptionsPresent = $null -ne [Environment]::GetEnvironmentVariable('NODE_OPTIONS')
    nodeExtraCaCertsPreserved = (
        [Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS') -ceq
            'CANARY_NODE_EXTRA_CA_CERTS'
    )
    explicitCanaryApplied = (
        [Environment]::GetEnvironmentVariable('AICLI_EXPLICIT_ENV_CANARY') -ceq
            'CANARY_EXPLICIT_ENVIRONMENT_DELTA'
    )
    explicitProviderSecretApplied = (
        [Environment]::GetEnvironmentVariable('OPENAI_API_KEY') -ceq
            'CANARY_EXPLICIT_PROVIDER_SECRET'
    )
    codexHomeApplied = (
        [Environment]::GetEnvironmentVariable('CODEX_HOME') -ceq
            'CANARY_CODEX_HOME'
    )
    codexPackageRootApplied = (
        [Environment]::GetEnvironmentVariable('CODEX_MANAGED_PACKAGE_ROOT') -ceq
            'CANARY_CODEX_PACKAGE_ROOT'
    )
    codexNpmMarkerApplied = (
        [Environment]::GetEnvironmentVariable('CODEX_MANAGED_BY_NPM') -ceq '1'
    )
    isolatedTempApplied = (
        [Environment]::GetEnvironmentVariable('TEMP') -ceq 'CANARY_MACHINE_TEMP'
    )
}
[Console]::Out.Write(($observed | ConvertTo-Json -Compress))
'@ | Set-Content -LiteralPath $probePath -Encoding utf8

            $parentCanaries = [ordered]@{
                AICLI_PARENT_NOISE_CANARY = 'CANARY_PARENT_NOISE'
                OPENAI_API_KEY = 'CANARY_PARENT_PROVIDER_SECRET'
                ANTHROPIC_API_KEY = 'CANARY_UNRELATED_PROVIDER_SECRET'
                RUST_LOG = 'CANARY_RUST_LOG'
                RUST_BACKTRACE = 'CANARY_RUST_BACKTRACE'
                CODEX_LOG = 'CANARY_CODEX_LOG'
                NODE_DEBUG = 'CANARY_NODE_DEBUG'
                NODE_OPTIONS = 'CANARY_NODE_OPTIONS'
                NODE_EXTRA_CA_CERTS = 'CANARY_NODE_EXTRA_CA_CERTS'
            }
            $originals = @{}
            foreach ($name in $parentCanaries.Keys) {
                $originals[$name] = [Environment]::GetEnvironmentVariable(
                    $name,
                    [EnvironmentVariableTarget]::Process
                )
                [Environment]::SetEnvironmentVariable(
                    $name,
                    $parentCanaries[$name],
                    [EnvironmentVariableTarget]::Process
                )
            }

            try {
                $result = Invoke-AiCliChildCapture `
                    -FileName (Get-Command pwsh.exe).Source `
                    -ArgumentList @('-NoProfile', '-File', $probePath) `
                    -WorkingDirectory $Work `
                    -EnvironmentDelta @{
                        AICLI_EXPLICIT_ENV_CANARY = 'CANARY_EXPLICIT_ENVIRONMENT_DELTA'
                        OPENAI_API_KEY = 'CANARY_EXPLICIT_PROVIDER_SECRET'
                        CODEX_HOME = 'CANARY_CODEX_HOME'
                        CODEX_MANAGED_PACKAGE_ROOT = 'CANARY_CODEX_PACKAGE_ROOT'
                        CODEX_MANAGED_BY_NPM = '1'
                        TEMP = 'CANARY_MACHINE_TEMP'
                        TMP = 'CANARY_MACHINE_TEMP'
                    } `
                    -WritableWorkspace $Work `
                    -TimeoutMs 5000 `
                    -CloseStdIn

                $result.ExitCode | Should -Be 0
                $observed = $result.StdOut | ConvertFrom-Json
                $observed.systemRootPresent | Should -BeTrue
                $observed.pathPresent | Should -BeTrue
                $observed.parentNoisePresent | Should -BeFalse
                $observed.unrelatedProviderSecretPresent | Should -BeFalse
                $observed.rustLogPresent | Should -BeFalse
                $observed.rustBacktracePresent | Should -BeFalse
                $observed.codexLogPresent | Should -BeFalse
                $observed.nodeDebugPresent | Should -BeFalse
                $observed.nodeOptionsPresent | Should -BeFalse
                $observed.nodeExtraCaCertsPreserved | Should -BeTrue
                $observed.explicitCanaryApplied | Should -BeTrue
                $observed.explicitProviderSecretApplied | Should -BeTrue
                $observed.codexHomeApplied | Should -BeTrue
                $observed.codexPackageRootApplied | Should -BeTrue
                $observed.codexNpmMarkerApplied | Should -BeTrue
                $observed.isolatedTempApplied | Should -BeTrue
            } finally {
                foreach ($name in $parentCanaries.Keys) {
                    [Environment]::SetEnvironmentVariable(
                        $name,
                        $originals[$name],
                        [EnvironmentVariableTarget]::Process
                    )
                }
            }
        }
    }

    It 'keeps parent inheritance for a non-machine captured child' {
        InModuleScope AiCliProfileManager -Parameters @{ Work = $TestDrive } {
            $probePath = Join-Path $Work 'general-environment-probe.ps1'
            @'
$present = (
    [Environment]::GetEnvironmentVariable('AICLI_GENERAL_PARENT_CANARY') -ceq
        'CANARY_GENERAL_PARENT'
)
[Console]::Out.Write(($present | ConvertTo-Json -Compress))
'@ | Set-Content -LiteralPath $probePath -Encoding utf8

            $name = 'AICLI_GENERAL_PARENT_CANARY'
            $original = [Environment]::GetEnvironmentVariable(
                $name,
                [EnvironmentVariableTarget]::Process
            )
            [Environment]::SetEnvironmentVariable(
                $name,
                'CANARY_GENERAL_PARENT',
                [EnvironmentVariableTarget]::Process
            )
            try {
                $result = Invoke-AiCliChildCapture `
                    -FileName (Get-Command pwsh.exe).Source `
                    -ArgumentList @('-NoProfile', '-File', $probePath) `
                    -WorkingDirectory $Work `
                    -TimeoutMs 5000 `
                    -CloseStdIn

                $result.ExitCode | Should -Be 0
                ($result.StdOut | ConvertFrom-Json) | Should -BeTrue
            } finally {
                [Environment]::SetEnvironmentVariable(
                    $name,
                    $original,
                    [EnvironmentVariableTarget]::Process
                )
            }
        }
    }
}
