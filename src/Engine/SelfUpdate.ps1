# SelfUpdate.ps1 — psmm's own version, update check and update guidance.
#
# Update semantics VERIFIED empirically against PSResourceGet 1.2.0 with a
# local test repository (2026-07-14):
#   - a prerelease-label-only bump (0.1.0-beta2 -> 0.1.0-beta3) is invisible
#     to Update-PSResource (even with -Prerelease and an explicit -Version)
#     and to plain Install-PSResource; ONLY
#     `Install-PSResource <name> -Prerelease -Reinstall` installs it (the two
#     labels share the module's <base version> folder, so it replaces
#     in place)
#   - a base-version bump (0.1.0-x -> 0.2.0-x) updates normally via
#     `Update-PSResource <name> -Prerelease` (side-by-side folders)
#   - Remove-Module first is NOT needed: replacement succeeds while the
#     module is imported; the session keeps running the old copy until
#     `Import-Module <name> -Force` or a new session
#
# The check itself is a fire-and-forget ThreadJob writing a small JSON cache
# next to the main config, throttled to once per day: profile load never
# pays network cost - it only reads the cache from a previous session.

# The RUNNING psmm version as a full semver string, e.g. '0.1.0-beta3'.
function Get-PSMMVersionString {
    [CmdletBinding()] param()
    $m = $ExecutionContext.SessionState.Module
    if (-not $m) { return '' }
    $pre = $null
    try { $pre = $m.PrivateData.PSData.Prerelease } catch { }
    "$($m.Version)$(if ($pre) { "-$pre" })"
}

# The psmm version currently ON DISK in this module's install folder, e.g.
# '0.1.0-beta4'. May differ from Get-PSMMVersionString after an in-session
# `Install-PSResource psmm -Prerelease -Reinstall` (prerelease labels share
# the base-version folder, so the files are replaced in place while the
# session keeps running the old copy - see the header of this file).
# Empty string when the manifest cannot be read.
function Get-PSMMOnDiskVersionString {
    [CmdletBinding()] param()
    try {
        $d = Import-PowerShellDataFile (Join-Path $script:PSMMRoot 'psmm.psd1')
        $pre = $null
        try { $pre = $d.PrivateData.PSData.Prerelease } catch { }
        "$($d.ModuleVersion)$(if ($pre) { "-$pre" })"
    } catch { '' }
}

# NuGet-style semver comparison of two version strings (may carry prerelease
# labels). Returns -1 / 0 / 1 for $A <, ==, > $B. Rules: base [version]
# first; a stable version outranks any prerelease of the same base;
# prerelease labels compare per dot-separated segment, numerically when both
# segments are numeric, ordinal-case-insensitively otherwise.
function Compare-PSMMVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$A,
        [Parameter(Mandatory)][string]$B
    )
    $baseA, $preA = $A -split '-', 2
    $baseB, $preB = $B -split '-', 2
    $c = ([version]$baseA).CompareTo([version]$baseB)
    if ($c -ne 0) { return [Math]::Sign($c) }
    if (-not $preA -and -not $preB) { return 0 }
    if (-not $preA) { return 1 }    # stable > prerelease
    if (-not $preB) { return -1 }
    $segsA = $preA -split '\.'
    $segsB = $preB -split '\.'
    for ($i = 0; $i -lt [Math]::Max($segsA.Count, $segsB.Count); $i++) {
        if ($i -ge $segsA.Count) { return -1 }   # fewer segments = smaller
        if ($i -ge $segsB.Count) { return 1 }
        $nA = 0; $nB = 0
        $isNumA = [int]::TryParse($segsA[$i], [ref]$nA)
        $isNumB = [int]::TryParse($segsB[$i], [ref]$nB)
        $c = if ($isNumA -and $isNumB) { $nA.CompareTo($nB) }
             else { [string]::Compare($segsA[$i], $segsB[$i], [System.StringComparison]::OrdinalIgnoreCase) }
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    0
}

