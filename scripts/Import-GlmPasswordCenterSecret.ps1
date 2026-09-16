#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$secret = [Environment]::GetEnvironmentVariable('AICLI_PASSWORD_CENTER_SECRET', 'Process')
[Environment]::SetEnvironmentVariable('AICLI_PASSWORD_CENTER_SECRET', $null, 'Process')
if ([string]::IsNullOrWhiteSpace($secret)) { throw 'Password Center did not inject the GLM credential.' }

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$modulePath = Join-Path $repo 'src\AiCliProfileManager\AiCliProfileManager.psd1'
$module = Import-Module $modulePath -Force -PassThru
$ids = @('codex-glm-5-3', 'codex-glm-5-3-flash')

try {
    $result = & $module {
        param([string[]]$ProfileIds, [string]$PlainText)
        $created = [Collections.Generic.List[string]]::new()
        $oldProfiles = [Collections.Generic.List[object]]::new()
        try {
            foreach ($id in $ProfileIds) {
                $current = Get-AiCliUserProfile -Id $id
                $existed = $null -ne $current
                $template = Get-AiCliProviderManifest -Id $id
                if ($existed -and [string]$current.templateId -cne $id) {
                    throw "The existing AICLI profile is not bound to the exact template: $id"
                }
                if (-not $existed) {
                    $current = [ordered]@{
                        schemaVersion = 1
                        id = $id
                        templateId = $id
                        displayName = [string](Get-AiCliProperty $template 'displayName')
                        region = [string](Get-AiCliProperty $template 'region')
                        plan = [string](Get-AiCliProperty $template 'plan')
                        models = Get-AiCliProperty $template 'models'
                        endpoint = [string](Get-AiCliProperty $template 'endpoint')
                        secretRef = $null
                        updatedUtc = [DateTime]::UtcNow.ToString('o')
                    }
                }
                if ([string]$template.provider -cne 'glm' -or
                    [string]$template.transport -cne 'responses' -or
                    [string]$template.endpoint -cne 'https://open.bigmodel.cn/api/v1') {
                    throw "The exact GLM profile contract is invalid: $id"
                }
                $oldProfiles.Add([pscustomobject]@{
                    Id = $id
                    Existed = $existed
                    Profile = if ($existed) { $current } else { $null }
                    SecretRef = [string]$current.secretRef
                }) | Out-Null
                $newRef = New-AiCliSecret -PlainText $PlainText -Label "$id-api-key"
                $created.Add($newRef) | Out-Null
                $current.secretRef = $newRef
                $current.updatedUtc = [DateTime]::UtcNow.ToString('o')
                Save-AiCliUserProfile -Profile $current
            }
            foreach ($id in $ProfileIds) {
                $check = Get-AiCliResolvedProfile -Id $id
                if (-not [bool]$check.configured -or -not [bool]$check.secretConfigured) {
                    throw "The GLM profile secret readback failed: $id"
                }
            }
            foreach ($old in $oldProfiles) {
                if ($old.SecretRef -and -not (Test-AiCliSecretReferencedByAnotherProfile -SecretId $old.SecretRef)) {
                    Remove-AiCliSecret -SecretId $old.SecretRef
                }
            }
            return [ordered]@{
                schema = 'aicli.password-center-profile-import.v1'
                status = 'pass'
                profiles = @($ProfileIds)
                plaintext_returned = $false
            }
        } catch {
            foreach ($old in $oldProfiles) {
                try {
                    if ($old.Existed) {
                        Save-AiCliUserProfile -Profile $old.Profile
                    } else {
                        $path = Get-AiCliUserProfilePath -Id $old.Id
                        if (Test-Path -LiteralPath $path -PathType Leaf) {
                            Remove-Item -LiteralPath $path -Force
                        }
                    }
                } catch {}
            }
            foreach ($newRef in $created) {
                try { Remove-AiCliSecret -SecretId $newRef } catch {}
            }
            throw
        }
    } -ProfileIds $ids -PlainText $secret
    $result | ConvertTo-Json -Depth 6 -Compress
} finally {
    $secret = $null
}
