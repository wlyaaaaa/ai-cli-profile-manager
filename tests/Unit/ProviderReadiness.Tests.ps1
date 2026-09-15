#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ProviderReadinessRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Get-Module AiCliProfileManager -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:ProviderReadinessRepoRoot 'src\AiCliProfileManager\AiCliProfileManager.psd1') -Force

    if (-not ('AiCliProviderReadinessFixture' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class AiCliProviderReadinessFixture : IDisposable
{
    private readonly string mode;
    private readonly TcpListener listener;
    private Thread worker;
    public int Port { get; private set; }
    public int Requests { get; private set; }

    public AiCliProviderReadinessFixture(string mode)
    {
        this.mode = mode;
        this.listener = new TcpListener(IPAddress.Loopback, 0);
    }

    public void Start()
    {
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Start();
    }

    private void Run()
    {
        try {
            while (true) {
                using (var client = listener.AcceptTcpClient()) {
                    using (var stream = client.GetStream()) {
                        string request = ReadHeaders(stream);
                        if (String.IsNullOrEmpty(request)) return;
                        Requests++;
                        if (mode == "body-never-arrives") {
                            byte[] headers = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n");
                            stream.Write(headers, 0, headers.Length);
                            stream.Flush();
                            Thread.Sleep(10000);
                            return;
                        }
                        string body = request.Contains("/_gpu_broker/status") ? "{\"ok\":true}" : (mode == "missing-model" ? "{\"data\":[{\"id\":\"other:latest\"}]}" : (mode == "truncated-json" ? "{\"data\":" : "{\"data\":[{\"id\":\"qwen-main-v1:latest\"}]}"));
                        byte[] bytes = Encoding.UTF8.GetBytes(body);
                        string header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + bytes.Length + "\r\nConnection: close\r\n\r\n";
                        byte[] response = Encoding.UTF8.GetBytes(header + body);
                        stream.Write(response, 0, response.Length);
                        stream.Flush();
                    }
                }
            }
        } catch (SocketException) { }
        catch (ObjectDisposedException) { }
    }

    private static string ReadHeaders(NetworkStream stream)
    {
        var bytes = new System.Collections.Generic.List<byte>();
        int matched = 0;
        byte[] marker = Encoding.ASCII.GetBytes("\r\n\r\n");
        while (true) {
            int next = stream.ReadByte();
            if (next < 0) return null;
            bytes.Add((byte)next);
            matched = ((byte)next == marker[matched]) ? matched + 1 : 0;
            if (matched == marker.Length) return Encoding.ASCII.GetString(bytes.ToArray());
        }
    }

    public void Dispose()
    {
        listener.Stop();
        if (worker != null) worker.Join(1000);
    }
}
'@
    }
}

