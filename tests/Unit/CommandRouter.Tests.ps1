#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'CommandRouter' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        $script:DataRoot = Join-Path $TestDrive 'aicli-data'
        New-Item -ItemType Directory -Force -Path $script:DataRoot | Out-Null
    }

    It 'version returns 0' {
        $code = Invoke-AiCli -Tokens @('version') -DataRoot $script:DataRoot
        $code | Should -Be 0
    }

    It 'version json declares the optional machine event projection' {
        $oldOut = [Console]::Out
        $writer = [IO.StringWriter]::new()
        try {
            [Console]::SetOut($writer)
            $code = Invoke-AiCli -Tokens @('version','--json') -DataRoot $script:DataRoot
        } finally {
            [Console]::SetOut($oldOut)
        }
        $code | Should -Be 0
        $payload = $writer.ToString() | ConvertFrom-Json
        $payload.version | Should -Be (Get-AiCliVersion)
        $payload.capabilities.machineEventProjection | Should -Be 'aicli.machine-event.v1'
        $payload.capabilities.managedPublicWebSearch |
            Should -BeExactly 'public_web_search/bing-rss-v1'
    }

    It 'unknown command returns 2' {
        $code = Invoke-AiCli -Tokens @('definitely-not-a-command') -DataRoot $script:DataRoot
        $code | Should -Be 2
    }

    It 'test without --live fails' {
        $code = Invoke-AiCli -Tokens @('test', 'codex-official') -DataRoot $script:DataRoot
        $code | Should -BeIn @(2, 4)
    }

    It 'profile list --json is pure-ish success' {
        $code = Invoke-AiCli -Tokens @('profile', 'list', '--available', '--json') -DataRoot $script:DataRoot
        $code | Should -Be 0
    }

    It 'discovers exact Codex Profile identities and max mappings in list JSON' {
        $oldOut = [Console]::Out
        $writer = [IO.StringWriter]::new()
        try {
            [Console]::SetOut($writer)
            $code = Invoke-AiCli -Tokens @('profile', 'list', '--available', '--json') -DataRoot $script:DataRoot
        } finally {
            [Console]::SetOut($oldOut)
        }
        $code | Should -Be 0
        $profiles = @((($writer.ToString() | ConvertFrom-Json).profiles))
        foreach ($expected in @(
            @{ id = 'codex-qwen3-7-max-paygo'; model = 'qwen3.7-max-2026-06-08'; requested = 'max'; effective = 'xhigh' },
            @{ id = 'codex-qwen3-8-max-paygo'; model = 'qwen3.8-max'; requested = 'max'; effective = 'xhigh' },
            @{ id = 'codex-deepseek'; model = 'deepseek-v4-flash'; requested = 'max'; effective = 'max' },
            @{ id = 'codex-deepseek-v4-pro'; model = 'deepseek-v4-pro'; requested = 'max'; effective = 'max' },
            @{ id = 'codex-ollama-main'; model = 'qwen-main-v1'; requested = 'max'; effective = 'max' },
            @{ id = 'codex-ollama-review'; model = 'qwen-review-v1'; requested = 'max'; effective = 'max' }
        )) {
            $row = @($profiles | Where-Object id -eq $expected.id)
            $row.Count | Should -Be 1 -Because $expected.id
            $row[0].model | Should -Be $expected.model -Because $expected.id
            $row[0].wire | Should -Be 'responses' -Because $expected.id
            $row[0].requestedEffort | Should -Be $expected.requested -Because $expected.id
            $row[0].effectiveEffort | Should -Be $expected.effective -Because $expected.id
        }
    }

    It 'shows runtime status and the max to native mapping in text list output' {
        $text = (& {
            Invoke-AiCli -Tokens @('profile', 'list', '--available') -DataRoot $script:DataRoot | Out-Null
        } 6>&1 | Out-String)

        $text | Should -Match '状态'
        $text | Should -Match 'codex-qwen3-7-max-paygo.*max→xhigh.*不可用'
        $text | Should -Match 'codex-qwen3-8-max-paygo.*max→xhigh.*不可用'
        $text | Should -Match 'codex-deepseek-v4-pro.*max.*不可用'
    }

    It 'advertises one-command exact Profile starts in help' {
        $help = (& {
            Invoke-AiCli -Tokens @('help') -DataRoot $script:DataRoot | Out-Null
        } 6>&1 | Out-String)
        foreach ($id in @(
            'codex-qwen3-7-max-paygo',
            'codex-qwen3-8-max-paygo',
            'codex-deepseek',
            'codex-deepseek-v4-pro',
            'codex-ollama-main',
            'codex-ollama-review'
        )) {
            $help | Should -Match ([regex]::Escape("aicli start $id --project"))
        }
    }

    It 'help compare works' {
        $code = Invoke-AiCli -Tokens @('help', 'compare') -DataRoot $script:DataRoot
        $code | Should -Be 0
    }

    It 'rejects unknown options instead of silently ignoring them' {
        (Invoke-AiCli -Tokens @('version','--definitely-invalid') -DataRoot $script:DataRoot) | Should -Be 2
        (Invoke-AiCli -Tokens @('native','codex-official','unexpected') -DataRoot $script:DataRoot) | Should -Be 2
        (Invoke-AiCli -Tokens @('profile','list','--definitely-invalid') -DataRoot $script:DataRoot) | Should -Be 2
    }

    It 'routes explicit SecretRef reuse options without accepting a secret value' {
        InModuleScope AiCliProfileManager {
            Mock Invoke-AiCliProfileConfigure {}

            Invoke-AiCliProfileCommand -Tokens @(
                'configure', 'codex-deepseek', '--reuse-existing-secret'
            ) | Should -Be 0
            Should -Invoke Invoke-AiCliProfileConfigure -Times 1 -Exactly -ParameterFilter {
                $TemplateId -eq 'codex-deepseek' -and
                $ReuseExistingSecret -and
                -not $ReuseSecretFrom
            }

            Invoke-AiCliProfileCommand -Tokens @(
                'configure', 'codex-deepseek-v4-pro',
                '--reuse-secret-from', 'codex-deepseek'
            ) | Should -Be 0
            Should -Invoke Invoke-AiCliProfileConfigure -Times 1 -Exactly -ParameterFilter {
                $TemplateId -eq 'codex-deepseek-v4-pro' -and
                -not $ReuseExistingSecret -and
                $ReuseSecretFrom -eq 'codex-deepseek'
            }
        }
    }

    It 'rejects an unknown help topic' {
        (Invoke-AiCli -Tokens @('help','definitely-invalid') -DataRoot $script:DataRoot) | Should -Be 2
    }

    It 'rejects a Claude login request for ccp instead of silently using Codex OAuth' {
        (Invoke-AiCli -Tokens @('proxy','ccp','login','claude') -DataRoot $script:DataRoot) | Should -Be 2
    }

    It 'provides command help topics' {
        foreach ($topic in @('setup','profile','start','doctor','test','proxy','update','native','eject','uninstall')) {
            (Invoke-AiCli -Tokens @('help',$topic) -DataRoot $script:DataRoot) | Should -Be 0
        }
    }
}
