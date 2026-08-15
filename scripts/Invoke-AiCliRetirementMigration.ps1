#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$RoamingRoot = (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AiCliProfileManager'),
    [string]$LocalRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AiCliProfileManager'),
    [string]$CodexHome = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'),
    [string]$ModuleRoot,
    [version]$CurrentVersion = '0.3.9',
    [switch]$PreflightOnly,
    [switch]$FailOnBlocked
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleGuid = 'a1c11c11-0a11-4c11-b111-a1c110110011'
$retiredProfileIds = @(
    'codex-qwen-paygo',
    'codex-qwen-token-plan',
    'codex-qwen3-7-plus-paygo',
    'claude-qwen-paygo',
    'claude-qwen-token-plan',
    'claude-qwen-coding-plan',
    'oi-qwen-paygo'
)
$activeQwen37ProfileId = 'codex-qwen3-7-max-paygo'
$activeQwen37ModelId = 'qwen3.7-max-2026-06-08'
$activeQwen37ProviderId = 'aicli_qwen37_max_0608_paygo'
$resolvedRoamingRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($RoamingRoot))
$resolvedLocalRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($LocalRoot))
$resolvedCodexHome = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($CodexHome))
$resolvedModuleRoot = if ([string]::IsNullOrWhiteSpace($ModuleRoot)) {
    $null
} else {
    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($ModuleRoot))
}
$quarantineRoot = Join-Path $resolvedLocalRoot 'retirement\qwen37-v1'
$blocked = [Collections.Generic.List[string]]::new()
$actions = [Collections.Generic.List[object]]::new()
$stateKeysToRemove = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$profileIdsToClear = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Get-RetirementSha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash($Bytes)).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RetirementTextHash {
    param([Parameter(Mandatory)][string]$Text)
    return Get-RetirementSha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Test-RetiredQwenText {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($retiredProfileIds | Where-Object { $Text.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) {
        return $true
    }
    return $Text -match '(?i)qwen3(?:\.|[-_])?7(?:[-_.])?(?:max|plus)(?:$|[-._:/+@"''\s])'
}

function Test-ActiveQwen37Profile {
    param($Profile)
    if ($Profile -isnot [Collections.IDictionary] -or
        [string]$Profile.templateId -cne $activeQwen37ProfileId) {
        return $false
    }
    $models = $Profile.models
    if ($models -isnot [Collections.IDictionary] -or
        [string]$models.primary -cne $activeQwen37ModelId) {
        return $false
    }
    $selected = @(
        foreach ($field in @('primary','small','candidates','reserved')) {
            @($models[$field]) | Where-Object { $_ } | ForEach-Object { [string]$_ }
        }
    )
    return $selected.Count -gt 0 -and
        @($selected | Where-Object { $_ -cne $activeQwen37ModelId }).Count -eq 0
}

function Test-ActiveQwen37ManagedToml {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $modelMatch = [regex]::Match($Text, '(?m)^model\s*=\s*"([^"]+)"\r?$')
    $providerMatch = [regex]::Match($Text, '(?m)^model_provider\s*=\s*"([^"]+)"\r?$')
    return $modelMatch.Success -and
        $modelMatch.Groups[1].Value -ceq $activeQwen37ModelId -and
        $providerMatch.Success -and
        $providerMatch.Groups[1].Value -ceq $activeQwen37ProviderId
}

function Test-ActiveQwen37Catalog {
    param([string]$Text)
    try { $catalog = $Text | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop }
    catch { return $false }
    $models = @($catalog.models)
    return $models.Count -eq 1 -and
        $models[0] -is [Collections.IDictionary] -and
        [string]$models[0].slug -ceq $activeQwen37ModelId
}

function Test-NormalItem {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Directory
    )
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ([bool]$item.PSIsContainer -ne $Directory) { return $false }
        return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    } catch { return $false }
}

