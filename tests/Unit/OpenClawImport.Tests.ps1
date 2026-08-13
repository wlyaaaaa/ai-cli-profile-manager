#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'OpenClaw import helper' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ImportScript = Join-Path $script:RepoRoot 'scripts\Import-FromOpenClaw.ps1'
    }

    BeforeEach {
        $script:CaseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:DataRoot = Join-Path $script:CaseRoot 'data root'
        $script:Config = Join-Path $script:CaseRoot 'openclaw.json'
        New-Item -ItemType Directory -Force -Path $script:CaseRoot | Out-Null
        [ordered]@{
            models = [ordered]@{
                providers = [ordered]@{
                    openai = [ordered]@{
                        baseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1'
                        apiKey = 'CANARY_OPENCLAW_QWEN_SECRET'
                    }
                    deepseek = [ordered]@{
                        baseUrl = 'https://api.deepseek.com/v1'
                        apiKey = 'CANARY_OPENCLAW_DEEPSEEK_SECRET'
                    }
                }
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:Config -Encoding utf8
    }

    It 'previews recognized providers without writing or revealing secrets' {
        $output = & pwsh -NoLogo -NoProfile -File $script:ImportScript `
            -OpenClawJson $script:Config -DataRoot $script:DataRoot 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Not -Match 'PREVIEW .*qwen'
        $output | Should -Match 'PREVIEW claude-deepseek'
        $output | Should -Match 'PREVIEW codex-deepseek'
        $output | Should -Match 'PREVIEW codex-deepseek-v4-pro'
        $output | Should -Not -Match 'CANARY_OPENCLAW_(QWEN|DEEPSEEK)_SECRET'
        @(Get-ChildItem -LiteralPath $script:DataRoot -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match 'Profiles' }).Count | Should -Be 0
    }

    It 'applies recognized profiles with DPAPI-backed secret references and no plaintext residue' {
        $output = & pwsh -NoLogo -NoProfile -File $script:ImportScript `
            -OpenClawJson $script:Config -DataRoot $script:DataRoot -Apply 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $output | Should -Not -Match 'CANARY_OPENCLAW_(QWEN|DEEPSEEK)_SECRET'
        $profiles = @(Get-ChildItem -LiteralPath $script:DataRoot -Recurse -File -Filter '*.json' |
            Where-Object { $_.DirectoryName -match 'Profiles' })
        $profiles.Count | Should -Be 4
        foreach ($profileFile in $profiles) {
            $profile = Get-Content -LiteralPath $profileFile.FullName -Raw | ConvertFrom-Json
            $profile.secretRef | Should -Match '^[a-f0-9]{32}$'
            $profile.importedFrom | Should -Match '^openclaw:'
        }
        $secretFiles = @(Get-ChildItem -LiteralPath $script:DataRoot -Recurse -File |
            Where-Object { $_.DirectoryName -match 'secrets' })
        $secretFiles.Count | Should -Be 4
        # Secret files are deliberately ACL-restricted and covered by the
        # dedicated SecretStore tests. Scan every non-secret artifact here.
        $allBytesAsText = @(Get-ChildItem -LiteralPath $script:DataRoot -Recurse -File |
            Where-Object { $_.DirectoryName -notmatch 'secrets' } | ForEach-Object {
            [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($_.FullName))
        }) -join "`n"
        $allBytesAsText | Should -Not -Match 'CANARY_OPENCLAW_(QWEN|DEEPSEEK)_SECRET'
    }
}
