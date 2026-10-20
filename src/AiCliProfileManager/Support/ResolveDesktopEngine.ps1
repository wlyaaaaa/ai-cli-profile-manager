#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-AiCliDesktopEngineHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
    catch { return $null }
}


function Test-AiCliOpenAICodexSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $certificate = $signature.SignerCertificate
        return (
            [string]$signature.Status -ceq 'Valid' -and
            $null -ne $certificate -and
            [string]$certificate.Subject -cmatch
                '^CN="OpenAI OpCo, LLC", O="OpenAI OpCo, LLC"(?:, [^\r\n]+)?$'
        )
    }
    catch { return $false }
}

function Get-AiCliCodexCliVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-AiCliOpenAICodexSignature -Path $Path)) { return $null }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [IO.Path]::GetFullPath($Path)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    [void]$start.ArgumentList.Add('--version')
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill($true)
            return $null
        }
        if ($process.ExitCode -ne 0 -or
            -not [string]::IsNullOrWhiteSpace($stderr)) {
            return $null
        }
        $match = [regex]::Match(
            $stdout.Trim(),
            '^codex-cli\s+([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$'
        )
        if (-not $match.Success) { return $null }
        return [System.Management.Automation.SemanticVersion]::Parse($match.Groups[1].Value)
    }
    catch { return $null }
    finally { if ($null -ne $process) { $process.Dispose() } }
}

function Get-AiCliOfficialCodexCacheCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OfficialCache,
        [Parameter(Mandatory)][System.Management.Automation.SemanticVersion]$MinimumVersion
    )

    if (-not (Test-Path -LiteralPath $OfficialCache -PathType Container)) {
        return $null
    }
    $root = [IO.Path]::GetFullPath($OfficialCache).TrimEnd('\')
    $candidates = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
        if ($directory.Name -cnotmatch '^[a-f0-9]{16}$' -or
            ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            continue
        }
        $candidate = Join-Path $directory.FullName 'codex.exe'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $candidate -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $full = [IO.Path]::GetFullPath($candidate)
        if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $version = Get-AiCliCodexCliVersion -Path $full
        if ($null -eq $version -or $version -lt $MinimumVersion) { continue }
        $hash = Get-AiCliDesktopEngineHash -Path $full
        if ([string]::IsNullOrWhiteSpace($hash)) { continue }
        $candidates += [pscustomobject]@{
            FileName = $full
            Version = $version
            Hash = $hash
            LastWriteTimeUtc = $item.LastWriteTimeUtc
        }
    }
    if ($candidates.Count -eq 0) { return $null }
    return @($candidates | Sort-Object -Property @(
        @{ Expression = 'Version'; Descending = $true },
        @{ Expression = 'LastWriteTimeUtc'; Descending = $true },
        @{ Expression = 'FileName'; Descending = $true }
    ))[0]
}

function New-AiCliDesktopEngineResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Resolution,
        [string]$ContentHash,
        [string]$PackageFullName
    )

    return [pscustomobject]@{
        FileName       = [IO.Path]::GetFullPath($FileName)
        PrefixArgs     = @()
        Kind           = 'desktop-codex'
        Resolution     = $Resolution
        ContentHash    = $ContentHash
        PackageFullName = $PackageFullName
    }
}

function Get-AiCliDesktopEngineFallback {
    [CmdletBinding()]
    param()

    try {
        $resolved = Resolve-AiCliLaunchExecutable -Name 'codex'
        if ($null -eq $resolved -or
            [string]::IsNullOrWhiteSpace([string]$resolved.FileName) -or
            -not (Test-Path -LiteralPath $resolved.FileName -PathType Leaf)) {
            return $null
        }
        return [pscustomobject]@{
            FileName        = [IO.Path]::GetFullPath([string]$resolved.FileName)
            PrefixArgs      = @($resolved.PrefixArgs | ForEach-Object { [string]$_ })
            Kind            = 'desktop-fallback'
            Resolution      = 'fallback'
            ContentHash     = $null
            PackageFullName = $null
            FallbackKind    = [string]$resolved.Kind
        }
    }
    catch { return $null }
}

