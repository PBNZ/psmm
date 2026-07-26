# Install.ps1 — gallery operations: install, update, uninstall.
# Microsoft.PowerShell.PSResourceGet is the primary engine with a
# PowerShellGet fallback (older machines). Read-only lookups live in State.ps1.

# Which install engine is active? (surfaced in the UI; defuses the
# PSResourceGet-vs-PowerShellGet confusion)
function Get-PSMMInstallEngine {
    [CmdletBinding()] param()
    if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) { 'PSResourceGet' } else { 'PowerShellGet' }
}

# Is this session elevated? Drives which scopes the UI offers (#28).
function Test-PSMMElevated {
    [CmdletBinding()] param()
    if ($IsWindows) {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return ([System.Security.Principal.WindowsPrincipal]$id).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    [System.Environment]::UserName -eq 'root'
}

# The roots that count as CurrentUser.
#
# $HOME alone is NOT enough, and getting this wrong is expensive. On Windows
# the CurrentUser module location is derived from the **Documents known
# folder**, which can live on another drive entirely — a redirected or
# relocated Documents puts every one of your own modules outside $HOME. On
# such a machine a bare $HOME prefix test reports them all as AllUsers, so the
# grid marks them read-only and version cleanup refuses to touch them
# ("session is not elevated") — the feature silently stops working for exactly
# the modules it exists to clean up. Verified on a real machine where
# $HOME = C:\Users\<user> and Documents = E:\Users\<user>\Documents.
#
# Cached: this runs once per installed version during a full scan, and the
# Documents known folder cannot move inside a live session.
function Get-PSMMUserModuleRoot {
    [CmdletBinding()] param()
    if ($null -ne $script:PSMM_UserRoots) { return $script:PSMM_UserRoots }
    $roots = [System.Collections.Generic.List[string]]::new()
    if ($HOME) { $roots.Add("$HOME") }
    # Documents-derived default (Windows). Unix keeps its user modules under
    # ~/.local/share/powershell/Modules, which $HOME already covers.
    $docs = $null
    try { $docs = Get-PSMMUserDefaultModulePath } catch { }
    if ($docs) { $roots.Add("$docs") }
    $script:PSMM_UserRoots = @($roots | Where-Object { $_ } | Select-Object -Unique)
    $script:PSMM_UserRoots
}

# Classify a module base path into an install scope: the scope you would have
# to install to in order to replace it. Two values only — 'System' is NOT one
# of them, because "shipped with PowerShell" is not somewhere anything can be
# installed; see Test-PSMMPlatformModulePath for that question.
function Get-PSMMScopeForPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    foreach ($root in (Get-PSMMUserModuleRoot)) {
        if ($Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return 'CurrentUser' }
    }
    'AllUsers'
}

