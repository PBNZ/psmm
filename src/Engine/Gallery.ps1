# Gallery.ps1 — read-only PowerShell Gallery search (#38), version lookups and
# update checks.

# --- search (gh#17) --------------------------------------------------------
#
# There are two different questions you can ask the gallery, and psmm needs
# both:
#
#   a NAME PATTERN - Find-PSResource -Name 'Az.*'. Provider-side, honours
#     every registered repository, and matches the module NAME only.
#   FULL TEXT      - the OData Search() endpoint the gallery WEBSITE calls.
#     Matches name + description + tags, ranked the way the site ranks it,
#     and limited server-side.
#
# psmm used to send everything down the first path, wrapping a bare term as
# "*term*". Measured against the live gallery on 2026-07-23 (PSResourceGet
# 1.2.0), that is wrong in four separate ways:
#
#   'excel' as *excel*   29 hits in 1.3 s, Search-ExcelFileWithUI first and
#                        ImportExcel (22.9M downloads) sixth. The website
#                        puts ImportExcel first.
#   'excel' full text    40 hits in 0.46 s, ImportExcel first - and it also
#                        finds GetSQL and PSWriteOffice, Excel modules whose
#                        NAME contains no "excel" at all.
#   'sharepoint'         the name glob misses PnP.PowerShell entirely, same
#                        reason: the word is in the description, not the name.
#   'a' as *a*           8828 records over the wire in 216 SECONDS, then cut
#                        to an arbitrary 40 (xExchange, xFailOverCluster...).
#                        -First cannot be pushed down into a glob; it IS the
#                        endpoint's $top.
#
# A leading wildcard has additionally been seen to return 0 results AND 0
# errors (the original gh#17 report; not reproducible on demand) - a silent
# failure no -ErrorAction can catch. So: a bare term goes full text, and an
# explicit wildcard stays on the provider, which is the only thing that can
# honour it.

# The public gallery's full-text search URI - the query the website runs.
function Get-PSMMGallerySearchUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Term,
        [int]$First = 40,
        [switch]$Prerelease
    )
    # OData string literal: double the single quotes, THEN percent-encode the
    # whole thing - a bare & or # in the term would otherwise end the query
    # string and take the filter with it.
    $literal = [uri]::EscapeDataString(("$Term" -replace "'", "''"))
    $top = [Math]::Max(1, [Math]::Min(200, $First))
    # No $orderby on purpose: DownloadCount desc, DownloadCount asc and no
    # $orderby at all return the SAME order (verified), i.e. the endpoint
    # ignores it - while an unknown field is a 400. The default order is the
    # site's relevance ranking, which is exactly what we want.
    'https://www.powershellgallery.com/api/v2/Search()' +
    "?searchTerm='$literal'&`$filter=IsLatestVersion&`$top=$top" +
    '&semVerLevel=2.0.0' +
    "&includePrerelease=$(if ($Prerelease) { 'true' } else { 'false' })"
}

# One <m:properties> child as text. Two shapes are NOT [string] and both
# stringify to "System.Xml.XmlElement" if read naively: a null field carries
# m:null="true", and a typed field (Edm.Int32 and friends) keeps its value
# in #text.
function Get-PSMMODataText {
    [CmdletBinding()]
    param($Node)
    if ($null -eq $Node) { return '' }
    if ($Node -is [string]) { return $Node }
    try { if ("$($Node.null)" -eq 'true') { return '' } } catch { }
    try {
        $t = $Node.'#text'
        if ($null -ne $t) { return "$t" }
    } catch { }
    try { return "$($Node.InnerText)" } catch { return '' }
}

# One <entry> from the OData feed -> the same lightweight result shape the
# provider path produces.
function ConvertFrom-PSMMGalleryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)
    $p = $Entry.properties
    $split = Split-PSMMVersionString -Text (Get-PSMMODataText $p.Version)
    $downloads = [long]0
    [void][long]::TryParse((Get-PSMMODataText $p.DownloadCount), [ref]$downloads)
    $desc = Get-PSMMODataText $p.Description
    if (-not $desc) { $desc = Get-PSMMODataText $p.Summary }
    [pscustomobject]@{
        Name        = (Get-PSMMODataText $p.Id)
        Version     = $split.Version
        Prerelease  = $split.Prerelease
        Description = $desc
        Author      = (Get-PSMMODataText $p.Authors)
        Downloads   = $downloads
        ProjectUri  = (Get-PSMMODataText $p.ProjectUrl)
        Repository  = 'PSGallery'
    }
}