function Test-SafeRetirementRoot {
    param([Parameter(Mandatory)][string]$Path)

    $current = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $current)) {
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            return $false
        }
        $current = $parent
    }
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (-not (Test-NormalItem -Path $current -Directory $true)) {
            return $false
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
    return $true
}

function Add-RetirementAction {
    param([string]$Kind, [string]$Path, [string]$Category)
    $actions.Add([pscustomobject]@{
        Kind = $Kind
        Path = [IO.Path]::GetFullPath($Path)
        Category = $Category
    }) | Out-Null
}

function Add-RetirementBlocker {
    param([string]$Reason, [string]$Path)
    $blocked.Add("$Reason :: $([IO.Path]::GetFullPath($Path))") | Out-Null
}

function Assert-RetirementRootIfPresent {
    param([string]$Path, [string]$Label)
    if ((Test-Path -LiteralPath $Path) -and -not (Test-NormalItem -Path $Path -Directory $true)) {
        Add-RetirementBlocker -Reason "$Label 不是普通目录或是重解析点" -Path $Path
        return $false
    }
    return $true
}

foreach ($rootContract in @(
    [pscustomobject]@{ Path = $resolvedRoamingRoot; Label = 'RoamingRoot' },
    [pscustomobject]@{ Path = $resolvedLocalRoot; Label = 'LocalRoot' },
    [pscustomobject]@{ Path = $resolvedCodexHome; Label = 'CodexHome' },
    [pscustomobject]@{ Path = $resolvedModuleRoot; Label = 'ModuleRoot' }
)) {
    if (-not [string]::IsNullOrWhiteSpace($rootContract.Path) -and
        -not (Test-SafeRetirementRoot -Path $rootContract.Path)) {
        Add-RetirementBlocker `
            -Reason "$($rootContract.Label) 或其既有祖先不是普通目录" `
            -Path $rootContract.Path
    }
}

# Preflight user Profiles. They are moved intact; SecretRef files are never read,
# copied or deleted by this migration.
$profilesRoot = Join-Path $resolvedRoamingRoot 'profiles'
if ((Assert-RetirementRootIfPresent -Path $profilesRoot -Label 'Profile 目录') -and
    (Test-Path -LiteralPath $profilesRoot)) {
    foreach ($file in @(Get-ChildItem -LiteralPath $profilesRoot -Filter '*.json' -File -Force -ErrorAction Stop)) {
        $raw = [IO.File]::ReadAllText($file.FullName)
        if (-not (Test-RetiredQwenText -Text $raw)) { continue }
        if (-not (Test-NormalItem -Path $file.FullName -Directory $false) -or
            $file.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\.json$') {
            Add-RetirementBlocker -Reason '退役用户 Profile 身份不安全' -Path $file.FullName
            continue
        }
        try { $profile = $raw | ConvertFrom-Json -AsHashtable -Depth 100 }
        catch {
            Add-RetirementBlocker -Reason '退役用户 Profile JSON 无效' -Path $file.FullName
            continue
        }
        $profileId = [string]$profile.id
        if ([string]::IsNullOrWhiteSpace($profileId) -or
            $file.BaseName -cne $profileId) {
            Add-RetirementBlocker -Reason '退役用户 Profile 文件名与 ID 不一致' -Path $file.FullName
            continue
        }
        if (Test-ActiveQwen37Profile -Profile $profile) { continue }
        Add-RetirementAction -Kind File -Path $file.FullName -Category 'profiles'
        $profileIdsToClear.Add($profileId) | Out-Null
    }
}

