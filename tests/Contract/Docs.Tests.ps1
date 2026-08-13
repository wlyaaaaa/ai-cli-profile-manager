#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Docs contract' {
    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:UserDocs = Join-Path $script:Root 'docs\user'
    }

    It 'has required user handbook files' {
        $required = @(
            'QUICKSTART.md','START-AND-PROFILES.md','DOCTOR-AND-TEST.md','PROXIES.md',
            'CLI-COMMANDS.md','CLI-LEARNING.md','UPDATE-AND-REPAIR.md','TROUBLESHOOTING.md','PRIVACY-AND-UNINSTALL.md',
            'OPEN-INTERPRETER.md','CLAUDE-PERMISSIONS-AND-QWEN.md'
        )
        foreach ($f in $required) {
            Test-Path (Join-Path $script:UserDocs $f) | Should -BeTrue -Because $f
        }
    }

    It 'README mentions aicli and 0.3.5' {
        $readme = Get-Content (Join-Path $script:Root 'README.md') -Raw
        $readme | Should -Match 'aicli'
        $readme | Should -Match '0\.3\.5'
    }

    It 'no TODO placeholders in user docs' {
        Get-ChildItem $script:UserDocs -Filter '*.md' | ForEach-Object {
            $t = Get-Content $_.FullName -Raw
            $t | Should -Not -Match 'TODO\(implement\)'
        }
    }

    It 'binds generated handbook PDFs to the current 0.3.5 main documentation' {
        $builder = Get-Content (Join-Path $script:Root 'scripts\Build-Pdfs.py') -Raw
        $playwrightHelper = Join-Path $script:Root 'scripts\Print-HtmlPdfPlaywright.js'
        $builder | Should -Match 'VERSION\s*=\s*"0\.3\.5"'
        $builder | Should -Match 'REPOSITORY_BLOB\s*=\s*"https://github\.com/wlyaaaaa/ai-cli-profile-manager/blob/main"'
        $builder | Should -Match 'render_with_playwright'
        Test-Path -LiteralPath $playwrightHelper -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath $playwrightHelper -Raw) | Should -Match 'page\.pdf'
    }

    It 'documents loss-aware third-party continuity without changing the native baseline' {
        $main = Get-Content (Join-Path $script:UserDocs 'AI CLI Profile Manager 使用手册.md') -Raw
        $cli = Get-Content (Join-Path $script:UserDocs 'Codex、Claude Code 与 Open Interpreter CLI 中文手册.md') -Raw
        foreach ($text in @($main, $cli)) {
            $text | Should -Match '原生 ChatGPT\s*\+\s*Codex'
            $text | Should -Match '不要.*主动.*compact'
            $text | Should -Match 'AGENTS\.md'
            $text | Should -Match 'SKILL\.md'
            $text | Should -Match 'git (status|diff)'
        }
    }
}
