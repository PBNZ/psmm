# State.ps1 — refresh entry state from the live session and the disk.

# --- psmm's own modules vs the user's session (gh#16) ---------------------
#
# psmm manages the modules YOU asked for. The ones it imports to render that
# view are infrastructure and must not be reported as if you had asked for
# them: they inflate the "N loaded" count, they turn up in the unmanaged scan
# as if they were yours to adopt, and - worst - the files > apply sweep would
# happily Remove-Module psmm and its own UI engine mid-session.
#
# Two related but DIFFERENT sets, and conflating them is the trap:
#
#   own modules      psmm + its UI dependency. Marked as infrastructure in
#                    the UI, never unloaded by psmm, never counted as yours.
#   private imports  the module OBJECTS psmm imported into its own session
#                    state. Subtracted from the loaded view, because your
#                    prompt cannot see them.
#
# The second set is tracked by INSTANCE, not by name, and that distinction is
# load-bearing: if you import the same module globally yourself, `Get-Module`
# inside psmm returns YOUR instance (verified), so a by-name exclusion would
# hide a module you really do have loaded.

function Get-PSMMUIDependencyName { 'PwshSpectreConsole' }

function Get-PSMMOwnModuleName {
    [CmdletBinding()] param()
    $self = ''
    try { $self = "$($ExecutionContext.SessionState.Module.Name)" } catch { }
    if (-not $self) { $self = 'psmm' }
    @($self, (Get-PSMMUIDependencyName))
}

function Test-PSMMOwnModule {
    [CmdletBinding()]
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    foreach ($n in (Get-PSMMOwnModuleName)) {
        if ([string]::Equals($n, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# Record a module psmm imported into its OWN session state.
function Register-PSMMPrivateImport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Module)
    if (-not $script:PSMM_PrivateImports) { $script:PSMM_PrivateImports = [System.Collections.Generic.List[object]]::new() }
    if (-not (Test-PSMMPrivateImport -Module $Module)) { $script:PSMM_PrivateImports.Add($Module) }
}

function Get-PSMMPrivateImport {
    [CmdletBinding()] param()
    if ($script:PSMM_PrivateImports) { @($script:PSMM_PrivateImports) } else { @() }
}

# Is THIS module object one psmm imported for itself? Reference equality, not
# name equality - see the note above.
function Test-PSMMPrivateImport {
    [CmdletBinding()]
    param([AllowNull()] $Module)
    if (-not $Module -or -not $script:PSMM_PrivateImports) { return $false }
    foreach ($m in $script:PSMM_PrivateImports) {
        if ([object]::ReferenceEquals($m, $Module)) { return $true }
    }
    $false
}

# Cheap: in-session loaded modules only (no disk scan).
# NB: $Entries params here allow null/empty - an empty entry set is a normal
# state (fresh machine, zero configs), and PowerShell returns empty arrays
# from functions as $null.
#
# Session-state caveat (gh#2): `Get-Module` run inside the psmm module returns
# the GLOBAL module table plus anything imported into psmm's own private state.
# Every import psmm performs ON THE USER'S BEHALF passes -Global (see
# Import-PSMMModuleTimed), so those two sets coincide - except for the modules
# psmm imports FOR ITSELF, which are subtracted here by instance (gh#16).
function Update-PSMMLoaded {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $Entries)
    if (-not $Entries) { return }
    $loaded = @{}
    Get-Module -ErrorAction SilentlyContinue | ForEach-Object {
        # psmm's own private copy is not in the user's session - reporting it
        # as loaded is the same lie gh#2 was about, just smaller
        if (Test-PSMMPrivateImport -Module $_) { return }
        $loaded[$_.Name] = $_
    }
    foreach ($e in $Entries) {
        $m = $loaded[$e.Name]
        $e.Loaded = $loaded.ContainsKey($e.Name)
        $e.LoadedVersion = if ($m) { $m.Version } else { $null }
        $e.LoadedPrerelease = Get-PSMMPrereleaseLabel -ModuleInfo $m
    }
}

# Availability, versions and scope from disk.
# With -Name: cheap, name-filtered refresh for just those modules.
# Without:    ONE full -ListAvailable scan (call sparingly: open + reload only).
function Update-PSMMAvailable {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()] $Entries,
        [string[]]$Name
    )
    if (-not $Entries) { return }
    $apply = {
        param($entry, $mods)   # $mods: Get-Module -ListAvailable results, one per version
        $sorted = @($mods | Sort-Object Version -Descending)
        $entry.Installed         = [bool]$sorted
        $entry.InstalledVersion  = if ($sorted) { $sorted[0].Version } else { $null }
        # the prerelease label rides along from the manifest we already have in
        # hand - no extra disk cost, and versions must never be shown without it
        $entry.InstalledPrerelease = if ($sorted) { Get-PSMMPrereleaseLabel -ModuleInfo $sorted[0] } else { '' }
        $entry.InstalledVersions = @($sorted | ForEach-Object {
            [pscustomobject]@{
                Version    = $_.Version
                Prerelease = (Get-PSMMPrereleaseLabel -ModuleInfo $_)
                Path       = $_.ModuleBase
                Scope      = Get-PSMMScopeForPath -Path $_.ModuleBase
                ModuleType = "$($_.ModuleType)"
                Manifest   = "$($_.Path)"
            }
        })
        $scopes = @($entry.InstalledVersions.Scope | Select-Object -Unique)
        $entry.InstallScope = if ($scopes.Count -gt 1) { 'mixed' } elseif ($scopes.Count -eq 1) { $scopes[0] } else { $null }
    }

    if ($Name) {
        foreach ($nm in $Name) {
            $mods = @(Get-Module -ListAvailable -Name $nm -ErrorAction SilentlyContinue)
            foreach ($e in @($Entries | Where-Object Name -eq $nm)) { & $apply $e $mods }
        }
        return
    }
    $avail = @{}
    Get-Module -ListAvailable -ErrorAction SilentlyContinue | Group-Object Name | ForEach-Object {
        $avail[$_.Name] = $_.Group
    }
    foreach ($e in $Entries) {
        & $apply $e @(if ($e.Name -and $avail.ContainsKey($e.Name)) { $avail[$e.Name] } else { @() })
    }
}