# Preflight managed Codex state and TOML files. A state-backed file must agree
# with fullPath/fileName/contentHash. A state-less file is accepted only when
# its AICLI marker and body hash close independently.
$statePath = Join-Path $resolvedLocalRoot 'state\codex-managed-profiles.json'
$state = [ordered]@{}
$stateReadable = $true
if (Test-Path -LiteralPath $statePath) {
    if (-not (Test-NormalItem -Path $statePath -Directory $false)) {
        Add-RetirementBlocker -Reason 'Codex managed state 不是普通文件' -Path $statePath
        $stateReadable = $false
    } else {
        try { $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json -AsHashtable -Depth 100 }
        catch {
            Add-RetirementBlocker -Reason 'Codex managed state JSON 无效' -Path $statePath
            $stateReadable = $false
        }
        if ($state -isnot [Collections.IDictionary]) {
            Add-RetirementBlocker -Reason 'Codex managed state 根节点无效' -Path $statePath
            $stateReadable = $false
            $state = [ordered]@{}
        }
    }
}

$codexTomlFiles = @()
if ((Assert-RetirementRootIfPresent -Path $resolvedCodexHome -Label 'CODEX_HOME') -and
    (Test-Path -LiteralPath $resolvedCodexHome)) {
    $codexTomlFiles = @(Get-ChildItem -LiteralPath $resolvedCodexHome -Filter 'aicli-*.config.toml' -File -Force -ErrorAction Stop)
}
$tomlActions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $codexTomlFiles) {
    $raw = [IO.File]::ReadAllText($file.FullName)
    $safeId = $file.Name.Substring(0, $file.Name.Length - '.config.toml'.Length)
    $record = if ($stateReadable -and $state.Contains($safeId)) { $state[$safeId] } else { $null }
    $recordProfileId = if ($record) { [string]$record.profileId } else { '' }
    if (-not (Test-RetiredQwenText -Text ($raw + "`n" + $recordProfileId))) { continue }
    $activeManagedToml = Test-ActiveQwen37ManagedToml -Text $raw
    if (-not (Test-NormalItem -Path $file.FullName -Directory $false)) {
        Add-RetirementBlocker -Reason '退役 Codex Profile 不是普通文件' -Path $file.FullName
        continue
    }
    $profileMarker = [regex]::Match($raw, '(?m)^# aicli-profile-id=([^\r\n]+)\r?$')
    $hashMarker = [regex]::Match($raw, '(?m)^# aicli-content-hash=([a-f0-9]{64})\r?$')
    $bodyMarker = [regex]::Match($raw, '(?m)^# aicli-do-not-edit-unless-you-accept-unmanaged\r?\n')
    if ($raw -notmatch '(?m)^# aicli-managed=true\r?$' -or
        -not $profileMarker.Success -or $profileMarker.Groups[1].Value -cne $safeId -or
        -not $hashMarker.Success -or -not $bodyMarker.Success) {
        Add-RetirementBlocker -Reason '退役 Codex Profile 缺少闭合 managed marker' -Path $file.FullName
        continue
    }
    $body = $raw.Substring($bodyMarker.Index + $bodyMarker.Length)
    $actualBodyHash = Get-RetirementTextHash -Text $body
    if ($actualBodyHash -cne $hashMarker.Groups[1].Value) {
        Add-RetirementBlocker -Reason '退役 Codex Profile body hash 不闭合' -Path $file.FullName
        continue
    }
    if ($record) {
        $recordedPath = [IO.Path]::GetFullPath([string]$record.fullPath)
        if ($recordedPath -cne [IO.Path]::GetFullPath($file.FullName) -or
            [string]$record.fileName -cne $file.Name -or
            [string]$record.contentHash -cne $actualBodyHash) {
            Add-RetirementBlocker -Reason '退役 Codex Profile 与 managed state 不一致' -Path $file.FullName
            continue
        }
    }
    if ($activeManagedToml) { continue }
    Add-RetirementAction -Kind File -Path $file.FullName -Category 'codex-profiles'
    $tomlActions.Add([IO.Path]::GetFullPath($file.FullName)) | Out-Null
    $stateKeysToRemove.Add($safeId) | Out-Null
}

