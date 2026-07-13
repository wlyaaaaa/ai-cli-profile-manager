#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Managed proxy release safety' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        foreach ($name in @(
            'Brand.ps1',
            'Paths.ps1',
            'Redaction.ps1',
            'JsonStore.ps1',
            'ConsoleUi.ps1',
            'ManifestService.ps1',
            'ChildProcess.ps1',
            'PortAllocator.ps1',
            'ProcessIdentity.ps1',
            'ProxyService.ps1'
        )) {
            . (Join-Path $root "src\AiCliProfileManager\Private\$name")
        }
    }

    BeforeEach {
        $script:caseRoot = Join-Path ([IO.Path]::GetTempPath()) ('aicli-proxy-safety-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:caseRoot -Force | Out-Null
        Set-AiCliDataRootOverride -Path $script:caseRoot
    }

    AfterEach {
        Set-AiCliDataRootOverride -Path $null
        Remove-Item -LiteralPath $script:caseRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'uses one global allocation and start lock for both proxies' {
        $ccpLock = Get-AiCliProxyGlobalLockTarget
        $cliproxyLock = Get-AiCliProxyGlobalLockTarget

        $ccpLock | Should -Be $cliproxyLock
        [IO.Path]::GetFileName($ccpLock) | Should -Be 'managed-proxy-allocation-start.lock'
    }

    It 'accepts only the expected executable name for each proxy' {
        $paths = Initialize-AiCliProxyDirs -ProxyId ccp
        $versionDir = Join-Path $paths.VersionsDir 'v-test'
        New-Item -ItemType Directory -Path $versionDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $versionDir 'unrelated.exe') -Force | Out-Null
        New-Item -ItemType Junction -Path $paths.CurrentLink -Target $versionDir | Out-Null

        Get-AiCliProxyExecutable -ProxyId ccp | Should -BeNullOrEmpty

        $expected = Join-Path $versionDir 'claude-code-proxy.exe'
        New-Item -ItemType File -Path $expected -Force | Out-Null
        Get-AiCliProxyExecutable -ProxyId ccp | Should -Be $expected
    }

    It 'refuses a current junction that points outside the managed versions tree' {
        $paths = Initialize-AiCliProxyDirs -ProxyId ccp
        $outside = Join-Path $script:caseRoot 'outside-proxy'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $outside 'claude-code-proxy.exe') -Force | Out-Null
        New-Item -ItemType Junction -Path $paths.CurrentLink -Target $outside | Out-Null

        Get-AiCliProxyExecutable -ProxyId ccp | Should -BeNullOrEmpty
    }

    It 'refuses a reparse-point executable inside the managed versions tree' {
        $paths = Initialize-AiCliProxyDirs -ProxyId ccp
        $versionDir = Join-Path $paths.VersionsDir 'v-test'
        $outside = Join-Path $script:caseRoot 'outside.exe'
        New-Item -ItemType Directory -Path $versionDir -Force | Out-Null
        New-Item -ItemType File -Path $outside -Force | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $versionDir 'claude-code-proxy.exe') -Target $outside -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because '当前 Windows 环境不允许创建文件符号链接'
            return
        }
        New-Item -ItemType Junction -Path $paths.CurrentLink -Target $versionDir | Out-Null

        Get-AiCliProxyExecutable -ProxyId ccp | Should -BeNullOrEmpty
    }

    It 'rejects a traversal ZIP entry before extraction' {
        $zipPath = Join-Path $script:caseRoot 'traversal.zip'
        $stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $null = $archive.CreateEntry('../escape.exe')
        } finally {
            $archive.Dispose()
            $stream.Dispose()
        }

        { Assert-AiCliProxyZipSafe -ZipPath $zipPath -DestinationRoot (Join-Path $script:caseRoot 'extract') } |
            Should -Throw '*unsafe ZIP entry*'
        Test-Path -LiteralPath (Join-Path $script:caseRoot 'escape.exe') | Should -BeFalse
    }

    It 'accepts a normal ZIP without extracting it' {
        $zipPath = Join-Path $script:caseRoot 'safe.zip'
        $stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $null = $archive.CreateEntry('bin/claude-code-proxy.exe')
        } finally {
            $archive.Dispose()
            $stream.Dispose()
        }

        { Assert-AiCliProxyZipSafe -ZipPath $zipPath -DestinationRoot (Join-Path $script:caseRoot 'extract') } |
            Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $script:caseRoot 'extract') | Should -BeFalse
    }

    It 'does not touch the current pointer when staged structure is invalid' {
        $base = Join-Path $script:caseRoot 'pointer'
        $oldTarget = Join-Path $base 'old'
        $badTarget = Join-Path $base 'bad'
        $current = Join-Path $base 'current'
        New-Item -ItemType Directory -Path $oldTarget, $badTarget -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $oldTarget 'claude-code-proxy.exe') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $oldTarget 'old.marker') -Force | Out-Null
        New-Item -ItemType Junction -Path $current -Target $oldTarget | Out-Null

        { Set-AiCliProxyCurrentPointer -ProxyId ccp -CurrentLink $current -TargetDir $badTarget } |
            Should -Throw '*expected executable*'
        Test-Path -LiteralPath (Join-Path $current 'old.marker') | Should -BeTrue
    }

    It 'restores the old current pointer when the pointer swap fails' {
        $base = Join-Path $script:caseRoot 'rollback'
        $oldTarget = Join-Path $base 'old'
        $newTarget = Join-Path $base 'new'
        $current = Join-Path $base 'current'
        New-Item -ItemType Directory -Path $oldTarget, $newTarget -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $oldTarget 'claude-code-proxy.exe') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $newTarget 'claude-code-proxy.exe') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $oldTarget 'old.marker') -Force | Out-Null
        New-Item -ItemType Junction -Path $current -Target $oldTarget | Out-Null
        Mock Move-Item {
            param($LiteralPath, $Destination)
            if ([IO.Path]::GetFileName($LiteralPath) -like '.current-next-*') {
                throw 'simulated pointer swap failure'
            }
            [IO.Directory]::Move($LiteralPath, $Destination)
        }

        { Set-AiCliProxyCurrentPointer -ProxyId ccp -CurrentLink $current -TargetDir $newTarget } |
            Should -Throw '*simulated pointer swap failure*'
        Test-Path -LiteralPath (Join-Path $current 'old.marker') | Should -BeTrue
    }

    It 'switches current only after the new structure is valid' {
        $base = Join-Path $script:caseRoot 'switch-success'
        $oldTarget = Join-Path $base 'old'
        $newTarget = Join-Path $base 'new'
        $current = Join-Path $base 'current'
        New-Item -ItemType Directory -Path $oldTarget, $newTarget -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $oldTarget 'claude-code-proxy.exe') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $newTarget 'claude-code-proxy.exe') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $newTarget 'new.marker') -Force | Out-Null
        New-Item -ItemType Junction -Path $current -Target $oldTarget | Out-Null

        Set-AiCliProxyCurrentPointer -ProxyId ccp -CurrentLink $current -TargetDir $newTarget

        Test-Path -LiteralPath (Join-Path $current 'new.marker') | Should -BeTrue
        Test-Path -LiteralPath $oldTarget | Should -BeTrue
    }

    It 'waits for an exact IPv4 loopback listener owned by the launched PID' {
        $proc = [pscustomobject]@{ Id = 4242; HasExited = $false }
        Mock Get-AiCliTcpListeners {
            @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 43197; OwningProcess = 4242 })
        }
        Mock Test-AiCliProxyHttpProtocol { [pscustomobject]@{ Responded = $true; StatusCode = 404; Reason = 'http-response' } }

        $result = Wait-AiCliProxyReady -Process $proc -Port 43197 -TimeoutMs 50 -PollIntervalMs 1

        $result.Ready | Should -BeTrue
        $result.Reason | Should -Be 'ready'
    }

    It 'rejects a listener on the target port owned by another process' {
        $proc = [pscustomobject]@{ Id = 4242; HasExited = $false }
        Mock Get-AiCliTcpListeners {
            @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 43197; OwningProcess = 9001 })
        }

        $result = Wait-AiCliProxyReady -Process $proc -Port 43197 -TimeoutMs 50 -PollIntervalMs 1

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Be 'listener-owned-by-other-process'
    }

    It 'does not declare readiness without an explicit local HTTP response' {
        $proc = [pscustomobject]@{ Id = 4242; HasExited = $false }
        Mock Get-AiCliTcpListeners {
            @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 43197; OwningProcess = 4242 })
        }
        Mock Test-AiCliProxyHttpProtocol {
            [pscustomobject]@{ Responded = $false; StatusCode = $null; Reason = 'no-http-response' }
        }

        $result = Wait-AiCliProxyReady -Process $proc -Port 43197 -TimeoutMs 20 -PollIntervalMs 1

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Be 'protocol-probe-failed:no-http-response'
    }

    It 'requires port ownership as part of managed process identity' {
        $started = (Get-Date).ToUniversalTime()
        $versionDir = Join-Path (Get-AiCliProxyPaths -ProxyId ccp).VersionsDir 'v-test'
        New-Item -ItemType Directory -Path $versionDir -Force | Out-Null
        $path = Join-Path $versionDir 'claude-code-proxy.exe'
        New-Item -ItemType File -Path $path -Force | Out-Null
        $proc = [pscustomobject]@{ Id = 4242; StartTime = $started.ToLocalTime(); Path = $path }
        $state = [ordered]@{
            proxyId = 'ccp'
            pid = 4242
            startTimeUtc = $started.ToString('o')
            executablePath = $path
            host = '127.0.0.1'
            port = 43197
            nonce = 'test-nonce'
        }
        Mock Get-Process { $proc }
        Mock Get-AiCliTcpListeners {
            @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 43197; OwningProcess = 9001 })
        }

        $identity = Test-AiCliProcessIdentity -State $state -Strict

        $identity.Match | Should -BeFalse
        $identity.Reason | Should -Be 'listener-owner-mismatch'
    }

    It 'rejects a self-consistent process path outside the managed proxy root' {
        $started = (Get-Date).ToUniversalTime()
        $foreignPath = Join-Path $script:caseRoot 'foreign-listener.exe'
        New-Item -ItemType File -Path $foreignPath -Force | Out-Null
        $proc = [pscustomobject]@{ Id = 4242; StartTime = $started.ToLocalTime(); Path = $foreignPath }
        $state = [ordered]@{
            proxyId = 'ccp'
            pid = 4242
            startTimeUtc = $started.ToString('o')
            executablePath = $foreignPath
            host = '127.0.0.1'
            port = 43197
            nonce = 'test-nonce'
        }
        Mock Get-Process { $proc }
        Mock Get-AiCliTcpListeners {
            @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 43197; OwningProcess = 4242 })
        }

        $identity = Test-AiCliProcessIdentity -State $state -Strict -ExpectedProxyId ccp

        $identity.Match | Should -BeFalse
        $identity.Reason | Should -Be 'path-outside-managed-root'
    }

    It 'retains state when a managed process cannot be stopped' {
        $proc = [pscustomobject]@{ Id = 4242 }
        $proc | Add-Member -MemberType ScriptMethod -Name Kill -Value { throw 'access denied' }
        Mock Get-AiCliProxyState { [ordered]@{ pid = 4242 } }
        Mock Test-AiCliProcessIdentity { [pscustomobject]@{ Match = $true; Reason = 'ok'; Process = $proc } }
        Mock Clear-AiCliProxyState {}

        { Stop-AiCliManagedProcess -ProxyId ccp } | Should -Throw '*access denied*'
        Should -Invoke Clear-AiCliProxyState -Times 0 -Exactly
    }

    It 'keeps proxy login arguments as distinct ProcessStartInfo entries' {
        $configPath = Join-Path $script:caseRoot 'space and unicode config.yaml'
        $psi = New-AiCliProxyLoginStartInfo -FileName 'C:\Program Files\proxy.exe' `
            -ArgumentList @('-codex-login', '-config', $configPath) `
            -WorkingDirectory 'C:\Program Files'

        $psi.UseShellExecute | Should -BeFalse
        @($psi.ArgumentList).Count | Should -Be 3
        $psi.ArgumentList[2] | Should -Be $configPath
    }

    It 'implements the pinned ccp v0.1.15 environment and auth command contract' {
        $paths = Initialize-AiCliProxyDirs -ProxyId ccp
        $environment = Get-AiCliCcpEnvironmentDelta -Paths $paths -Port 43197

        $environment.PORT | Should -Be '43197'
        $environment.CCP_CONFIG_DIR | Should -Be $paths.AuthDir
        $environment.LOCALAPPDATA | Should -Be $paths.LogsDir
        @(Get-AiCliCcpAuthArguments -Action login) | Should -Be @('codex','auth','login')
        @(Get-AiCliCcpAuthArguments -Action device) | Should -Be @('codex','auth','device')
        @(Get-AiCliCcpAuthArguments -Action status) | Should -Be @('codex','auth','status')
        @(Get-AiCliCcpAuthArguments -Action logout) | Should -Be @('codex','auth','logout')

        Test-AiCliProxyAuthPresent -ProxyId ccp | Should -BeFalse
        $authFile = Join-Path $paths.AuthDir 'codex\auth.json'
        New-Item -ItemType Directory -Path (Split-Path $authFile) -Force | Out-Null
        Set-Content -LiteralPath $authFile -Value '{}' -Encoding utf8
        Test-AiCliProxyAuthPresent -ProxyId ccp | Should -BeTrue
    }

    It 'returns Limited when proxy logout cannot be confirmed' {
        Mock Get-AiCliProxyExecutable { $null }

        Invoke-AiCliProxyLogout -ProxyId ccp | Should -Be 3
    }

    It 'returns Limited when the upstream logout command fails' {
        Mock Get-AiCliProxyExecutable { 'C:\managed\claude-code-proxy.exe' }
        Mock Invoke-AiCliChildCapture { [pscustomobject]@{ ExitCode = 2 } }

        Invoke-AiCliProxyLogout -ProxyId ccp | Should -Be 3
    }

    It 'does not execute a nonexistent CLIProxyAPI logout command' {
        Mock Get-AiCliProxyExecutable { 'C:\managed\cli-proxy-api.exe' }
        Mock Invoke-AiCliChildCapture { throw 'must not run' }

        Invoke-AiCliProxyLogout -ProxyId cliproxy | Should -Be 3
        Should -Invoke Invoke-AiCliChildCapture -Times 0 -Exactly
    }

    It 'returns Success only after confirmed upstream logout' {
        Mock Get-AiCliProxyExecutable { 'C:\managed\claude-code-proxy.exe' }
        Mock Invoke-AiCliChildCapture { [pscustomobject]@{ ExitCode = 0 } }

        Invoke-AiCliProxyLogout -ProxyId ccp | Should -Be 0
    }

    It 'returns Success when an explicitly confirmed local auth purge completes' {
        Mock Get-AiCliProxyExecutable { $null }
        Mock Confirm-AiCliAction { $true }
        Mock Stop-AiCliManagedProcess {}

        Invoke-AiCliProxyLogout -ProxyId ccp -PurgeLocalAuth | Should -Be 0
        Test-Path -LiteralPath (Get-AiCliProxyPaths -ProxyId ccp).AuthDir -PathType Container | Should -BeTrue
    }

    It 'does not save successful state when readiness verification fails' {
        $started = Get-Date
        $script:fakeProcess = [pscustomobject]@{ Id = 4242; StartTime = $started; HasExited = $false }
        Mock Enter-AiCliFileLock { [pscustomobject]@{ FileStream = $null; LockPath = 'test' } }
        Mock Exit-AiCliFileLock {}
        Mock Get-AiCliProxyState { $null }
        Mock Get-AiCliProxyExecutable { 'C:\managed\claude-code-proxy.exe' }
        Mock Resolve-AiCliTrustedProxyExecutablePath { 'C:\managed\versions\v-test\claude-code-proxy.exe' }
        Mock Set-AiCliProxyConfigure { 43197 }
        Mock Get-AiCliProxyRuntimeMeta { [ordered]@{ port = 43197; localClientKey = 'local-only' } }
        Mock Test-AiCliPortCandidate { [pscustomobject]@{ Ok = $true; Reason = 'ok' } }
        Mock Start-AiCliProxyChildProcess { $script:fakeProcess }
        Mock Wait-AiCliProxyReady { [pscustomobject]@{ Ready = $false; Reason = 'startup-timeout' } }
        Mock Stop-AiCliStartedProcess {}
        Mock Save-AiCliProxyState {}
        Mock Save-AiCliProxyPort {}

        $null = Start-AiCliProxy -ProxyId ccp

        Should -Invoke Enter-AiCliFileLock -Times 1 -Exactly -ParameterFilter { $TimeoutMs -ge 60000 }
        Should -Invoke Stop-AiCliStartedProcess -Times 1 -Exactly
        Should -Invoke Save-AiCliProxyState -Times 0 -Exactly
        Should -Invoke Save-AiCliProxyPort -Times 0 -Exactly
    }

    It 'does not call an identity-only existing process healthy when HTTP is unresponsive' {
        Mock Enter-AiCliFileLock { [pscustomobject]@{ FileStream = $null; LockPath = 'test' } }
        Mock Exit-AiCliFileLock {}
        Mock Get-AiCliProxyState { [ordered]@{ pid = 4242; port = 43197; proxyId = 'ccp' } }
        Mock Test-AiCliProcessIdentity { [pscustomobject]@{ Match = $true; Reason = 'ok' } }
        Mock Test-AiCliProxyHttpProtocol { [pscustomobject]@{ Responded = $false; StatusCode = $null } }
        Mock Start-AiCliProxyChildProcess { throw 'must not launch a duplicate' }

        Start-AiCliProxy -ProxyId ccp | Should -Be 4
        Should -Invoke Start-AiCliProxyChildProcess -Times 0 -Exactly
    }

    It 'saves state only after exact listener readiness succeeds' {
        $started = Get-Date
        $script:fakeProcess = [pscustomobject]@{ Id = 4242; StartTime = $started; HasExited = $false }
        $script:capturedStartInfo = $null
        Mock Enter-AiCliFileLock { [pscustomobject]@{ FileStream = $null; LockPath = 'test' } }
        Mock Exit-AiCliFileLock {}
        Mock Get-AiCliProxyState { $null }
        Mock Get-AiCliProxyExecutable { 'C:\managed\claude-code-proxy.exe' }
        Mock Resolve-AiCliTrustedProxyExecutablePath { 'C:\managed\versions\v-test\claude-code-proxy.exe' }
        Mock Set-AiCliProxyConfigure { 43197 }
        Mock Get-AiCliProxyRuntimeMeta { [ordered]@{ port = 43197; localClientKey = 'local-only' } }
        Mock Test-AiCliPortCandidate { [pscustomobject]@{ Ok = $true; Reason = 'ok' } }
        Mock Start-AiCliProxyChildProcess {
            param($StartInfo)
            $script:capturedStartInfo = $StartInfo
            $script:fakeProcess
        }
        Mock Wait-AiCliProxyReady {
            [pscustomobject]@{
                Ready = $true
                Reason = 'ready'
                Listeners = @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 43197; OwningProcess = 4242 })
            }
        }
        Mock Stop-AiCliStartedProcess {}
        Mock Save-AiCliProxyState {}
        Mock Save-AiCliProxyPort {}

        $null = Start-AiCliProxy -ProxyId ccp

        Should -Invoke Stop-AiCliStartedProcess -Times 0 -Exactly
        Should -Invoke Save-AiCliProxyState -Times 1 -Exactly
        Should -Invoke Save-AiCliProxyPort -Times 1 -Exactly
        @($script:capturedStartInfo.ArgumentList) | Should -Be @('serve','--no-monitor')
        $script:capturedStartInfo.Environment['PORT'] | Should -Be '43197'
        $script:capturedStartInfo.Environment['CCP_CONFIG_DIR'] | Should -Be (Get-AiCliProxyPaths -ProxyId ccp).AuthDir
    }

    It 'cleans the launched process when state persistence fails after readiness' {
        $started = Get-Date
        $script:fakeProcess = [pscustomobject]@{ Id = 4242; StartTime = $started; HasExited = $false }
        Mock Enter-AiCliFileLock { [pscustomobject]@{ FileStream = $null; LockPath = 'test' } }
        Mock Exit-AiCliFileLock {}
        Mock Get-AiCliProxyState { $null }
        Mock Get-AiCliProxyExecutable { 'C:\managed\claude-code-proxy.exe' }
        Mock Resolve-AiCliTrustedProxyExecutablePath { 'C:\managed\versions\v-test\claude-code-proxy.exe' }
        Mock Set-AiCliProxyConfigure { 43197 }
        Mock Get-AiCliProxyRuntimeMeta { [ordered]@{ port = 43197; localClientKey = 'local-only' } }
        Mock Test-AiCliPortCandidate { [pscustomobject]@{ Ok = $true; Reason = 'ok' } }
        Mock Start-AiCliProxyChildProcess { $script:fakeProcess }
        Mock Wait-AiCliProxyReady { [pscustomobject]@{ Ready = $true; Reason = 'ready'; ProtocolStatusCode = 404 } }
        Mock Stop-AiCliStartedProcess {}
        Mock Save-AiCliProxyState { throw 'simulated state write failure' }
        Mock Save-AiCliProxyPort {}

        $null = Start-AiCliProxy -ProxyId ccp

        Should -Invoke Stop-AiCliStartedProcess -Times 1 -Exactly
        Should -Invoke Save-AiCliProxyPort -Times 0 -Exactly
    }

    It 'retries the next candidate after a foreign process wins the port race' {
        $started = Get-Date
        $script:fakeProcess = [pscustomobject]@{ Id = 4242; StartTime = $started; HasExited = $false }
        $script:configureCount = 0
        $script:waitCount = 0
        Mock Enter-AiCliFileLock { [pscustomobject]@{ FileStream = $null; LockPath = 'test' } }
        Mock Exit-AiCliFileLock {}
        Mock Get-AiCliProxyState { $null }
        Mock Get-AiCliProxyExecutable { 'C:\managed\claude-code-proxy.exe' }
        Mock Resolve-AiCliTrustedProxyExecutablePath { 'C:\managed\versions\v-test\claude-code-proxy.exe' }
        Mock Set-AiCliProxyConfigure {
            $script:configureCount++
            if ($script:configureCount -eq 1) { return 43197 }
            return 43198
        }
        Mock Get-AiCliProxyRuntimeMeta { [ordered]@{ port = 43198; localClientKey = 'local-only' } }
        Mock Test-AiCliPortCandidate { [pscustomobject]@{ Ok = $true; Reason = 'ok' } }
        Mock Start-AiCliProxyChildProcess { $script:fakeProcess }
        Mock Wait-AiCliProxyReady {
            $script:waitCount++
            if ($script:waitCount -eq 1) {
                return [pscustomobject]@{
                    Ready = $false
                    Reason = 'listener-owned-by-other-process'
                    Listeners = @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 43197; OwningProcess = 9001 })
                }
            }
            return [pscustomobject]@{ Ready = $true; Reason = 'ready'; ProtocolStatusCode = 404 }
        }
        Mock Stop-AiCliStartedProcess {}
        Mock Save-AiCliProxyState {}
        Mock Save-AiCliProxyPort {}

        $null = Start-AiCliProxy -ProxyId ccp

        Should -Invoke Start-AiCliProxyChildProcess -Times 2 -Exactly
        Should -Invoke Stop-AiCliStartedProcess -Times 1 -Exactly
        Should -Invoke Save-AiCliProxyPort -Times 1 -Exactly -ParameterFilter { $Port -eq 43198 }
    }

    It 'fails closed when Windows port-range inspection fails' {
        Mock Get-AiCliNetshPortRanges { throw 'netsh unavailable' }

        $check = Test-AiCliPortCandidate -Port 43197

        $check.Ok | Should -BeFalse
        $check.Reason | Should -BeLike 'netsh-query-failed*'
    }

    It 'does not silently move a user-selected port to the automatic pool' {
        Mock Select-AiCliProxyPort {
            param($ProxyId, $UserPort, $ExcludePorts)
            if ($UserPort -in @($ExcludePorts)) { throw 'user port unavailable' }
            return $UserPort
        }
        Mock Test-AiCliPortCandidate { [pscustomobject]@{ Ok = $true; Reason = 'ok' } }

        $selected = Set-AiCliProxyConfigure -ProxyId ccp -Port 44000 -LockHeld -DeferPersistedPort
        $savedMeta = Get-AiCliProxyRuntimeMeta -ProxyId ccp

        $selected | Should -Be 44000
        $savedMeta.portSource | Should -Be 'user'
        { Set-AiCliProxyConfigure -ProxyId ccp -LockHeld -DeferPersistedPort -ExcludePorts @(44000) } |
            Should -Throw '*user port unavailable*'
    }

    It 'separates local protocol response from authentication and upstream verification' {
        Mock Get-AiCliProxyState {
            [ordered]@{ pid = 4242; port = 43197; host = '127.0.0.1'; proxyId = 'ccp' }
        }
        Mock Test-AiCliProcessIdentity { [pscustomobject]@{ Match = $true; Reason = 'ok' } }
        Mock Get-AiCliProxyExecutable { 'C:\managed\claude-code-proxy.exe' }
        Mock Test-AiCliProxyHttpProtocol {
            [pscustomobject]@{ Responded = $true; StatusCode = 401; Reason = 'http-response' }
        }
        $script:statusResult = $null
        Mock Write-AiCliJson { param($Object) $script:statusResult = $Object }

        $null = Get-AiCliProxyStatus -ProxyId ccp -Json

        $script:statusResult.processAndListenerVerified | Should -BeTrue
        $script:statusResult.protocolResponded | Should -BeTrue
        $script:statusResult.authenticationVerified | Should -BeFalse
        $script:statusResult.upstreamVerified | Should -BeFalse
    }

    It 'serializes stop through the shared lifecycle lock' {
        $expectedLock = Get-AiCliProxyGlobalLockTarget
        Mock Enter-AiCliFileLock { [pscustomobject]@{ FileStream = $null; LockPath = 'test' } }
        Mock Exit-AiCliFileLock {}
        Mock Stop-AiCliManagedProcess {}

        $null = Stop-AiCliProxy -ProxyId ccp

        Should -Invoke Enter-AiCliFileLock -Times 1 -Exactly -ParameterFilter {
            $TargetPath -eq $expectedLock -and $TimeoutMs -ge 60000
        }
        Should -Invoke Stop-AiCliManagedProcess -Times 1 -Exactly
    }

    It 'refuses installed-instance update before download and keeps current intact' {
        $paths = Initialize-AiCliProxyDirs -ProxyId ccp
        New-Item -ItemType Directory -Path $paths.CurrentLink -Force | Out-Null
        $marker = Join-Path $paths.CurrentLink 'installed.marker'
        New-Item -ItemType File -Path $marker -Force | Out-Null
        $expectedLock = Get-AiCliProxyGlobalLockTarget
        Mock Enter-AiCliFileLock { [pscustomobject]@{ FileStream = $null; LockPath = 'test' } }
        Mock Exit-AiCliFileLock {}
        Mock Invoke-AiCliProxyFirstInstall {}

        $null = Install-AiCliProxy -ProxyId ccp

        Should -Invoke Enter-AiCliFileLock -Times 1 -Exactly -ParameterFilter {
            $TargetPath -eq $expectedLock -and $TimeoutMs -ge 60000
        }
        Should -Invoke Invoke-AiCliProxyFirstInstall -Times 0 -Exactly
        Test-Path -LiteralPath $marker | Should -BeTrue
    }
}