Describe 'selected local Provider readiness' {
    It 'requires complete broker and model JSON while accepting the standard latest tag' {
        $fixture = [AiCliProviderReadinessFixture]::new('ready')
        $fixture.Start()
        try {
            $profile = [ordered]@{ id = 'test-local-provider'; provider = 'ollama'; endpoint = "http://127.0.0.1:$($fixture.Port)/v1"; models = [ordered]@{ primary = 'qwen-main-v1' }; compatibility = [ordered]@{ localGpuBrokerSession = [ordered]@{ contractVersion = 1; requiredForMachineRun = $true; managementOrigin = "http://127.0.0.1:$($fixture.Port)" } } }
            $actual = InModuleScope AiCliProfileManager -Parameters @{ Profile = $profile } {
                Test-AiCliSelectedLocalProviderReadiness -MergedProfile $Profile
            }
            $actual.Applicable | Should -BeTrue
            $actual.Ready | Should -BeTrue
            $actual.Reason | Should -Be 'ready'
            $fixture.Requests | Should -Be 2
        } finally {
            $fixture.Dispose()
        }
    }

    It 'fails within the total timeout when HTTP headers arrive but the body never does' {
        $fixture = [AiCliProviderReadinessFixture]::new('body-never-arrives')
        $fixture.Start()
        try {
            $profile = [ordered]@{ id = 'test-local-provider'; provider = 'ollama'; endpoint = "http://127.0.0.1:$($fixture.Port)/v1"; models = [ordered]@{ primary = 'qwen-main-v1' }; compatibility = [ordered]@{ localGpuBrokerSession = [ordered]@{ contractVersion = 1; requiredForMachineRun = $true; managementOrigin = "http://127.0.0.1:$($fixture.Port)" } } }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $actual = InModuleScope AiCliProfileManager -Parameters @{ Profile = $profile } {
                Test-AiCliSelectedLocalProviderReadiness -MergedProfile $Profile -ConnectTimeoutSeconds 1 -TotalTimeoutSeconds 1
            }
            $watch.Stop()
            $actual.Ready | Should -BeFalse
            $actual.Reason | Should -Be 'response_timeout'
            $watch.ElapsedMilliseconds | Should -BeLessThan 2500
        } finally {
            $fixture.Dispose()
        }
    }

    It 'fails when the selected model identity is absent' {
        $fixture = [AiCliProviderReadinessFixture]::new('missing-model')
        $fixture.Start()
        try {
            $profile = [ordered]@{ id = 'test-local-provider'; provider = 'ollama'; endpoint = "http://127.0.0.1:$($fixture.Port)/v1"; models = [ordered]@{ primary = 'qwen-main-v1' }; compatibility = [ordered]@{ localGpuBrokerSession = [ordered]@{ contractVersion = 1; requiredForMachineRun = $true; managementOrigin = "http://127.0.0.1:$($fixture.Port)" } } }
            $actual = InModuleScope AiCliProfileManager -Parameters @{ Profile = $profile } {
                Test-AiCliSelectedLocalProviderReadiness -MergedProfile $Profile
            }
            $actual.Ready | Should -BeFalse
            $actual.Reason | Should -Be 'models_exact_identity_missing'
        } finally {
            $fixture.Dispose()
        }
    }

    It 'fails when a complete response body is truncated JSON' {
        $fixture = [AiCliProviderReadinessFixture]::new('truncated-json')
        $fixture.Start()
        try {
            $profile = [ordered]@{ id = 'test-local-provider'; provider = 'ollama'; endpoint = "http://127.0.0.1:$($fixture.Port)/v1"; models = [ordered]@{ primary = 'qwen-main-v1' }; compatibility = [ordered]@{ localGpuBrokerSession = [ordered]@{ contractVersion = 1; requiredForMachineRun = $true; managementOrigin = "http://127.0.0.1:$($fixture.Port)" } } }
            $actual = InModuleScope AiCliProfileManager -Parameters @{ Profile = $profile } {
                Test-AiCliSelectedLocalProviderReadiness -MergedProfile $Profile
            }
            $actual.Ready | Should -BeFalse
            $actual.Reason | Should -Be 'models_json_invalid'
        } finally {
            $fixture.Dispose()
        }
    }

    It 'keeps the real child and its CODEX_HOME inheritance untouched when readiness fails' {
        InModuleScope AiCliProfileManager {
            $profile = [ordered]@{ provider = 'ollama'; endpoint = 'http://127.0.0.1:32100/v1'; models = [ordered]@{ primary = 'qwen-main-v1' } }
            Mock Get-AiCliResolvedProfile { $profile }
            Mock Test-AiCliSelectedLocalProviderReadiness {
                [pscustomobject]@{ Applicable = $true; Ready = $false; Reason = 'response_timeout'; Summary = '本地 Provider 未在 5 秒内返回完整正文' }
            }
            Mock Start-AiCliChildProcess { throw 'must not start' }

            Start-AiCliProfile -ProfileId 'test-local-provider' | Should -Be (Get-AiCliExitCode Unavailable)
            Should -Invoke Start-AiCliChildProcess -Times 0 -Exactly
        }
    }

    It 'adds the same failed selected-local readiness result to Doctor' {
        InModuleScope AiCliProfileManager {
            $global:AiCliCapturedDoctor = $null
            $profile = [ordered]@{
                id = 'test-local-provider'; templateId = 'test-local-provider'; configured = $true
                provider = 'ollama'; engine = 'codex'; transport = 'responses'
                endpoint = 'http://127.0.0.1:32100/v1'; models = [ordered]@{ primary = 'qwen-main-v1' }
            }
            Mock Resolve-AiCliLaunchExecutable { $null }
            Mock Find-AiCliCommandPath { $null }
            Mock Resolve-AiCliInterpreterExecutable { $null }
            Mock Get-AiCliClaudeConflictSettingsHints { @() }
            Mock Get-AiCliProxyExecutable { $null }
            Mock Get-AiCliProxyState { $null }
            Mock Test-AiCliProcessIdentity { [pscustomobject]@{ Match = $false } }
            Mock Get-AiCliResolvedProfile { $profile }
            Mock Get-AiCliProviderManifest { $null }
            Mock Get-AiCliProfileCliIdentityEvidence { $null }
            Mock Test-AiCliProfileMinimumCliVersion { [pscustomobject]@{ Required = $false; Supported = $false } }
            Mock Test-AiCliSelectedLocalProviderReadiness {
                [pscustomobject]@{ Applicable = $true; Ready = $false; Reason = 'response_timeout'; Summary = '本地 Provider 未在 5 秒内返回完整正文' }
            }
            Mock Write-AiCliJson { param($Object) $global:AiCliCapturedDoctor = $Object }

            Invoke-AiCliDoctor -ProfileId 'test-local-provider' -Json | Should -Be (Get-AiCliExitCode Unavailable)
            $check = @($global:AiCliCapturedDoctor.checks | Where-Object id -eq 'profile.local_provider_readiness')
            $check | Should -HaveCount 1
            $check[0].status | Should -Be '不可用'
        }
    }
}
