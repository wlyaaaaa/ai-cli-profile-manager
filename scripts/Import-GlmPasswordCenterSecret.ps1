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
                if ($null -eq $current -or [string]$current.templateId -cne $id) {
                    throw "The exact AICLI profile is unavailable: $id"
                }
                $resolved = Get-AiCliResolvedProfile -Id $id
                if ([string]$resolved.provider -cne 'glm' -or
                    [string]$resolved.transport -cne 'responses' -or
                    [string]$resolved.endpoint -cne 'https://open.bigmodel.cn/api/v1') {
                    throw "The exact GLM profile contract is invalid: $id"
                }
                $oldProfiles.Add([pscustomobject]@{
                    Id = $id
                    Profile = $current
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
                try { Save-AiCliUserProfile -Profile $old.Profile } catch {}
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
