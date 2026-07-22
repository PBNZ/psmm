# Gallery.ps1 — read-only PowerShell Gallery search (#38), version lookups and
# update checks.

# Search the gallery by name pattern. Wildcards are added around the query
# unless the caller already supplied any. Returns lightweight result objects.
function Find-PSMMGalleryModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$First = 40
    )
    $pattern = if ($Query -match '[\*\?]') { $Query } else { "*$Query*" }
    $results = if (Get-Command Find-PSResource -ErrorAction SilentlyContinue) {
        Find-PSResource -Name $pattern -Type Module -ErrorAction SilentlyContinue
    } else {
        Find-Module -Name $pattern -ErrorAction SilentlyContinue
    }
    @($results | Select-Object -First $First | ForEach-Object {
        [pscustomobject]@{
            Name        = $_.Name
            Version     = "$($_.Version)"
            Prerelease  = "$($_.Prerelease)".TrimStart('-')
            Description = "$($_.Description)"
            Author      = "$($_.Author)"
        }
    })
}

# --- version comparison (SemVer-ish, gh#6) --------------------------------
# A gallery version is a [version] base plus an optional prerelease label. The
# base alone cannot order 0.1.0-beta2 / 0.1.0-beta8 / 0.1.0 - they all parse to
# [version]0.1.0 - so the label has to decide. psmm already owns exactly that
# comparison (Compare-PSMMVersion in SelfUpdate.ps1, verified against
# PSResourceGet's behaviour); this is the (version, label) pair adapter for it,
# tolerant of the missing/unparseable versions entry state can hold.
function Compare-PSMMEntryVersion {
    [CmdletBinding()]
    param($VersionA, [string]$PrereleaseA, $VersionB, [string]$PrereleaseB)
    $a = Get-PSMMVersionDisplay -Version $VersionA -Prerelease $PrereleaseA
    $b = Get-PSMMVersionDisplay -Version $VersionB -Prerelease $PrereleaseB
    if (-not $a -and -not $b) { return 0 }
    if (-not $a) { return -1 }
    if (-not $b) { return 1 }
    try { Compare-PSMMVersion -A $a -B $b } catch { 0 }
}

# Split "1.2.3-beta4" into its base version and label (gallery objects usually
# carry them separately, but not every provider does).
function Split-PSMMVersionString {
    [CmdletBinding()]
    param([string]$Text)
    $t = "$Text".Trim()
    $pre = ''
    if ($t -match '^([^-]+)-(.+)$') { $t = $Matches[1]; $pre = $Matches[2] }
    [pscustomobject]@{ Version = $t; Prerelease = $pre }
}

# Normalise one gallery result into @{ Version; Prerelease }.
function ConvertTo-PSMMGalleryVersion {
    [CmdletBinding()]
    param($Result)
    $pre = ''
    try { $pre = "$($Result.Prerelease)".TrimStart('-') } catch { }
    $split = Split-PSMMVersionString -Text "$($Result.Version)"
    if (-not $pre) { $pre = $split.Prerelease }
    [pscustomobject]@{ Version = $split.Version; Prerelease = $pre }
}

