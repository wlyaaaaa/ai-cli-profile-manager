#Requires -Version 7.2
[CmdletBinding()]
param([string[]]$ProfileId = @())
# Compatibility name. This operation writes references, never imports a key.
$module = Import-Module (Join-Path $PSScriptRoot '..\src\AiCliProfileManager\AiCliProfileManager.psd1') -Force -PassThru
& $module {
    param([string[]]$Ids)
    if (-not $Ids.Count) {
        $Ids = @(Get-AiCliProfileList | Where-Object { $_.provider -eq 'glm' } | ForEach-Object id)
    }
    foreach ($id in $Ids) {
        $profile = Get-AiCliResolvedProfile -Id $id
        if ($profile.provider -ne 'glm') { throw 'Expected a GLM profile.' }
        $saved = Get-AiCliUserProfile -Id $id
        if (-not $saved) { $saved = [ordered]@{ schemaVersion=1; id=$id; templateId=$profile.templateId } }
        $saved.secretRef = 'passwordcenter:glm'
        Save-AiCliUserProfile -Profile $saved
    }
} -Ids $ProfileId