# Modules installed with MORE than one version on disk (cleanup feature):
# every version except the newest is a pruning candidate.
function Get-PSMMDuplicateVersion {
    [CmdletBinding()] param()
    Get-Module -ListAvailable -ErrorAction SilentlyContinue |
        Group-Object Name |
        Where-Object { @($_.Group.Version | Select-Object -Unique).Count -gt 1 } |
        ForEach-Object {
            $sorted = @($_.Group | Sort-Object Version -Descending)
            [pscustomobject]@{
                Name     = $_.Name
                Latest   = $sorted[0].Version
                Obsolete = @($sorted | Select-Object -Skip 1 | ForEach-Object {
                    [pscustomobject]@{
                        Version = $_.Version
                        Path    = $_.ModuleBase
                        Scope   = Get-PSMMScopeForPath -Path $_.ModuleBase
                    }
                })
            }
        }
}

# Installed modules NOT named in any config file (unmanaged-module feature).
# Returns one object per module name, newest version, with scope.
# psmm's own modules are excluded: offering the user psmm's UI engine as
# something to "adopt into a config" is noise, not a feature (gh#16).
function Get-PSMMUnmanagedModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ManagedNames)
    $managed = [System.Collections.Generic.HashSet[string]]::new(
        [string[]](@($ManagedNames) + @(Get-PSMMOwnModuleName)), [System.StringComparer]::OrdinalIgnoreCase)
    Get-Module -ListAvailable -ErrorAction SilentlyContinue |
        Group-Object Name |
        Where-Object { -not $managed.Contains($_.Name) } |
        ForEach-Object {
            $newest = @($_.Group | Sort-Object Version -Descending)[0]
            [pscustomobject]@{
                Name        = $_.Name
                Version     = $newest.Version
                Scope       = Get-PSMMScopeForPath -Path $newest.ModuleBase
                Description = $newest.Description
            }
        }
}
