# Plan.ps1 — the ONE place the Mode x Install matrix is decided (gh#29).
#
# Before this file the decision was written out four times — the startup
# loader, the actuator, the deferred ThreadJob body and the grid's install
# task — and the four had drifted apart (gh#19, gh#20, gh#21, gh#25).
# Everything now goes through three functions:
#
#   Get-PSMMEntryPlan     entry (+ intent) -> a structured plan object
#   Invoke-PSMMPlanAction plan -> executes the DISK/GALLERY half, one line out
#   Get-PSMMJobPrelude    the source text a ThreadJob dot-sources so it runs
#                         these real functions instead of re-implementing them
#
# Scheduling is DERIVED, not declared: an import is always foreground, and
# every disk or gallery operation is always background — in all nine cells.
# That is what keeps the gallery off the profile hot path (gh#19). Nothing
# outside this file may branch on Mode/Install to decide policy; there is a
# static guard for that in Tests/Engine.Plan.Tests.ps1.

# One entry's decision. Intent selects WHOSE decision it is: the startup
# loader's declared policy, or a user pressing i / u on a row (Q-4 — the
# policy governs automatic behaviour, never the user's hands).
function Get-PSMMEntryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [ValidateSet('Startup', 'Install', 'Update')][string]$Intent = 'Startup',
        [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser'
    )

    $mode     = "$($Entry.Mode)"
    $declared = "$($Entry.Install)"
    $pin      = "$($Entry.Version)"
    $exact    = [bool]$Entry.PinnedExact
    $range    = [bool]($pin -and -not $exact)
    # a pin that NAMES a prerelease implies the prerelease track regardless of
    # the entry's own opt-in — you cannot install 1.2.3-beta4 without it
    $pre      = ([bool]$Entry.AllowPrerelease) -or ([bool]$Entry.PinnedPrerelease)
    $notices  = [System.Collections.Generic.List[string]]::new()

    # the declared policy in the verbs the actuator understands
    $install = switch ($declared) {
        'CheckOnly' { 'none' }
        'Latest'    { 'latest' }
        default     { 'ifmissing' }    # IfMissing, and anything that degraded to it
    }

    # gh#20: an exact pin names ONE version, so there is nothing to update TO.
    # Left alone, Latest means "-Reinstall the version you already have", in
    # the foreground, every single shell start. Degrade it to IfMissing.
    if ($install -eq 'latest' -and $exact) {
        $install = 'ifmissing'
        $notices.Add("pinned to $pin $([char]0x2014) Latest installs the pin once and never updates past it")
    }

    $import = ($mode -eq 'Load')
    # gh#23 and the docs' promise ("pinned modules are never flagged update
    # available"): an exact pin is never checked, because the flag could only
    # ever be noise. A RANGE pin IS checked — against the newest version
    # inside the range (Get-PSMMGalleryLatest -VersionRange), so its flag can
    # actually clear when you press u.
    $check = -not $exact

    if ($mode -eq 'Ignore') {
        # cells 7-9: nothing, and no gallery I/O of any kind
        $import  = $false
        $install = 'none'
        $check   = $false
        if ($Entry.InstallExplicit) {
            $notices.Add('Install policy has no effect while Mode is Ignore')
        }
    }

    # An explicit keypress overrides the declared policy but not the pin: i
    # installs what is missing, u moves to the newest ELIGIBLE version, which
    # for an exact pin is the pin itself (i.e. nothing to do).
    switch ($Intent) {
        'Install' { $import = $false; $install = 'ifmissing'; $check = $false }
        'Update'  {
            $import = $false; $check = $false
            $install = if ($exact) { 'ifmissing' } else { 'latest' }
        }
    }

    # Derived, never declared. 'foreground' means the ONLY thing this plan does
    # is import — nothing touches disk or the gallery. 'background' means there
    # is disk/gallery work, and it is always deferred; cell 4 lands here too,
    # because even a bare presence report is a disk sweep. 'none' is Ignore.
    $schedule = if ($mode -eq 'Ignore' -and $Intent -eq 'Startup') { 'none' }
                elseif ($install -ne 'none' -or -not $import) { 'background' }
                else { 'foreground' }

    # plain words for the grid's context sentence and the startup report
    $reason = if ($Intent -ne 'Startup') {
        if ($install -eq 'latest') { 'update to the newest eligible version' } else { 'install if missing' }
    } elseif ($mode -eq 'Ignore') {
        'off - nothing happens at shell start'
    } elseif ($import) {
        # kept short on purpose: this is one muted line under the grid, and it
        # has to share the row with the session and on-disk clauses
        switch ($install) {
            'latest'    { if ($range) { 'imports at shell start, background-updates inside the pin' }
                          else { 'imports at shell start, background-updates afterwards' } }
            'ifmissing' { 'imports at shell start, background-installs if missing' }
            default     { 'imports at shell start, never auto-installed' }
        }
    } else {
        switch ($install) {
            'latest'    { if ($range) { 'background-updates inside the pin at shell start' }
                          else { 'background-updates to latest at shell start' } }
            'ifmissing' { 'background-installs at shell start when missing' }
            default     { 'watch only - psmm will never install or load this' }
        }
    }

    [pscustomobject]@{
        Name         = "$($Entry.Name)"
        FriendlyName = if ($Entry.FriendlyName) { "$($Entry.FriendlyName)" } else { "$($Entry.Name)" }
        Mode         = $mode
        Declared     = $declared
        Intent       = $Intent
        Import       = $import                        # foreground, this session only
        Install      = $install                       # 'none' | 'ifmissing' | 'latest'
        Check        = $check                          # report-only update check is meaningful
        Schedule     = $schedule                       # 'foreground' | 'background' | 'none'
        Version      = if ($pin) { $pin } else { $null }
        PinnedExact  = $exact
        PinnedRange  = $range
        Prerelease   = $pre
        Scope        = $Scope
        Reason       = $reason
        Notices      = $notices.ToArray()
    }
}

