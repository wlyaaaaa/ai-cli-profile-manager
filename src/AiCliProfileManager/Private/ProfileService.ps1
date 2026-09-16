# User profiles: virtual templates, multi-instance, merge, default, remove.

function Get-AiCliSettings {
    $paths = Initialize-AiCliDirectories
    $default = [ordered]@{
        schemaVersion     = 1
        defaultProfileId  = $null
        lastProfileId     = $null
        projectBookmarks  = @()
        proxyPorts        = [ordered]@{ ccp = $null; cliproxy = $null }
        verification      = [ordered]@{}
    }
    $s = Read-AiCliJsonFile -Path $paths.SettingsFile -Default $default
    if (-not $s.proxyPorts) { $s.proxyPorts = [ordered]@{ ccp = $null; cliproxy = $null } }
    return $s
}

function Save-AiCliSettings {
    param($Settings)
    $paths = Get-AiCliAppPaths
    Write-AiCliJsonFile -Path $paths.SettingsFile -Value $Settings
}

function Get-AiCliUserProfilePath {
    param([string]$Id)
    $safeId = Assert-AiCliSafeIdentifier -Id $Id -Kind 'Profile ID'
    $paths = Get-AiCliAppPaths
    return (Join-Path $paths.ProfilesDir "$safeId.json")
}

function Get-AiCliUserProfile {
    param([string]$Id)
    $path = Get-AiCliUserProfilePath -Id $Id
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $profile = Read-AiCliJsonFile -Path $path
    if ($profile -isnot [System.Collections.IDictionary]) {
        throw [IO.InvalidDataException]::new("用户 Profile JSON 损坏或不是对象: $Id")
    }
    return $profile
}

function Save-AiCliUserProfile {
    param($Profile)
    $id = Get-AiCliProperty $Profile 'id'
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'Profile 缺少 id' }
    $null = Assert-AiCliSafeIdentifier -Id $id -Kind 'Profile ID'
    $path = Get-AiCliUserProfilePath -Id $id
    Write-AiCliJsonFile -Path $path -Value $Profile
}