function Resolve-AiCliPhysicalDirectory {
    <#
    .SYNOPSIS
      Follows every junction or symbolic link in an existing directory path.

    .DESCRIPTION
      The upstream cache is commonly redirected to another volume.  Creating a
      subdirectory through such a junction has been observed to report success
      while no directory appears, even though files and reads pass through, so
      new directories are created beneath the physical target instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root.TrimEnd('\')
    foreach ($part in $full.Substring($root.Length).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path ($current + '\') $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { continue }
        $target = $item.ResolveLinkTarget($true)
        if ($null -eq $target -or -not (Test-Path -LiteralPath $target.FullName -PathType Container)) {
            throw 'The Desktop engine cache link has no reachable target.'
        }
        $current = [IO.Path]::GetFullPath($target.FullName).TrimEnd('\')
    }
    return $current
}

function Get-AiCliStagedAppxEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$SourceHash
    )

    $paths = Get-AiCliAppPaths
    $cacheRoot = [IO.Path]::GetFullPath((Join-Path ([string]$paths.LocalRoot) 'desktop\upstream'))
    $destination = Join-Path $cacheRoot $SourceHash
    $cachedEngine = Join-Path $destination 'codex.exe'
    $companions = @(
        Get-ChildItem -LiteralPath $SourceDirectory -File -Filter 'codex*.exe' -ErrorAction Stop |
            Sort-Object Name
    )
    if ($companions.Count -eq 0 -or -not ($companions.Name -contains 'codex.exe')) {
        throw 'The installed Desktop package has no complete Codex engine.'
    }
    if ((Get-AiCliDesktopEngineHash -Path $cachedEngine) -eq $SourceHash) {
        foreach ($companion in $companions) {
            if ((Get-AiCliDesktopEngineHash -Path (Join-Path $destination $companion.Name)) -ne
                (Get-AiCliDesktopEngineHash -Path $companion.FullName)) {
                throw "The staged Desktop engine companion changed: $($companion.Name)"
            }
        }
        $version = Get-AiCliCodexCliVersion -Path $cachedEngine
        if ($null -eq $version) { throw 'The staged Desktop engine could not be verified.' }
        return [pscustomobject]@{ FileName = $cachedEngine; Version = $version; Hash = $SourceHash }
    }
    if (Test-Path -LiteralPath $destination) {
        throw 'The staged Desktop engine directory is incomplete or changed.'
    }

    New-Item -ItemType Directory -Path $cacheRoot -Force -ErrorAction Stop | Out-Null
    $physicalRoot = Resolve-AiCliPhysicalDirectory -Path $cacheRoot
    $physicalDestination = Join-Path $physicalRoot $SourceHash
    $staging = [IO.Path]::GetFullPath((Join-Path $physicalRoot ('.' + $SourceHash + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')))
    if (-not $staging.StartsWith($physicalRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Desktop engine staging path is outside its cache.'
    }
    $publishLock = Enter-AiCliFileLock -TargetPath $physicalRoot
    try {
        New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null
        if (-not (Test-Path -LiteralPath $staging -PathType Container)) {
            throw 'The Desktop engine staging directory was reported created but is missing.'
        }
        foreach ($companion in $companions) {
            $target = Join-Path $staging $companion.Name
            # Store resources can carry EFS attributes. Copy the verified bytes,
            # not the source file attributes, into the managed executable cache.
            $inputStream = [IO.File]::OpenRead($companion.FullName)
            try {
                $outputStream = [IO.File]::Create($target)
                try { $inputStream.CopyTo($outputStream) }
                finally { $outputStream.Dispose() }
            }
            finally { $inputStream.Dispose() }
            if ((Get-AiCliDesktopEngineHash -Path $target) -ne (Get-AiCliDesktopEngineHash -Path $companion.FullName)) {
                throw "Desktop engine companion hash mismatch: $($companion.Name)"
            }
        }
        if ((Get-AiCliDesktopEngineHash -Path (Join-Path $staging 'codex.exe')) -ne $SourceHash) {
            throw 'Desktop engine staging hash mismatch.'
        }
        $version = Get-AiCliCodexCliVersion -Path (Join-Path $staging 'codex.exe')
        if ($null -eq $version) { throw 'The installed Desktop engine has no valid OpenAI signature or version.' }
        if (-not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $staging -Destination $physicalDestination -ErrorAction Stop
            $staging = $null
        }
    }
    finally {
        try {
            if ($staging -and (Test-Path -LiteralPath $staging)) {
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
            }
        }
        finally { Exit-AiCliFileLock -Lock $publishLock }
    }
    if ((Get-AiCliDesktopEngineHash -Path $cachedEngine) -ne $SourceHash) {
        throw 'The staged Desktop engine did not retain the package bytes.'
    }
    return [pscustomobject]@{ FileName = $cachedEngine; Version = $version; Hash = $SourceHash }
}

function Remove-AiCliObsoleteUpstreamCache {
    [CmdletBinding()]
    param($Result, $Package, [string]$SourceHash, [string]$PackageName = 'OpenAI.Codex')

    $lock = $null
    try {
        $logicalRoot = Join-Path ([string](Get-AiCliAppPaths).LocalRoot) 'desktop\upstream'
        if (-not (Test-Path -LiteralPath $logicalRoot -PathType Container)) { return }
        $root = Resolve-AiCliPhysicalDirectory -Path $logicalRoot
        $lock = Enter-AiCliFileLock -TargetPath $root -TimeoutMs 250
        $statePath = Join-Path $root 'cleanup-state.json'
        $state = Read-AiCliJsonFile -Path $statePath -Default @{}
        if ($state -is [Collections.IDictionary] -and $state['sourceHash'] -ceq $SourceHash) { return }
        $samePackage = {
            $latest = @(Get-AppxPackage -Name $PackageName -ErrorAction Stop | Sort-Object Version -Descending)
            $latest.Count -gt 0 -and $latest[0].PackageFullName -ceq $Package.PackageFullName -and
                (Get-AiCliDesktopEngineHash -Path (Join-Path $latest[0].InstallLocation 'app\resources\codex.exe')) -ceq $SourceHash
        }
        if (-not (& $samePackage)) { return }
        $expected = @('codex.exe', 'codex-code-mode-host.exe', 'codex-command-runner.exe',
            'codex-windows-sandbox-service.exe', 'codex-windows-sandbox-setup.exe')
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop)) {
            if ($directory.Name -cnotmatch '^[a-f0-9]{64}$' -or
                $directory.Name -in @($SourceHash, $Result.ContentHash) -or
                ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $retired = Join-Path $root ('.' + $directory.Name + '.' + [Guid]::NewGuid().ToString('N') + '.retiring')
            $handles = [Collections.Generic.List[IDisposable]]::new()
            try {
                # Rename under the publication lock; an executable image can
                # still be running after its parent directory was renamed.
                Rename-Item -LiteralPath $directory.FullName -NewName ([IO.Path]::GetFileName($retired)) -ErrorAction Stop
                $entries = @(Get-ChildItem -LiteralPath $retired -Force -ErrorAction Stop)
                $safe = $entries.Count -eq 5 -and @($entries | Where-Object { $_.PSIsContainer -or $_.Name -cnotin $expected }).Count -eq 0
                foreach ($item in @((Get-Item -LiteralPath $retired -Force -ErrorAction Stop)) + $entries) {
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                        @(Get-Item -LiteralPath ('\\?\' + $item.FullName) -Stream * -ErrorAction Stop | Where-Object Stream -NE ':$DATA').Count) { $safe = $false; break }
                    if (-not $item.PSIsContainer -and -not (Test-AiCliOpenAICodexSignature -Path $item.FullName)) { $safe = $false; break }
                }
                if ((Get-AiCliDesktopEngineHash -Path (Join-Path $retired 'codex.exe')) -cne $directory.Name) { $safe = $false }
                if (-not $safe) {
                    Write-AiCliLog -Level Debug -Message "Upstream cache retained: $($directory.Name) (unverified)."
                    continue
                }
                $fresh = @(Get-ChildItem -LiteralPath $retired -Force -ErrorAction Stop)
                if ($fresh.Count -ne 5 -or @($fresh | Where-Object { $_.PSIsContainer -or $_.Name -cnotin $expected -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count -or
                    -not (& $samePackage)) { continue }
                # ReadWrite rejects mapped executable images. Hold every file
                # until deletion so a failed open retains the whole directory.
                foreach ($file in $fresh) {
                    $handles.Add([IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Delete))
                }
                Remove-Item -LiteralPath $retired -Recurse -Force -ErrorAction Stop
                Write-AiCliLog -Level Info -Message "Retired upstream cache: $($directory.Name)."
            }
            catch { Write-AiCliLog -Level Warn -Message "Upstream cache retained: $($directory.Name); cleanup failed." }
            finally {
                foreach ($handle in $handles) { $handle.Dispose() }
                if (Test-Path -LiteralPath $retired) {
                    try { Rename-Item -LiteralPath $retired -NewName $directory.Name -ErrorAction Stop }
                    catch { Write-AiCliLog -Level Warn -Message "Upstream cache name could not be restored: $retired." }
                }
            }
        }
        # Failed candidates can be retried after the next package engine update;
        # model-list refreshes for this source must not repeat signature checks.
        Write-AiCliJsonFile -Path $statePath -Value @{ sourceHash = $SourceHash } -SkipLock
    }
    catch { Write-AiCliLog -Level Debug -Message 'Upstream cache retention deferred; inspection or lock unavailable.' }
    finally { Exit-AiCliFileLock -Lock $lock }
}

function Resolve-AiCliDesktopEngine {
    <#
    .SYNOPSIS
      Resolves a Desktop Codex executable that matches the registered AppX package.

    .DESCRIPTION
      The registered AppX package anchors the official Desktop identity.  OpenAI may
      independently rotate the signed LocalAppData Codex child while the Store package
      version remains unchanged, so a newer/equal valid OpenAI-signed official cache
      entry is preferred even when its bytes differ from the bundled resource.  The
      AppX resource is staged under AICLI-owned LocalAppData only when no eligible
      official cache entry exists.
    #>
    [CmdletBinding()]
    param([string]$PackageName = 'OpenAI.Codex')

    try {
        $packages = @(
            Get-AppxPackage -Name $PackageName -ErrorAction Stop |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
                Sort-Object -Property Version -Descending
        )
    }
    catch { throw 'The installed Desktop package could not be inspected.' }

    if ($packages.Count -eq 0) { return Get-AiCliDesktopEngineFallback }
    $package = $packages[0]
    $sourceDirectory = Join-Path ([string]$package.InstallLocation) 'app\resources'
    $source = Join-Path $sourceDirectory 'codex.exe'
    $sourceHash = Get-AiCliDesktopEngineHash -Path $source
    if ([string]::IsNullOrWhiteSpace($sourceHash)) {
        throw 'The installed Desktop engine could not be read.'
    }
    $sourceVersion = Get-AiCliCodexCliVersion -Path $source
    $staged = $null
    if ($null -eq $sourceVersion) {
        $staged = Get-AiCliStagedAppxEngine -SourceDirectory $sourceDirectory -SourceHash $sourceHash
        $sourceVersion = $staged.Version
    }

    try {
        $localAppData = Get-AiCliKnownFolder -Name LocalAppData
        $officialCache = Join-Path $localAppData 'OpenAI\Codex\bin'
        $current = Get-AiCliOfficialCodexCacheCandidate `
            -OfficialCache $officialCache `
            -MinimumVersion $sourceVersion
        if ($null -ne $current) {
            $resolution = if ($current.Hash -ceq $sourceHash) {
                'official-cache'
            }
            else {
                'official-cache-self-updated'
            }
            $result = New-AiCliDesktopEngineResult `
                -FileName $current.FileName `
                -Resolution $resolution `
                -ContentHash $current.Hash `
                -PackageFullName ([string]$package.PackageFullName)
            Remove-AiCliObsoleteUpstreamCache -Result $result -Package $package -SourceHash $sourceHash -PackageName $PackageName
            return $result
        }
    }
    catch {
        # A blocked or malformed official cache must not prevent a valid signed
        # package resource from being staged in the AICLI-owned cache below.
    }

    if ($null -eq $staged) {
        $staged = Get-AiCliStagedAppxEngine -SourceDirectory $sourceDirectory -SourceHash $sourceHash
    }
    $result = New-AiCliDesktopEngineResult -FileName $staged.FileName -Resolution 'aicli-upstream-cache' `
        -ContentHash $sourceHash -PackageFullName ([string]$package.PackageFullName)
    Remove-AiCliObsoleteUpstreamCache -Result $result -Package $package -SourceHash $sourceHash -PackageName $PackageName
    return $result
}
