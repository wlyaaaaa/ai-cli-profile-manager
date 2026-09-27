#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Inspect','Apply')][string]$Mode = 'Inspect',
    [string]$BackupRoot,
    [string]$ModulePath = (Join-Path $PSScriptRoot '../src/AiCliProfileManager/AiCliProfileManager.psd1')
)
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'Apply' -and -not $BackupRoot) { throw 'Apply requires a metadata backup directory.' }
$module = Import-Module $ModulePath -Force -PassThru
& $module {
    param($Operation,$Backup)
    $paths = Get-AiCliAppPaths
    $changes = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $paths.ProfilesDir -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        try { $resolved = Get-AiCliResolvedProfile -Id $id } catch { continue }
        $reference = Get-AiCliVendorSecretRef -Profile $resolved
        if (-not $reference) { continue }
        $original = [IO.File]::ReadAllText($file.FullName)
        $saved = $original | ConvertFrom-Json -AsHashtable
        if ($saved.secretRef -ceq $reference) { continue }
        if ($Operation -eq 'Apply') {
            [IO.Directory]::CreateDirectory($Backup) | Out-Null
            $backupPath = Join-Path $Backup $file.Name
            if (Test-Path -LiteralPath $backupPath) { throw 'Metadata backup already exists; use a new directory.' }
            [IO.File]::WriteAllText($backupPath, $original, [Text.UTF8Encoding]::new($false))
            if ([IO.File]::ReadAllText($file.FullName) -cne $original) { throw 'Profile changed concurrently.' }
            $saved.secretRef = $reference
            Save-AiCliUserProfile -Profile $saved
            if ((Get-AiCliUserProfile -Id $id).secretRef -cne $reference) { throw 'Vendor reference readback failed.' }
        }
        $changes += @{profile=$id;vendor=$resolved.provider;reference=$reference;metadataChanged=($Operation -eq 'Apply')}
    }
    @{status='pass';mode=$Operation;profiles=$changes;credentialValuesRead=$false;secretFilesChanged=$false} | ConvertTo-Json -Depth 5
} -Operation $Mode -Backup $BackupRoot
