#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.0.0'}
Describe 'Gemini ordinary-user process lifecycle' {
 BeforeAll {
  $repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
  . (Join-Path $repo 'src\AiCliProfileManager\Private\Paths.ps1')
  . (Join-Path $repo 'src\AiCliProfileManager\Private\JsonStore.ps1')
  . (Join-Path $repo 'src\AiCliProfileManager\Private\PortAllocator.ps1')
  . (Join-Path $repo 'src\AiCliProfileManager\Private\GeminiBridgeService.ps1')
 }
 BeforeEach {
  $script:disposed=$false
  $script:instant=[datetime]::UtcNow
  $script:fake=[pscustomobject]@{Id=456;Path='E:\example\bridge.exe';StartTime=$script:instant}
  $script:fake|Add-Member ScriptMethod Dispose {$script:disposed=$true}
  $script:dep=[pscustomobject]@{Executable='E:\example\bridge.exe';ReleaseId='0123456789abcdef'}
  $script:receipt=@{schema='aicli.gemini-process.v1';pid=456;startTicks=$script:instant.Ticks;releaseId=$script:dep.ReleaseId}
  Mock Get-Process { $script:fake }
 }
 It 'accepts an exact process pending authenticated control-plane verification' {
  (Test-AiCliGeminiProcessReceipt $script:dep $script:receipt).Id|Should -Be 456
 }
 It 'treats a recycled PID as stale without touching the unrelated process' {
  $script:receipt.startTicks--
  Test-AiCliGeminiProcessReceipt $script:dep $script:receipt|Should -BeNullOrEmpty
  $script:disposed|Should -BeTrue
 }
 It 'treats an old release receipt as stale' {
  $script:receipt.releaseId='fedcba9876543210'
  Test-AiCliGeminiProcessReceipt $script:dep $script:receipt|Should -BeNullOrEmpty
 }
 It 'rejects a visible mismatched executable as stale' {
  $script:fake.Path='E:\unrelated.exe'
  Test-AiCliGeminiProcessReceipt $script:dep $script:receipt|Should -BeNullOrEmpty
 }
 It 'does not confuse image-query permissions with a mismatched executable' {
  $script:fake.Path=$null
  (Test-AiCliGeminiProcessReceipt $script:dep $script:receipt).Id|Should -Be 456
 }
 It 'handles exited processes and invalid PIDs' {
  Mock Get-Process {$null}
  Test-AiCliGeminiProcessReceipt $script:dep $script:receipt|Should -BeNullOrEmpty
  $script:receipt.pid=0
  Test-AiCliGeminiProcessReceipt $script:dep $script:receipt|Should -BeNullOrEmpty
 }
 It 'isolates credential stdout from the long-lived process host' {
  $source=[IO.File]::ReadAllText((Join-Path $repo 'src\AiCliProfileManager\Private\GeminiBridgeService.ps1'))
  $source|Should -Match '\$start.UseShellExecute=\$true'
  $source|Should -Match "'-ServiceHost','-ExpectedRelease'"
  $source|Should -Match 'function Invoke-AiCliGeminiBridgeHost'
  $source|Should -Match '\$process.WaitForExit\(\)'
  $source|Should -Match 'ReadToEndAsync\('
  $source|Should -Not -Match '-RedirectStandardInput'
 }
 It 'requires authenticated matching health before legacy reuse and shutdown' {
  $source=[IO.File]::ReadAllText((Join-Path $repo 'src\AiCliProfileManager\Private\GeminiBridgeService.ps1'))
  $source|Should -Match '\[int\]\$health.pid -eq \$old.Id'
  $source|Should -Match '\[int\]\$health.pid -ne \$p.Id'
 }
 It 'uses positive auth freshness so an exited local bridge can be restarted' {
  $source=[IO.File]::ReadAllText((Join-Path $repo 'src\AiCliProfileManager\Private\GeminiBridgeService.ps1'))
  $source|Should -Match 'refresh_interval_ms=1'
  $source|Should -Not -Match 'refresh_interval_ms=0'
 }
}