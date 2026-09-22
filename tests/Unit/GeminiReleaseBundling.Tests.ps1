#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.0.0'}
Describe 'Gemini V2 immutable release and model promotion gates' {
    BeforeAll {
        $repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $installer=Join-Path $repo 'scripts\Install-GeminiCodexBridge.ps1'
        $acceptance=Join-Path $repo 'scripts\Test-GeminiModelCandidate.ps1'
        $builder=Join-Path $repo 'scripts\Build-GeminiCodexCatalog.ps1'
        $installText=[IO.File]::ReadAllText($installer)
        $acceptText=[IO.File]::ReadAllText($acceptance)
    }
    It 'has no fixed Gemini 3.8 identity in the release path' {
        $installText | Should -Not -Match 'gemini-3\.8-flash|codex-gemini-3-8-flash'
        $acceptText | Should -Not -Match 'gemini-3\.8-flash|codex-gemini-3-8-flash'
    }
    It 'builds runtime model snapshots from data and model-only update reuses installed binaries' {
        $installText | Should -Match 'Build-GeminiCodexCatalog\.ps1'
        $installText | Should -Match '-RuntimeBundle'
        $installText | Should -Match 'if\(\$Mode-eq''UpdateModels''\)'
        $installText | Should -Match "Name-notin@\('gemini-models\.json','gemini-codex-catalog\.json'\)"
    }
    It 'refreshes an inherited isolation receipt when the runtime template changes' {
        $installText | Should -Match 'isolationReceiptExplicit'
        $installText | Should -Match 'receiptMatches'
        $installText.Contains("if(`$Mode-eq'UpdateModels' -or `$isolationReceiptExplicit){throw 'isolation_receipt_mismatch'}",[StringComparison]::Ordinal) | Should -BeTrue
        $installText | Should -Match '\$needsIsolation=\$true;\$IsolationReceiptPath=\$null'
    }
    It 'proves isolation before the first V2 install and never requires a stale fixed receipt' {
        $installText | Should -Match '--verify-isolation'
        $installText | Should -Match 'isolation_verification_receipt_missing'
        $installText | Should -Match 'isolation_receipt_mismatch'
    }
    It 'runs live model acceptance before the deployment mutation block' {
        $acceptIndex=$installText.IndexOf('Test-GeminiModelCandidate.ps1',[StringComparison]::Ordinal)
        $verifyIndex=$installText.IndexOf('Read-AiCliGeminiModelAcceptance',[StringComparison]::Ordinal)
        $releaseStart=$installText.IndexOf('$releaseId=',[StringComparison]::Ordinal)
        $switchIndex=$installText.IndexOf('& $module {',$releaseStart,[StringComparison]::Ordinal)
        $acceptIndex | Should -BeGreaterThan 0
        $verifyIndex | Should -BeGreaterThan $acceptIndex
        $switchIndex | Should -BeGreaterThan $verifyIndex
        $installText | Should -Match 'modelAcceptanceSha256'
    }
    It 'accepts every registered model effort and requires public summary nonce roundtrip and fresh identities' {
        $acceptText | Should -Match 'foreach\(\$definition in \$set\.models\).*foreach\(\$mapping in \$definition\.efforts\)'
        $acceptText | Should -Match 'candidate_public_summary_missing'
        $acceptText | Should -Match 'candidate_tool_intent_invalid'
        $acceptText | Should -Match 'candidate_nonce_roundtrip_failed'
        $acceptText | Should -Match 'candidate_transport_identity_reused'
        $acceptText | Should -Match 'candidate_acceptance_coverage_incomplete'
    }
    It 'stores only synthetic acceptance evidence and never the nonce itself' {
        $acceptText | Should -Match "schema='aicli\.gemini-model-acceptance\.v1'"
        $acceptText | Should -Match 'nonceRoundTrip=\$true'
        $acceptText | Should -Not -Match 'nonce=\$nonce'
        $acceptText | Should -Not -Match 'answer=\$answer'
    }
    It 'keeps candidate release generation deterministic for a synthetic future model' {
        . (Join-Path $repo 'scripts\GeminiModelData.ps1')
        $data=Get-Content (Join-Path $repo 'data\gemini-models.json') -Raw|ConvertFrom-Json -AsHashtable -Depth 60
        $next=($data.models[0]|ConvertTo-Json -Depth 60)|ConvertFrom-Json -AsHashtable -Depth 60
        $next.id='gemini-future-release-test';$next.profileId='codex-gemini-future-release-test';$next.displayName='Gemini future release test';$next.menuModel='gemini-future-release-exact';$next.defaultEffort='medium';$next.contextWindow=262144;$next.efforts=@(@{effort='medium';model='gemini-future-release-exact';cliEffort='high'});$data.models+=@($next)
        $modelPath=Join-Path $TestDrive 'models.json';[IO.File]::WriteAllText($modelPath,($data|ConvertTo-Json -Depth 60),[Text.UTF8Encoding]::new($false))
        $out=Join-Path $TestDrive 'bundle';$result=& $builder -SourceRoot $repo -ModelSetPath $modelPath -OutputRoot $out -RuntimeBundle
        $result.models | Should -Be 2
        $catalog=Get-Content (Join-Path $out 'gemini-codex-catalog.json') -Raw|ConvertFrom-Json -Depth 100
        @($catalog.entries|Where-Object {$_.model -eq 'gemini-future-release-exact'}).Count | Should -Be 1
        @($catalog.entries|Where-Object {$_.model -eq 'gemini-future-release-exact'})[0].contextWindow | Should -Be 262144
    }
    It 'requires a preaccepted receipt to match release, hashes, freshness and full coverage' {
        $installText | Should -Match 'ModelAcceptanceReceiptPath'
        $installText | Should -Match 'Read-AiCliGeminiModelAcceptance'
        $installText | Should -Match 'oldAcceptance'
        $installText | Should -Match 'modelAcceptanceSha256'
    }
    It 'validates a preaccepted receipt against every exact model and effort' {
        . (Join-Path $repo 'scripts\GeminiModelData.ps1')
        . (Join-Path $repo 'scripts\GeminiModelAcceptance.ps1')
        $set=Read-AiCliGeminiModelSet -Path (Join-Path $repo 'data\gemini-models.json') -SchemaPath (Join-Path $repo 'data\schemas\gemini-model-set.schema.json')
        $release='0123456789abcdef';$modelSha='a'*64;$cliSha=[string]$set.cli.approvedSha256;$isoSha='b'*64
        $coverage=@($set.models|ForEach-Object {$m=$_;@($m.efforts|ForEach-Object {[ordered]@{modelId=$m.id;menuModel=$m.menuModel;requestedModel=$_.model;effort=$_.effort;cliEffort=$_.cliEffort;outcome='capability_pass';errorCode=$null;failurePhase=$null;operationalAttempts=0;summaryObserved=$true;toolIntentVerified=$true;nonceRoundTrip=$true;freshTransactionsVerified=$true;seconds=1.0}})})
        $receipt=[ordered]@{schema='aicli.gemini-model-acceptance.v1';pass=$true;candidateReleaseId=$release;modelSetSha256=$modelSha;cliSha256=$cliSha;isolationReceiptSha256=$isoSha;driverProtocolVersion=2;verifiedUtc=[DateTimeOffset]::UtcNow.ToString('O');coverage=$coverage}
        $path=Join-Path $TestDrive 'acceptance.json';[IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        (Read-AiCliGeminiModelAcceptance -Path $path -ModelSet $set -CandidateReleaseId $release -ModelSetSha256 $modelSha -CliSha256 $cliSha -IsolationReceiptSha256 $isoSha).pass | Should -BeTrue
        $receipt.coverage=@($coverage|Select-Object -Skip 1);[IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        {Read-AiCliGeminiModelAcceptance -Path $path -ModelSet $set -CandidateReleaseId $release -ModelSetSha256 $modelSha -CliSha256 $cliSha -IsolationReceiptSha256 $isoSha}|Should -Throw '*coverage_mismatch*'
    }
    It 'rejects stale, mismatched or capability-incomplete acceptance receipts' {
        . (Join-Path $repo 'scripts\GeminiModelData.ps1')
        . (Join-Path $repo 'scripts\GeminiModelAcceptance.ps1')
        $set=Read-AiCliGeminiModelSet -Path (Join-Path $repo 'data\gemini-models.json') -SchemaPath (Join-Path $repo 'data\schemas\gemini-model-set.schema.json')
        $release='fedcba9876543210';$modelSha='c'*64;$cliSha=[string]$set.cli.approvedSha256;$isoSha='d'*64
        $coverage=@($set.models|ForEach-Object {$m=$_;@($m.efforts|ForEach-Object {[ordered]@{modelId=$m.id;requestedModel=$_.model;effort=$_.effort;cliEffort=$_.cliEffort;outcome='capability_pass';errorCode=$null;failurePhase=$null;operationalAttempts=0;summaryObserved=$true;toolIntentVerified=$true;nonceRoundTrip=$true;freshTransactionsVerified=$true}})})
        $receipt=[ordered]@{schema='aicli.gemini-model-acceptance.v1';pass=$true;candidateReleaseId=$release;modelSetSha256=$modelSha;cliSha256=$cliSha;isolationReceiptSha256=$isoSha;driverProtocolVersion=2;verifiedUtc=[DateTimeOffset]::UtcNow.AddDays(-2).ToString('O');coverage=$coverage}
        $path=Join-Path $TestDrive 'stale.json';[IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        {Read-AiCliGeminiModelAcceptance -Path $path -ModelSet $set -CandidateReleaseId $release -ModelSetSha256 $modelSha -CliSha256 $cliSha -IsolationReceiptSha256 $isoSha}|Should -Throw '*expired*'
        $receipt.verifiedUtc=[DateTimeOffset]::UtcNow.ToString('O');$receipt.coverage[0].summaryObserved=$false;[IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        {Read-AiCliGeminiModelAcceptance -Path $path -ModelSet $set -CandidateReleaseId $release -ModelSetSha256 $modelSha -CliSha256 $cliSha -IsolationReceiptSha256 $isoSha}|Should -Throw '*capability_missing*'
    }
    It 'accepts bounded connection or location errors only when the model group still has a real capability pass' {
        . (Join-Path $repo 'scripts\GeminiModelData.ps1')
        . (Join-Path $repo 'scripts\GeminiModelAcceptance.ps1')
        $set=Read-AiCliGeminiModelSet -Path (Join-Path $repo 'data\gemini-models.json') -SchemaPath (Join-Path $repo 'data\schemas\gemini-model-set.schema.json')
        $release='1111111111111111';$modelSha='e'*64;$cliSha=[string]$set.cli.approvedSha256;$isoSha='f'*64
        $m=$set.models[0];$coverage=@();$i=0
        foreach($e in $m.efforts){
            if($i++ -eq 0){$coverage+=[ordered]@{modelId=$m.id;requestedModel=$e.model;effort=$e.effort;cliEffort=$e.cliEffort;outcome='capability_pass';errorCode=$null;failurePhase=$null;operationalAttempts=0;summaryObserved=$true;toolIntentVerified=$true;nonceRoundTrip=$true;freshTransactionsVerified=$true}}
            else{$coverage+=[ordered]@{modelId=$m.id;requestedModel=$e.model;effort=$e.effort;cliEffort=$e.cliEffort;outcome='allowed_operational_error';errorCode='google_location_not_supported';failurePhase='tool_result';operationalAttempts=2;summaryObserved=$true;toolIntentVerified=$true;nonceRoundTrip=$false;freshTransactionsVerified=$false}}
        }
        $receipt=[ordered]@{schema='aicli.gemini-model-acceptance.v1';pass=$true;candidateReleaseId=$release;modelSetSha256=$modelSha;cliSha256=$cliSha;isolationReceiptSha256=$isoSha;driverProtocolVersion=2;verifiedUtc=[DateTimeOffset]::UtcNow.ToString('O');coverage=$coverage}
        $path=Join-Path $TestDrive 'location-ok.json';[IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        (Read-AiCliGeminiModelAcceptance -Path $path -ModelSet $set -CandidateReleaseId $release -ModelSetSha256 $modelSha -CliSha256 $cliSha -IsolationReceiptSha256 $isoSha).pass|Should -BeTrue
        foreach($c in $coverage){$c.outcome='allowed_operational_error';$c.errorCode='google_location_not_supported';$c.failurePhase='tool_intent';$c.operationalAttempts=2;$c.summaryObserved=$false;$c.toolIntentVerified=$false;$c.nonceRoundTrip=$false;$c.freshTransactionsVerified=$false}
        [IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        {Read-AiCliGeminiModelAcceptance -Path $path -ModelSet $set -CandidateReleaseId $release -ModelSetSha256 $modelSha -CliSha256 $cliSha -IsolationReceiptSha256 $isoSha}|Should -Throw '*model_group_unproven*'
        $coverage[0].outcome='allowed_operational_error';$coverage[0].errorCode='antigravity_login_required'
        [IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        {Read-AiCliGeminiModelAcceptance -Path $path -ModelSet $set -CandidateReleaseId $release -ModelSetSha256 $modelSha -CliSha256 $cliSha -IsolationReceiptSha256 $isoSha}|Should -Throw '*operational_error_invalid*'
    }
    It 'keeps Antigravity transport projectless and Codex-owned while forcing noninteractive child mode' {
        $driver=[IO.File]::ReadAllText((Join-Path $repo 'src\AiCliProfileManager\Support\GeminiBridge\AntigravityDriver.cs'))
        $driver | Should -Match 'start\.Environment\["CI"\]="true"'
        $driver | Should -Not -Match '"--project"|"--new-project"|"--continue"|"--conversation"'
        $driver | Should -Not -Match '"--print="'
        $driver | Should -Match 'Project, workspace, current directory and no-project state belong exclusively to the Codex thread'
    }
    It 'activates the exact prevalidated candidate directory without recompiling it' {
        $installText | Should -Match 'PreparedCandidateDirectory'
        $installText | Should -Match '\$publish=\$PreparedCandidateDirectory'
        $installText | Should -Match 'gemini_prepared_candidate_receipts_required'
        $installText | Should -Match 'gemini_prepared_model_set_mismatch'
        $prepared=$installText.IndexOf('if($PreparedCandidateDirectory)',[StringComparison]::Ordinal)
        $publish=$installText.IndexOf('$publish=$PreparedCandidateDirectory',$prepared,[StringComparison]::Ordinal)
        $buildElse=$installText.IndexOf('}else{',$publish,[StringComparison]::Ordinal)
        $dotnet=$installText.IndexOf('& $dotnet publish',$buildElse,[StringComparison]::Ordinal)
        $generator=$installText.IndexOf('Build-GeminiCodexCatalog.ps1',$buildElse,[StringComparison]::Ordinal)
        $prepared | Should -BeGreaterThan 0
        $publish | Should -BeGreaterThan $prepared
        $dotnet | Should -BeGreaterThan $buildElse
        $generator | Should -BeGreaterThan $buildElse
    }
}
