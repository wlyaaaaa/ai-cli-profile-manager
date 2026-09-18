#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Read-only runtime diagnostics' {
    BeforeAll {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $repo 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        function Invoke-DiagnosticFixture {
            param([string]$Root, [string]$Registry = '')
            $old = [Console]::Out
            $writer = [IO.StringWriter]::new()
            $tokens = @('diagnose','--json')
            if ($Registry) { $tokens += @('--bridge-registry',$Registry) }
            try {
                [Console]::SetOut($writer)
                $code = Invoke-AiCli -Tokens $tokens -DataRoot $Root
            } finally { [Console]::SetOut($old) }
            $code | Should -Be 0
            return ($writer.ToString() | ConvertFrom-Json -Depth 40).diagnostics
        }
        function New-DiagnosticFixture {
            param([string]$Root)
            $releaseId = '0123456789abcdef'
            $desktop = Join-Path $Root 'Local\desktop'
            $release = Join-Path $desktop ('releases\' + $releaseId)
            [void][IO.Directory]::CreateDirectory((Join-Path $release 'bridge'))
            $files = @()
            foreach($relative in @('GetDesktopModelPlan.ps1','GetDesktopProviderToken.ps1','ResolveDesktopEngine.ps1','bridge\AiCli.CodexDesktopBridge.deps.json','bridge\AiCli.CodexDesktopBridge.dll','bridge\AiCli.CodexDesktopBridge.exe','bridge\AiCli.CodexDesktopBridge.runtimeconfig.json')) {
                $file = Join-Path $release $relative
                [IO.File]::WriteAllText($file,'PUBLIC_TEST_FIXTURE',[Text.UTF8Encoding]::new($false))
                $files += @{path=$relative; size=(Get-Item -LiteralPath $file).Length; sha256=(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()}
            }
            $state = @{schemaVersion=2; enabled=$true; executable=(Join-Path $release 'bridge\AiCli.CodexDesktopBridge.exe'); ignored_private_field='SENSITIVE_TEST_SENTINEL'}
            $statePath = Join-Path $desktop 'state.json'
            [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            $registryPath = Join-Path $Root 'bridge-registry.json'
            $registry = @{schema='pcconfig.aicli-desktop-bridge-allowlist.v1'; releases=@(@{release_id=$releaseId; files=$files})}
            [IO.File]::WriteAllText($registryPath,($registry|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            return @{registry=$registryPath; state=$statePath; release=$release}
        }
        function Get-FixtureSnapshot {
            param([string]$Root)
            return @((Get-ChildItem -LiteralPath $Root -File -Recurse) | Sort-Object FullName | ForEach-Object {
                '{0}|{1}|{2}' -f $_.FullName,$_.LastWriteTimeUtc.Ticks,(Get-FileHash -LiteralPath $_.FullName).Hash
            }) -join "`n"
        }
    }
    It 'does not initialize a missing application root' {
        $root = Join-Path $TestDrive 'absent'
        $diag = Invoke-DiagnosticFixture -Root $root
        $diag.schema | Should -BeExactly 'aicli.runtime-diagnostics.v1'
        $diag.write_mode | Should -BeExactly 'zero_write'
        $diag.network_performed | Should -BeFalse
        $diag.model_invoked | Should -BeFalse
        $diag.credentials_read | Should -BeFalse
        $diag.desktop.configuration_state | Should -BeExactly 'not_configured'
        Test-Path -LiteralPath $root | Should -BeFalse
    }
    It 'verifies seven files without promoting runtime or E2E evidence and without writes' {
        $root = Join-Path $TestDrive 'verified'
        $fixture = New-DiagnosticFixture -Root $root
        $before = Get-FixtureSnapshot -Root $root
        $diag = Invoke-DiagnosticFixture -Root $root -Registry $fixture.registry
        $diag.desktop.installation_state | Should -BeExactly 'verified'
        $diag.desktop.running_process_loaded | Should -BeExactly 'unknown'
        $diag.desktop.end_to_end | Should -BeExactly 'unknown'
        $diag.desktop.files.Count | Should -Be 7
        foreach($file in $diag.desktop.files) {
            $file.regular_file | Should -BeOfType ([bool])
            $file.regular_file | Should -BeTrue
            $file.size_match | Should -BeTrue
            $file.sha256_match | Should -BeTrue
        }
        ($diag | ConvertTo-Json -Depth 20) | Should -Not -Match 'SENSITIVE_TEST_SENTINEL'
        (Get-FixtureSnapshot -Root $root) | Should -BeExactly $before
    }
    It 'distinguishes configuration from unverified installation' {
        $root = Join-Path $TestDrive 'unverified'
        $null = New-DiagnosticFixture -Root $root
        $diag = Invoke-DiagnosticFixture -Root $root
        $diag.desktop.configuration_state | Should -BeExactly 'configured'
        $diag.desktop.installation_state | Should -BeExactly 'registry_not_supplied'
    }
    It 'reports a mismatching file without repairing or replacing it' {
        $root = Join-Path $TestDrive 'mismatch'
        $fixture = New-DiagnosticFixture -Root $root
        [IO.File]::WriteAllText((Join-Path $fixture.release 'ResolveDesktopEngine.ps1'),'DIFFERENT_PUBLIC_FIXTURE')
        $before = Get-FixtureSnapshot -Root $root
        $diag = Invoke-DiagnosticFixture -Root $root -Registry $fixture.registry
        $diag.desktop.installation_state | Should -BeExactly 'mismatch'
        (Get-FixtureSnapshot -Root $root) | Should -BeExactly $before
    }
    It 'does not disclose malformed state or guessed execution identity' {
        $root = Join-Path $TestDrive 'malformed'
        $fixture = New-DiagnosticFixture -Root $root
        [IO.File]::WriteAllText($fixture.state,'SENSITIVE_TEST_SENTINEL_NOT_JSON')
        $diag = Invoke-DiagnosticFixture -Root $root -Registry $fixture.registry
        $diag.desktop.configuration_state | Should -BeExactly 'invalid'
        $diag.desktop.installation_state | Should -BeExactly 'invalid_or_unavailable'
        ($diag | ConvertTo-Json -Depth 20) | Should -Not -Match 'SENSITIVE_TEST_SENTINEL'
    }
    It 'rejects a non-managed executable path before inspecting it' {
        $root = Join-Path $TestDrive 'scope'
        $fixture = New-DiagnosticFixture -Root $root
        [IO.File]::WriteAllText($fixture.state,(@{enabled=$true;executable=(Join-Path $TestDrive 'outside.exe')}|ConvertTo-Json))
        $diag = Invoke-DiagnosticFixture -Root $root -Registry $fixture.registry
        $diag.desktop.installation_state | Should -BeExactly 'invalid_or_unavailable'
    }
    It 'preserves pipeline booleans through the public redaction boundary' {
        InModuleScope AiCliProfileManager {
            $bool = Test-Path -LiteralPath $PSScriptRoot
            $result = Protect-AiCliObject -InputObject @{exists=$bool; nested=[pscustomobject]@{ok=$true;token='SENSITIVE_TEST_SENTINEL'}}
            $json = $result | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            $json.exists | Should -BeOfType ([bool])
            $json.nested.ok | Should -BeTrue
            $json.nested.token | Should -BeExactly '***REDACTED***'
        }
    }
}
