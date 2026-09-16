# DPAPI CurrentUser secret store — secrets never logged or exported in cleartext.

try {
    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop
} catch {
    try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch {}
}
if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
    throw '当前 PowerShell 无法加载 DPAPI ProtectedData（需要 Windows + 支持的 .NET）。'
}

function Get-AiCliSecretEntropy {
    param([int]$FormatVersion = 1)
    $s = "AiCliProfileManager|v$FormatVersion|DPAPI-CurrentUser"
    return [Text.Encoding]::UTF8.GetBytes($s)
}

function Protect-AiCliSecretBytes {
    param([byte[]]$PlainBytes, [int]$FormatVersion = 1)
    $entropy = Get-AiCliSecretEntropy -FormatVersion $FormatVersion
    return [System.Security.Cryptography.ProtectedData]::Protect(
        $PlainBytes,
        $entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
}

function Unprotect-AiCliSecretBytes {
    param([byte[]]$CipherBytes, [int]$FormatVersion = 1)
    $entropy = Get-AiCliSecretEntropy -FormatVersion $FormatVersion
    return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $CipherBytes,
        $entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
}

function Set-AiCliSecretAcl {
    param([string]$Path)
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        $apply = {
            param([string]$Target, [bool]$Container)
            $suffix = if ($Container) { ':(OI)(CI)F' } else { ':F' }
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $icacls
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            foreach ($arg in @(
                $Target, '/inheritance:r',
                '/grant:r', ('*' + $sid + $suffix),
                '/grant:r', ('*S-1-5-18' + $suffix),
                '/grant:r', ('*S-1-5-32-544' + $suffix),
                '/Q'
            )) { [void]$psi.ArgumentList.Add($arg) }
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.WaitForExit()
            if ($proc.ExitCode -ne 0) {
                $err = Protect-AiCliSecretText $proc.StandardError.ReadToEnd()
                throw "icacls exit=$($proc.ExitCode) $err"
            }
            $proc.Dispose()
        }
        $item = Get-Item -LiteralPath $Path -Force
        $isContainer = $item.PSIsContainer
        & $apply $item.FullName $isContainer
        if ($isContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -Recurse -ErrorAction Stop)) {
                & $apply $child.FullName $child.PSIsContainer
            }
        }
    } catch {
        Write-AiCliLog -Level Warn -Message "无法收紧秘密目录 ACL: $($_.Exception.Message)"
    }
}

function New-AiCliSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlainText,
        [string]$Label = 'api-key'
    )
    if ([string]::IsNullOrEmpty($PlainText)) {
        throw '秘密值不能为空'
    }
    $paths = Initialize-AiCliDirectories
    Set-AiCliSecretAcl -Path $paths.SecretsDir
    $id = [guid]::NewGuid().ToString('N')
    $formatVersion = 1
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    try {
        $cipher = Protect-AiCliSecretBytes -PlainBytes $plainBytes -FormatVersion $formatVersion
    } finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
    $meta = [ordered]@{
        schemaVersion = 1
        formatVersion = $formatVersion
        id            = $id
        label         = $Label
        createdUtc    = (Get-Date).ToUniversalTime().ToString('o')
        cipherBase64  = [Convert]::ToBase64String($cipher)
    }
    $file = Join-Path $paths.SecretsDir "$id.json"
    Write-AiCliJsonFile -Path $file -Value $meta
    return $id
}

function Get-AiCliSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SecretId)
    $safeId = Assert-AiCliSecretIdentifier -Id $SecretId
    $paths = Get-AiCliAppPaths
    $file = Join-Path $paths.SecretsDir "$safeId.json"
    if (-not (Test-Path -LiteralPath $file)) {
        throw "秘密不存在: $SecretId"
    }
    $meta = Read-AiCliJsonFile -Path $file
    $cipherB64 = Get-AiCliProperty $meta 'cipherBase64'
    $formatVersion = Get-AiCliProperty $meta 'formatVersion'
    if ([string]::IsNullOrWhiteSpace([string]$cipherB64)) {
        throw "秘密文件损坏或缺少 cipherBase64: $SecretId"
    }
    if ($null -eq $formatVersion) { $formatVersion = 1 }
    $cipher = [Convert]::FromBase64String([string]$cipherB64)
    $plainBytes = Unprotect-AiCliSecretBytes -CipherBytes $cipher -FormatVersion ([int]$formatVersion)
    try {
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    } finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Test-AiCliSecretExists {
    param([string]$SecretId)
    if ([string]::IsNullOrWhiteSpace($SecretId)) { return $false }
    try { $safeId = Assert-AiCliSecretIdentifier -Id $SecretId } catch { return $false }
    $paths = Get-AiCliAppPaths
    return (Test-Path -LiteralPath (Join-Path $paths.SecretsDir "$safeId.json"))
}

function Remove-AiCliSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SecretId)
    $safeId = Assert-AiCliSecretIdentifier -Id $SecretId
    $paths = Get-AiCliAppPaths
    $file = Join-Path $paths.SecretsDir "$safeId.json"
    if (Test-Path -LiteralPath $file) {
        Remove-Item -LiteralPath $file -Force
    }
}

function Get-AiCliSecretMeta {
    param([string]$SecretId)
    try { $safeId = Assert-AiCliSecretIdentifier -Id $SecretId } catch { return $null }
    $paths = Get-AiCliAppPaths
    $file = Join-Path $paths.SecretsDir "$safeId.json"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $meta = Read-AiCliJsonFile -Path $file
    return [ordered]@{
        id         = $meta.id
        label      = $meta.label
        createdUtc = $meta.createdUtc
        configured = $true
    }
}