function Test-AiCliSecretReferencedByAnotherProfile {
    param(
        [Parameter(Mandatory)][string]$SecretId,
        [string]$ExceptProfileId
    )
    $null = Assert-AiCliSecretIdentifier -Id $SecretId
    $paths = Initialize-AiCliDirectories
    foreach ($file in @(Get-ChildItem -LiteralPath $paths.ProfilesDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $profileId = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($ExceptProfileId -and $profileId -eq $ExceptProfileId) { continue }
        $profile = Read-AiCliJsonFile -Path $file.FullName
        if ((Get-AiCliProperty $profile 'secretRef') -eq $SecretId) { return $true }
    }
    return $false
}

function Remove-AiCliUserProfile {
    param(
        [string]$Id,
        [switch]$Yes
    )
    $templates = Get-AiCliBuiltinTemplateIds
    # Removing only deletes user instance file; templates live in package data
    $path = Get-AiCliUserProfilePath -Id $Id
    if (-not (Test-Path -LiteralPath $path)) {
        throw "用户 Profile 不存在（模板不可删除）: $Id"
    }
    if (-not (Confirm-AiCliAction -Message "将删除用户 Profile 实例: $Id（不会删除模板）" -Yes:$Yes)) {
        throw [System.OperationCanceledException]::new('用户取消删除')
    }
    $prof = Read-AiCliJsonFile -Path $path
    $secretRef = Get-AiCliProperty $prof 'secretRef'
    Remove-Item -LiteralPath $path -Force
    if ($secretRef) {
        # remove secret only if no other profile references it
        if (-not (Test-AiCliSecretReferencedByAnotherProfile -SecretId $secretRef)) {
            Remove-AiCliSecret -SecretId $secretRef
        }
    }
    $settings = Get-AiCliSettings
    if ($settings.defaultProfileId -eq $Id) { $settings.defaultProfileId = $null }
    if ($settings.lastProfileId -eq $Id) { $settings.lastProfileId = $null }
    Save-AiCliSettings -Settings $settings
}

function Assert-AiCliExactCodexUserProfileCompatible {
    param(
        [Parameter(Mandatory)]$Template,
        [Parameter(Mandatory)]$UserProfile
    )
    $engine = [string](Get-AiCliProperty $Template 'engine')
    $provider = [string](Get-AiCliProperty $Template 'provider')
    $flexible = [bool](Get-AiCliProperty $Template 'flexible' $true)
    if ($engine -cne 'codex' -or $provider -cnotin @('qwen','deepseek','glm','ollama') -or $flexible) {
        return
    }

    $conflicts = [System.Collections.Generic.List[string]]::new()
    foreach ($field in @('region','plan')) {
        $userValue = [string](Get-AiCliProperty $UserProfile $field)
        $templateValue = [string](Get-AiCliProperty $Template $field)
        if ($userValue -and $userValue -cne $templateValue) {
            [void]$conflicts.Add($field)
        }
    }

    $workspaceEndpoint = [bool](Get-AiCliProperty $Template 'workspaceBaseUrlRequired' $false)
    if (-not $workspaceEndpoint) {
        $userEndpoint = [string](Get-AiCliProperty $UserProfile 'endpoint')
        $templateEndpoint = [string](Get-AiCliProperty $Template 'endpoint')
        if ($userEndpoint) {
            $normalizedUserEndpoint = $userEndpoint.Trim().TrimEnd('/')
            $normalizedTemplateEndpoint = $templateEndpoint.Trim().TrimEnd('/')
            if (-not [string]::Equals(
                    $normalizedUserEndpoint,
                    $normalizedTemplateEndpoint,
                    [StringComparison]::OrdinalIgnoreCase)) {
                [void]$conflicts.Add('endpoint')
            }
        }
    }

    $templateModels = Get-AiCliProperty $Template 'models'
    $userModels = Get-AiCliProperty $UserProfile 'models'
    if ($null -ne $userModels) {
        foreach ($field in @('primary','small')) {
            $userModel = [string](Get-AiCliProperty $userModels $field)
            $templateModel = [string](Get-AiCliProperty $templateModels $field)
            if ($userModel -and $userModel -cne $templateModel) {
                [void]$conflicts.Add("models.$field")
            }
        }
        foreach ($field in @('candidates','reserved')) {
            $rawUserModels = Get-AiCliProperty $userModels $field
            if ($null -eq $rawUserModels) { continue }
            $userList = @($rawUserModels | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $templateList = @(
                (Get-AiCliProperty $templateModels $field) |
                    Where-Object { $_ } |
                    ForEach-Object { [string]$_ }
            )
            if (($userList -join "`n") -cne ($templateList -join "`n")) {
                [void]$conflicts.Add("models.$field")
            }
        }
    }

    if ($conflicts.Count -gt 0) {
        $templateId = [string](Get-AiCliProperty $Template 'id')
        $profileId = [string](Get-AiCliProperty $UserProfile 'id')
        throw "用户 Profile $profileId 与 exact 模板不一致（$($conflicts -join ', ')）。为避免静默改投 Provider、地域或模型，请运行 aicli profile configure $templateId 重新配置。"
    }
}

function Merge-AiCliProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Template,
        $UserProfile
    )
    Assert-AiCliProfileDoesNotUseRetiredModel -Profile $Template -Context 'Provider 模板'
    if ($null -ne $UserProfile) {
        Assert-AiCliProfileDoesNotUseRetiredModel -Profile $UserProfile -Context '用户 Profile'
        Assert-AiCliExactCodexUserProfileCompatible -Template $Template -UserProfile $UserProfile
    }
    $merged = [ordered]@{}
    foreach ($k in @('schemaVersion','id','displayName','engine','provider','plan','region','transport','wireApi','endpoint','models','modelMetadata','auth','proxyRef','capabilities','compatibility','sources','deprecation','codexProviderId','codexModelCatalog','codexAutoCompactTokenLimit','codexAutoCompactTokenLimitScope','interpreterProviderId','requiresSecret','virtualReady','dataDestination','notes','hidden','env','defaultModel','modelPrefix','defaultEffort','effortLevels','effortMap','flexible','workspaceBaseUrlRequired')) {
        $v = Get-AiCliProperty $Template $k
        if ($null -ne $v) { $merged[$k] = $v }
    }
    $merged['templateId'] = Get-AiCliProperty $Template 'id'
    $merged['isVirtual'] = $true
    $merged['configured'] = -not [bool](Get-AiCliProperty $Template 'requiresSecret' $false)
    $merged['secretConfigured'] = $false
    $merged['secretRef'] = $null

    if ($UserProfile) {
        $merged['isVirtual'] = $false
        $merged['id'] = Get-AiCliProperty $UserProfile 'id'
        $dn = Get-AiCliProperty $UserProfile 'displayName'
        if ($dn) { $merged['displayName'] = $dn }
        foreach ($k in @('preferences','notes')) {
            $uv = Get-AiCliProperty $UserProfile $k
            if ($null -ne $uv) { $merged[$k] = $uv }
        }
        $workspaceBaseUrlRequired = [bool](Get-AiCliProperty $Template 'workspaceBaseUrlRequired' $false)
        if ($workspaceBaseUrlRequired) {
            $userEndpoint = [string](Get-AiCliProperty $UserProfile 'endpoint')
            if (-not [string]::IsNullOrWhiteSpace($userEndpoint)) {
                $merged['endpoint'] = Resolve-AiCliQwenWorkspaceResponsesEndpoint -Endpoint $userEndpoint
            }
        }
        $templateFlexible = [bool](Get-AiCliProperty $Template 'flexible' $true)
        if ($templateFlexible) {
            foreach ($k in @('region','plan')) {
                $uv = Get-AiCliProperty $UserProfile $k
                if ($null -ne $uv) { $merged[$k] = $uv }
            }
            if (-not $workspaceBaseUrlRequired) {
                $userEndpoint = Get-AiCliProperty $UserProfile 'endpoint'
                if ($null -ne $userEndpoint) { $merged['endpoint'] = $userEndpoint }
            }
            $userModels = Get-AiCliProperty $UserProfile 'models'
            if ($null -ne $userModels) { $merged['models'] = $userModels }
        }
        $sr = Get-AiCliProperty $UserProfile 'secretRef'
        $merged['secretRef'] = $sr
        $merged['secretConfigured'] = Test-AiCliSecretExists -SecretId $sr
        $merged['configured'] = $true
        if ((Get-AiCliProperty $Template 'requiresSecret') -and -not $merged['secretConfigured']) {
            $merged['configured'] = $false
        }
        if ($workspaceBaseUrlRequired -and
            [string]::IsNullOrWhiteSpace([string](Get-AiCliProperty $merged 'endpoint'))) {
            $merged['configured'] = $false
        }
    } else {
        # virtual template
        $needs = [bool](Get-AiCliProperty $Template 'requiresSecret' $false)
        $virt = [bool](Get-AiCliProperty $Template 'virtualReady' $false)
        $merged['configured'] = $virt -or (-not $needs)
    }

    # Managed-proxy readiness applies equally to virtual templates and to a
    # user Profile created from one. A saved JSON file must never make an
    # uninstalled or unauthenticated proxy appear configured.
    $proxy = Get-AiCliProperty $Template 'proxyRef'
    if ($proxy) {
        $exeOk = $false
        $authOk = $false
        try {
            $exeOk = [bool](Get-AiCliProxyExecutable -ProxyId $proxy)
            $authOk = Test-AiCliProxyAuthPresent -ProxyId $proxy
        } catch {}
        $merged['proxyInstalled'] = $exeOk
        $merged['proxyAuthPresent'] = $authOk
        $merged['configured'] = $exeOk -and $authOk
    }

    $merged['profileFingerprint'] = Get-AiCliProfileFingerprint -Profile $merged
    $settings = Get-AiCliSettings
    $ver = $null
    if ($settings.verification) {
        # do not use $pid — it is a PowerShell automatic variable (process id)
        $profileKey = [string]$merged['id']
        if ($settings.verification -is [System.Collections.IDictionary]) {
            if (@($settings.verification.Keys) -contains $profileKey) {
                $ver = $settings.verification[$profileKey]
            }
        } else {
            $prop = $settings.verification.PSObject.Properties[$profileKey]
            if ($prop) { $ver = $prop.Value }
        }
    }
    $verificationInvalidation = $null
    if ($ver -and (Get-AiCliProperty $ver 'profileFingerprint') -ne $merged['profileFingerprint']) {
        $verificationInvalidation = 'Profile 指纹已变化'
        $ver = $null
    }
    if ($ver) {
        $currentCheck = Test-AiCliVerificationRecordCurrent -Record $ver -MergedProfile $merged
        if (-not $currentCheck.Current) {
            $verificationInvalidation = $currentCheck.Reason
            $ver = $null
        }
    }
    $merged['verification'] = $ver
    if ($verificationInvalidation) { $merged['verificationInvalidation'] = $verificationInvalidation }
    $merged['status'] = Resolve-AiCliProfileStatus -Merged $merged
    return $merged
}