# Execute one plan's DISK/GALLERY half. Never imports — an import is
# foreground and belongs to the caller, which is what stops a background
# install from landing in a session the user is already typing into (Q-2).
# Returns one status line. Callers parse only the 'FAILED ' prefix.
function Invoke-PSMMPlanAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan)
    $name = "$($Plan.Name)"
    $have = [bool](Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue)
    switch ("$($Plan.Install)") {
        'ifmissing' {
            if ($have) { return "ok $name" }
            Install-PSMMModule -Name $name -Version $Plan.Version -Prerelease:([bool]$Plan.Prerelease) -Scope "$($Plan.Scope)"
            return "installed $name"
        }
        'latest' {
            Install-PSMMModule -Name $name -Update -Version $Plan.Version -Prerelease:([bool]$Plan.Prerelease) -Scope "$($Plan.Scope)"
            return "updated $name"
        }
        default {
            # 'none' — CheckOnly. Presence IS the whole report.
            if ($have) { return "ok $name" }
            return "FAILED ${name}: not installed (check-only)"
        }
    }
}

# The source text a ThreadJob dot-sources so it executes psmm's REAL engine
# functions. Module functions are invisible inside Start-ThreadJob — its
# runspace holds no reference to this module — which is why the matrix used
# to be re-implemented by hand in two job bodies, and why those copies
# drifted (gh#25, gh#29). Shipping the definitions keeps exactly one copy.
#
# Cost is a few string concatenations plus one parse inside the job; it is
# never on the import path, and only runs when there IS background work.
function Get-PSMMJobPrelude {
    [CmdletBinding()]
    param(
        [string[]]$FunctionName = @(
            'Get-PSMMPrereleaseLabel'
            'Get-PSMMNormalVersion'
            'Test-PSMMVersionInstalled'
            'Test-PSMMInstalledPrerelease'
            'Install-PSMMModule'
            'Invoke-PSMMPlanAction'
        )
    )
    $sb = [System.Text.StringBuilder]::new()
    foreach ($n in $FunctionName) {
        $cmd = Get-Command -Name $n -CommandType Function -ErrorAction Stop
        $null = $sb.AppendLine("function $n {").AppendLine($cmd.Definition).AppendLine('}')
    }
    $sb.ToString()
}
