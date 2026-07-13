# Path resolution via Windows Known Folders — no hard-coded user drive letters in production.

$script:AiCliDataRootOverride = $null

function Assert-AiCliSafeIdentifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Kind = 'ID',
        [int]$MaxLength = 64
    )
    if ([string]::IsNullOrWhiteSpace($Id) -or
        $Id.Length -gt $MaxLength -or
        $Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        throw "$Kind 仅允许字母、数字、连字符和下划线，必须以字母或数字开头，最长 $MaxLength 个字符。"
    }
    return $Id
}

function Assert-AiCliSecretIdentifier {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[a-fA-F0-9]{32}$') {
        throw 'Secret ID 格式非法。'
    }
    return $Id.ToLowerInvariant()
}

function Assert-AiCliModelId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Model)
    if ($Model -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/+@-]{0,127}$') {
        throw "模型 ID 格式非法: $Model"
    }
    return $Model
}

function Test-AiCliMapContains {
    param($Map, [string]$Key)
    if ($null -eq $Map) { return $false }
    if ($Map -is [System.Collections.IDictionary]) {
        return (@($Map.Keys) -contains $Key)
    }
    return [bool]$Map.PSObject.Properties[$Key]
}

function Test-AiCliMapHasKey {
    param($Map, [string]$Key)
    if ($null -eq $Map) { return $false }
    if ($Map -is [System.Collections.IDictionary]) {
        return $Map.Contains($Key)
    }
    return [bool]$Map.PSObject.Properties[$Key]
}

function Get-AiCliProperty {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if (Test-AiCliMapContains -Map $Obj -Key $Name) { return $Obj[$Name] }
        return $Default
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function Assert-AiCliEndpointSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { throw '端点 URL 不能为空' }
    try { $uri = [Uri]$Url } catch { throw '端点 URL 格式非法。' }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { throw '端点 URL 不允许嵌入用户名或密码。' }
    if (-not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw '端点 URL 不允许 query 或 fragment。'
    }
    if ($uri.Scheme -eq 'https') { return }
    if ($uri.Scheme -eq 'http') {
        if ($uri.Host -in @('127.0.0.1','localhost','::1')) { return }
        throw '非本机明文 HTTP 端点默认拒绝。请使用 HTTPS，或 localhost/127.0.0.1。'
    }
    throw "不支持的 URL scheme: $($uri.Scheme)"
}

function Set-AiCliDataRootOverride {
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $script:AiCliDataRootOverride = $null
    } else {
        $script:AiCliDataRootOverride = [System.IO.Path]::GetFullPath($Path)
    }
}

function Get-AiCliKnownFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('RoamingAppData','LocalAppData','UserProfile','ProgramFiles','Temp')]
        [string]$Name
    )
    switch ($Name) {
        'RoamingAppData' { return [Environment]::GetFolderPath('ApplicationData') }
        'LocalAppData'   { return [Environment]::GetFolderPath('LocalApplicationData') }
        'UserProfile'    { return [Environment]::GetFolderPath('UserProfile') }
        'ProgramFiles'   { return [Environment]::GetFolderPath('ProgramFiles') }
        'Temp'           { return [System.IO.Path]::GetTempPath() }
    }
}