if ($stateReadable) {
    foreach ($key in @($state.Keys)) {
        $record = $state[$key]
        if ([string]$record.profileId -ceq $activeQwen37ProfileId) { continue }
        if (-not (Test-RetiredQwenText -Text ([string]$record.profileId)) -or
            $stateKeysToRemove.Contains([string]$key)) { continue }
        $fullPath = [string]$record.fullPath
        if ([string]::IsNullOrWhiteSpace($fullPath)) {
            Add-RetirementBlocker -Reason '退役 managed state 缺少 fullPath' -Path $statePath
            continue
        }
        $resolvedFullPath = [IO.Path]::GetFullPath($fullPath)
        $expectedPrefix = $resolvedCodexHome + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedFullPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Add-RetirementBlocker -Reason '退役 managed state 指向 CODEX_HOME 之外' -Path $statePath
            continue
        }
        if (Test-Path -LiteralPath $resolvedFullPath) {
            Add-RetirementBlocker -Reason '退役 managed state 对应文件未通过扫描' -Path $resolvedFullPath
            continue
        }
        $stateKeysToRemove.Add([string]$key) | Out-Null
    }
}

# Catalogs are content addressed. Move only hash-valid retired catalogs that
# are no longer referenced by a remaining Codex config file.
$catalogRoot = Join-Path $resolvedCodexHome 'aicli-model-catalogs'
if ((Assert-RetirementRootIfPresent -Path $catalogRoot -Label 'Codex catalog 目录') -and
    (Test-Path -LiteralPath $catalogRoot)) {
    $remainingTomlText = @(
        $codexTomlFiles |
            Where-Object { -not $tomlActions.Contains([IO.Path]::GetFullPath($_.FullName)) } |
            ForEach-Object { [IO.File]::ReadAllText($_.FullName) }
    ) -join "`n"
    foreach ($file in @(Get-ChildItem -LiteralPath $catalogRoot -Filter '*.json' -File -Force -ErrorAction Stop)) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $raw = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        if (-not (Test-RetiredQwenText -Text $raw)) { continue }
        if (-not (Test-NormalItem -Path $file.FullName -Directory $false) -or
            $file.Name -notmatch '-([a-f0-9]{12})\.json$') {
            Add-RetirementBlocker -Reason '退役 Codex catalog 身份不安全' -Path $file.FullName
            continue
        }
        $actualHash = Get-RetirementSha256Hex -Bytes $bytes
        if (-not $actualHash.StartsWith($Matches[1], [StringComparison]::Ordinal)) {
            Add-RetirementBlocker -Reason '退役 Codex catalog 内容寻址哈希不闭合' -Path $file.FullName
            continue
        }
        try { $null = $raw | ConvertFrom-Json -Depth 100 }
        catch {
            Add-RetirementBlocker -Reason '退役 Codex catalog JSON 无效' -Path $file.FullName
            continue
        }
        if ((Test-ActiveQwen37Catalog -Text $raw) -and
            $remainingTomlText.IndexOf($file.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            continue
        }
        if ($remainingTomlText.IndexOf($file.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Add-RetirementBlocker -Reason '退役 Codex catalog 仍被保留配置引用' -Path $file.FullName
            continue
        }
        Add-RetirementAction -Kind File -Path $file.FullName -Category 'codex-catalogs'
    }
}

# Remove runnable old module versions from every normal import path by moving
# only directories whose PSD1 identity closes over name/GUID/root/version.
if ($resolvedModuleRoot -and (Test-Path -LiteralPath $resolvedModuleRoot)) {
    if (-not (Test-NormalItem -Path $resolvedModuleRoot -Directory $true) -or
        -not [IO.Path]::GetFileName($resolvedModuleRoot).Equals('AiCliProfileManager', [StringComparison]::OrdinalIgnoreCase)) {
        Add-RetirementBlocker -Reason '模块根目录身份不安全' -Path $resolvedModuleRoot
    } else {
        foreach ($directory in @(Get-ChildItem -LiteralPath $resolvedModuleRoot -Directory -Force -ErrorAction Stop)) {
            try { $version = [version]$directory.Name } catch { continue }
            if ($version -ge $CurrentVersion) { continue }
            $manifestPath = Join-Path $directory.FullName 'AiCliProfileManager.psd1'
            $rootModulePath = Join-Path $directory.FullName 'AiCliProfileManager.psm1'
            $valid = Test-NormalItem -Path $directory.FullName -Directory $true
            $valid = $valid -and (Test-NormalItem -Path $manifestPath -Directory $false)
            $valid = $valid -and (Test-NormalItem -Path $rootModulePath -Directory $false)
            if ($valid) {
                try {
                    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
                    $valid = [string]$manifest.GUID -eq $moduleGuid -and
                        [string]$manifest.RootModule -eq 'AiCliProfileManager.psm1' -and
                        [version][string]$manifest.ModuleVersion -eq $version -and
                        $version.ToString() -eq $directory.Name
                } catch { $valid = $false }
            }
            if (-not $valid) {
                Add-RetirementBlocker -Reason '旧模块目录无法证明 AICLI 身份' -Path $directory.FullName
                continue
            }
            Add-RetirementAction -Kind Directory -Path $directory.FullName -Category 'modules'
        }
    }
}

# Close every quarantine destination before reporting a ready preflight. This
# prevents an installer from promoting a new module and only then discovering
# that a reintroduced legacy entrance collides with an earlier quarantine.
if (Test-Path -LiteralPath $quarantineRoot) {
    if (-not (Test-NormalItem -Path $quarantineRoot -Directory $true)) {
        Add-RetirementBlocker -Reason '退役 quarantine 不是普通目录或是重解析点' -Path $quarantineRoot
    }
}
$plannedDestinations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($action in $actions) {
    $destinationRoot = Join-Path $quarantineRoot $action.Category
    if ((Test-Path -LiteralPath $destinationRoot) -and
        -not (Test-NormalItem -Path $destinationRoot -Directory $true)) {
        Add-RetirementBlocker -Reason '退役 quarantine 子目录不是普通目录或是重解析点' -Path $destinationRoot
        continue
    }
    $destination = [IO.Path]::GetFullPath(
        (Join-Path $destinationRoot ([IO.Path]::GetFileName($action.Path)))
    )
    if (-not $plannedDestinations.Add($destination)) {
        Add-RetirementBlocker -Reason '多个退役入口映射到同一 quarantine 目标' -Path $destination
        continue
    }
    if (Test-Path -LiteralPath $destination) {
        Add-RetirementBlocker -Reason '退役 quarantine 目标已存在' -Path $destination
    }
}

# Metadata that will be rewritten is part of the same closed transaction. It
# must be parseable before any module promotion or legacy entrance move, and
# its backup destinations must be ordinary direct children with no collision.
$metadataRoot = Join-Path $quarantineRoot 'metadata'
if ((Test-Path -LiteralPath $metadataRoot) -and
    -not (Test-NormalItem -Path $metadataRoot -Directory $true)) {
    Add-RetirementBlocker `
        -Reason '退役 metadata 目录不是普通目录或是重解析点' `
        -Path $metadataRoot
}
$metadataPlans = [Collections.Generic.List[object]]::new()
if ($stateReadable -and $stateKeysToRemove.Count -gt 0 -and
    (Test-Path -LiteralPath $statePath)) {
    if (-not (Test-NormalItem -Path $statePath -Directory $false)) {
        Add-RetirementBlocker -Reason 'Codex managed state 不是普通文件' -Path $statePath
    } else {
        $metadataPlans.Add([pscustomobject]@{
            Source = $statePath
            Name = 'codex-managed-profiles.before.json'
        }) | Out-Null
    }
}
$settingsPath = Join-Path $resolvedRoamingRoot 'settings.json'
if ($profileIdsToClear.Count -gt 0 -and (Test-Path -LiteralPath $settingsPath)) {
    if (-not (Test-NormalItem -Path $settingsPath -Directory $false)) {
        Add-RetirementBlocker -Reason 'AICLI settings 不是普通文件' -Path $settingsPath
    } else {
        try {
            $settingsPreflight = [IO.File]::ReadAllText($settingsPath) |
                ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
            if ($settingsPreflight -isnot [System.Collections.IDictionary]) {
                throw 'settings root is not an object'
            }
            foreach ($field in @('defaultProfileId', 'lastProfileId')) {
                if ($settingsPreflight.Contains($field) -and
                    $null -ne $settingsPreflight[$field] -and
                    $settingsPreflight[$field] -isnot [string]) {
                    throw "settings field is invalid: $field"
                }
            }
            $needsSettingsRewrite = @('defaultProfileId', 'lastProfileId') |
                Where-Object {
                    $value = [string]$settingsPreflight[$_]
                    $value -and $profileIdsToClear.Contains($value)
                }
            if (@($needsSettingsRewrite).Count -gt 0) {
                $metadataPlans.Add([pscustomobject]@{
                    Source = $settingsPath
                    Name = 'settings.before.json'
                }) | Out-Null
            }
        } catch {
            Add-RetirementBlocker -Reason 'AICLI settings JSON 无效' -Path $settingsPath
        }
    }
}
foreach ($metadataPlan in $metadataPlans) {
    $destination = [IO.Path]::GetFullPath(
        (Join-Path $metadataRoot $metadataPlan.Name)
    )
    if ((Split-Path -Parent $destination) -cne [IO.Path]::GetFullPath($metadataRoot)) {
        Add-RetirementBlocker -Reason '退役 metadata 目标父目录无效' -Path $destination
        continue
    }
    if (-not $plannedDestinations.Add($destination)) {
        Add-RetirementBlocker -Reason '多个 metadata 备份映射到同一目标' -Path $destination
        continue
    }
    if (Test-Path -LiteralPath $destination) {
        Add-RetirementBlocker -Reason '退役 metadata 备份目标已存在' -Path $destination
    }
}

$preflightResult = [pscustomobject]@{
    status = if ($blocked.Count -eq 0) { 'ready' } else { 'blocked' }
    moved = @()
    blocked = @($blocked)
    stateEntriesRemoved = 0
    settingsCleared = @()
    quarantineRoot = $quarantineRoot
    planned = $actions.Count
}
if ($blocked.Count -gt 0) {
    if ($FailOnBlocked) {
        throw "AICLI retirement migration blocked ($($blocked.Count)): $($blocked -join ' | ')"
    }
    return $preflightResult
}
if ($PreflightOnly) { return $preflightResult }

$moved = [Collections.Generic.List[string]]::new()
$completedMoves = [Collections.Generic.List[object]]::new()
$metadataBackups = [Collections.Generic.List[object]]::new()
function Backup-RetirementMetadata {
    param([string]$Source, [string]$Name)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $null }
    $backupDir = Join-Path $quarantineRoot 'metadata'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    if (-not (Test-NormalItem -Path $backupDir -Directory $true) -or
        -not (Test-NormalItem -Path $Source -Directory $false)) {
        throw '退役 metadata 备份身份无效。'
    }
    $destination = [IO.Path]::GetFullPath((Join-Path $backupDir $Name))
    if ((Split-Path -Parent $destination) -cne [IO.Path]::GetFullPath($backupDir) -or
        (Test-Path -LiteralPath $destination)) {
        throw "退役 metadata 备份冲突: $destination"
    }
    Copy-Item -LiteralPath $Source -Destination $destination
    if (-not (Test-NormalItem -Path $destination -Directory $false)) {
        throw "退役 metadata 备份不是普通文件: $destination"
    }
    $metadataBackups.Add([pscustomobject]@{ Source = $Source; Backup = $destination }) | Out-Null
    return $destination
}

