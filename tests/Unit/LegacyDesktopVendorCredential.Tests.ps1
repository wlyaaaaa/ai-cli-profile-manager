BeforeAll { $script:Repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }

Describe 'Running legacy Desktop bridge with the newer module' {
    It 'imports the newest module by name and receives all three vendor keys without a DPAPI copy' {
        $hostRoot=Join-Path $TestDrive 'host'
        $data=Join-Path $TestDrive 'profile-data'
        $moduleRoot=Join-Path $TestDrive 'modules/AiCliProfileManager/0.3.19'
        foreach($folder in @('tools','registries')){[IO.Directory]::CreateDirectory((Join-Path $hostRoot $folder))|Out-Null}
        [IO.Directory]::CreateDirectory($moduleRoot)|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $data 'AppData/profiles'))|Out-Null
        $origins=@{qwen='https://dashscope.aliyuncs.com';glm='https://open.bigmodel.cn';deepseek='https://api.deepseek.com'}
        $vendors=@{}
        foreach($vendor in $origins.Keys){$vendors[$vendor]=@{origins=@{http=$origins[$vendor]}}}
        @{api_vendors=$vendors}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $hostRoot 'registries/secret_broker.json') -Encoding utf8
        @{schemaVersion=1;id='codex-qwen3-8-max-paygo';templateId='codex-qwen3-8-max-paygo';endpoint='https://ws-fixture.cn-beijing.maas.aliyuncs.com/compatible-mode/v1'}|
            ConvertTo-Json|Set-Content (Join-Path $data 'AppData/profiles/codex-qwen3-8-max-paygo.json') -Encoding utf8
        $fakeBroker=Join-Path $hostRoot 'tools/Invoke-PasswordCenterVendor.ps1'
        @'
param([string]$Vendor,[string]$RequestPath,[switch]$NativeClient,[switch]$Json)
$ErrorActionPreference='Stop'
if(-not $NativeClient){exit 9}
$r=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
$map=@{qwen='https://dashscope.aliyuncs.com';glm='https://open.bigmodel.cn';deepseek='https://api.deepseek.com'}
if($r.endpoint -cne $map[$Vendor] -or $r.vendor -cne $Vendor){exit 8}
$p=[IO.Pipes.NamedPipeClientStream]::new('.',$r.pipe_name,[IO.Pipes.PipeDirection]::Out)
try{$p.Connect(10000);$bytes=[Text.Encoding]::UTF8.GetBytes('synthetic-legacy-'+$Vendor);$p.Write($bytes);$p.Flush()}finally{$p.Dispose()}
[Console]::Out.Write('{"schema":"pcconfig.secret-broker-result.v1","status":"pass","secret_returned":false}')
'@ | Set-Content -LiteralPath $fakeBroker -Encoding utf8
        # Run the unchanged legacy release script in a fresh process. Its
        # fallback Import-Module by name resolves this 0.3.19 fixture module.
        $source=Get-Content (Join-Path $script:Repo 'src/AiCliProfileManager/AiCliProfileManager.psm1') -Raw
        $private=(Join-Path $script:Repo 'src/AiCliProfileManager/Private').Replace("'","''")
        $public=(Join-Path $script:Repo 'src/AiCliProfileManager/Public').Replace("'","''")
        $source=$source.Replace('$privateDir = Join-Path $PSScriptRoot ''Private''', '$privateDir = '''+$private+'''')
        $source=$source.Replace('$publicDir  = Join-Path $PSScriptRoot ''Public''', '$publicDir = '''+$public+'''')
        $source+="`nSet-AiCliDataRootOverride -Path `$env:AICLI_LEGACY_TEST_DATA`nfunction script:Get-AiCliVendorBrokerPath { return `$env:AICLI_LEGACY_TEST_BROKER }`n"
        $source|Set-Content (Join-Path $moduleRoot 'AiCliProfileManager.psm1') -Encoding utf8
        "@{RootModule='AiCliProfileManager.psm1';ModuleVersion='0.3.19';GUID='a1c11c11-0a11-4c11-b111-a1c110110011'}"|
            Set-Content (Join-Path $moduleRoot 'AiCliProfileManager.psd1') -Encoding utf8
        $legacy=Join-Path $script:Repo 'tests/fixtures/LegacyDesktopProviderToken-562b29bf.ps1'
        foreach($case in @(@{Vendor='qwen';Profile='codex-qwen3-8-max-paygo'},@{Vendor='glm';Profile='codex-glm-5-3'},@{Vendor='deepseek';Profile='codex-deepseek-flash'})) {
            $start=[Diagnostics.ProcessStartInfo]::new('pwsh')
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $start.Environment['PSModulePath']=(Join-Path $TestDrive 'modules')+';'+$env:PSModulePath
            $start.Environment['AICLI_LEGACY_TEST_DATA']=$data
            $start.Environment['AICLI_LEGACY_TEST_BROKER']=$fakeBroker
            foreach($arg in @('-NoProfile','-NonInteractive','-File',$legacy,'-ProfileId',$case.Profile)){[void]$start.ArgumentList.Add($arg)}
            $process=[Diagnostics.Process]::Start($start)
            try {
                $read=$process.StandardOutput.ReadToEndAsync();$errorRead=$process.StandardError.ReadToEndAsync()
                if(-not $process.WaitForExit(20000)){$process.Kill($true);throw 'legacy helper timed out'}
                $process.ExitCode | Should -Be 0 -Because $errorRead.GetAwaiter().GetResult()
                ($read.GetAwaiter().GetResult() -ceq ('synthetic-legacy-'+$case.Vendor)) | Should -BeTrue
            } finally {$process.Dispose()}
        }
        @(Get-ChildItem (Join-Path $data 'Local/secrets') -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}
