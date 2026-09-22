#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
Describe 'Antigravity model-only P0 contract' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        . (Join-Path $root 'src\AiCliProfileManager\Support\AntigravityProbeContract.ps1')
        function New-ProbeInit {
            '{"event":"init","conversation_id":"11111111-1111-4111-8111-111111111111","init":{"model":"gemini-3.8-flash-high","agent":"aicli-codex-model-bridge","permission_mode":"request-review","tools":[]}}' | ConvertFrom-Json
        }
        function New-ProbeUsage {
            @{ input_tokens=100L; output_tokens=10L; thinking_tokens=8L; cache_read_tokens=20L; total_tokens=110L }
        }
    }
    It 'accepts only the initialization stage, not provider readiness' {
        $v = Test-AiCliAntigravityInitialization (New-ProbeInit)
        $v.status | Should -Be 'pass'
        $v.provider_readiness | Should -Be 'not_evaluated'
        $v.tool_count | Should -Be 0
        ($v | ConvertTo-Json -Compress) | Should -Not -Match '11111111|conversation_id'
    }
    It 'blocks the actual P0 failure shape even with a correctly echoed agent and model' {
        $e=New-ProbeInit; $e.init.tools=@('run_command','write_to_file','call_mcp_tool','search_web','invoke_subagent')
        $v=Test-AiCliAntigravityInitialization $e
        $v.status | Should -Be 'blocked'
        $v.reason | Should -Be 'native_tools_present'
        $v.tool_count | Should -Be 5
    }
    It 'does not silently allow manage_task as a supposedly harmless exception' {
        $e=New-ProbeInit; $e.init.tools=@('manage_task')
        (Test-AiCliAntigravityInitialization $e).reason | Should -Be 'native_tools_present'
    }
    It 'rejects missing and malformed tool inventory' -ForEach @(@{Value=$null},@{Value=''},@{Value=@{}},@{Value='[]'}) {
        $e=New-ProbeInit; $e.init.tools=$Value
        (Test-AiCliAntigravityInitialization $e).status | Should -Be 'blocked'
    }
    It 'rejects absent init, forged identity, alias fallback and relaxed permissions' {
        (Test-AiCliAntigravityInitialization $null).status | Should -Be 'blocked'
        $e=New-ProbeInit; $e.conversation_id='not-a-session'
        (Test-AiCliAntigravityInitialization $e).reason | Should -Be 'invalid_conversation_identity'
        $e=New-ProbeInit; $e.init.model='gemini-3.8-flash'
        (Test-AiCliAntigravityInitialization $e).reason | Should -Be 'model_identity_mismatch'
        $e=New-ProbeInit; $e.init.agent='default'
        (Test-AiCliAntigravityInitialization $e).reason | Should -Be 'agent_identity_mismatch'
        $e=New-ProbeInit; $e.init.permission_mode='always-proceed'
        (Test-AiCliAntigravityInitialization $e).reason | Should -Be 'permission_mode_mismatch'
    }
    It 'requires the exact requested Google effort variant' -ForEach @(@{Effort='low'},@{Effort='medium'},@{Effort='high'}) {
        $e=New-ProbeInit; $e.init.model='gemini-3.8-flash-'+$Effort
        (Test-AiCliAntigravityInitialization $e -Effort $Effort).status | Should -Be 'pass'
    }
    It 'identifies inherited API routing and credentials without reading values or changing parent state' {
        $envs=@{GEMINI_API_KEY='dummy';GOOGLE_API_KEY='dummy';GOOGLE_APPLICATION_CREDENTIALS='dummy';OPENAI_BASE_URL='dummy';CODEX_HOME='dummy';HTTPS_PROXY='retained';PATH='retained';USERPROFILE='retained'}
        $names=@(Get-AiCliAntigravityEnvironmentRemovalNames $envs)
        $names | Should -Contain 'GEMINI_API_KEY'
        $names | Should -Contain 'GOOGLE_API_KEY'
        $names | Should -Contain 'GOOGLE_APPLICATION_CREDENTIALS'
        $names | Should -Not -Contain 'HTTPS_PROXY'
        $names | Should -Not -Contain 'USERPROFILE'
        $envs.GEMINI_API_KEY | Should -Be 'dummy'
        ($names -join ',') | Should -Not -Match 'dummy'
    }
    It 'differences cumulative usage without double counting thinking' {
        $old=New-ProbeUsage; $new=New-ProbeUsage
        $new.input_tokens=130L; $new.output_tokens=25L; $new.thinking_tokens=18L; $new.cache_read_tokens=40L; $new.total_tokens=155L
        $d=Get-AiCliAntigravityUsageDelta -Current $new -Previous $old
        $d.input_tokens | Should -Be 30
        $d.output_tokens | Should -Be 15
        $d.thinking_tokens | Should -Be 10
        $d.total_tokens | Should -Be 45
    }
    It 'accepts the first complete snapshot without fabricating an earlier one' {
        (Get-AiCliAntigravityUsageDelta -Current (New-ProbeUsage)).total_tokens | Should -Be 110
    }
    It 'fails instead of silently clamping a regressed usage counter' {
        $old=New-ProbeUsage; $new=New-ProbeUsage; $new.output_tokens=1L
        {Get-AiCliAntigravityUsageDelta -Current $new -Previous $old} | Should -Throw '*regressed*'
    }
    It 'rejects incomplete or noninteger usage, including null and boolean counters' {
        $u=New-ProbeUsage; $u.Remove('thinking_tokens')
        {Get-AiCliAntigravityUsageDelta -Current $u} | Should -Throw '*incomplete*'
        foreach($bad in @($null,$true,'1',-1,1.5)) {
            $u=New-ProbeUsage; $u.input_tokens=$bad
            {Get-AiCliAntigravityUsageDelta -Current $u} | Should -Throw '*invalid_counter*'
        }
    }
    It 'fails closed for partial evidence even under StrictMode' {
        Set-StrictMode -Version Latest
        foreach ($e in @([pscustomobject]@{},[pscustomobject]@{event='init';init=@{}},'not-json',@(1,2))) {
            (Test-AiCliAntigravityInitialization $e).status | Should -Be 'blocked'
        }
        $e=New-ProbeInit; $e.init.PSObject.Properties.Remove('tools')
        (Test-AiCliAntigravityInitialization $e).status | Should -Be 'blocked'
        Set-StrictMode -Off
    }
}
