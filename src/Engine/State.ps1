# State.ps1 — refresh entry state from the live session and the disk.

# Cheap: in-session loaded modules only (no disk scan).
# NB: $Entries params here allow null/empty - an empty entry set is a normal
# state (fresh machine, zero configs), and PowerShell returns empty arrays
# from functions as $null.
function Update-PSMMLoaded {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $Entries)
    if (-not $Entries) { return }
    $loaded = @{}
    Get-Module -ErrorAction SilentlyContinue | ForEach-Object { $loaded[$_.Name] = $_.Version }
    foreach ($e in $Entries) {
        $e.Loaded = $loaded.ContainsKey($e.Name)
        $e.LoadedVersion = $loaded[$e.Name]
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
        $entry.InstalledVersions = @($sorted | ForEach-Object {
            [pscustomobject]@{
                Version = $_.Version
                Path    = $_.ModuleBase
                Scope   = Get-PSMMScopeForPath -Path $_.ModuleBase
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
function Get-PSMMUnmanagedModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ManagedNames)
    $managed = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$ManagedNames, [System.StringComparer]::OrdinalIgnoreCase)
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
