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

# Is the newest installed copy of a module a prerelease? (the label lives in
# the manifest's PSData, not in the [version])
function Test-PSMMInstalledPrerelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $newest = @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending) | Select-Object -First 1
    if (-not $newest) { return $false }
    $pre = $null
    try { $pre = $newest.PrivateData.PSData.Prerelease } catch { }
    [bool]$pre
}

# Install or update one module. Honours an optional version pin (exact or
# NuGet range) and the target scope. Throws on failure — callers decide how
# to report; a bulk operation must survive one module failing.
function Install-PSMMModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Update,
        [string]$Version,
        [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser'
    )
    if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
        if ($Version) {
            # A pin always installs the pinned version/range, update or not.
            Install-PSResource -Name $Name -Version $Version -Scope $Scope -TrustRepository -Reinstall:$Update -ErrorAction Stop
        } elseif ($Update -and (Get-Module -ListAvailable -Name $Name) -and (Test-PSMMInstalledPrerelease -Name $Name)) {
            # Prerelease installed: Update-PSResource is blind to a
            # prerelease-label-only bump (beta2 -> beta3 shares the base
            # version folder) - Install -Prerelease -Reinstall is the only
            # command that moves it (verified against PSResourceGet 1.2.0,
            # see src/Engine/SelfUpdate.ps1).
            Install-PSResource -Name $Name -Prerelease -Reinstall -Scope $Scope -TrustRepository -ErrorAction Stop
        } elseif ($Update -and (Get-Command Update-PSResource -ErrorAction SilentlyContinue) -and (Get-Module -ListAvailable -Name $Name)) {
            Update-PSResource -Name $Name -Scope $Scope -ErrorAction Stop
        } else {
            Install-PSResource -Name $Name -Scope $Scope -TrustRepository -ErrorAction Stop
        }
    } else {
        # PowerShellGet fallback: exact pins map to -RequiredVersion; NuGet
        # ranges are a PSResourceGet feature, so fall back to latest with a
        # warning rather than failing the whole operation.
        $exact = $Version -and $Version -match '^\d+(\.\d+){1,3}$'
        if ($Version -and -not $exact) {
            Write-Warning "psmm: version range '$Version' for '$Name' needs PSResourceGet - installing latest instead"
        }
        $params = @{ Name = $Name; Scope = $Scope; Force = $true; AllowClobber = $true; ErrorAction = 'Stop' }
        if ($exact) { $params.RequiredVersion = $Version }
        if ($Update -and (Test-PSMMInstalledPrerelease -Name $Name)) { $params.AllowPrerelease = $true }
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
    switch ($Entry.Install) {
        'CheckOnly' { if (-not $installed) { return 'not installed (check-only)' }; $note = 'present' }
        'IfMissing' {
            if (-not $installed) { Install-PSMMModule -Name $name -Version $Entry.Version; $note = 'installed' }
            else { $note = 'present' }
        }
        'Latest' { Install-PSMMModule -Name $name -Update -Version $Entry.Version; $note = 'latest' }
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
function Import-PSMMModuleTimed {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Entry.PinnedExact) {
            Import-Module -Name $Entry.Name -RequiredVersion $Entry.Version -ErrorAction Stop
        } else {
            Import-Module -Name $Entry.Name -ErrorAction Stop
        }
    } finally {
        $sw.Stop()
        $Entry.ImportMs = [int]$sw.Elapsed.TotalMilliseconds
    }
}
