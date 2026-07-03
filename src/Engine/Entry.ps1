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

    # Optional version pin: exact ("1.2.3") or NuGet range ("[1.0,2.0)").
    $version = $null
    if ($Raw.PSObject.Properties['Version'] -and $Raw.Version) { $version = ([string]$Raw.Version).Trim() }
    $pinnedExact = $false
    if ($version) {
        if ($version -match '^\d+(\.\d+){1,3}$') {
            $pinnedExact = $true
        } elseif ($version -notmatch '^[\[\(][0-9\.\,\s\*\-A-Za-z]*[\]\)]$') {
            $issues.Add("Invalid Version '$version' (ignoring pin)")
            $version = $null
        }
    }

    [pscustomobject]@{
        Name              = $name
        FriendlyName      = if ($Raw.FriendlyName) { [string]$Raw.FriendlyName } else { $name }
        Description       = [string]$Raw.Description
        Install           = $install
        Mode              = $mode
        Version           = $version
        PinnedExact       = $pinnedExact
        Source            = $Source
        Writable          = $Writable
        Issues            = $issues.ToArray()
        Installed         = $false
        InstalledVersion  = $null
        InstalledVersions = @()      # every installed version (duplicate-cleanup feature)
        InstallScope      = $null    # CurrentUser | AllUsers | mixed | $null (unknown)
        Loaded            = $false
        LoadedVersion     = $null
        LatestVersion     = $null
        UpdateAvailable   = $false
        ImportMs          = $null    # measured import duration (startup / UI load)
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
