#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Repository PowerShell encoding contract' {
    It 'uses UTF-8 BOM for every tracked PowerShell script containing Chinese text' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $paths = @(git -C $repoRoot -c core.quotepath=false ls-files -- '*.ps1')
        $LASTEXITCODE | Should -Be 0
        $paths.Count | Should -BeGreaterThan 0
        $missing = @(foreach ($path in $paths) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $repoRoot $path))
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            if ($text -match '\p{IsCJKUnifiedIdeographs}' -and
                -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
                    $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
                $path
            }
        })
        $missing | Should -BeNullOrEmpty -Because ($missing -join ', ')
    }
}
