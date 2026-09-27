BeforeAll { $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }

Describe 'Native Desktop auth.command delivery' {
    It 'writes the synthetic token only to its actual native client parent pipe' {
        $project = Join-Path $TestDrive 'client'
        [IO.Directory]::CreateDirectory($project) | Out-Null
        @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><AssemblyName>codex</AssemblyName><ImplicitUsings>enable</ImplicitUsings></PropertyGroup></Project>
'@ | Set-Content -LiteralPath (Join-Path $project 'client.csproj') -Encoding utf8
        @'
using System.Diagnostics;
using System.Text.Json;
var start = new ProcessStartInfo("pwsh") { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true };
foreach(var arg in new[]{"-NoProfile","-NonInteractive","-File",args[0],"-ProfileId","future-profile","-ClientPath",Environment.ProcessPath!,"-ModulePath",args[1]}) start.ArgumentList.Add(arg);
using var process=Process.Start(start)!;
var stdout=process.StandardOutput.ReadToEndAsync(); var stderr=process.StandardError.ReadToEndAsync();
if(!process.WaitForExit(15000)){process.Kill(true);Environment.Exit(3);}
var output=await stdout; var error=await stderr;
Console.WriteLine(JsonSerializer.Serialize(new{passed=process.ExitCode==0 && output=="synthetic-desktop-auth-token",stderrEmpty=error.Length==0}));
'@ | Set-Content -LiteralPath (Join-Path $project 'Program.cs') -Encoding utf8
        $stub = Join-Path $TestDrive 'Fixture.psm1'
        @'
function Get-AiCliResolvedProfile { param($Id) return @{ engine='codex';transport='responses' } }
function Get-AiCliProperty { param($Object,$Name) return $Object[$Name] }
function Get-AiCliVendorSecretRef { param($Profile) return 'passwordcenter:glm' }
function Get-AiCliProfileSecret { param($Profile,[switch]$Desktop) if(-not $Desktop){throw 'not desktop'} return 'synthetic-desktop-auth-token' }
'@ | Set-Content -LiteralPath $stub -Encoding utf8
        $output = Join-Path $TestDrive 'out'
        & dotnet build (Join-Path $project 'client.csproj') --output $output --nologo --verbosity quiet *> (Join-Path $TestDrive 'build.log')
        $LASTEXITCODE | Should -Be 0
        $helper = Join-Path $script:Repo 'src/AiCliProfileManager/Support/GetDesktopProviderToken.ps1'
        $raw = & (Join-Path $output 'codex.exe') $helper $stub
        $LASTEXITCODE | Should -Be 0
        $result = $raw | ConvertFrom-Json
        $result.passed | Should -BeTrue
        $result.stderrEmpty | Should -BeTrue
        $raw | Should -Not -Match 'synthetic-desktop-auth-token'
        $standalone = & pwsh -NoProfile -NonInteractive -File $helper -ProfileId future-profile -ClientPath (Join-Path $output 'codex.exe') -ModulePath $stub 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $standalone | Should -Not -Match 'synthetic-desktop-auth-token'
    }
}
