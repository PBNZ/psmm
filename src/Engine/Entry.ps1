# Entry.ps1 — raw JSON → validated module entry, and file-level parsing.

# Normalise one raw module entry into the rich object the rest of psmm uses.
# Invalid Install/Mode values degrade to the defaults with an issue recorded —
# a broken entry must never take the whole config file down.
function Resolve-PSMMEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Raw,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][bool]$Writable
    )

    $validInstall = 'CheckOnly', 'IfMissing', 'Latest'
    $validMode    = 'Load', 'InstallOnly', 'Ignore'
    $issues       = [System.Collections.Generic.List[string]]::new()

    $name = [string]$Raw.Name
    if ([string]::IsNullOrWhiteSpace($name)) { $issues.Add('Missing Name') }

    $install = if ($Raw.PSObject.Properties['Install'] -and $Raw.Install) { [string]$Raw.Install } else { 'IfMissing' }
    if ($install -notin $validInstall) { $issues.Add("Invalid Install '$install' (using IfMissing)"); $install = 'IfMissing' }

    $mode = if ($Raw.PSObject.Properties['Mode'] -and $Raw.Mode) { [string]$Raw.Mode } else { 'Load' }
    if ($mode -notin $validMode) { $issues.Add("Invalid Mode '$mode' (using Load)"); $mode = 'Load' }

    # Optional version pin: exact ("1.2.3"), exact prerelease ("1.2.3-beta4")
    # or NuGet range ("[1.0,2.0)").
    #
    # The prerelease label is part of the pin (gh#6): 0.1.0-beta8 and 0.1.0 are
    # different releases that share one [version]. It is kept SEPARATE from the
    # base version because Import-Module -RequiredVersion is typed [version]
    # and throws on a label - see Import-PSMMModuleTimed.
    $version = $null
    if ($Raw.PSObject.Properties['Version'] -and $Raw.Version) { $version = ([string]$Raw.Version).Trim() }
    $pinnedExact = $false
    $pinnedBase = $null
    $pinnedLabel = ''
    if ($version) {
        if ($version -match '^(?<base>\d+(\.\d+){1,3})(-(?<label>[A-Za-z0-9][A-Za-z0-9.-]*))?$') {
            $pinnedExact = $true
            $pinnedBase = $Matches['base']
            $pinnedLabel = "$($Matches['label'])"
        } elseif ($version -notmatch '^[\[\(][0-9\.\,\s\*\-A-Za-z]*[\]\)]$') {
            $issues.Add("Invalid Version '$version' (ignoring pin)")
            $version = $null
        }
    }

    # Optional prerelease opt-in (gh#6): "Prerelease": true lets install/update
    # and the pin picker consider prerelease versions from the gallery.
    $allowPre = $false
    if ($Raw.PSObject.Properties['Prerelease'] -and $null -ne $Raw.Prerelease) {
        try { $allowPre = [bool]$Raw.Prerelease }
        catch { $issues.Add("Invalid Prerelease '$($Raw.Prerelease)' (using false)") }
    }

    [pscustomobject]@{
        Name               = $name
        FriendlyName       = if ($Raw.FriendlyName) { [string]$Raw.FriendlyName } else { $name }
        Description        = [string]$Raw.Description
        Install            = $install
        Mode               = $mode
        Version            = $version
        PinnedExact        = $pinnedExact
        PinnedBaseVersion  = $pinnedBase    # the pin without its prerelease label
        PinnedPrerelease   = $pinnedLabel   # '' unless the pin names a prerelease
        AllowPrerelease    = $allowPre      # config "Prerelease": true
        Source             = $Source
        Writable           = $Writable
        Issues             = $issues.ToArray()
        Installed          = $false
        InstalledVersion   = $null
        InstalledPrerelease = ''     # label of the newest installed copy ('' = stable)
        InstalledVersions  = @()     # every installed version (duplicate-cleanup feature)
        InstallScope       = $null   # CurrentUser | AllUsers | mixed | $null (unknown)
        Loaded             = $false
        LoadedVersion      = $null
        LoadedPrerelease   = ''
        LatestVersion      = $null
        LatestPrerelease   = ''
        UpdateAvailable    = $false
        ImportMs           = $null   # measured import duration (startup / UI load)
    }
}

# Parse one config file's JSON into its file-level shape. Throws on bad JSON —
# the caller records the warning and skips the file.
function ConvertFrom-PSMMJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)
    $obj = $Json | ConvertFrom-Json -ErrorAction Stop
    [pscustomobject]@{
        Legend     = $obj._legend
        HasEnabled = [bool]$obj.PSObject.Properties['Enabled']
        Enabled    = if ($obj.PSObject.Properties['Enabled'] -and $null -ne $obj.Enabled) { [bool]$obj.Enabled } else { $true }
        Includes   = if ($obj.PSObject.Properties['Includes']) { @($obj.Includes | Where-Object { $_ }) } else { @() }
        Modules    = @($obj.Modules)
    }
}
