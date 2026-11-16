Describe 'Live project verification projection' {
    BeforeAll {
        $script:repo = (Resolve-Path "$PSScriptRoot/../..").Path
        Get-Module AiCliProfileManager -All | Remove-Module -Force
        Import-Module "$script:repo/src/AiCliProfileManager/AiCliProfileManager.psd1" -Force
    }
    It 'keeps latest-record counts separate from current validity and excludes private payloads' {
        InModuleScope AiCliProfileManager -Parameters @{ Root = $TestDrive; Repo = $script:repo } {
            param($Root,$Repo)
            Set-AiCliDataRootOverride $Root
            try {
                $paths = Get-AiCliAppPaths
                $old = @{ level='agent'; result='pass'; agentPass=$true; textPass=$true; timestampUtc='2026-09-01T00:00:00Z'; productVersion='0.0.1'; failureSummary='never-export' }
                $new = @{ level='text'; result='fail'; textPass=$false; timestampUtc=[DateTimeOffset]::UtcNow.ToString('o'); productVersion=Get-AiCliVersion }
                Write-AiCliJsonFile $paths.SettingsFile @{ verification=@{ privateName=$old; another=$new } }
                Update-AiCliLiveStatus -SourceRoot $Repo -InstalledRoot "$Repo/src/AiCliProfileManager"
                $live = Get-Content "$($paths.LocalRoot)/live.json" -Raw | ConvertFrom-Json -AsHashtable
                $live.metrics.current_agent | Should -Be 0
                $live.metrics.results | Should -Match '2 个历史测试过的配置.*通过 1 个.*实战的 1 个里通过 1 个'
                $live.records.Count | Should -Be 2
                @($live.records.label) | Should -Contain 'privateName'
                $stableLabel = ($live.public_records | Where-Object version -eq '0.0.1').label
                $stableLabel | Should -Match '^配置 [a-f0-9]{12}$'
                ($live.public_records | ConvertTo-Json) | Should -Not -Match 'privateName|never-export|profile'
                $old.productVersion = Get-AiCliVersion
                Write-AiCliJsonFile $paths.SettingsFile @{ verification=@{ privateName=$old } }
                $null = Invoke-AiCli -Tokens @('help') -DataRoot $Root
                (Get-Content "$($paths.LocalRoot)/live.json" -Raw | ConvertFrom-Json).metrics.current_agent | Should -BeNullOrEmpty
                (Get-Content "$($paths.LocalRoot)/live.json" -Raw | ConvertFrom-Json).public_records[0].label | Should -Be $stableLabel
            } finally { Set-AiCliDataRootOverride $null }
        }
    }
}
