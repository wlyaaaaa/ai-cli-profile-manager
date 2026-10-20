#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Desktop enable UTF-8 discovery handoff' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $scriptPath = Join-Path $repoRoot 'scripts\Set-CodexDesktopLocalModels.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $scriptPath, [ref]$tokens, [ref]$errors
        )
        $errors.Count | Should -Be 0
        $definition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Invoke-Utf8JsonPowerShellFile'
        }, $true))
        $definition.Count | Should -Be 1
        $script:utf8 = [Text.UTF8Encoding]::new($false)
        . ([scriptblock]::Create($definition[0].Extent.Text))
    }

    It 'preserves Chinese JSON across a nested PowerShell process' {
        $child = Join-Path $TestDrive 'emit-json.ps1'
        $payload = '{"text":"最终答复：清楚区分已验证的结果。","nested":{"ok":true}}'
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
        $base64 = [Convert]::ToBase64String($bytes)
        @"
`$bytes = [Convert]::FromBase64String('$base64')
`$stream = [Console]::OpenStandardOutput()
`$stream.Write(`$bytes, 0, `$bytes.Length)
`$stream.Flush()
"@ | Set-Content -LiteralPath $child -Encoding utf8NoBOM

        $result = Invoke-Utf8JsonPowerShellFile -Path $child

        $result.text | Should -BeExactly '最终答复：清楚区分已验证的结果。'
        $result.nested.ok | Should -BeTrue
    }
}

Describe 'Desktop bridge release retention' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts\Set-CodexDesktopLocalModels.ps1'), [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-ObsoleteDesktopReleases' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    It 'keeps current and previous releases and retries an occupied obsolete release intact' {
        $script:InstallRoot = Join-Path $TestDrive 'desktop'
        $ids = @('1111111111111111', '2222222222222222', '3333333333333333', '4444444444444444', '5555555555555555')
        $files = @('GetDesktopModelPlan.ps1', 'GetDesktopProviderToken.ps1', 'ResolveDesktopEngine.ps1', 'bridge\AiCli.CodexDesktopBridge.exe', 'bridge\AiCli.CodexDesktopBridge.dll', 'bridge\AiCli.CodexDesktopBridge.deps.json', 'bridge\AiCli.CodexDesktopBridge.runtimeconfig.json')
        foreach ($id in $ids) { foreach ($file in $files) {
            if ($id -eq $ids[4] -and $file -in @('GetDesktopProviderToken.ps1', 'ResolveDesktopEngine.ps1')) { continue }
            $path = Join-Path $InstallRoot "releases\$id\$file"
            [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
            [IO.File]::WriteAllText($path, 'fixture')
        } }
        $current = Join-Path $InstallRoot "releases\$($ids[0])\bridge\AiCli.CodexDesktopBridge.exe"
        $previous = Join-Path $InstallRoot "releases\$($ids[1])\bridge\AiCli.CodexDesktopBridge.exe"
        $occupied = Join-Path $InstallRoot "releases\$($ids[2])"
        $handle = [IO.File]::Open((Join-Path $occupied $files[4]), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Remove-ObsoleteDesktopReleases $current $previous
            $current | Should -Exist
            $previous | Should -Exist
            @(Get-ChildItem -LiteralPath $occupied -File -Recurse).Count | Should -Be $files.Count
            (Join-Path $InstallRoot "releases\$($ids[3])") | Should -Not -Exist
            (Join-Path $InstallRoot "releases\$($ids[4])") | Should -Not -Exist
        } finally { $handle.Dispose() }
        Remove-ObsoleteDesktopReleases $current $previous
        $occupied | Should -Not -Exist
    }
    It 'retains an obsolete release intact while its executable is running' {
        $script:InstallRoot = Join-Path $TestDrive 'desktop-running'
        $release = Join-Path $InstallRoot 'releases\6666666666666666'
        $files = @('GetDesktopModelPlan.ps1', 'GetDesktopProviderToken.ps1', 'ResolveDesktopEngine.ps1', 'bridge\AiCli.CodexDesktopBridge.exe', 'bridge\AiCli.CodexDesktopBridge.dll', 'bridge\AiCli.CodexDesktopBridge.deps.json', 'bridge\AiCli.CodexDesktopBridge.runtimeconfig.json')
        foreach ($file in $files) {
            $path = Join-Path $release $file
            [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
            [IO.File]::WriteAllText($path, 'fixture')
        }
        $executable = Join-Path $release 'bridge\AiCli.CodexDesktopBridge.exe'
        Copy-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('System')) 'ping.exe') -Destination $executable -Force
        $start = [Diagnostics.ProcessStartInfo]::new($executable, '-t 127.0.0.1')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        try {
            $process.WaitForExit(1000) | Should -BeFalse
            Remove-ObsoleteDesktopReleases '' ''
            @(Get-ChildItem -LiteralPath $release -File -Recurse).Count | Should -Be $files.Count
        } finally {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
        }
        Remove-ObsoleteDesktopReleases '' ''
        $release | Should -Not -Exist
    }
}