function Get-AiCliAppPaths {
    [CmdletBinding()]
    param()

    $brand = Get-AiCliBrand
    $name = $brand.ModuleName

    if ($script:AiCliDataRootOverride) {
        $root = $script:AiCliDataRootOverride
        return [ordered]@{
            AppDataRoot   = Join-Path $root 'AppData'
            LocalRoot     = Join-Path $root 'Local'
            SettingsDir   = Join-Path $root 'AppData'
            SecretsDir    = Join-Path $root 'Local\secrets'
            StateDir      = Join-Path $root 'Local\state'
            ProxiesDir    = Join-Path $root 'Local\proxies'
            CacheDir      = Join-Path $root 'Local\cache'
            LogsDir       = Join-Path $root 'Local\logs'
            BackupsDir    = Join-Path $root 'Local\backups'
            LocksDir      = Join-Path $root 'Local\locks'
            ProfilesDir   = Join-Path $root 'AppData\profiles'
            SettingsFile  = Join-Path $root 'AppData\settings.json'
            IsTestRoot    = $true
        }
    }

    $appData = Join-Path (Get-AiCliKnownFolder RoamingAppData) $name
    $local   = Join-Path (Get-AiCliKnownFolder LocalAppData) $name

    return [ordered]@{
        AppDataRoot   = $appData
        LocalRoot     = $local
        SettingsDir   = $appData
        SecretsDir    = Join-Path $local 'secrets'
        StateDir      = Join-Path $local 'state'
        ProxiesDir    = Join-Path $local 'proxies'
        CacheDir      = Join-Path $local 'cache'
        LogsDir       = Join-Path $local 'logs'
        BackupsDir    = Join-Path $local 'backups'
        LocksDir      = Join-Path $local 'locks'
        ProfilesDir   = Join-Path $appData 'profiles'
        SettingsFile  = Join-Path $appData 'settings.json'
        IsTestRoot    = $false
    }
}

function Initialize-AiCliDirectories {
    [CmdletBinding()]
    param()
    $p = Get-AiCliAppPaths
    foreach ($key in @('SettingsDir','SecretsDir','StateDir','ProxiesDir','CacheDir','LogsDir','BackupsDir','LocksDir','ProfilesDir')) {
        $dir = $p[$key]
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }
    return $p
}

function Get-AiCliModuleRoot {
    [CmdletBinding()]
    param()
    # Private scripts are under .../AiCliProfileManager/Private
    $privateDir = $PSScriptRoot
    return (Split-Path -Parent $privateDir)
}

function Get-AiCliRepoRoot {
    [CmdletBinding()]
    param()
    $moduleRoot = Get-AiCliModuleRoot
    # Prefer data shipped beside module (installed layout or dev copy)
    if (Test-Path (Join-Path $moduleRoot 'data\providers')) { return $moduleRoot }
    # src/AiCliProfileManager -> repo root
    $src = Split-Path -Parent $moduleRoot
    $maybe = Split-Path -Parent $src
    if (Test-Path (Join-Path $maybe 'data\providers')) { return $maybe }
    if (Test-Path (Join-Path $src 'data\providers')) { return $src }
    return $maybe
}

function Get-AiCliDataPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Relative
    )
    $mod = Get-AiCliModuleRoot
    $besideModule = Join-Path $mod (Join-Path 'data' $Relative)
    if (Test-Path -LiteralPath $besideModule) { return $besideModule }

    $repo = Get-AiCliRepoRoot
    $candidate = Join-Path $repo (Join-Path 'data' $Relative)
    if (Test-Path -LiteralPath $candidate) { return $candidate }

    # Dev tree: repo/data even if path not yet verified as "exists" for write targets
    $dev = Join-Path (Split-Path -Parent (Split-Path -Parent $mod)) (Join-Path 'data' $Relative)
    if (Test-Path -LiteralPath $dev) { return $dev }
    return $candidate
}

