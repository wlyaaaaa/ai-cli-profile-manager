# Password Center references; DPAPI decryption is read-only legacy migration compatibility.

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

# Retained only to read old 32-hex references during migration; never write new ciphertext.
function Unprotect-AiCliSecretBytes {
    param([byte[]]$CipherBytes, [int]$FormatVersion = 1)
    $entropy = Get-AiCliSecretEntropy -FormatVersion $FormatVersion
    return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $CipherBytes,
        $entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
}

function Get-AiCliSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SecretId)
    # Old Desktop releases import the newest module by name and call this
    # function with the resolved reference. Keep that call shape compatible.
    if ($SecretId -match '^passwordcenter:([a-z0-9][a-z0-9_-]*)$') {
        $vendor = $Matches[1]
        return Request-AiCliVendorCredential -Vendor $vendor -Endpoint (Get-AiCliVendorDefaultEndpoint -Vendor $vendor)
    }
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
    # A reference cannot prove that the vault contains a usable key. No fetch
    # is performed by this local-presence probe; null explicitly means unknown.
    if ($SecretId -match '^passwordcenter:') { return $null }
    if ([string]::IsNullOrWhiteSpace($SecretId)) { return $false }
    try { $safeId = Assert-AiCliSecretIdentifier -Id $SecretId } catch { return $false }
    $paths = Get-AiCliAppPaths
    return (Test-Path -LiteralPath (Join-Path $paths.SecretsDir "$safeId.json"))
}

function Remove-AiCliSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SecretId)
    if ($SecretId -match '^passwordcenter:') { return }
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
