#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Redaction' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        # load private for direct test
        . (Join-Path $root 'src\AiCliProfileManager\Private\Brand.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\Redaction.ps1')
    }

    It 'redacts sk- style tokens' {
        $t = Protect-AiCliSecretText 'key=sk-test-canary-not-a-real-secret-00000'
        $t | Should -Not -Match 'sk-test-canary'
        $t | Should -Match 'REDACTED'
    }

    It 'redacts the complete Bearer credential before key-value matching' {
        foreach ($secret in @(
            'OPAQUE_TOKEN_VALUE_123456',
            'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature_part',
            'sk-test-canary-not-a-real-secret-12345'
        )) {
            $safe = Protect-AiCliSecretText "Authorization: Bearer $secret"
            $safe | Should -Not -Match ([regex]::Escape($secret))
            $safe | Should -Match 'REDACTED'

            $safeEquals = Protect-AiCliSecretText "authorization=Bearer $secret"
            $safeEquals | Should -Not -Match ([regex]::Escape($secret))
        }
    }

    It 'redacts Basic credentials and every segment of a standalone JWT' {
        $basic = 'dXNlcjpwYXNzd29yZA=='
        $safeBasic = Protect-AiCliSecretText "Authorization: Basic $basic"
        $safeBasic | Should -Not -Match ([regex]::Escape($basic))

        $jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature_part'
        $safeJwt = Protect-AiCliSecretText "upstream failed with $jwt"
        $safeJwt | Should -Not -Match ([regex]::Escape($jwt))
        $safeJwt | Should -Match 'REDACTED'
    }

    It 'redacts object secret keys' {
        $o = Protect-AiCliObject @{ apiKey = 'super-secret-value'; model = 'x' }
        $o.apiKey | Should -Be '***REDACTED***'
        $o.model | Should -Be 'x'
    }

    It 'redacts Qwen Workspace identifiers while preserving the endpoint family' {
        $workspaceId = 'ws-sensitive-workspace-123'
        $safe = Protect-AiCliSecretText (
            "https://$workspaceId.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        )

        $safe | Should -Not -Match ([regex]::Escape($workspaceId))
        $safe | Should -Be 'https://ws-***.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'
    }
}