# Cache file for the daily background check (lives next to the main config,
# so the $PSMM_MainConfigPath override redirects it too - tests rely on it).
function Get-PSMMUpdateCachePath {
    [CmdletBinding()] param()
    Join-Path (Split-Path -Parent (Get-PSMMMainConfigPath)) 'psmm-update-check.json'
}

function Read-PSMMUpdateCache {
    [CmdletBinding()] param()
    $p = Get-PSMMUpdateCachePath
    if (-not (Test-Path -LiteralPath $p -ErrorAction Ignore)) { return $null }
    try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { $null }
}

# Kick the once-a-day gallery check as a fire-and-forget ThreadJob. Returns
# the job when one was started, $null when throttled or unavailable.
# Governed by the $PSMM_UpdateCheck knob (default $true).
function Start-PSMMSelfUpdateCheck {
    [CmdletBinding()]
    param([switch]$Force)
    if (-not (Get-PSMMSetting -Name 'PSMM_UpdateCheck' -Default $true)) { return $null }
    if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) { return $null }
    if (@(Get-PSMMTask | Where-Object { $_.Kind -eq 'selfupdate' -and -not $_.Done }).Count) { return $null }
    $cache = Read-PSMMUpdateCache
    if (-not $Force -and $cache -and $cache.CheckedAt) {
        try {
            # ConvertFrom-Json may have materialised CheckedAt as [datetime]
            $t = $cache.CheckedAt
            $checked = if ($t -is [datetime]) { $t.ToUniversalTime() }
                       else {
                           [datetime]::Parse("$t", [cultureinfo]::InvariantCulture,
                               ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal))
                       }
            if (([datetime]::UtcNow - $checked) -lt [timespan]::FromHours(24)) { return $null }
        } catch { }
    }
    $path = Get-PSMMUpdateCachePath
    # via the task registry: the TUI shows it on the tasks screen and reacts
    # to its completion (Receive-PSMMUITask refreshes the update notice)
    Start-PSMMTask -Label 'check: psmm update' -Kind 'selfupdate' -ArgumentList @($path) -ScriptBlock {
        param($cachePath)
        try {
            $stable = Find-PSResource -Name psmm -Repository PSGallery -ErrorAction SilentlyContinue
            $pre    = Find-PSResource -Name psmm -Repository PSGallery -Prerelease -ErrorAction SilentlyContinue
            $dir = Split-Path -Parent $cachePath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            ([pscustomobject]@{
                CheckedAt        = [datetime]::UtcNow.ToString('o')
                LatestStable     = $(if ($stable) { "$($stable.Version)$(if ($stable.Prerelease) { "-$($stable.Prerelease)" })" })
                LatestPrerelease = $(if ($pre) { "$($pre.Version)$(if ($pre.Prerelease) { "-$($pre.Prerelease)" })" })
            } | ConvertTo-Json) | Set-Content -LiteralPath $cachePath -Encoding utf8
        } catch { }   # best-effort: no network, no cache update
    }
}

# Is a newer psmm available, per the cached check? $null when up to date (or
# no cache yet). Prerelease users are compared against the newest prerelease,
# stable users only against the newest stable - and the returned Command is
# the VERIFIED one for that jump (see the header of this file).
function Test-PSMMUpdateAvailable {
    [CmdletBinding()] param()
    $current = Get-PSMMVersionString
    if (-not $current) { return $null }
    $cache = Read-PSMMUpdateCache
    if (-not $cache) { return $null }
    $onPrerelease = $current -match '-'
    $candidate = if ($onPrerelease) { $cache.LatestPrerelease } else { $cache.LatestStable }
    if (-not $candidate) { return $null }
    if ((Compare-PSMMVersion -A "$candidate" -B $current) -le 0) { return $null }
    $command = if ("$candidate" -match '-') { 'Install-PSResource psmm -Prerelease -Reinstall' }
               else { 'Update-PSResource psmm' }
    [pscustomobject]@{
        Current = $current
        Latest  = "$candidate"
        Command = $command
    }
}