function Resolve-AiCliProfileStatus {
    param($Merged)
    $configured = [bool](Get-AiCliProperty $Merged 'configured')
    if (-not $configured) { return '不可用' }
    $ver = Get-AiCliProperty $Merged 'verification'
    if ($null -eq $ver) { return '可用但有限制' }
    $result = Get-AiCliProperty $ver 'result'
    if ($result -eq 'fail') { return '不可用' }
    $level = Get-AiCliProperty $ver 'level'
    $textPass = [bool](Get-AiCliProperty $ver 'textPass' $false)
    $toolPass = [bool](Get-AiCliProperty $ver 'toolPass' $false)
    $toolSkipped = [bool](Get-AiCliProperty $ver 'toolSkipped' $false)
    $agentPass = [bool](Get-AiCliProperty $ver 'agentPass' $false)
    if ($level -eq 'agent' -and $result -eq 'pass' -and $agentPass) { return '可用' }
    if ($level -eq 'all' -and $result -eq 'pass' -and $textPass -and $toolPass -and -not $toolSkipped) { return '可用' }
    if ($result -eq 'pass' -and ($textPass -or $toolPass)) { return '可用但有限制' }
    return '可用但有限制'
}

function Get-AiCliProfileFingerprint {
    param([Parameter(Mandatory)]$Profile)
    $stable = [ordered]@{}
    foreach ($key in @('schemaVersion','id','templateId','engine','provider','plan','region','transport','wireApi','endpoint','models','modelMetadata','auth','capabilities','codexProviderId','codexModelCatalog','codexAutoCompactTokenLimit','codexAutoCompactTokenLimitScope','compatibility','defaultEffort','effortLevels','effortMap','flexible','workspaceBaseUrlRequired','requiresSecret','proxyRef','preferences','secretRef')) {
        $value = Get-AiCliProperty $Profile $key
        if ($null -ne $value) { $stable[$key] = $value }
    }
    $catalogName = [string](Get-AiCliProperty $Profile 'codexModelCatalog')
    if ($catalogName) {
        $catalogPath = Get-AiCliDataPath -Relative (Join-Path 'model-catalogs' $catalogName)
        if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
            throw "Codex model catalog 不存在，无法计算 Profile 指纹: $catalogName"
        }
        $stable['codexModelCatalogSha256'] = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $json = $stable | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (([BitConverter]::ToString($sha.ComputeHash($bytes))) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Get-AiCliResolvedProfile {
    param([Parameter(Mandatory)][string]$Id)
    $user = Get-AiCliUserProfile -Id $Id
    if ($user) {
        $userId = [string](Get-AiCliProperty $user 'id')
        if ($userId -cne $Id) {
            throw "用户 Profile 文件名与内部 ID 不一致: $Id / $userId"
        }
        Assert-AiCliProfileDoesNotUseRetiredModel -Profile $user -Context "用户 Profile $Id"
        $tid = Get-AiCliProperty $user 'templateId'
        if (-not $tid) { $tid = Get-AiCliProperty $user 'id' }
        $template = Get-AiCliProviderManifest -Id $tid
        if ([bool](Get-AiCliProperty $template 'hidden' $false)) {
            throw "用户 Profile $Id 引用了隐藏模板 $tid；该可变入口已停用，请改用公开 exact Profile。"
        }
        $allTemplates = Import-AiCliProviderManifests
        if ($allTemplates.Contains($Id) -and [string]$tid -cne $Id) {
            throw "内置 Profile ID $Id 不能绑定到模板 $tid；请删除冲突用户 Profile 后重新配置。"
        }
        return (Merge-AiCliProfile -Template $template -UserProfile $user)
    }
    # try as template id (virtual)
    try {
        $template = Get-AiCliProviderManifest -Id $Id
    } catch {
        throw "未找到 Profile 或模板: $Id。使用 aicli profile list --available 查看。"
    }
    $hidden = Get-AiCliProperty $template 'hidden' $false
    if ($hidden) { throw "模板 $Id 为内部扩展，首版不作为公开 Profile。" }
    return (Merge-AiCliProfile -Template $template -UserProfile $null)
}

function Get-AiCliProfileList {
    param([switch]$Available)
    $result = @()
    $templates = Import-AiCliProviderManifests
    $userIds = @()
    $paths = Initialize-AiCliDirectories
    if (Test-Path -LiteralPath $paths.ProfilesDir) {
        Get-ChildItem -LiteralPath $paths.ProfilesDir -Filter '*.json' | ForEach-Object {
            $userIds += [IO.Path]::GetFileNameWithoutExtension($_.Name)
        }
    }
    $seen = @{}
    foreach ($uid in $userIds) {
        try {
            $r = Get-AiCliResolvedProfile -Id $uid
            $result += $r
            $seen[$uid] = $true
        } catch [IO.InvalidDataException] {
            throw
        } catch {}
    }
    foreach ($tid in $templates.Keys) {
        $t = $templates[$tid]
        if (Get-AiCliProperty $t 'hidden' $false) { continue }
        if (@($seen.Keys) -contains $tid) { continue }
        $merged = Merge-AiCliProfile -Template $t -UserProfile $null
        if ($Available) {
            $result += $merged
        } else {
            # default list: startable or configured
            $cfg = [bool](Get-AiCliProperty $merged 'configured' $false)
            $virt = [bool](Get-AiCliProperty $merged 'virtualReady' $false)
            if ($cfg -or $virt -or -not (Get-AiCliProperty $t 'requiresSecret' $false)) {
                if ($cfg) { $result += $merged }
            }
            # always show virtualReady official templates
            if ([bool](Get-AiCliProperty $t 'virtualReady' $false)) {
                if (-not ($result | Where-Object { (Get-AiCliProperty $_ 'id') -eq $tid })) { $result += $merged }
            }
        }
    }
    return $result
}

function Set-AiCliDefaultProfile {
    param([string]$Id)
    $null = Get-AiCliResolvedProfile -Id $Id
    $s = Get-AiCliSettings
    $s.defaultProfileId = $Id
    Save-AiCliSettings -Settings $s
}

function Set-AiCliLastProfile {
    param([string]$Id)
    $s = Get-AiCliSettings
    $s.lastProfileId = $Id
    Save-AiCliSettings -Settings $s
}

function Resolve-AiCliReusableSecretRef {
    param(
        [Parameter(Mandatory)]$Template,
        [Parameter(Mandatory)][string]$ProfileId,
        $ExistingProfile,
        [switch]$ReuseExistingSecret,
        [string]$ReuseSecretFrom,
        [AllowNull()][string]$TargetEndpoint
    )

    if ($ReuseExistingSecret -and $ReuseSecretFrom) {
        throw '--reuse-existing-secret 与 --reuse-secret-from 不能同时使用。'
    }
    if (-not $ReuseExistingSecret -and [string]::IsNullOrWhiteSpace($ReuseSecretFrom)) {
        return $null
    }
    if (-not [bool](Get-AiCliProperty $Template 'requiresSecret' $false)) {
        throw '当前模板不需要秘密，不能使用 SecretRef 复用选项。'
    }

    $getCredentialDomain = {
        param($Profile, [AllowNull()][string]$EndpointOverride, [bool]$UseEndpointOverride)
        $endpoint = if ($UseEndpointOverride) {
            [string]$EndpointOverride
        } else {
            [string](Get-AiCliProperty $Profile 'endpoint')
        }
        $hostName = ''
        if (-not [string]::IsNullOrWhiteSpace($endpoint)) {
            try { $hostName = ([Uri]$endpoint).DnsSafeHost.ToLowerInvariant() } catch {}
        }
        return ('{0}|{1}|{2}|{3}|{4}' -f
            ([string](Get-AiCliProperty $Profile 'provider')).ToLowerInvariant(),
            ([string](Get-AiCliProperty (Get-AiCliProperty $Profile 'auth') 'type')).ToLowerInvariant(),
            ([string](Get-AiCliProperty $Profile 'plan')).ToLowerInvariant(),
            ([string](Get-AiCliProperty $Profile 'region')).ToLowerInvariant(),
            $hostName)
    }
    $useTargetEndpointOverride = $PSBoundParameters.ContainsKey('TargetEndpoint')
    $targetDomain = & $getCredentialDomain $Template $TargetEndpoint $useTargetEndpointOverride
    $secretRef = $null
    if ($ReuseExistingSecret) {
        if ($null -eq $ExistingProfile) {
            throw "Profile $ProfileId 尚无现有 SecretRef 可复用。"
        }
        $existingTemplateId = [string](Get-AiCliProperty $ExistingProfile 'templateId')
        if ([string]::IsNullOrWhiteSpace($existingTemplateId)) {
            throw "Profile $ProfileId 缺少可验证的模板身份，拒绝复用 SecretRef。"
        }
        $existingTemplate = Get-AiCliProviderManifest -Id $existingTemplateId
        $existingUsesWorkspaceEndpoint = [bool](Get-AiCliProperty $existingTemplate 'workspaceBaseUrlRequired' $false)
        $existingEndpoint = if ($existingUsesWorkspaceEndpoint) {
            [string](Get-AiCliProperty $ExistingProfile 'endpoint')
        } else { $null }
        if ((& $getCredentialDomain $existingTemplate $existingEndpoint $existingUsesWorkspaceEndpoint) -cne $targetDomain) {
            throw "Profile $ProfileId 的原 Provider/认证域与目标不一致，拒绝复用 SecretRef。"
        }
        $secretRef = [string](Get-AiCliProperty $ExistingProfile 'secretRef')
    } else {
        $sourceId = Assert-AiCliSafeIdentifier -Id $ReuseSecretFrom -Kind '来源 Profile ID'
        if ($sourceId -ceq $ProfileId) {
            throw '复用当前 Profile 的 SecretRef 请使用 --reuse-existing-secret。'
        }
        $sourceRaw = Get-AiCliUserProfile -Id $sourceId
        if ($null -eq $sourceRaw) {
            throw "来源用户 Profile 不存在: $sourceId"
        }
        $source = Get-AiCliResolvedProfile -Id $sourceId
        if ((& $getCredentialDomain $source $null $false) -cne $targetDomain) {
            throw "来源 Profile $sourceId 与目标 Provider/认证域不兼容，拒绝复用 SecretRef。"
        }
        if (-not [bool](Get-AiCliProperty $source 'secretConfigured' $false)) {
            throw "来源 Profile $sourceId 的 SecretRef 不可用。"
        }
        $secretRef = [string](Get-AiCliProperty $sourceRaw 'secretRef')
    }

    if ([string]::IsNullOrWhiteSpace($secretRef) -or
        -not (Test-AiCliSecretExists -SecretId $secretRef)) {
        throw '指定的现有 SecretRef 不存在或不可用。'
    }
    return $secretRef
}

function Resolve-AiCliQwenWorkspaceResponsesEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Endpoint)

    $normalized = $Endpoint.Trim().TrimEnd('/')
    try {
        Assert-AiCliEndpointSafe -Url $normalized
        $uri = [Uri]$normalized
    } catch {
        throw 'Qwen Workspace Codex 需要有效的北京 Workspace Responses Base URL。'
    }

    $currentPath = '/compatible-mode/v1'
    $legacyPath = '/api/v2/apps/protocols/compatible-mode/v1'
    $requestedPath = $uri.AbsolutePath.TrimEnd('/')
    $valid = $uri.Scheme -ceq 'https' -and
        $uri.Port -eq 443 -and
        $uri.Host -cmatch '^ws-[a-z0-9][a-z0-9-]*\.cn-beijing\.maas\.aliyuncs\.com$' -and
        $requestedPath -cin @($currentPath, $legacyPath) -and
        [string]::IsNullOrEmpty($uri.Query) -and
        [string]::IsNullOrEmpty($uri.Fragment) -and
        [string]::IsNullOrEmpty($uri.UserInfo)
    if (-not $valid) {
        throw 'Qwen Workspace Codex 需要北京百炼控制台提供的 Workspace Responses Base URL；通用 DashScope 与 Token Plan 地址均不可用。'
    }
    return "https://$($uri.Host)$currentPath"
}

