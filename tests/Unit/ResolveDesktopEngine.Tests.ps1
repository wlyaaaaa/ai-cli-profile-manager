#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Resolve-AiCliDesktopEngine' {
    BeforeAll {
        # These module helpers are deliberately minimal placeholders so Pester
        # can replace them with isolated fixture paths in each test.
        function Get-AiCliKnownFolder { param([string]$Name) throw "Unexpected known folder: $Name" }
        function Get-AiCliAppPaths { throw 'Unexpected AICLI paths lookup' }
        function Resolve-AiCliLaunchExecutable { param([string]$Name) throw "Unexpected resolver: $Name" }
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        . (Join-Path $repoRoot 'src\AiCliProfileManager\Support\ResolveDesktopEngine.ps1')
    }

    BeforeEach {
        $script:FixtureRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $script:PackageA = Join-Path $script:FixtureRoot 'package-a'
        $script:PackageB = Join-Path $script:FixtureRoot 'package-b'
        $script:OfficialCache = Join-Path $script:FixtureRoot 'official-cache'
        $script:AiCliLocal = Join-Path $script:FixtureRoot 'aicli-local'
        foreach ($package in @($script:PackageA, $script:PackageB)) {
            New-Item -ItemType Directory -Path (Join-Path $package 'app\resources') -Force | Out-Null
        }
        New-Item -ItemType Directory -Path $script:OfficialCache -Force | Out-Null
        New-Item -ItemType Directory -Path $script:AiCliLocal -Force | Out-Null

        [IO.File]::WriteAllText((Join-Path $script:PackageA 'app\resources\codex.exe'), 'engine-a')
        [IO.File]::WriteAllText((Join-Path $script:PackageB 'app\resources\codex.exe'), 'engine-b')
        [IO.File]::WriteAllText((Join-Path $script:PackageB 'app\resources\codex-command-runner.exe'), 'runner-b')

        Mock Get-AiCliKnownFolder { $script:OfficialCache } -ParameterFilter { $Name -eq 'LocalAppData' }
        Mock Get-AiCliAppPaths { [ordered]@{ LocalRoot = $script:AiCliLocal } }
    }

    It 'selects the current registered package instead of a stale official cache after an update' {
        $old = Join-Path $script:OfficialCache 'OpenAI\Codex\bin\old-a'
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        Copy-Item (Join-Path $script:PackageA 'app\resources\codex.exe') (Join-Path $old 'codex.exe')

        Mock Get-AppxPackage {
            @(
                [pscustomobject]@{ Version = [version]'1.0.0.0'; InstallLocation = $script:PackageA; PackageFullName = 'OpenAI.Codex_1' },
                [pscustomobject]@{ Version = [version]'2.0.0.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
            )
        } -ParameterFilter { $Name -eq 'OpenAI.Codex' }
        Mock Resolve-AiCliLaunchExecutable { throw 'fallback must not be used' }

        $resolved = Resolve-AiCliDesktopEngine
        $expected = Join-Path $script:AiCliLocal ('desktop\upstream\' + (Get-FileHash (Join-Path $script:PackageB 'app\resources\codex.exe') -Algorithm SHA256).Hash.ToLowerInvariant() + '\codex.exe')

        $resolved.FileName | Should -Be $expected
        $resolved.Kind | Should -Be 'desktop-codex'
        $resolved.Resolution | Should -Be 'aicli-upstream-cache'
        (Get-Content -LiteralPath $resolved.FileName -Raw) | Should -Be 'engine-b'
        (Get-Content -LiteralPath (Join-Path (Split-Path $resolved.FileName) 'codex-command-runner.exe') -Raw) | Should -Be 'runner-b'
        Should -Invoke Resolve-AiCliLaunchExecutable -Times 0 -Exactly
    }

    It 'reuses only the official cache entry whose hash matches the current package' {
        $current = Join-Path $script:OfficialCache 'OpenAI\Codex\bin\current-b'
        New-Item -ItemType Directory -Path $current -Force | Out-Null
        Copy-Item (Join-Path $script:PackageB 'app\resources\codex.exe') (Join-Path $current 'codex.exe')

        Mock Get-AppxPackage {
            [pscustomobject]@{ Version = [version]'2.0.0.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
        } -ParameterFilter { $Name -eq 'OpenAI.Codex' }

        $resolved = Resolve-AiCliDesktopEngine

        $resolved.FileName | Should -Be (Join-Path $current 'codex.exe')
        $resolved.Resolution | Should -Be 'official-cache'
        Test-Path -LiteralPath (Join-Path $script:AiCliLocal 'desktop\upstream') | Should -BeFalse
    }

    It 'returns a marked existing resolver fallback when no registered AppX package is available' {
        $fallback = Join-Path $script:FixtureRoot 'fallback\codex.exe'
        New-Item -ItemType Directory -Path (Split-Path $fallback) -Force | Out-Null
        [IO.File]::WriteAllText($fallback, 'fallback')
        Mock Get-AppxPackage { @() } -ParameterFilter { $Name -eq 'OpenAI.Codex' }
        Mock Resolve-AiCliLaunchExecutable {
            [pscustomobject]@{ FileName = $fallback; PrefixArgs = @('--portable'); Kind = 'native' }
        } -ParameterFilter { $Name -eq 'codex' }

        $resolved = Resolve-AiCliDesktopEngine

        $resolved.FileName | Should -Be $fallback
        @($resolved.PrefixArgs) | Should -Be @('--portable')
        $resolved.Kind | Should -Be 'desktop-fallback'
        $resolved.Resolution | Should -Be 'fallback'
        $resolved.FallbackKind | Should -Be 'native'
    }
}
