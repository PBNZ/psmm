# Gallery.ps1 — read-only PowerShell Gallery search (#38) and update checks.

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
            Description = "$($_.Description)"
            Author      = "$($_.Author)"
        }
    })
}

# Latest gallery version for one module name ($null when not found).
function Get-PSMMGalleryLatest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    try {
        if (Get-Command Find-PSResource -ErrorAction SilentlyContinue) {
            $hits = Find-PSResource -Name $Name -ErrorAction Stop
            return ($hits | Sort-Object { [version]("$($_.Version)" -replace '-.*$', '') } -Descending | Select-Object -First 1).Version
        }
        return (Find-Module -Name $Name -ErrorAction Stop).Version
    } catch { return $null }
}

# Opt-in update check for a set of entries: marks UpdateAvailable/LatestVersion.
# Network-bound - never runs automatically. Respects exact pins (a pinned
# module reports pinned rather than update-available).
function Update-PSMMLatestVersion {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $Entries)   # empty set = normal (zero configs)
    $found = 0
    foreach ($e in @($Entries | Where-Object Installed)) {
        $latest = Get-PSMMGalleryLatest -Name $e.Name
        if (-not $latest) { continue }
        $e.LatestVersion = $latest
        $e.UpdateAvailable = $false
        if ($e.PinnedExact) { continue }   # pinned: never nag
        if ($e.InstalledVersion) {
            $lv = "$latest" -replace '-.*$', ''
            try { $e.UpdateAvailable = ([version]$lv -gt [version]"$($e.InstalledVersion)") } catch { }
        }
        if ($e.UpdateAvailable) { $found++ }
    }
    $found
}