function Invoke-AiCliProfileConfigure {
    param(
        [Parameter(Mandatory)][string]$TemplateId,
        [string]$ProfileId,
        [switch]$ReuseExistingSecret,
        [string]$ReuseSecretFrom
    )
    $template = Get-AiCliProviderManifest -Id $TemplateId
    if (Get-AiCliProperty $template 'hidden' $false) {
        throw "不能配置隐藏模板: $TemplateId"
    }
    $id = if ($ProfileId) { $ProfileId } else { $TemplateId }
    $null = Assert-AiCliSafeIdentifier -Id $id -Kind 'Profile ID'
    $allTemplates = Import-AiCliProviderManifests
    if ($allTemplates.Contains($id) -and $id -cne $TemplateId) {
        throw "Profile ID $id 已由内置模板 $id 保留，不能绑定到 $TemplateId。"
    }

    Write-AiCliInfo ("配置模板：{0} → 实例 ID：{1}" -f (Get-AiCliProperty $template 'displayName'), $id)
    Write-AiCliInfo ("引擎：{0}  Provider：{1}  套餐：{2}" -f (Get-AiCliProperty $template 'engine'), (Get-AiCliProperty $template 'provider'), (Get-AiCliProperty $template 'plan'))
    $dest = Get-AiCliProperty $template 'dataDestination'
    if ($dest) { Write-AiCliWarn ("数据去向：{0}" -f $dest) }

    $existing = Get-AiCliUserProfile -Id $id
    $region = Get-AiCliProperty $template 'region'
    $models = Get-AiCliProperty $template 'models'
    $endpoint = Get-AiCliProperty $template 'endpoint'

    if ((Get-AiCliProperty $template 'provider') -eq 'custom' -or $TemplateId -eq 'claude-custom') {
        $endpoint = Read-Host 'Base URL（Anthropic Messages 兼容，https 或 localhost http）'
        Assert-AiCliEndpointSafe -Url $endpoint
        $model = Read-Host '主模型 ID'
        $small = Read-Host '小模型 ID（可空）'
        $null = Assert-AiCliModelId -Model $model
        if (-not [string]::IsNullOrWhiteSpace($small)) { $null = Assert-AiCliModelId -Model $small }
        $models = [ordered]@{ primary = $model; small = $small }
        $region = 'custom'
    } elseif ([bool](Get-AiCliProperty $template 'flexible' $true) -and
        (Get-AiCliProperty $template 'provider') -eq 'ollama') {
        $enteredEndpoint = Read-Host ("Ollama Base URL（默认 {0}，回车保留）" -f $endpoint)
        if (-not [string]::IsNullOrWhiteSpace($enteredEndpoint)) {
            Assert-AiCliEndpointSafe -Url $enteredEndpoint
            $endpoint = $enteredEndpoint
        }
        $model = Read-Host ("模型 ID（默认 {0}，回车保留）" -f (Get-AiCliProperty $models 'primary'))
        if (-not [string]::IsNullOrWhiteSpace($model)) {
            $null = Assert-AiCliModelId -Model $model
            $models = [ordered]@{ primary = $model; small = $model }
        }
    } elseif ([bool](Get-AiCliProperty $template 'workspaceBaseUrlRequired' $false)) {
        if ($ReuseSecretFrom) {
            $reuseSource = Get-AiCliResolvedProfile -Id $ReuseSecretFrom
            $endpoint = Resolve-AiCliQwenWorkspaceResponsesEndpoint `
                -Endpoint ([string](Get-AiCliProperty $reuseSource 'endpoint'))
            Write-AiCliInfo '将复用来源 Profile 的同域 Workspace Endpoint；不会回显 Workspace 标识。'
        } elseif ($ReuseExistingSecret -and $existing) {
            $endpoint = Resolve-AiCliQwenWorkspaceResponsesEndpoint `
                -Endpoint ([string](Get-AiCliProperty $existing 'endpoint'))
            Write-AiCliInfo '将保留当前 Profile 的同域 Workspace Endpoint；不会回显 Workspace 标识。'
        } else {
            $enteredEndpoint = Read-Host '百炼 Workspace Responses Base URL（北京控制台模型页 Responses API 示例中的 base_url）'
            $endpoint = Resolve-AiCliQwenWorkspaceResponsesEndpoint -Endpoint $enteredEndpoint
        }
    } elseif ([bool](Get-AiCliProperty $template 'flexible' $true) -and
        (Get-AiCliProperty $template 'provider') -eq 'qwen' -and
        (Get-AiCliProperty $template 'plan') -eq 'paygo') {
        $r = Read-Host '地域 [cn-beijing / singapore]（默认 cn-beijing）'
        if ([string]::IsNullOrWhiteSpace($r)) { $r = 'cn-beijing' }
        $region = $r
        if ($r -notin @('cn-beijing','singapore')) { throw '地域仅支持 cn-beijing 或 singapore。' }
        if ($r -eq 'singapore') {
            $ws = Read-Host 'WorkspaceId（新加坡必需）'
            if ($ws -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{1,127}$') { throw 'WorkspaceId 格式非法。' }
            $engine = Get-AiCliProperty $template 'engine'
            $endpoint = if ($engine -eq 'claude') {
                "https://$ws.ap-southeast-1.maas.aliyuncs.com/apps/anthropic"
            } else {
                "https://$ws.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
            }
        }
        $model = Read-Host ("主模型（默认 {0}）" -f (Get-AiCliProperty $models 'primary'))
        if (-not [string]::IsNullOrWhiteSpace($model)) {
            $null = Assert-AiCliModelId -Model $model
            $models = [ordered]@{ primary = $model; small = (Get-AiCliProperty $models 'small') }
        }
    } elseif ([bool](Get-AiCliProperty $template 'flexible' $true) -and
        (Get-AiCliProperty $template 'engine') -in @('claude', 'interpreter') -and
        (Get-AiCliProperty $template 'provider') -notin @('anthropic','chatgpt-proxy')) {
        $model = Read-Host ("主模型（默认 {0}，回车保留）" -f (Get-AiCliProperty $models 'primary'))
        if (-not [string]::IsNullOrWhiteSpace($model)) {
            $null = Assert-AiCliModelId -Model $model
            $models = [ordered]@{ primary = $model; small = (Get-AiCliProperty $models 'small') }
        }
    }

    $secretRef = Resolve-AiCliReusableSecretRef `
        -Template $template `
        -ProfileId $id `
        -ExistingProfile $existing `
        -ReuseExistingSecret:$ReuseExistingSecret `
        -ReuseSecretFrom $ReuseSecretFrom `
        -TargetEndpoint ([string]$endpoint)
    $oldSecretRef = if ($existing) { Get-AiCliProperty $existing 'secretRef' } else { $null }
    $createdNewSecret = $false
    if ($secretRef) {
        Write-AiCliInfo '将复用现有 SecretRef；不会读取、回显或复制秘密值。'
    } elseif ([bool](Get-AiCliProperty $template 'requiresSecret' $false)) {
        $plain = Read-AiCliSecret -Prompt '请输入 API Key（不回显，不会写入 Git 或日志）'
        if ([string]::IsNullOrEmpty($plain)) { throw '未录入密钥，配置已取消' }
        try {
            $secretRef = New-AiCliSecret -PlainText $plain -Label "$id-api-key"
            $createdNewSecret = $true
        } finally {
            $plain = $null
        }
    } elseif ($existing) {
        $secretRef = Get-AiCliProperty $existing 'secretRef'
    }

    $userProf = [ordered]@{
        schemaVersion = 1
        id            = $id
        templateId    = $TemplateId
        displayName   = (Get-AiCliProperty $template 'displayName')
        region        = $region
        plan          = (Get-AiCliProperty $template 'plan')
        models        = $models
        endpoint      = $endpoint
        secretRef     = $secretRef
        updatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    }
    try {
        Save-AiCliUserProfile -Profile $userProf
    } catch {
        if ($createdNewSecret -and $secretRef) {
            try { Remove-AiCliSecret -SecretId $secretRef } catch {}
        }
        throw
    }
    if ($oldSecretRef -and $oldSecretRef -ne $secretRef -and
        -not (Test-AiCliSecretReferencedByAnotherProfile -SecretId $oldSecretRef -ExceptProfileId $id)) {
        Remove-AiCliSecret -SecretId $oldSecretRef
    }
    Write-AiCliSuccess "已保存 Profile: $id"
    Write-AiCliInfo "下一步：aicli doctor $id"
    return $userProf
}