# Full-text search against the public gallery. Throws on a transport or HTTP
# failure so the caller can fall back AND say why - the whole point of gh#17
# is that "no results" must not mean "the request failed".
function Find-PSMMGalleryFullText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Term,
        [int]$First = 40,
        [switch]$Prerelease
    )
    $uri = Get-PSMMGallerySearchUri -Term $Term -First $First -Prerelease:$Prerelease
    # -TimeoutSec because Invoke-RestMethod waits forever by default and this
    # call blocks the UI thread. PS7 already routes through the system proxy.
    $raw = Invoke-RestMethod -Uri $uri -TimeoutSec 25 -ErrorAction Stop
    # zero hits come back as $null, and @($null) is a ONE-element array
    @(@($raw) | Where-Object { $null -ne $_ } |
        ForEach-Object { ConvertFrom-PSMMGalleryEntry -Entry $_ } |
        Where-Object { $_.Name })
}

# Provider-side NAME search: the only path that can honour a wildcard, and
# the only path that can see a private repository.
function Find-PSMMGalleryByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [int]$First = 40,
        [string[]]$Repository
    )
    $results = if (Get-Command Find-PSResource -ErrorAction SilentlyContinue) {
        if ($Repository) { Find-PSResource -Name $Pattern -Type Module -Repository $Repository -ErrorAction SilentlyContinue }
        else { Find-PSResource -Name $Pattern -Type Module -ErrorAction SilentlyContinue }
    } else {
        if ($Repository) { Find-Module -Name $Pattern -Repository $Repository -ErrorAction SilentlyContinue }
        else { Find-Module -Name $Pattern -ErrorAction SilentlyContinue }
    }
    @($results | Select-Object -First $First | ForEach-Object {
        [pscustomobject]@{
            Name        = $_.Name
            Version     = "$($_.Version)"
            Prerelease  = "$($_.Prerelease)".TrimStart('-')
            Description = "$($_.Description)"
            Author      = "$($_.Author)"
            Downloads   = [long]0          # the provider does not report it
            ProjectUri  = "$($_.ProjectUri)"
            Repository  = "$($_.Repository)"
        }
    })
}

# Registered repositories that are NOT the public gallery. The full-text
# endpoint only knows about powershellgallery.com, so anything else has to be
# asked through the provider or its modules become unfindable - which would
# be a fresh instance of the bug this file is fixing.
function Get-PSMMExtraRepository {
    [CmdletBinding()] param()
    $names = @()
    try {
        if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {
            $names = @(Get-PSResourceRepository -ErrorAction Stop |
                Where-Object { "$($_.Uri)" -notmatch 'powershellgallery\.com' } |
                ForEach-Object { "$($_.Name)" })
        } elseif (Get-Command Get-PSRepository -ErrorAction SilentlyContinue) {
            $names = @(Get-PSRepository -ErrorAction Stop |
                Where-Object { "$($_.SourceLocation)" -notmatch 'powershellgallery\.com' } |
                ForEach-Object { "$($_.Name)" })
        }
    } catch { }   # no provider, or it refuses to enumerate: gallery only
    @($names | Where-Object { $_ })
}

# Concatenate two result sets, first one wins on a duplicate name.
function Merge-PSMMGalleryResult {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]$Primary,
        [AllowNull()][AllowEmptyCollection()]$Secondary,
        [int]$Limit = 40
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @(@($Primary) + @($Secondary))) {
        if ($null -eq $r -or -not "$($r.Name)") { continue }
        if (-not $seen.Add("$($r.Name)")) { continue }
        $out.Add($r)
        if ($out.Count -ge $Limit) { break }
    }
    @($out)
}

# One exception boiled down to a single short line for a status message.
function Get-PSMMErrorLine {
    [CmdletBinding()]
    param($ErrorRecord)
    $m = ("$($ErrorRecord.Exception.Message)" -replace '\s+', ' ').Trim()
    if ($m.Length -gt 90) { $m = $m.Substring(0, 87) + '...' }
    $m
}