function Get-AiCliCodexHome {
    [CmdletBinding()]
    param()
    if ($env:CODEX_HOME -and (Test-Path -LiteralPath $env:CODEX_HOME)) {
        return [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    $default = Join-Path (Get-AiCliKnownFolder UserProfile) '.codex'
    return $default
}

function Resolve-AiCliProjectPath {
    [CmdletBinding()]
    param([string]$Project)
    if ([string]::IsNullOrWhiteSpace($Project)) {
        return (Get-Location).Path
    }
    $full = [System.IO.Path]::GetFullPath($Project)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("项目目录不存在: $full")
    }
    return $full
}

function Remove-AiCliPathEntry {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$PathValue,
        [Parameter(Mandatory)][string]$Entry
    )
    $target = $Entry.Trim().TrimEnd('\','/')
    $kept = @($PathValue -split ';' | Where-Object {
        $candidate = ([string]$_).Trim()
        $candidate -and -not [string]::Equals(
            $candidate.TrimEnd('\','/'), $target, [StringComparison]::OrdinalIgnoreCase
        )
    })
    return ($kept -join ';')
}

function Remove-AiCliProfileBlockText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $useCrLf = $Text.Contains("`r`n")
    $normalized = $Text.Replace("`r`n", "`n")
    $normalized = [regex]::Replace(
        $normalized,
        '(?ms)# >>> AI CLI Profile Manager >>>\n.*?# <<< AI CLI Profile Manager <<<',
        ''
    )

    # Prerelease installers used this exact unmarked block. Remove only the
    # known text so unrelated PowerShell profile customizations remain.
    $legacy = @'
# AI CLI Profile Manager
$__aicliOk = $false
try {
  if (-not (Get-Module AiCliProfileManager -ErrorAction SilentlyContinue)) {
    Import-Module AiCliProfileManager -ErrorAction Stop
  }
  $__aicliOk = [bool](Get-Command aicli -ErrorAction SilentlyContinue)
} catch { $__aicliOk = $false }
if (-not $__aicliOk) {
  $shim = Join-Path $env:LOCALAPPDATA 'aicli\bin\aicli.cmd'
  if (Test-Path -LiteralPath $shim) {
    Set-Alias -Name aicli -Value $shim -Scope Global -Force -ErrorAction SilentlyContinue
  }
}
'@
    $normalized = $normalized.Replace($legacy.Replace("`r`n", "`n").Trim(), '')
    $normalized = $normalized.TrimEnd("`r", "`n")
    if ($useCrLf) { return $normalized.Replace("`n", "`r`n") }
    return $normalized
}

function Test-AiCliManagedModuleDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not [string]::Equals($item.Name, 'AiCliProfileManager', [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $versionCount = 0
        foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
            if (-not $child.PSIsContainer) {
                if ([string]::Equals($child.Name, 'current-link-note.txt', [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                return $false
            }
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            try { $directoryVersion = [version]$child.Name } catch { return $false }
            if ($directoryVersion.ToString() -ne $child.Name) { return $false }
            $manifest = Join-Path $child.FullName 'AiCliProfileManager.psd1'
            $rootModule = Join-Path $child.FullName 'AiCliProfileManager.psm1'
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or
                -not (Test-Path -LiteralPath $rootModule -PathType Leaf)) {
                return $false
            }
            $data = Import-PowerShellDataFile -LiteralPath $manifest
            if ([string]$data.GUID -ne 'a1c11c11-0a11-4c11-b111-a1c110110011' -or
                [string]$data.RootModule -ne 'AiCliProfileManager.psm1' -or
                [version][string]$data.ModuleVersion -ne $directoryVersion) {
                return $false
            }
            $versionCount++
        }
        return ($versionCount -gt 0)
    } catch {}
    return $false
}

function Remove-AiCliShellIntegration {
    [CmdletBinding()]
    param()
    $bin = Join-Path (Get-AiCliKnownFolder LocalAppData) 'aicli\bin'
    foreach ($name in @('aicli.ps1','aicli.cmd')) {
        $file = Join-Path $bin $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
    }
    if ((Test-Path -LiteralPath $bin) -and -not (Get-ChildItem -LiteralPath $bin -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $bin -Force -ErrorAction SilentlyContinue
        $parent = Split-Path -Parent $bin
        if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        }
    }

    $oldUserPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
    $newUserPath = Remove-AiCliPathEntry -PathValue $oldUserPath -Entry $bin
    if (-not [string]::Equals($oldUserPath, $newUserPath, [StringComparison]::Ordinal)) {
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    }

    $profilePath = $PROFILE.CurrentUserCurrentHost
    if (Test-Path -LiteralPath $profilePath) {
        $before = [IO.File]::ReadAllText($profilePath)
        $after = Remove-AiCliProfileBlockText -Text $before
        if (-not [string]::Equals($before, $after, [StringComparison]::Ordinal)) {
            [IO.File]::WriteAllText($profilePath, $after, [Text.UTF8Encoding]::new($false))
        }
    }
}