# Is this module base one of the PLATFORM's own module directories?
# $PSHOME/Modules on every platform, plus Windows PowerShell's System32 store.
#
# These modules ship WITH PowerShell, so they are not ordinary machine-wide
# installs: you cannot replace pwsh's own Microsoft.PowerShell.* from the
# gallery. The unmanaged view still LISTS them - browsing their commands and
# help through psmm is a real use - but marks them `system` rather than
# `all`, and version cleanup refuses to remove one at any elevation (gh#27).
# Roots are read from $PSHOME / $env:SystemRoot at call time, never hard-coded.
#
# Deliberately NOT folded into Get-PSMMScopeForPath as a third scope value:
# that function feeds install-scope and elevation decisions, and "shipped with
# the platform" is not a scope anything can be installed to.
function Test-PSMMPlatformModulePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $roots = [System.Collections.Generic.List[string]]::new()
    if ($PSHOME) { $roots.Add((Join-Path $PSHOME 'Modules')) }
    if ($env:SystemRoot) {
        $roots.Add((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'))
        $roots.Add((Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\Modules'))
    }
    foreach ($r in $roots) {
        if ($Path.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# The prerelease label of one module copy ('' when it is a stable release).
# It lives in the manifest's PSData, never in the [version] - 0.1.0-beta8 and
# 0.1.0 share the same [version] 0.1.0 (gh#6).
function Get-PSMMPrereleaseLabel {
    [CmdletBinding()]
    param([AllowNull()] $ModuleInfo)
    if (-not $ModuleInfo) { return '' }
    $pre = $null
    try { $pre = $ModuleInfo.PrivateData.PSData.Prerelease } catch { }
    if ([string]::IsNullOrWhiteSpace("$pre")) { return '' }
    "$pre".TrimStart('-')
}

# "1.2.0-beta3" for display: the [version] plus the prerelease label when there
# is one. Every version psmm shows goes through here (gh#6).
function Get-PSMMVersionDisplay {
    [CmdletBinding()]
    param($Version, [string]$Prerelease)
    if ($null -eq $Version -or "$Version" -eq '') { return '' }
    if ([string]::IsNullOrWhiteSpace($Prerelease)) { return "$Version" }
    "$Version-$($Prerelease.TrimStart('-'))"
}

# "2.5" and "2.5.0" name the same release; [version] disagrees, because the
# segments you leave out are -1 rather than 0. Pad to four parts so matching a
# pin is never defeated by how many segments the user happened to type.
function Get-PSMMNormalVersion {
    [CmdletBinding()]
    param($Version)
    try {
        $v = [version]"$Version"
        '{0}.{1}.{2}.{3}' -f $v.Major, [Math]::Max(0, $v.Minor), [Math]::Max(0, $v.Build), [Math]::Max(0, $v.Revision)
    } catch { "$Version" }
}

# Is this EXACT version pin (base version + prerelease label) already on disk?
# A RANGE pin always answers $false — "newest inside the range" is a moving
# target, so an update against it is genuinely meaningful (gh#20, gh#23).
function Test-PSMMVersionInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version
    )
    if ($Version -notmatch '^(?<base>\d+(\.\d+){1,3})(-(?<label>[A-Za-z0-9][A-Za-z0-9.-]*))?$') { return $false }
    $want  = Get-PSMMNormalVersion -Version $Matches['base']
    $label = "$($Matches['label'])"
    foreach ($m in @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)) {
        if ((Get-PSMMNormalVersion -Version "$($m.Version)") -ne $want) { continue }
        if ((Get-PSMMPrereleaseLabel -ModuleInfo $m) -eq $label) { return $true }
    }
    $false
}

# Is the newest installed copy of a module a prerelease?
function Test-PSMMInstalledPrerelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $newest = @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending) | Select-Object -First 1
    if (-not $newest) { return $false }
    [bool](Get-PSMMPrereleaseLabel -ModuleInfo $newest)
}

# Install or update one module. Honours an optional version pin (exact or
# NuGet range), the entry's prerelease policy and the target scope. Throws on
# failure — callers decide how to report; a bulk operation must survive one
# module failing.
# -Prerelease is the entry's opt-in (gh#6). Independently of it, a module whose
# INSTALLED copy is already a prerelease keeps being updated along the
# prerelease track, because that is the only thing that can move it at all.
function Install-PSMMModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Update,
        [string]$Version,
        [switch]$Prerelease,
        [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser'
    )
    # gh#20, second line of defence. The policy function already degrades
    # Latest to IfMissing for an exact pin, so nothing psmm schedules asks for
    # this any more — but Install-PSMMModule is callable directly (the module
    # menu's u), and "update to the version you already have" must never mean
    # "download it again". The pin IS the answer; if it is on disk, we are done.
    if ($Update -and $Version -and (Test-PSMMVersionInstalled -Name $Name -Version $Version)) { return }

    if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
        # a pin that names a prerelease implies -Prerelease, whatever the
        # entry's policy says: you cannot install 1.2.3-beta4 without it
        $pre = [bool]$Prerelease -or ($Version -match '^\d+(\.\d+){1,3}-')
        if ($Version) {
            # A pin always installs the pinned version/range, update or not.
            Install-PSResource -Name $Name -Version $Version -Scope $Scope -Prerelease:$pre -TrustRepository -Reinstall:$Update -ErrorAction Stop
        } elseif ($Update -and (Get-Module -ListAvailable -Name $Name) -and ($pre -or (Test-PSMMInstalledPrerelease -Name $Name))) {
            # Prerelease track: Update-PSResource is blind to a
            # prerelease-label-only bump (beta2 -> beta3 shares the base
            # version folder) - Install -Prerelease -Reinstall is the only
            # command that moves it (verified against PSResourceGet 1.2.0,
            # see src/Engine/SelfUpdate.ps1).
            Install-PSResource -Name $Name -Prerelease -Reinstall -Scope $Scope -TrustRepository -ErrorAction Stop
        } elseif ($Update -and (Get-Command Update-PSResource -ErrorAction SilentlyContinue) -and (Get-Module -ListAvailable -Name $Name)) {
            Update-PSResource -Name $Name -Scope $Scope -Prerelease:$pre -ErrorAction Stop
        } else {
            Install-PSResource -Name $Name -Scope $Scope -Prerelease:$pre -TrustRepository -ErrorAction Stop
        }
    } else {
        # PowerShellGet fallback: exact pins map to -RequiredVersion; NuGet
        # ranges are a PSResourceGet feature, so fall back to latest with a
        # warning rather than failing the whole operation.
        $exact = $Version -and $Version -match '^\d+(\.\d+){1,3}(-[A-Za-z0-9][A-Za-z0-9.-]*)?$'
        if ($Version -and -not $exact) {
            Write-Warning "psmm: version range '$Version' for '$Name' needs PSResourceGet - installing latest instead"
        }
        $params = @{ Name = $Name; Scope = $Scope; Force = $true; AllowClobber = $true; ErrorAction = 'Stop' }
        if ($exact) { $params.RequiredVersion = $Version }
        if ($Prerelease -or ($Version -match '^\d+(\.\d+){1,3}-') -or
            ($Update -and (Test-PSMMInstalledPrerelease -Name $Name))) { $params.AllowPrerelease = $true }
        Install-Module @params
    }
}

