#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.0.0'}
Describe 'Gemini reversible integration freeze' {
 BeforeAll {
  $repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
  . (Join-Path $repo 'src\AiCliProfileManager\Private\Paths.ps1')
  . (Join-Path $repo 'src\AiCliProfileManager\Private\JsonStore.ps1')
  . (Join-Path $repo 'src\AiCliProfileManager\Private\PortAllocator.ps1')
  . (Join-Path $repo 'src\AiCliProfileManager\Private\GeminiBridgeService.ps1')
  function New-FrozenFixture {
   $paths=Get-AiCliGeminiPaths
   $release='0123456789abcdef';$dir=Join-Path $paths.Root ('releases\'+$release)
   [IO.Directory]::CreateDirectory($dir)|Out-Null
   $files=@('AiCli.GeminiResponsesBridge.exe','AiCli.GeminiResponsesBridge.dll','AiCli.GeminiResponsesBridge.runtimeconfig.json')|ForEach-Object {
    $p=Join-Path $dir $_;[IO.File]::WriteAllText($p,'not executable: freeze unit fixture')
    @{path=$_;sha256=(Get-FileHash $p).Hash.ToLowerInvariant()}
   }
   [IO.File]::WriteAllText($paths.Token,'fixture: must not be decrypted')
   Write-AiCliJsonFile $paths.Settings @{Port=43199}
   Write-AiCliJsonFile $paths.Deployment @{schema='aicli.gemini-deployment.v1';enabled=$true;releaseId=$release;port=43199;files=$files;settingsSha256=(Get-FileHash $paths.Settings).Hash.ToLowerInvariant()}
   return $paths
  }
 }
 BeforeEach {
  $script:freezeRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
  Mock Get-AiCliAppPaths { [pscustomobject]@{LocalRoot=$script:freezeRoot;LocksDir=(Join-Path $script:freezeRoot 'locks');BackupsDir=(Join-Path $script:freezeRoot 'backups')} }
 }
 It 'ships a frozen status independent of model version or previous deployment' {
  (Get-AiCliGeminiIntegrationState).state | Should -BeExactly 'frozen'
  Test-AiCliGeminiIntegrationFrozen | Should -BeTrue
 }
 It 'returns no menu entries without creating a missing runtime' {
  Get-AiCliDesktopGeminiModels | Should -BeNullOrEmpty
  Test-Path $script:freezeRoot | Should -BeFalse
 }
 It 'cannot reactivate an old enabled deployment restored from backup' {
  $p=New-FrozenFixture
  Get-AiCliGeminiDeployment -VerifyFiles | Should -BeNullOrEmpty
  Get-AiCliDesktopGeminiModels | Should -BeNullOrEmpty
  (Read-AiCliGeminiJson $p.Deployment).enabled | Should -BeTrue
 }
 It 'preserves auditable release files through IncludeDisabled' {
  $p=New-FrozenFixture
  $before=(Get-FileHash $p.Deployment).Hash
  $d=Get-AiCliGeminiDeployment -IncludeDisabled -VerifyFiles
  $d.ReleaseId | Should -BeExactly '0123456789abcdef'
  (Get-FileHash $p.Deployment).Hash | Should -Be $before
 }
 It 'blocks regular start before decrypting tokens or making network calls' {
  Mock Get-AiCliGeminiLocalToken { throw 'must_not_decrypt' }
  Mock Invoke-AiCliGeminiControl { throw 'must_not_connect' }
  {Start-AiCliGeminiBridge} | Should -Throw '*gemini_integration_frozen*'
  Should -Invoke Get-AiCliGeminiLocalToken -Times 0
  Should -Invoke Invoke-AiCliGeminiControl -Times 0
 }
 It 'blocks direct service-host entry before process creation' {
  Mock Get-AiCliGeminiLocalToken { throw 'must_not_decrypt' }
  {Invoke-AiCliGeminiBridgeHost -ExpectedRelease '0123456789abcdef'} | Should -Throw '*gemini_integration_frozen*'
  Should -Invoke Get-AiCliGeminiLocalToken -Times 0
 }
 It 'honors a persisted freeze even after source status changes' {
  $p=New-FrozenFixture;$d=Read-AiCliGeminiJson $p.Deployment;$d.lifecycle='frozen';Write-AiCliJsonFile $p.Deployment $d
  Mock Test-AiCliGeminiIntegrationFrozen { $false }
  {Assert-AiCliGeminiIntegrationActive}|Should -Throw '*gemini_integration_frozen*'
  Get-AiCliGeminiDeployment|Should -BeNullOrEmpty
 }
 It 'blocks install and model-only update before build or live probes' {
  {& (Join-Path $repo 'scripts\Install-GeminiCodexBridge.ps1') -Mode Install -BuildRoot (Join-Path $TestDrive 'must-not-create')}|Should -Throw '*gemini_integration_frozen*'
  {& (Join-Path $repo 'scripts\Install-GeminiCodexBridge.ps1') -Mode UpdateModels -BuildRoot (Join-Path $TestDrive 'must-not-create')}|Should -Throw '*gemini_integration_frozen*'
  Test-Path (Join-Path $TestDrive 'must-not-create')|Should -BeFalse
 }
 It 'blocks old live acceptance scripts before reading candidates or invoking models' {
  {& (Join-Path $repo 'scripts\Test-GeminiModelCandidate.ps1') -CandidateDirectory (Join-Path $TestDrive 'absent') -IsolationReceiptPath (Join-Path $TestDrive 'absent.json')}|Should -Throw '*gemini_integration_frozen*'
 }
 It 'retains cleanup access to a disabled release instead of starting it' {
  $text=[IO.File]::ReadAllText((Join-Path $repo 'src\AiCliProfileManager\Private\GeminiBridgeService.ps1'))
  $text|Should -Match 'function Stop-AiCliGeminiBridge \{\s*\$d=Get-AiCliGeminiDeployment -IncludeDisabled'
 }
 It 'shows module and deployment states separately in Status without enabling either' {
  $status=& (Join-Path $repo 'scripts\Install-GeminiCodexBridge.ps1') -Mode Status
  $status.moduleLifecycle|Should -BeExactly 'frozen'
  $status.lifecycle|Should -BeExactly 'frozen'
  $status.enabled|Should -BeFalse
  $status.PSObject.Properties.Name|Should -Contain 'deploymentLifecycle'
  $status.PSObject.Properties.Name|Should -Contain 'deploymentEnabled'
 }
 It 'blocks the native Python live fixture before creating test roots or checking CLI dependencies' {
  $target=Join-Path $TestDrive 'must-not-run-model'
  $fixture=Join-Path $repo 'tests\Integration\GeminiNativeTransactions.py'
  $old=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$result=& python $fixture --root $target --codex absent --test-dll absent --settings absent --catalog absent --pwsh absent --dotnet absent --live 2>&1;$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
  $exit|Should -Not -Be 0
  ($result|Out-String)|Should -Match 'gemini_integration_frozen'
  Test-Path $target|Should -BeFalse
 }
}