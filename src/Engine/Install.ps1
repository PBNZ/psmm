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

# Classify a module base path into an install scope.
# Heuristic: anything under $HOME is CurrentUser, everything else AllUsers —
# holds for the standard PSModulePath layout on Windows, Linux and macOS.
function Get-PSMMScopeForPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith($HOME, [System.StringComparison]::OrdinalIgnoreCase)) { 'CurrentUser' } else { 'AllUsers' }
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

# One entry's startup action, honouring the orthogonal Mode x Install matrix.
# Mode decides load-vs-not; Install decides disk/gallery policy.
function Invoke-PSMMEntryAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    $name = $Entry.Name
    if ($Entry.Mode -eq 'Ignore') { return 'ignored' }
    $installed = [bool](Get-Module -ListAvailable -Name $name)
    $note = ''
    $pre = [bool]$Entry.AllowPrerelease
    switch ($Entry.Install) {
        'CheckOnly' { if (-not $installed) { return 'not installed (check-only)' }; $note = 'present' }
        'IfMissing' {
            if (-not $installed) { Install-PSMMModule -Name $name -Version $Entry.Version -Prerelease:$pre; $note = 'installed' }
            else { $note = 'present' }
        }
        'Latest' { Install-PSMMModule -Name $name -Update -Version $Entry.Version -Prerelease:$pre; $note = 'latest' }
    }
    if ($Entry.Mode -eq 'InstallOnly') { return "$note (not loaded)" }
    if (-not (Get-Module -Name $name)) {
        Import-PSMMModuleTimed -Entry $Entry
        return "$note + loaded"
    }
    return "$note + already loaded"
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