# Remove one specific installed version (duplicate-version cleanup).
function Uninstall-PSMMModuleVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version
    )
    if (Get-Command Uninstall-PSResource -ErrorAction SilentlyContinue) {
        Uninstall-PSResource -Name $Name -Version "[$Version]" -ErrorAction Stop
    } else {
        Uninstall-Module -Name $Name -RequiredVersion $Version -Force -ErrorAction Stop
    }
}

# Import one entry's module, honouring an exact pin and recording how long the
# import took (ImportMs — surfaced in the startup report and the UI, because
# "which module makes my shell slow?" is the question everyone asks).
#
# -Global is MANDATORY here, not a nicety (gh#2). Every psmm import runs inside
# the psmm module, and about_Modules / Import-Module -Scope is explicit: called
# from within a module, Import-Module imports into THAT module's session state.
# Without -Global the module lands in psmm's private state - invisible to the
# user's prompt, `Get-Module` empty, its commands "not recognized" - while
# psmm's own `Get-Module` (which sees global + its own private state) happily
# reports it as loaded, for the rest of the session. Command auto-loading hides
# this for modules that export explicit names; modules whose manifest exports
# '*' (e.g. Microsoft.Online.SharePoint.PowerShell) cannot auto-load and break
# outright.
function Import-PSMMModuleTimed {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Entry.PinnedExact) {
            # -RequiredVersion is typed [System.Version] and throws on a
            # prerelease label, so a "1.2.3-beta4" pin imports by its BASE
            # version - which is the folder PowerShell actually installed it to
            # (a prerelease shares its base-version folder).
            $req = if ($Entry.PinnedBaseVersion) { $Entry.PinnedBaseVersion } else { $Entry.Version }
            Import-Module -Name $Entry.Name -RequiredVersion $req -Global -ErrorAction Stop
        } else {
            Import-Module -Name $Entry.Name -Global -ErrorAction Stop
        }
    } finally {
        $sw.Stop()
        $Entry.ImportMs = [int]$sw.Elapsed.TotalMilliseconds
    }
}