# Latest gallery version for one module name ($null when not found).
# Returns @{ Version; Prerelease }; -Prerelease includes prerelease builds.
function Get-PSMMGalleryLatest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Prerelease
    )
    try {
        if (Get-Command Find-PSResource -ErrorAction SilentlyContinue) {
            $hits = @(Find-PSResource -Name $Name -Prerelease:$Prerelease -ErrorAction Stop)
        } else {
            $hits = @(Find-Module -Name $Name -AllowPrerelease:$Prerelease -ErrorAction Stop)
        }
        $best = $null
        foreach ($h in $hits) {
            $v = ConvertTo-PSMMGalleryVersion -Result $h
            if (-not $Prerelease -and $v.Prerelease) { continue }
            if (-not $best -or (Compare-PSMMEntryVersion -VersionA $v.Version -PrereleaseA $v.Prerelease `
                        -VersionB $best.Version -PrereleaseB $best.Prerelease) -gt 0) {
                $best = $v
            }
        }
        return $best
    } catch { return $null }
}

# Every version of one module that can be pinned: what is on disk (instant,
# offline) and what the gallery offers (network). Newest first, deduplicated.
# Feeds the pin picker (gh#5).
function Get-PSMMAvailableVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Prerelease,
        [switch]$SkipGallery
    )
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($m in @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)) {
        $all.Add([pscustomobject]@{
                Version    = "$($m.Version)"
                Prerelease = (Get-PSMMPrereleaseLabel -ModuleInfo $m)
                OnDisk     = $true
                InGallery  = $false
            })
    }
    if (-not $SkipGallery) {
        try {
            $hits = if (Get-Command Find-PSResource -ErrorAction SilentlyContinue) {
                @(Find-PSResource -Name $Name -Version '*' -Prerelease:$Prerelease -ErrorAction Stop)
            } else {
                @(Find-Module -Name $Name -AllVersions -AllowPrerelease:$Prerelease -ErrorAction Stop)
            }
            foreach ($h in $hits) {
                if ("$($h.Name)" -ne $Name) { continue }
                $v = ConvertTo-PSMMGalleryVersion -Result $h
                if (-not $Prerelease -and $v.Prerelease) { continue }
                $all.Add([pscustomobject]@{
                        Version = $v.Version; Prerelease = $v.Prerelease
                        OnDisk = $false; InGallery = $true
                    })
            }
        } catch { }   # offline / not published: disk versions are still useful
    }
    # merge duplicates (a version can be both on disk and in the gallery)
    $merged = [ordered]@{}
    foreach ($v in $all) {
        $key = (Get-PSMMVersionDisplay -Version $v.Version -Prerelease $v.Prerelease)
        if ($merged.Contains($key)) {
            $merged[$key].OnDisk = $merged[$key].OnDisk -or $v.OnDisk
            $merged[$key].InGallery = $merged[$key].InGallery -or $v.InGallery
        } else {
            $merged[$key] = [pscustomobject]@{
                Display = $key; Version = $v.Version; Prerelease = $v.Prerelease
                OnDisk = $v.OnDisk; InGallery = $v.InGallery
            }
        }
    }
    # newest first - Sort-Object has no custom-comparer parameter, and the
    # ordering here is semantic (base version + prerelease label), so sort the
    # backing list with the comparison we already own
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($v in $merged.Values) { $list.Add($v) }
    $list.Sort([System.Comparison[object]] {
            param($a, $b)
            -1 * (Compare-PSMMEntryVersion -VersionA $a.Version -PrereleaseA $a.Prerelease `
                    -VersionB $b.Version -PrereleaseB $b.Prerelease)
        })
    @($list)
}

# Opt-in update check for a set of entries: marks UpdateAvailable/LatestVersion.
# Network-bound - never runs automatically. Respects exact pins (a pinned
# module reports pinned rather than update-available) and each entry's
# prerelease policy (gh#6).
function Update-PSMMLatestVersion {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $Entries)   # empty set = normal (zero configs)
    $found = 0
    foreach ($e in @($Entries | Where-Object Installed)) {
        $latest = Get-PSMMGalleryLatest -Name $e.Name -Prerelease:([bool]$e.AllowPrerelease)
        if (-not $latest) { continue }
        $e.LatestVersion = $latest.Version
        $e.LatestPrerelease = $latest.Prerelease
        $e.UpdateAvailable = $false
        if ($e.PinnedExact) { continue }   # pinned: never nag
        if ($e.InstalledVersion) {
            $e.UpdateAvailable = (Compare-PSMMEntryVersion -VersionA $latest.Version -PrereleaseA $latest.Prerelease `
                    -VersionB "$($e.InstalledVersion)" -PrereleaseB "$($e.InstalledPrerelease)") -gt 0
        }
        if ($e.UpdateAvailable) { $found++ }
    }
    $found
}