Describe 'Desktop bridge protected approval gate' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $scriptPath = Join-Path $repoRoot 'scripts\Set-CodexDesktopLocalModels.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$errors
        )
        $errors.Count | Should -Be 0
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Test-ProtectedBridgeApproval'
        }, $true)
        $null -ne $functionAst | Should -BeTrue
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    It 'accepts only the exact seven-file release recorded by the protected registry' {
        $releaseId = '0123456789abcdef'
        $release = Join-Path $TestDrive "releases\$releaseId"
        $bridge = Join-Path $release 'bridge'
        New-Item -ItemType Directory -Path $bridge -Force | Out-Null
        $relativePaths = @(
            'GetDesktopModelPlan.ps1',
            'GetDesktopProviderToken.ps1',
            'ResolveDesktopEngine.ps1',
            'bridge\AiCli.CodexDesktopBridge.deps.json',
            'bridge\AiCli.CodexDesktopBridge.dll',
            'bridge\AiCli.CodexDesktopBridge.exe',
            'bridge\AiCli.CodexDesktopBridge.runtimeconfig.json'
        )
        $files = @()
        $index = 0
        foreach ($relative in $relativePaths) {
            $index++
            $target = Join-Path $release $relative
            [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
            [IO.File]::WriteAllText(
                $target,
                "fixture-$index",
                [Text.UTF8Encoding]::new($false)
            )
            $item = Get-Item -LiteralPath $target
            $files += [ordered]@{
                path = $relative
                size = $item.Length
                sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        $registryPath = Join-Path $TestDrive 'aicli_desktop_bridge.json'
        [ordered]@{
            schema = 'pcconfig.aicli-desktop-bridge-allowlist.v1'
            releases = @(
                [ordered]@{
                    release_id = $releaseId
                    install_root = $release
                    files = $files
                }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $registryPath -Encoding utf8NoBOM

        Test-ProtectedBridgeApproval `
            -ReleaseDirectory $release `
            -RegistryPath $registryPath | Should -BeTrue

        $dllPath = Join-Path $bridge 'AiCli.CodexDesktopBridge.dll'
        Add-Content -LiteralPath $dllPath -Value 'tamper'
        Test-ProtectedBridgeApproval `
            -ReleaseDirectory $release `
            -RegistryPath $registryPath | Should -BeFalse

        [IO.File]::WriteAllText(
            $dllPath,
            'fixture-5',
            [Text.UTF8Encoding]::new($false)
        )
        Test-ProtectedBridgeApproval `
            -ReleaseDirectory $release `
            -RegistryPath $registryPath | Should -BeTrue

        $realBridge = Join-Path $TestDrive 'real-bridge'
        Move-Item -LiteralPath $bridge -Destination $realBridge
        New-Item -ItemType Junction -Path $bridge -Target $realBridge | Out-Null
        Test-ProtectedBridgeApproval `
            -ReleaseDirectory $release `
            -RegistryPath $registryPath | Should -BeFalse
    }

    It 'checks protected approval before any activation mutation' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $scriptText = Get-Content -LiteralPath (
            Join-Path $repoRoot 'scripts\Set-CodexDesktopLocalModels.ps1'
        ) -Raw
        $approval = $scriptText.IndexOf(
            'Test-ProtectedBridgeApproval -ReleaseDirectory $release'
        )
        $providerMutation = $scriptText.IndexOf('Register-LocalProviders $plan')
        $entryMutation = $scriptText.IndexOf('Set-UserDesktopEntry $installedExe')
        $approval | Should -BeGreaterThan -1
        $providerMutation | Should -BeGreaterThan $approval
        $entryMutation | Should -BeGreaterThan $approval
    }
}

Describe 'Desktop bridge exact protected release activation' {
    It 'can enable a protected preinstalled release without recomputing its release id' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $text = Get-Content -LiteralPath (
            Join-Path $repoRoot 'scripts\Set-CodexDesktopLocalModels.ps1'
        ) -Raw
        $text | Should -Match '\[ValidatePattern\(''\^\[a-f0-9\]\{16\}\$''\)\]\[string\]\$ReleaseId'
        $text.Contains('if (-not [string]::IsNullOrWhiteSpace($ReleaseId))') | Should -BeTrue
        $text.Contains('    $release = Join-Path $InstallRoot (''releases\'' + $ReleaseId)') | Should -BeTrue
        $text.Contains('Test-ProtectedBridgeApproval -ReleaseDirectory $release') | Should -BeTrue
        $text.Contains('releaseId = (Split-Path $release -Leaf)') | Should -BeTrue
        $text.Contains('        $output = Join-Path $repo ''dist\desktop-bridge''') | Should -BeTrue
    }
}
