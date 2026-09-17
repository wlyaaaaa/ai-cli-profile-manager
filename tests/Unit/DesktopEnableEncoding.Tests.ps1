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
