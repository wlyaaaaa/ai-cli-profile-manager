# Unified redaction for text, objects, exceptions, URLs, logs.

$script:AiCliRedactionPatterns = @(
    # Scheme + credential must be removed before generic key/value rules see
    # only the scheme word and accidentally leave the real credential behind.
    '(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9\-\._~\+\/]+=*',
    '(?i)([A-Za-z0-9_-]*(?:api[_-]?key|token|secret|password|authorization)[A-Za-z0-9_-]*)\s*[=:]\s*["'']?([^\s"'';]+)',
    '(?i)(api[_-]?key|token|secret|password|authorization|bearer)\s*[=:]\s*["'']?([^\s"'';]+)',
    '(?i)sk-[A-Za-z0-9_\-\.]{10,}',
    '(?i)eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*={0,2}'
)

function Test-AiCliUsageMetric {
    param([string]$Name, $Value)
    $metricName = $Name.ToLowerInvariant() -replace '[_-]', ''
    if ($metricName -notin @(
        'inputtokens','outputtokens','prompttokens','completiontokens','totaltokens',
        'cachedtokens','reasoningtokens','cachedinputtokens','reasoningoutputtokens',
        'cachereadtokens','cachecreationtokens','cachereadinputtokens','cachecreationinputtokens',
        'currentcontexttokens','contextwindowtokens','inputwindowtokens','outputwindowtokens',
        'autocompactwindowtokens','codexautocompacttokenlimit','maxtokens','maxoutputtokens',
        'maxcompletiontokens'
    )) { return $false }
    if ($Value -is [bool] -or $null -eq $Value) { return $false }
    $number = 0.0
    return [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and
        -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Protect-AiCliSecretText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = [regex]::Replace(
        $Text,
        '(?i)(https://)ws-[a-z0-9][a-z0-9-]*(\.cn-beijing\.maas\.aliyuncs\.com)',
        '$1ws-***$2'
    )
    foreach ($pat in $script:AiCliRedactionPatterns) {
        $result = [regex]::Replace($result, $pat, {
            param($m)
            if ($m.Groups.Count -ge 3 -and $m.Groups[2].Success) {
                if (Test-AiCliUsageMetric -Name $m.Groups[1].Value -Value $m.Groups[2].Value) {
                    return $m.Value
                }
                return ($m.Groups[1].Value + '=***REDACTED***')
            }
            return '***REDACTED***'
        })
    }
    return $result
}

function Protect-AiCliObject {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $InputObject,
        [string[]]$SecretKeys = @('apiKey','api_key','secret','token','password','authorization','value','secretValue','refresh_token','access_token','cipherBase64')
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return (Protect-AiCliSecretText -Text $InputObject) }
    # Pipeline-produced primitives can have a PSObject wrapper; keep their type.
    if ($InputObject -is [bool]) { return [bool]$InputObject }
    if ($InputObject -is [ValueType]) { return $InputObject.PSObject.BaseObject }
    if ($InputObject -is [pscustomobject]) {
        $properties = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $properties[$property.Name] = $property.Value
        }
        $InputObject = $properties
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in $InputObject.Keys) {
            $keyStr = [string]$k
            # Conservative key-name detection: custom provider variables such as
            # AICLI_OI_PROVIDER_KEY must be redacted too. Boolean presence flags stay booleans.
            $isPresenceMetadata = $InputObject[$k] -is [bool] -and $keyStr -in @('secretPresence','secretConfigured','requiresSecret','localClientKeyPresent')
            # Preserve only the closed public display enum emitted by Format-AiCliSecretPresence.
            $isPresenceMetadata = $isPresenceMetadata -or ($keyStr -eq 'secretPresence' -and $InputObject[$k] -is [string] -and $InputObject[$k] -cin @('已配置','未配置'))
            $isUsageMetadata = Test-AiCliUsageMetric -Name $keyStr -Value $InputObject[$k]
            $isSecretField = (-not $isPresenceMetadata) -and (-not $isUsageMetadata) -and (
                ($SecretKeys -contains $keyStr) -or
                ($keyStr -match '(?i)(api.?key|key$|token|secret|password|authorization|credential|cipherBase64)')
            )
            if ($isSecretField) {
                $val = $InputObject[$k]
                if ($null -eq $val -or [string]::IsNullOrEmpty([string]$val)) {
                    $out[$keyStr] = $null
                } elseif ($val -is [bool]) {
                    $out[$keyStr] = $val
                } else {
                    $out[$keyStr] = '***REDACTED***'
                }
            } else {
                $out[$keyStr] = Protect-AiCliObject -InputObject $InputObject[$k] -SecretKeys $SecretKeys
            }
        }
        return $out
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += ,(Protect-AiCliObject -InputObject $item -SecretKeys $SecretKeys)
        }
        return ,$list
    }
    return $InputObject
}

function Format-AiCliSecretPresence {
    param([bool]$Configured)
    if ($Configured) { return '已配置' }
    return '未配置'
}

function Write-AiCliLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info','Warn','Error','Debug')][string]$Level = 'Info'
    )
    try {
        $paths = Get-AiCliAppPaths
        if (-not (Test-Path -LiteralPath $paths.LogsDir)) {
            New-Item -ItemType Directory -Force -Path $paths.LogsDir | Out-Null
        }
        $file = Join-Path $paths.LogsDir ("aicli-{0:yyyyMMdd}.log" -f (Get-Date))
        $safe = Protect-AiCliSecretText -Text $Message
        $line = "{0:o} [{1}] {2}" -f (Get-Date).ToUniversalTime(), $Level, $safe
        Add-Content -LiteralPath $file -Value $line -Encoding utf8
    } catch {
        # logging must never break the product
    }
}
