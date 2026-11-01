BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../src/AiCliProfileManager/AiCliProfileManager.psd1') -Force
    $script:oldProvider = $env:AICLI_MODEL_ROUTING_PROVIDER
    $script:oldRegistry = $env:AICLI_MODEL_ROUTING_REGISTRY
    $env:AICLI_MODEL_ROUTING_REGISTRY = $null
    $script:provider = Join-Path $TestDrive 'provider.ps1'
    @'
function Resolve-ModelSelection {
    param($Model,$Effort,$Registry)
    @{ model=$(if($Model -ceq 'orbit-classic'){'lantern'}else{$Model}); effort=$Effort; family='arbitrary'; replaced=($Model -ceq 'orbit-classic') }
}
'@ | Set-Content -LiteralPath $script:provider -Encoding utf8
    $env:AICLI_MODEL_ROUTING_PROVIDER = $script:provider
}
AfterAll {
    $env:AICLI_MODEL_ROUTING_PROVIDER = $script:oldProvider
    $env:AICLI_MODEL_ROUTING_REGISTRY = $script:oldRegistry
}
Describe 'Optional central model routing' {
    It 'routes arbitrary unversioned families in runtime Profiles without rewriting originals' {
        InModuleScope AiCliProfileManager {
            $source = @{id='custom'; endpoint='http://127.0.0.1:1234/v1'; models=@{primary='orbit-classic';small='orbit-classic';candidates=@('orbit-classic')}}
            $result = Update-AiCliProfileModelRouting $source
            $result.models.primary | Should -BeExactly 'lantern'
            $result.models.candidates[0] | Should -BeExactly 'lantern'
            $result.endpoint | Should -BeExactly $source.endpoint
            $source.models.primary | Should -BeExactly 'orbit-classic'
            (Resolve-AiCliModelSelection 'unregistered').model | Should -BeExactly 'unregistered'
        }
    }
    It 'routes every supported explicit native model spelling' {
        InModuleScope AiCliProfileManager {
            $args = @(Update-AiCliNativeModelRouting @('--model','orbit-classic','--model=orbit-classic','-morbit-classic','model="orbit-classic"'))
            ($args -join '|') | Should -BeExactly '--model|lantern|--model=lantern|-mlantern|model="lantern"'
        }
    }
    It 'puts the central target in the actual launch arguments before dispatch' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            Mock Get-AiCliResolvedProfile { @{id='codex-official';engine='codex';provider='openai';configured=$true;flexible=$true;models=@{primary='unregistered'};defaultEffort='high'} }
            Mock Resolve-AiCliCodexLaunchExecutable { @{FileName='fake.exe';PrefixArgs=@();Kind='fake'} }
            Mock Assert-AiCliProfileMinimumCliVersion {}
            $plan=Build-AiCliLaunchPlan -ProfileId codex-official -ProjectPath $Work -NativeArgs @('--model','orbit-classic')
            $plan.model | Should -BeExactly 'lantern'
            $plan.argumentList | Should -Contain 'lantern'
            $plan.argumentList | Should -Not -Contain 'orbit-classic'
        }
    }
    It 'writes the effective target into generated TOML and catalog data' {
        InModuleScope AiCliProfileManager {
            $p=@{id='fake';endpoint='http://127.0.0.1:1234/v1';displayName='fake';models=@{primary='orbit-classic'}}
            New-AiCliCodexProviderToml -MergedProfile $p | Should -Match 'model = "lantern"'
            $catalog = '{"models":[{"slug":"orbit-classic","display_name":"old","default_reasoning_level":"high"}]}' | ConvertFrom-Json
            (Update-AiCliCatalogModelRouting $catalog).models[0].slug | Should -BeExactly 'lantern'
        }
    }
    It 'deduplicates routed catalog aliases while preserving current model capabilities in either order' {
        InModuleScope AiCliProfileManager {
            foreach ($reverse in @($false, $true)) {
                $old = '{"slug":"orbit-classic","display_name":"old","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"}],"vendorMetadata":{"generation":"old"}}' | ConvertFrom-Json
                $duplicate = $old.PSObject.Copy()
                $current = '{"slug":"lantern","display_name":"Current model","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"high"},{"effort":"max"}],"vendorMetadata":{"generation":"current","futureField":17}}' | ConvertFrom-Json
                $unknown = '{"slug":"unregistered","display_name":"Unknown model","default_reasoning_level":"medium","futureField":23}' | ConvertFrom-Json
                $before = $current | ConvertTo-Json -Depth 20 -Compress
                $catalog = @{ models = $(if ($reverse) { @($current, $old, $duplicate, $unknown) } else { @($old, $duplicate, $current, $unknown) }) }
                $result = Update-AiCliCatalogModelRouting $catalog
                @($result.models).Count | Should -Be 2
                $result.models[0].slug | Should -BeExactly 'lantern'
                ($result.models[0] | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $before
                $result.models[1].futureField | Should -Be 23
            }
        }
    }
    It 'blocks a retired durable run before sync or dispatch and preserves its ledger' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            $script:AiCliDataRootOverride = Join-Path $Work 'recovery'
            try {
                Mock Build-AiCliLaunchPlan { [pscustomobject]@{engine='codex';profileId='fake';profileFingerprint=('a'*64);workingDirectory=$Work;model='orbit-classic';modelProvider='fake';wire='responses';effort='high';effectiveEffort='high'} }
                $created=New-AiCliRecoverableRun -ProfileId fake -ProjectPath $Work -TaskText task -TimeoutMs 5000 -MaxSteps 8 -MaxToolCalls 4
                $before=Get-AiCliRecoverableRunState -RunId $created.runId | ConvertTo-Json -Depth 100
                Mock Sync-AiCliRecoverableRunState { throw 'must not sync' }
                $result=Invoke-AiCliRecoverableRunCore -RunId $created.runId
                $result.status | Should -BeExactly 'migration_required'
                $result.model | Should -BeExactly 'orbit-classic'
                $result.modelMigration.targetModel | Should -BeExactly 'lantern'
                (Get-AiCliRecoverableRunState -RunId $created.runId | ConvertTo-Json -Depth 100) | Should -BeExactly $before
            } finally { $script:AiCliDataRootOverride=$null }
        }
    }
}
