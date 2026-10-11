#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Resolve-AiCliDesktopEngine' {
    BeforeAll {
        # These module helpers are deliberately minimal placeholders so Pester
        # can replace them with isolated fixture paths in each test.
        function Get-AiCliKnownFolder { param([string]$Name) throw "Unexpected known folder: $Name" }
        function Get-AiCliAppPaths { throw 'Unexpected AICLI paths lookup' }
        function Resolve-AiCliLaunchExecutable { param([string]$Name) throw "Unexpected resolver: $Name" }
        function Write-AiCliLog { param([string]$Message, [string]$Level) }
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        . (Join-Path $repoRoot 'src\AiCliProfileManager\Private\JsonStore.ps1')
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
        Mock Get-AiCliAppPaths { [ordered]@{ LocalRoot = $script:AiCliLocal; LocksDir = (Join-Path $script:FixtureRoot 'locks') } }
        Mock Get-CimInstance { @() }
        Mock Test-AiCliOpenAICodexSignature { $true }
        Mock Get-AiCliCodexCliVersion {
            $content = Get-Content -LiteralPath $Path -Raw
            if ($content -eq 'engine-a') { return [semver]'1.0.0' }
            if ($content -eq 'engine-newer') { return [semver]'3.0.0' }
            return [semver]'2.0.0'
        }
    }

    It 'selects the current registered package instead of a stale official cache after an update' {
        $old = Join-Path $script:OfficialCache 'OpenAI\Codex\bin\1111111111111111'
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
        $current = Join-Path $script:OfficialCache 'OpenAI\Codex\bin\2222222222222222'
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

    It 'prefers a newer valid OpenAI-signed official cache even when Store resource bytes differ' {
        $current = Join-Path $script:OfficialCache 'OpenAI\Codex\bin\3333333333333333'
        New-Item -ItemType Directory -Path $current -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $current 'codex.exe'), 'engine-newer')

        Mock Get-AppxPackage {
            [pscustomobject]@{ Version = [version]'2.0.0.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
        } -ParameterFilter { $Name -eq 'OpenAI.Codex' }

        $resolved = Resolve-AiCliDesktopEngine

        $resolved.FileName | Should -Be (Join-Path $current 'codex.exe')
        $resolved.Resolution | Should -Be 'official-cache-self-updated'
        $resolved.ContentHash | Should -Be (Get-FileHash (Join-Path $current 'codex.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
        Test-Path -LiteralPath (Join-Path $script:AiCliLocal 'desktop\upstream') | Should -BeFalse
    }

    It 'ignores an older signed cache and stages the newer Store resource' {
        $old = Join-Path $script:OfficialCache 'OpenAI\Codex\bin\4444444444444444'
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        Copy-Item (Join-Path $script:PackageA 'app\resources\codex.exe') (Join-Path $old 'codex.exe')

        Mock Get-AppxPackage {
            [pscustomobject]@{ Version = [version]'2.0.0.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
        } -ParameterFilter { $Name -eq 'OpenAI.Codex' }
        Mock Resolve-AiCliLaunchExecutable { throw 'fallback must not be used' }

        $resolved = Resolve-AiCliDesktopEngine

        $resolved.Resolution | Should -Be 'aicli-upstream-cache'
        (Get-Content -LiteralPath $resolved.FileName -Raw) | Should -Be 'engine-b'
    }

    It 'compares prerelease components instead of treating every build of one base version as equal' {
        $old = Join-Path $script:OfficialCache 'OpenAI\Codex\bin\7777777777777777'
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        Copy-Item (Join-Path $script:PackageA 'app\resources\codex.exe') (Join-Path $old 'codex.exe')
        Mock Get-AppxPackage {
            [pscustomobject]@{ Version = [version]'2.0.0.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
        } -ParameterFilter { $Name -eq 'OpenAI.Codex' }
        Mock Get-AiCliCodexCliVersion {
            $content = Get-Content -LiteralPath $Path -Raw
            if ($content -eq 'engine-a') { return [semver]'2.0.0-alpha.6' }
            return [semver]'2.0.0-alpha.16'
        }

        $resolved = Resolve-AiCliDesktopEngine

        $resolved.Resolution | Should -Be 'aicli-upstream-cache'
        (Get-Content -LiteralPath $resolved.FileName -Raw) | Should -Be 'engine-b'
    }

    It 'stages the current package before comparing versions when its encrypted resource cannot run in place' {
        $old = Join-Path $script:OfficialCache 'OpenAI\Codex\bin\6666666666666666'
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        Copy-Item (Join-Path $script:PackageA 'app\resources\codex.exe') (Join-Path $old 'codex.exe')
        Mock Get-AppxPackage {
            [pscustomobject]@{ Version = [version]'2.0.0.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
        } -ParameterFilter { $Name -eq 'OpenAI.Codex' }
        Mock Get-AiCliCodexCliVersion {
            if ($Path -eq (Join-Path $script:PackageB 'app\resources\codex.exe')) { return $null }
            $content = Get-Content -LiteralPath $Path -Raw
            if ($content -eq 'engine-a') { return [semver]'1.0.0' }
            return [semver]'2.0.0'
        }
        Mock Resolve-AiCliLaunchExecutable { throw 'An older fallback must not be used' }

        $resolved = Resolve-AiCliDesktopEngine

        $resolved.Resolution | Should -Be 'aicli-upstream-cache'
        (Get-Content -LiteralPath $resolved.FileName -Raw) | Should -Be 'engine-b'
        (Get-Content -LiteralPath (Join-Path (Split-Path $resolved.FileName) 'codex-command-runner.exe') -Raw) | Should -Be 'runner-b'
        Should -Invoke Resolve-AiCliLaunchExecutable -Times 0 -Exactly
    }

    It 'does not silently use an older cache when the current package cannot be staged' {
        Mock Get-AppxPackage {
            [pscustomobject]@{ Version = [version]'2.0.0.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
        } -ParameterFilter { $Name -eq 'OpenAI.Codex' }
        Mock Get-AiCliCodexCliVersion { $null }
        Mock Get-AiCliAppPaths { throw 'Managed cache unavailable' }
        Mock Resolve-AiCliLaunchExecutable { throw 'An older fallback must not be used' }

        { Resolve-AiCliDesktopEngine } | Should -Throw 'Managed cache unavailable'
        Should -Invoke Resolve-AiCliLaunchExecutable -Times 0 -Exactly
    }

    It 'stages beneath the physical target when the upstream cache is a junction' {
        $physical = Join-Path $script:FixtureRoot 'redirected-upstream'
        New-Item -ItemType Directory -Path $physical -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AiCliLocal 'desktop') -Force | Out-Null
        $link = Join-Path $script:AiCliLocal 'desktop\upstream'
        New-Item -ItemType Junction -Path $link -Target $physical | Out-Null
        Mock Get-AppxPackage {
            [pscustomobject]@{ Version = [version]'2.0.0.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
        } -ParameterFilter { $Name -eq 'OpenAI.Codex' }
        Mock Get-AiCliCodexCliVersion {
            if ($Path -eq (Join-Path $script:PackageB 'app\resources\codex.exe')) { return $null }
            return [semver]'2.0.0'
        }
        $hash = (Get-FileHash (Join-Path $script:PackageB 'app\resources\codex.exe') -Algorithm SHA256).Hash.ToLowerInvariant()

        $resolved = Resolve-AiCliDesktopEngine

        $resolved.FileName | Should -Be (Join-Path $link ($hash + '\codex.exe'))
        (Get-Content -LiteralPath (Join-Path $physical ($hash + '\codex.exe')) -Raw) | Should -Be 'engine-b'
        @(Get-ChildItem -LiteralPath $physical -Force -Filter '*.tmp').Count | Should -Be 0
        (Get-Item -LiteralPath $link -Force).LinkType | Should -Be 'Junction'
        Test-Path -LiteralPath (Get-AiCliLockPath -TargetPath $physical) | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $script:FixtureRoot 'locks') -File).Count | Should -Be 1
    }

    It 'resolves every linked component of a cache path to its physical directory' {
        $physical = Join-Path $script:FixtureRoot 'physical-root'
        New-Item -ItemType Directory -Path (Join-Path $physical 'inner') -Force | Out-Null
        $link = Join-Path $script:FixtureRoot 'linked-root'
        New-Item -ItemType Junction -Path $link -Target $physical | Out-Null

        Resolve-AiCliPhysicalDirectory -Path (Join-Path $link 'inner') |
            Should -Be ([IO.Path]::GetFullPath((Join-Path $physical 'inner')))
        Resolve-AiCliPhysicalDirectory -Path $physical |
            Should -Be ([IO.Path]::GetFullPath($physical))
    }

    It 'rejects a staged package whose companion changed after the first launch' {
        Mock Get-AppxPackage {
            [pscustomobject]@{ Version = [version]'2.0.0.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
        } -ParameterFilter { $Name -eq 'OpenAI.Codex' }
        Mock Get-AiCliCodexCliVersion {
            if ($Path -eq (Join-Path $script:PackageB 'app\resources\codex.exe')) { return $null }
            return [semver]'2.0.0'
        }

        $resolved = Resolve-AiCliDesktopEngine
        [IO.File]::WriteAllText((Join-Path (Split-Path $resolved.FileName) 'codex-command-runner.exe'), 'changed')

        { Resolve-AiCliDesktopEngine } | Should -Throw '*companion changed*'
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

    It 'retires only verified idle old cache: <Case>' -TestCases (@(
        'old', 'current', 'result', 'active', 'preparing', 'bridge', 'process-failure', 'incomplete-process',
        'extra', 'subdirectory', 'link', 'file-link', 'ads', 'directory-ads', 'signature', 'hash',
        'appx-changed', 'delete-failure', 'lock-failure', 'staging', 'own-bridge', 'referenced-command', 'recheck-process', 'recheck-appx', 'logical-reference'
    ) | ForEach-Object { @{ Case = $_ } }) {
        param($Case)
        $root = Join-Path $script:AiCliLocal 'desktop\upstream'
        $hash = Get-AiCliDesktopEngineHash -Path (Join-Path $script:PackageA 'app\resources\codex.exe')
        $old = Join-Path $root $hash
        New-Item -ItemType Directory -Path $old -Force | Out-Null
        $names = @('codex.exe', 'codex-code-mode-host.exe', 'codex-command-runner.exe', 'codex-windows-sandbox-service.exe', 'codex-windows-sandbox-setup.exe')
        foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path $old $name), 'engine-a') }
        $script:RetentionPath = $old
        $script:RetentionChecks = 0
        $package = [pscustomobject]@{ Version = [version]'2.0'; InstallLocation = $script:PackageB; PackageFullName = 'OpenAI.Codex_2' }
        Mock Get-AppxPackage { $package }
        $sourceHash = Get-AiCliDesktopEngineHash -Path (Join-Path $script:PackageB 'app\resources\codex.exe')
        $result = New-AiCliDesktopEngineResult -FileName (Join-Path $script:PackageB 'app\resources\codex.exe') -Resolution 'official-cache' -ContentHash $sourceHash
        switch ($Case) {
            'current' { $sourceHash = $hash; Mock Get-AiCliDesktopEngineHash { $hash } -ParameterFilter { $Path -like '*package-b*' } }
            'result' { $result.ContentHash = $hash }
            'active' { Mock Get-CimInstance { @([pscustomobject]@{ Name='codex.exe'; ProcessId=123; ExecutablePath=(Join-Path $script:RetentionPath 'codex.exe'); CommandLine='codex app-server' }) } }
            'preparing' { Mock Get-CimInstance { @([pscustomobject]@{ Name='pwsh.exe'; ProcessId=123; ExecutablePath='C:\pwsh.exe'; CommandLine='pwsh -File GetDesktopModelPlan.ps1' }) } }
            'bridge' { Mock Get-CimInstance { @([pscustomobject]@{ Name='AiCli.CodexDesktopBridge.exe'; ProcessId=123; ExecutablePath='C:\bridge.exe'; CommandLine='bridge' }) } }
            'process-failure' { Mock Get-CimInstance { throw 'unavailable' } }
            'incomplete-process' { Mock Get-CimInstance { @([pscustomobject]@{ Name='codex.exe'; ProcessId=123; ExecutablePath=$null; CommandLine=$null }) } }
            'extra' { [IO.File]::WriteAllText((Join-Path $old 'keep.txt'), 'unique') }
            'subdirectory' { New-Item -ItemType Directory -Path (Join-Path $old 'keep') | Out-Null }
            'link' { Rename-Item -LiteralPath $old -NewName ($hash + '-target'); New-Item -ItemType Junction -Path $old -Target ($old + '-target') | Out-Null }
            'file-link' { Mock Get-ChildItem { foreach ($name in $names) { [pscustomobject]@{ Name=$name; FullName=(Join-Path $script:RetentionPath $name); PSIsContainer=$false; Attributes=$(if ($name -eq 'codex.exe') { [IO.FileAttributes]::ReparsePoint } else { [IO.FileAttributes]::Normal }) } } } -ParameterFilter { $LiteralPath -eq $script:RetentionPath } }
            'ads' { Set-Content -LiteralPath (Join-Path $old 'codex.exe') -Stream keep -Value 'unique' }
            'directory-ads' { Set-Content -LiteralPath $old -Stream keep -Value 'unique' }
            'signature' { Mock Test-AiCliOpenAICodexSignature { $false } -ParameterFilter { $Path -like '*codex-command-runner.exe' } }
            'hash' { [IO.File]::WriteAllText((Join-Path $old 'codex.exe'), 'changed') }
            'appx-changed' { Mock Get-AppxPackage { [pscustomobject]@{ Version=[version]'3.0'; InstallLocation=$script:PackageA; PackageFullName='OpenAI.Codex_3' } } }
            'delete-failure' { Mock Remove-Item { throw 'in use' } -ParameterFilter { $LiteralPath -eq $script:RetentionPath } }
            'lock-failure' { Mock Enter-AiCliFileLock { throw 'busy' } }
            'staging' { Rename-Item -LiteralPath $old -NewName ('.' + $hash + '.pending.tmp'); $old = Join-Path $root ('.' + $hash + '.pending.tmp') }
            'own-bridge' { Mock Get-CimInstance { @([pscustomobject]@{ Name='pwsh.exe'; ProcessId=$PID; ParentProcessId=123; ExecutablePath='C:\pwsh.exe'; CommandLine='exporter' }, [pscustomobject]@{ Name='AiCli.CodexDesktopBridge.exe'; ProcessId=123; ExecutablePath='C:\bridge.exe'; CommandLine='bridge' }) } }
            'referenced-command' { Mock Get-CimInstance { @([pscustomobject]@{ Name='other.exe'; ProcessId=123; ExecutablePath='C:\other.exe'; CommandLine=$script:RetentionPath }) } }
            'recheck-process' { Mock Get-CimInstance { $script:RetentionChecks++; if ($script:RetentionChecks -eq 1) { @() } else { @([pscustomobject]@{ Name='codex.exe'; ProcessId=123; ExecutablePath=(Join-Path $script:RetentionPath 'codex.exe'); CommandLine='codex' }) } } }
            'recheck-appx' { Mock Get-AppxPackage { $script:RetentionChecks++; if ($script:RetentionChecks -eq 1) { $package } else { [pscustomobject]@{ Version=[version]'3.0'; InstallLocation=$script:PackageA; PackageFullName='OpenAI.Codex_3' } } } }
            'logical-reference' { $physical = Join-Path $script:FixtureRoot 'physical-upstream'; Move-Item -LiteralPath $root -Destination $physical; New-Item -ItemType Junction -Path $root -Target $physical | Out-Null; Mock Get-CimInstance { @([pscustomobject]@{ Name='codex.exe'; ProcessId=123; ExecutablePath=(Join-Path $script:RetentionPath 'codex.exe'); CommandLine='codex' }) } }
        }
        { Remove-AiCliObsoleteUpstreamCache -Result $result -Package $package -SourceHash $sourceHash } | Should -Not -Throw
        Test-Path -LiteralPath $old | Should -Be ($Case -notin @('old', 'own-bridge'))
        if ($Case -eq 'delete-failure') { Should -Invoke Remove-Item -Times 1 -Exactly }
        if ($Case -eq 'link') { Test-Path -LiteralPath ($old + '-target\codex.exe') | Should -BeTrue }
    }

    It 'runs retention only after successful AppX resolution: <Route>' -TestCases @(@{Route='official'}, @{Route='staged'}, @{Route='fallback'}) {
        param($Route)
        Mock Get-AppxPackage { if ($Route -ne 'fallback') { [pscustomobject]@{Version=[version]'2.0'; InstallLocation=$script:PackageB; PackageFullName='OpenAI.Codex_2'} } }
        Mock Remove-AiCliObsoleteUpstreamCache { }
        if ($Route -eq 'official') { Mock Get-AiCliOfficialCodexCacheCandidate { [pscustomobject]@{ FileName=(Join-Path $script:PackageB 'app\resources\codex.exe'); Hash='verified'; Version=[semver]'2.0' } } }
        Resolve-AiCliDesktopEngine | Out-Null
        Should -Invoke Remove-AiCliObsoleteUpstreamCache -Exactly -Times ([int]($Route -ne 'fallback'))
    }
}
