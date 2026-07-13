#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'PortAllocator' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        Import-Module (Join-Path $root 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
        . (Join-Path $root 'src\AiCliProfileManager\Private\Brand.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\Paths.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\JsonStore.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\Redaction.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\ManifestService.ps1')
        . (Join-Path $root 'src\AiCliProfileManager\Private\PortAllocator.ps1')
    }

    It 'parses English netsh dynamic range' {
        $text = "Start Port : 49152`nNumber of Ports : 16384"
        $r = Parse-AiCliNetshRanges -Text $text -Kind dynamicport
        $r[0].Start | Should -Be 49152
        $r[0].End | Should -Be (49152 + 16384 - 1)
    }

    It 'orders ccp candidates from 43197' {
        $c = Get-AiCliCandidatePorts -ProxyId ccp
        $c[0] | Should -Be 43197
    }

    It 'orders cliproxy candidates from 43198' {
        $c = Get-AiCliCandidatePorts -ProxyId cliproxy
        $c[0] | Should -Be 43198
    }

    It 'bind check on ephemeral high port in pool' {
        # find a free candidate
        $ok = $false
        foreach ($p in (Get-AiCliCandidatePorts -ProxyId ccp)) {
            $t = Test-AiCliPortCandidate -Port $p
            if ($t.Ok) { $ok = $true; break }
        }
        $ok | Should -BeTrue
    }
}
