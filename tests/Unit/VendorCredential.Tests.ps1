BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Remove-Module AiCliProfileManager -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:Repo 'src/AiCliProfileManager/AiCliProfileManager.psd1') -Force
}

Describe 'Vendor credential references' {
    BeforeEach {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliVendorRegistrations { @{
                qwen=@{native_hosts=@('dashscope.aliyuncs.com');origins=@{http='https://dashscope.aliyuncs.com'}}
                glm=@{native_hosts=@('open.bigmodel.cn');origins=@{http='https://open.bigmodel.cn/api/v1'}}
                deepseek=@{native_hosts=@('api.deepseek.com');origins=@{http='https://api.deepseek.com'}}
                openrouter=@{native_hosts=@('openrouter.ai');origins=@{http='https://openrouter.ai'}}
            } }
        }
    }
    It 'accepts a newly registered vendor and rejects an unregistered reference' {
        InModuleScope AiCliProfileManager {
            $profile = @{ provider='openrouter'; auth=@{type='api-key'}; secretRef='passwordcenter:openrouter'; endpoint='https://openrouter.ai/api' }
            Get-AiCliVendorSecretRef $profile | Should -BeExactly 'passwordcenter:openrouter'
            Mock Request-AiCliVendorCredential { 'synthetic-openrouter-key' }
            Get-AiCliProfileSecret $profile | Should -BeExactly 'synthetic-openrouter-key'
            { Get-AiCliSecret 'passwordcenter:unknown-vendor' } | Should -Throw '*vendor_not_registered*'
            Should -Invoke Request-AiCliVendorCredential -Times 1 -Exactly
        }
    }
    It 'preserves the registered reference of a migrated custom Profile' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliSettings { @{ verification=@{} } }
            Mock Get-AiCliVendorSecretRef { throw 'must preserve the explicit reference' }
            $profile = Merge-AiCliProfile -Template (Get-AiCliProviderManifest 'claude-custom') -UserProfile @{
                id='claude-openrouter-fixture'; templateId='claude-custom'; secretRef='passwordcenter:openrouter'
                endpoint='https://openrouter.ai/api'; models=@{primary='fixture-model'}
            }
            $profile.secretRef | Should -BeExactly 'passwordcenter:openrouter'
            $profile.configured | Should -BeTrue
            $profile.secretConfigured | Should -BeTrue
            $profile.referenceConfigured | Should -BeTrue
            $profile.keyAvailability | Should -BeExactly 'not-checked'
        }
    }
    It 'asks for registration rather than a key for an unregistered provider' {
        InModuleScope AiCliProfileManager {
            $template = Get-AiCliProviderManifest 'codex-glm-5-3'
            $template.provider = 'not-registered'
            Mock Get-AiCliProviderManifest { $template }
            Mock Get-AiCliUserProfile { $null }
            Mock Read-AiCliSecret { throw 'must not ask for a key' }
            { Invoke-AiCliProfileConfigure 'codex-glm-5-3' } | Should -Throw '*请先登记厂商*'
            Should -Invoke Read-AiCliSecret -Times 0
        }
    }
    It 'does not turn a configured vendor reference into verified key presence' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile { $null }
            Mock Get-AiCliSettings { @{ verification=@{} } }
            Mock Request-AiCliVendorCredential { throw 'diagnostic must not fetch a key' }
            Test-AiCliSecretExists 'passwordcenter:glm' | Should -BeNullOrEmpty
            $profile = Get-AiCliResolvedProfile 'codex-glm-5-3'
            $profile.secretConfigured | Should -BeTrue -Because 'legacy Desktop helpers require a configured delivery source'
            $profile.referenceConfigured | Should -BeTrue
            $profile.keyAvailability | Should -BeExactly 'not-checked'
            $state = Get-AiCliProfileCredentialState $profile
            $state.ValueVerified | Should -BeNullOrEmpty
            $state.Status | Should -BeExactly '可用但有限制'
            $state.Presence | Should -BeExactly '引用已配置，密钥未验证'
            (Protect-AiCliObject @{secretPresence=$state.Presence}).secretPresence | Should -BeExactly $state.Presence
            Should -Invoke Request-AiCliVendorCredential -Times 0
        }
    }

    It 'routes the old Get-AiCliSecret call through the registered vendor origin' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliVendorDefaultEndpoint { 'https://api.deepseek.com' }
            Mock Request-AiCliVendorCredential { 'synthetic-legacy-key' }
            Mock Unprotect-AiCliSecretBytes { throw 'must not read DPAPI' }
            $value = Get-AiCliSecret 'passwordcenter:deepseek'
            ($value -ceq 'synthetic-legacy-key') | Should -BeTrue
            Should -Invoke Request-AiCliVendorCredential -Times 1 -ParameterFilter {
                $Vendor -eq 'deepseek' -and $Endpoint -eq 'https://api.deepseek.com' -and -not $Desktop
            }
            Should -Invoke Unprotect-AiCliSecretBytes -Times 0
        }
    }
    It 'reports only a bounded Broker error when trusted-device material is missing' {
        InModuleScope AiCliProfileManager {
            Get-AiCliVendorDeliveryError '{"schema":"pcconfig.secret-broker-result.v1","error":"trusted_device_unlock_missing"}' | Should -BeExactly 'trusted_device_unlock_missing'
            Get-AiCliVendorDeliveryError '{"schema":"pcconfig.secret-broker-result.v1","error":"do not echo arbitrary payload!"}' | Should -BeExactly 'vendor_delivery_failed'
        }
    }
    It 'resolves two GLM models to one reference without reading or copying a secret' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile { $null }
            Mock Get-AiCliSettings { @{ verification=@{} } }
            Mock Get-AiCliSecret { throw 'must not read DPAPI' }
            Mock Request-AiCliVendorCredential { throw 'must not fetch a credential' }
            $first = Get-AiCliResolvedProfile -Id 'codex-glm-5-3'
            $second = Get-AiCliResolvedProfile -Id 'codex-glm-5-3-flash'
            $first.secretRef | Should -BeExactly 'passwordcenter:glm'
            $first.secretRef | Should -BeExactly $second.secretRef
            Should -Invoke Get-AiCliSecret -Times 0
            Should -Invoke Request-AiCliVendorCredential -Times 0
        }
    }

    It 'configures a future GLM model without New-AiCliSecret or a model allowlist' {
        InModuleScope AiCliProfileManager {
            Mock Get-AiCliUserProfile { $null }
            Mock Save-AiCliUserProfile {}
            Mock Read-AiCliSecret { throw 'must not ask for a key' }
            $profile = Invoke-AiCliProfileConfigure -TemplateId 'codex-glm-5-3' -ProfileId 'codex-vendor-custom' -Model 'glm-future-99'
            $profile.secretRef | Should -BeExactly 'passwordcenter:glm'
            $profile.modelOverride | Should -BeExactly 'glm-future-99'
            $merged = Merge-AiCliProfile -Template (Get-AiCliProviderManifest 'codex-glm-5-3') -UserProfile $profile
            $merged.models.primary | Should -BeExactly 'glm-future-99'
            $merged.codexModelCatalog | Should -BeNullOrEmpty
            Get-Command New-AiCliSecret -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Should -Invoke Read-AiCliSecret -Times 0
        }
    }

    It 'keeps the credential only in the CLI child environment and leaves config with its variable name' {
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive } {
            Mock Resolve-AiCliCodexLaunchExecutable { [pscustomobject]@{FileName='C:\fixture\codex.exe'; PrefixArgs=@(); Kind='fixture'} }
            Mock Get-AiCliResolvedCliVersionEvidence { [pscustomobject]@{Version='codex-cli 0.154.0'; FileName='C:\fixture\codex.exe'} }
            Mock Publish-AiCliCodexModelCatalog { $null }
            Mock Write-AiCliCodexManagedProfile { [pscustomobject]@{CliProfileName='fixture'; FilePath=(Join-Path $Work 'config.toml')} }
            Mock Request-AiCliVendorCredential { 'synthetic-aicli-vendor-canary' }
            $profile = Merge-AiCliProfile -Template (Get-AiCliProviderManifest 'codex-glm-5-3') -UserProfile $null
            $plan = Build-AiCliCodexLaunchPlan -MergedProfile $profile -ProjectPath $Work -NativeArgs @('--model','glm-future-100')
            $plan.model | Should -BeExactly 'glm-future-100'
            $plan.environmentDelta.AICLI_CODEX_PROVIDER_KEY | Should -BeExactly 'synthetic-aicli-vendor-canary'
            ($plan.argumentList -join ' ') | Should -Not -Match 'synthetic-aicli-vendor-canary'
            $toml = New-AiCliCodexProviderToml -MergedProfile $profile -EnvKeyName 'AICLI_CODEX_PROVIDER_KEY'
            $toml | Should -Match 'env_key = "AICLI_CODEX_PROVIDER_KEY"'
            $toml | Should -Not -Match 'synthetic-aicli-vendor-canary'
            Should -Invoke Request-AiCliVendorCredential -Times 1 -ParameterFilter { $Vendor -eq 'glm' -and $Endpoint -eq 'https://open.bigmodel.cn/api/v1' }
        }
    }

    It 'receives a synthetic key through a real one-shot local pipe in CLI and Desktop modes' {
        $fake = Join-Path $TestDrive 'fake-broker.ps1'
        @'
param([string]$Vendor,[string]$RequestPath,[switch]$NativeClient,[switch]$Json)
$r=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
if($r.vendor -ne $Vendor -or $r.endpoint -ne 'https://open.bigmodel.cn/api/v1'){exit 2}
$p=[IO.Pipes.NamedPipeClientStream]::new('.', $r.pipe_name, [IO.Pipes.PipeDirection]::Out)
try {$p.Connect(10000); $b=[Text.Encoding]::UTF8.GetBytes('synthetic-aicli-vendor-canary');$p.Write($b);$p.Flush()}finally{$p.Dispose()}
[Console]::Out.Write('{"status":"pass","secret_returned":false}')
'@ | Set-Content -LiteralPath $fake -Encoding utf8
        InModuleScope AiCliProfileManager -Parameters @{ Work=$TestDrive; Fake=$fake } {
            Mock Get-AiCliVendorBrokerPath { $Fake }
            Mock Get-AiCliAppPaths { @{ LocalRoot=$Work } }
            foreach ($desktop in @($false,$true)) {
                $value = Request-AiCliVendorCredential -Vendor glm -Endpoint 'https://open.bigmodel.cn/api/v1' -Desktop:$desktop
                ($value -ceq 'synthetic-aicli-vendor-canary') | Should -BeTrue
                $value = $null
            }
            @(Get-ChildItem -LiteralPath (Join-Path $Work 'vendor-requests') -File).Count | Should -Be 0
        }
    }
}

Describe 'Installed vendor metadata' {
    It 'requires native hosts and reports an unreadable registration explicitly' {
        $hostRoot = Join-Path $TestDrive 'authority-host'
        [IO.Directory]::CreateDirectory((Join-Path $hostRoot 'registries')) | Out-Null
        $registry = Join-Path $hostRoot 'registries/secret_broker.json'
        @{api_vendors=@{openrouter=@{native_hosts=@('openrouter.ai');origins=@{http='https://openrouter.ai'}};no_native=@{origins=@{http='https://invalid.example'}}}} | ConvertTo-Json -Depth 8 | Set-Content $registry
        InModuleScope AiCliProfileManager -Parameters @{ HostRoot=$hostRoot; Registry=$registry } {
            Mock Get-AiCliVendorBrokerPath { Join-Path $HostRoot 'tools/Invoke-PasswordCenterVendor.ps1' }
            (Get-AiCliVendorRegistrations).Contains('no_native') | Should -BeFalse
            Get-AiCliVendorDefaultEndpoint 'openrouter' | Should -BeExactly 'https://openrouter.ai'
            Remove-Item -LiteralPath $Registry
            { Get-AiCliVendorRegistrations } | Should -Throw '*vendor_registration_unavailable*'
        }
    }
}