# THE search entry point. Returns an envelope rather than bare results,
# because an empty screen has to be able to say WHY it is empty: "the gallery
# has nothing" and "the search service did not answer" look identical
# otherwise, and telling them apart is half of gh#17.
#   Mode: fulltext | name | fulltext-fallback | name-fallback | none
#   Note: plain text (the UI styles it), '' when there is nothing to explain
function Search-PSMMGallery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [int]$First = 40
    )
    $q = "$Query".Trim()
    $out = [pscustomobject]@{ Query = $q; Mode = 'none'; Results = @(); Note = '' }
    if (-not $q) { $out.Note = 'Type a name or a word to search for.'; return $out }

    if ($q -match '[\*\?]') {
        # an explicit pattern: hand it to the provider verbatim
        $out.Mode = 'name'
        $out.Results = @(Find-PSMMGalleryByName -Pattern $q -First $First)
        if ($out.Results.Count) { return $out }
        # nothing matched. A leading wildcard is the shape that has been seen
        # to fail silently, so retry the words in it as a full-text search
        # rather than leaving the user with a bare "No results."
        $bare = ((($q -replace '[\*\?]', ' ') -replace '\s+', ' ')).Trim()
        if ($bare) {
            try {
                $hits = @(Find-PSMMGalleryFullText -Term $bare -First $First)
                if ($hits.Count) {
                    $out.Mode = 'fulltext-fallback'
                    $out.Results = $hits
                    $out.Note = "No module NAME matches '$q' - showing gallery matches for '$bare' instead."
                    return $out
                }
            } catch { }   # the pattern found nothing either way; say that
        }
        $out.Note = "No module name matches '$q'."
        return $out
    }

    # a bare term: search the way the website searches
    $out.Mode = 'fulltext'
    try {
        $out.Results = @(Find-PSMMGalleryFullText -Term $q -First $First)
    } catch {
        # the search service did not answer. A NAME PREFIX search still works
        # and - unlike the old "*term*" - never builds a leading wildcard.
        $out.Mode = 'name-fallback'
        $out.Note = "The gallery search service did not answer ($(Get-PSMMErrorLine $_)). Showing modules whose NAME starts with '$q'."
        $out.Results = @(Find-PSMMGalleryByName -Pattern "$q*" -First $First)
    }

    # a module that has only ever published prereleases (psmm is one) is
    # invisible to the default query - searching 'psmm' inside psmm found
    # nothing at all. Say so rather than showing an empty screen.
    if (-not $out.Results.Count -and $out.Mode -eq 'fulltext') {
        try {
            $pre = @(Find-PSMMGalleryFullText -Term $q -First $First -Prerelease)
            if ($pre.Count) {
                $out.Results = $pre
                $out.Note = "Only prerelease versions match '$q'."
            }
        } catch { }
    }

    # the endpoint only knows the public gallery, so ask the provider for
    # anything else that is registered. Bounded, so a big internal feed
    # cannot bury the gallery's relevance ranking.
    $extraRepos = @(Get-PSMMExtraRepository)
    if ($extraRepos.Count) {
        $extra = @(Find-PSMMGalleryByName -Pattern "*$q*" -First ([Math]::Min(10, $First)) -Repository $extraRepos)
        if ($extra.Count) { $out.Results = @(Merge-PSMMGalleryResult -Primary $extra -Secondary $out.Results -Limit $First) }
    }

    if (-not $out.Results.Count -and -not $out.Note) { $out.Note = "The gallery has no module matching '$q'." }
    $out
}

# Download count as a short cell: 22940663 -> 22.9M. 0 means "not reported"
# (the provider path never reports one), which renders blank rather than '0'.
function Format-PSMMDownloadCount {
    [CmdletBinding()]
    param($Count)
    $n = [long]0
    if (-not [long]::TryParse("$Count", [ref]$n) -or $n -le 0) { return '' }
    # the gallery's busiest modules are past a billion (and its DownloadCount
    # is an Edm.Int32, so the very top ones saturate at 2147483647)
    if ($n -ge 1000000000) { return ('{0:0.#}B' -f ($n / 1000000000.0)) }
    if ($n -ge 1000000) { return ('{0:0.#}M' -f ($n / 1000000.0)) }
    if ($n -ge 1000) { return ('{0:0.#}k' -f ($n / 1000.0)) }
    "$n"
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