function Write-RetirementJsonAtomic {
    param([string]$Path, $Value)
    $temp = Join-Path (Split-Path -Parent $Path) ('.retirement-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText(
            $temp,
            ($Value | ConvertTo-Json -Depth 100),
            [Text.UTF8Encoding]::new($false)
        )
        $null = [IO.File]::ReadAllText($temp) | ConvertFrom-Json -AsHashtable -Depth 100
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

try {
    New-Item -ItemType Directory -Force -Path $quarantineRoot | Out-Null
    if (-not (Test-NormalItem -Path $quarantineRoot -Directory $true)) {
        throw "退役 quarantine 不是普通目录: $quarantineRoot"
    }
    foreach ($action in $actions) {
        $destinationRoot = Join-Path $quarantineRoot $action.Category
        New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
        if (-not (Test-NormalItem -Path $destinationRoot -Directory $true)) {
            throw "退役 quarantine 子目录不是普通目录: $destinationRoot"
        }
        $destination = Join-Path $destinationRoot ([IO.Path]::GetFileName($action.Path))
        if (Test-Path -LiteralPath $destination) { throw "退役 quarantine 目标已存在: $destination" }
        Move-Item -LiteralPath $action.Path -Destination $destination
        $completedMoves.Add([pscustomobject]@{ Source = $action.Path; Destination = $destination }) | Out-Null
        $moved.Add("$($action.Category)/$([IO.Path]::GetFileName($action.Path))") | Out-Null
    }

    $stateRemoved = 0
    if ($stateReadable -and $stateKeysToRemove.Count -gt 0 -and (Test-Path -LiteralPath $statePath)) {
        $null = Backup-RetirementMetadata -Source $statePath -Name 'codex-managed-profiles.before.json'
        foreach ($key in @($stateKeysToRemove)) {
            if ($state.Contains($key)) { $state.Remove($key); $stateRemoved++ }
        }
        Write-RetirementJsonAtomic -Path $statePath -Value $state
    }

    $settingsCleared = [Collections.Generic.List[string]]::new()
    if ($profileIdsToClear.Count -gt 0 -and (Test-Path -LiteralPath $settingsPath)) {
        if (-not (Test-NormalItem -Path $settingsPath -Directory $false)) {
            throw "AICLI settings 不是普通文件: $settingsPath"
        }
        $settings = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json -AsHashtable -Depth 100
        foreach ($field in @('defaultProfileId', 'lastProfileId')) {
            $value = [string]$settings[$field]
            if ($value -and $profileIdsToClear.Contains($value)) {
                $settings[$field] = $null
                $settingsCleared.Add($field) | Out-Null
            }
        }
        if ($settingsCleared.Count -gt 0) {
            $null = Backup-RetirementMetadata -Source $settingsPath -Name 'settings.before.json'
            Write-RetirementJsonAtomic -Path $settingsPath -Value $settings
        }
    }

    return [pscustomobject]@{
        status = 'complete'
        moved = @($moved)
        blocked = @()
        stateEntriesRemoved = $stateRemoved
        settingsCleared = @($settingsCleared)
        quarantineRoot = $quarantineRoot
        planned = $actions.Count
    }
} catch {
    for ($index = $metadataBackups.Count - 1; $index -ge 0; $index--) {
        $backup = $metadataBackups[$index]
        try { Copy-Item -LiteralPath $backup.Backup -Destination $backup.Source -Force } catch {}
    }
    for ($index = $completedMoves.Count - 1; $index -ge 0; $index--) {
        $move = $completedMoves[$index]
        try {
            if ((Test-Path -LiteralPath $move.Destination) -and -not (Test-Path -LiteralPath $move.Source)) {
                Move-Item -LiteralPath $move.Destination -Destination $move.Source
            }
        } catch {}
    }
    throw
}
