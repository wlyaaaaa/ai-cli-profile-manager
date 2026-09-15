BeforeAll {
    Get-Module AiCliProfileManager -All | Remove-Module -Force
    Import-Module (Join-Path $PSScriptRoot '..\..\src\AiCliProfileManager\AiCliProfileManager.psd1') -Force
}
Describe 'Local model selection' {
    It 'keeps the current four model identities visible' {
        InModuleScope AiCliProfileManager {
            $all = Import-AiCliProviderManifests
            $set = Read-AiCliJsonFile -Path (Get-AiCliDataPath -Relative 'local-model-set.json')
            foreach ($id in $set.profiles) { [bool](Get-AiCliProperty $all[$id] 'hidden' $false) | Should -BeFalse }
        }
    }
    It 'retires a removed model without hiding official or retained local profiles' {
        InModuleScope AiCliProfileManager {
            $set = Read-AiCliJsonFile -Path (Get-AiCliDataPath -Relative 'local-model-set.json')
            $removed = 'codex-ollama-qwen3-8-27b-abliterated'
            $set.profiles = @($set.profiles | Where-Object { $_ -ne $removed })
            Mock Read-AiCliJsonFile { param($Path) Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 60 }
            Mock Read-AiCliJsonFile { $set } -ParameterFilter { $Path -like '*local-model-set.json' }
            $all = Import-AiCliProviderManifests
            $all[$removed].hidden | Should -BeTrue
            [bool](Get-AiCliProperty $all['codex-ollama-main'] 'hidden' $false) | Should -BeFalse
            [bool](Get-AiCliProperty $all['codex-official'] 'hidden' $false) | Should -BeFalse
        }
    }
}
