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
    $staging = [IO.Path]::GetFullPath((Join-Path $cacheRoot ('.' + $SourceHash + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')))
    if (-not $staging.StartsWith($cacheRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Desktop engine staging path is outside its cache.'
    }
    try {
        New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null
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
            Move-Item -LiteralPath $staging -Destination $destination -ErrorAction Stop
            $staging = $null
        }
    }
    finally {
        if ($staging -and (Test-Path -LiteralPath $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
        }
    }
    if ((Get-AiCliDesktopEngineHash -Path $cachedEngine) -ne $SourceHash) {
        throw 'The staged Desktop engine did not retain the package bytes.'
    }
    return [pscustomobject]@{ FileName = $cachedEngine; Version = $version; Hash = $SourceHash }
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
            return New-AiCliDesktopEngineResult `
                -FileName $current.FileName `
                -Resolution $resolution `
                -ContentHash $current.Hash `
                -PackageFullName ([string]$package.PackageFullName)
        }
    }
    catch {
        # A blocked or malformed official cache must not prevent a valid signed
        # package resource from being staged in the AICLI-owned cache below.
    }

    if ($null -eq $staged) {
        $staged = Get-AiCliStagedAppxEngine -SourceDirectory $sourceDirectory -SourceHash $sourceHash
    }
    return New-AiCliDesktopEngineResult -FileName $staged.FileName -Resolution 'aicli-upstream-cache' `
        -ContentHash $sourceHash -PackageFullName ([string]$package.PackageFullName)
}
