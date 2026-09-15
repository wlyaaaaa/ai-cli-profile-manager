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

function Resolve-AiCliDesktopEngine {
    <#
    .SYNOPSIS
      Resolves a Desktop Codex executable that matches the registered AppX package.

    .DESCRIPTION
      The AppX resource hash, rather than a versioned cache directory or timestamp,
      identifies the active Desktop engine. Existing Desktop cache copies are reused
      only when their codex.exe hash matches the registered package. A missing cache
      is populated under AICLI-owned LocalAppData so Desktop updates remain usable
      when CODEX_CLI_PATH bypasses the official cache-copy path.
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
    catch { return Get-AiCliDesktopEngineFallback }

    if ($packages.Count -eq 0) { return Get-AiCliDesktopEngineFallback }
    $package = $packages[0]
    $sourceDirectory = Join-Path ([string]$package.InstallLocation) 'app\resources'
    $source = Join-Path $sourceDirectory 'codex.exe'
    $sourceHash = Get-AiCliDesktopEngineHash -Path $source
    if ([string]::IsNullOrWhiteSpace($sourceHash)) { return Get-AiCliDesktopEngineFallback }

    try {
        $localAppData = Get-AiCliKnownFolder -Name LocalAppData
        $officialCache = Join-Path $localAppData 'OpenAI\Codex\bin'
        if (Test-Path -LiteralPath $officialCache -PathType Container) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $officialCache -Directory -ErrorAction Stop)) {
                $candidate = Join-Path $directory.FullName 'codex.exe'
                if ((Get-AiCliDesktopEngineHash -Path $candidate) -eq $sourceHash) {
                    return New-AiCliDesktopEngineResult -FileName $candidate -Resolution 'official-cache' `
                        -ContentHash $sourceHash -PackageFullName ([string]$package.PackageFullName)
                }
            }
        }
    }
    catch {
        # A blocked or malformed official cache must not prevent a valid package
        # resource from being staged in the AICLI-owned cache below.
    }

    try {
        $paths = Get-AiCliAppPaths
        $cacheRoot = Join-Path ([string]$paths.LocalRoot) 'desktop\upstream'
        $destination = Join-Path $cacheRoot $sourceHash
        $cachedEngine = Join-Path $destination 'codex.exe'
        if ((Get-AiCliDesktopEngineHash -Path $cachedEngine) -eq $sourceHash) {
            return New-AiCliDesktopEngineResult -FileName $cachedEngine -Resolution 'aicli-upstream-cache' `
                -ContentHash $sourceHash -PackageFullName ([string]$package.PackageFullName)
        }

        $companions = @(
            Get-ChildItem -LiteralPath $sourceDirectory -File -Filter 'codex*.exe' -ErrorAction Stop |
                Sort-Object Name
        )
        if ($companions.Count -eq 0 -or -not ($companions.Name -contains 'codex.exe')) {
            return Get-AiCliDesktopEngineFallback
        }

        New-Item -ItemType Directory -Path $cacheRoot -Force -ErrorAction Stop | Out-Null
        $staging = Join-Path $cacheRoot ('.' + $sourceHash + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null
            foreach ($companion in $companions) {
                $target = Join-Path $staging $companion.Name
                Copy-Item -LiteralPath $companion.FullName -Destination $target -ErrorAction Stop
                if ((Get-AiCliDesktopEngineHash -Path $target) -ne (Get-AiCliDesktopEngineHash -Path $companion.FullName)) {
                    throw "Desktop engine companion hash mismatch: $($companion.Name)"
                }
            }
            if ((Get-AiCliDesktopEngineHash -Path (Join-Path $staging 'codex.exe')) -ne $sourceHash) {
                throw 'Desktop engine staging hash mismatch.'
            }

            if (-not (Test-Path -LiteralPath $destination)) {
                Move-Item -LiteralPath $staging -Destination $destination -ErrorAction Stop
                $staging = $null
            }
        }
        finally {
            if ($staging -and (Test-Path -LiteralPath $staging)) {
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        if ((Get-AiCliDesktopEngineHash -Path $cachedEngine) -eq $sourceHash) {
            return New-AiCliDesktopEngineResult -FileName $cachedEngine -Resolution 'aicli-upstream-cache' `
                -ContentHash $sourceHash -PackageFullName ([string]$package.PackageFullName)
        }
    }
    catch {
        # Fall through to an existing resolver. Do not execute an AppX resource
        # directly when its cache-copy path is unavailable.
    }

    return Get-AiCliDesktopEngineFallback
}
