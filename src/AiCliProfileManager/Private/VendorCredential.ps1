# Vendor references are metadata. Values are delivered once through a local pipe.
function Get-AiCliVendorSecretRef {
    param($Profile)
    $provider = [string](Get-AiCliProperty $Profile 'provider')
    $auth = [string](Get-AiCliProperty (Get-AiCliProperty $Profile 'auth') 'type')
    if ($provider -in @('qwen','glm','deepseek') -and $auth -eq 'api-key') {
        return 'passwordcenter:' + $provider
    }
    return $null
}

function Get-AiCliVendorBrokerPath {
    return Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'PCConfig\AuthorityHost\tools\Invoke-PasswordCenterVendor.ps1'
}

function Get-AiCliVendorDeliveryError {
    param([string]$Receipt)
    try {
        $value = $Receipt | ConvertFrom-Json -ErrorAction Stop
        if ($value.schema -ceq 'pcconfig.secret-broker-result.v1' -and
            [string]$value.error -cmatch '^[a-z][a-z0-9_:-]{0,95}$') { return [string]$value.error }
    } catch {}
    return 'vendor_delivery_failed'
}

function Request-AiCliVendorCredential {
    param([Parameter(Mandatory)][string]$Vendor, [Parameter(Mandatory)][string]$Endpoint, [switch]$Desktop)
    $broker = Get-AiCliVendorBrokerPath
    if (-not (Test-Path -LiteralPath $broker -PathType Leaf)) { throw 'Password Center vendor delivery is not installed.' }
    $name = 'passwordcenter-vendor-' + [guid]::NewGuid().ToString('N')
    $options = [IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly
    $pipe = [IO.Pipes.NamedPipeServerStream]::new($name, [IO.Pipes.PipeDirection]::In, 1,
        [IO.Pipes.PipeTransmissionMode]::Byte, $options)
    $requestRoot = Join-Path (Get-AiCliAppPaths).LocalRoot 'vendor-requests'
    [IO.Directory]::CreateDirectory($requestRoot) | Out-Null
    $requestPath = Join-Path $requestRoot ($name + '.json')
    $request = [ordered]@{ schema = 'passwordcenter.vendor-request.v1'; mode = 'deliver';
        vendor = $Vendor; endpoint = $Endpoint; pipe_name = $name; consumer_pid = $PID }
    $process = $null
    $reader = $null
    try {
        [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $wait = $pipe.WaitForConnectionAsync()
        $start = [Diagnostics.ProcessStartInfo]::new('pwsh')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($arg in @('-NoProfile','-NonInteractive','-File',$broker,'-Vendor',$Vendor,'-RequestPath',$requestPath,'-Json')) {
            [void]$start.ArgumentList.Add($arg)
        }
        if (-not $Desktop) { [void]$start.ArgumentList.Add('-NativeClient') }
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $exit = $process.WaitForExitAsync()
        $first = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($wait,$exit), 30000)
        if ($first -lt 0) { throw 'Password Center vendor delivery timed out.' }
        if (-not $wait.IsCompletedSuccessfully) {
            throw ('Password Center: ' + (Get-AiCliVendorDeliveryError -Receipt $stdout.GetAwaiter().GetResult()))
        }
        $reader = [IO.StreamReader]::new($pipe, [Text.Encoding]::UTF8)
        $read = $reader.ReadToEndAsync()
        if (-not $read.Wait(10000) -or -not $process.WaitForExit(10000)) { throw 'Password Center vendor delivery timed out.' }
        $receipt = $stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw ('Password Center: ' + (Get-AiCliVendorDeliveryError -Receipt $receipt)) }
        $secret = $read.GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($secret) -or $secret.Length -gt 65536) { throw 'Password Center returned an invalid credential.' }
        return $secret
    } finally {
        if ($reader) { $reader.Dispose() }
        $pipe.Dispose()
        if ($process) {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(2000) }
            $process.Dispose()
        }
        # Metadata only. Reuse the project's ordinary temporary-file lifecycle.
        if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
        $secret = $null
    }
}

function Get-AiCliProfileSecret {
    param([Parameter(Mandatory)]$Profile, [switch]$Desktop)
    $reference = [string](Get-AiCliProperty $Profile 'secretRef')
    if ($reference -match '^passwordcenter:(qwen|glm|deepseek)$') {
        return Request-AiCliVendorCredential -Vendor $Matches[1] -Endpoint ([string](Get-AiCliProperty $Profile 'endpoint')) -Desktop:$Desktop
    }
    return Get-AiCliSecret -SecretId $reference
}
