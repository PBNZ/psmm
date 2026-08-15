function Invoke-PSMMStartup {
    <#
    .SYNOPSIS
    Runs the psmm startup loader: installs and imports the modules your
    psmm-config.json files declare.

    .DESCRIPTION
    Reads every psmm config source (inline JSON, the main config in
    ~/.psmm/psmm-config.json, its Includes, the profile-directory config and
    any legacy globs), resolves precedence and conflicts, then actions each
    active entry:

      Mode = Load         imported into this session, in the foreground.
      Mode = InstallOnly  disk/gallery work only, never imported.
      Mode = Ignore       parsed but not actioned, and no gallery I/O at all.

    Mode decides load-vs-not; Install (CheckOnly / IfMissing / Latest) decides
    the disk/gallery policy. Scheduling is derived from the pair rather than
    declared by either: the import is the only thing that happens in the
    foreground, and every disk or gallery operation is deferred to a
    background thread job, in all nine cells. Nothing psmm does at startup
    waits on the network before your prompt appears.

    A module installed by that background job is reported, not imported - it
    is available next session rather than appearing behind a prompt you are
    already typing into. Set $PSMM_BackgroundStartup = $false to run the
    deferred work inline instead.

    The whole matrix is decided in one place, Get-PSMMEntryPlan; this function
    only executes the plans it hands back.

    Each imported module's import time is measured and shown in the report,
    so you always know which module is slowing your shell down.

    Intended use is one line in your $PROFILE:
        Import-Module psmm; Invoke-PSMMStartup

    .PARAMETER Quiet
    Suppress the per-module report and the config warnings.

    .EXAMPLE
    Invoke-PSMMStartup

    Loads/installs everything the config declares and prints the report.

    .EXAMPLE
    Invoke-PSMMStartup -Quiet

    Same, but silent (warnings are still collected; the psmm UI shows them).

    .LINK
    Show-PSModuleManager
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'The startup report is interactive host output by design, exactly like the original profile block.')]
    [CmdletBinding()]
    param([switch]$Quiet)

    $entries = Get-PSMMEntry
    $report  = (-not $Quiet -and (Get-PSMMSetting -Name 'PSMM_StartupReport' -Default $true))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # v2 report (design-system-v2 §8): collect one row per module, render at
    # the end via Get-PSMMStartupReportLines - same tokens as the TUI.
    $rows = [System.Collections.Generic.List[object]]::new()
    $mid = [char]0x00B7

    # One decision per entry, from the one function that makes it (gh#29).
    # Nothing below re-derives policy - it only executes what the plan says.
    $work = @(foreach ($e in $entries) {
        [pscustomobject]@{ Entry = $e; Plan = (Get-PSMMEntryPlan -Entry $e) }
    })
    $deferred = [System.Collections.Generic.List[object]]::new()

    foreach ($w in $work) {
        $e = $w.Entry
        $p = $w.Plan
        if ($p.Schedule -eq 'none') { continue }          # Mode=Ignore: nothing, no I/O
        if (-not $p.Import) { $deferred.Add($p); continue } # InstallOnly, all three cells

        # The import IS the presence check, and it is free: a module that
        # imports is on disk, so IfMissing has nothing left to do. This is
        # what keeps a Get-Module -ListAvailable disk sweep off the hot path.
        $present = $true
        try {
            if (-not (Get-Module -Name $e.Name)) { Import-PSMMModuleTimed -Entry $e }
            $rows.Add([pscustomobject]@{ Kind = 'ok'; Name = $e.FriendlyName; Ms = [int]$e.ImportMs; Note = '' })
        } catch [System.IO.FileNotFoundException] {
            $present = $false
            $note = if ($p.Install -eq 'none') { "missing $mid not loaded, check-only" }
                    else { "missing $mid installing in the background, available next session" }
            $rows.Add([pscustomobject]@{ Kind = 'warn'; Name = $e.FriendlyName; Ms = $null; Note = $note })
        } catch {
            $rows.Add([pscustomobject]@{ Kind = 'fail'; Name = $e.FriendlyName; Ms = $null; Note = "$($_.Exception.Message)" })
            if (-not $report) { Write-Warning "Could not set up $($e.FriendlyName): $($_.Exception.Message)" }
            continue
        }
        # Latest always has background work; IfMissing only when it is missing.
        if ($p.Install -eq 'latest' -or ($p.Install -eq 'ifmissing' -and -not $present)) { $deferred.Add($p) }
    }

    if ($deferred.Count) {
        $useBackground = (Get-PSMMSetting -Name 'PSMM_BackgroundStartup' -Default $true) -and
                         (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
        if ($useBackground) {
            $null = Start-PSMMDeferredJob -Plans $deferred
            $label = "$($deferred[0].FriendlyName)$(if ($deferred.Count -gt 1) { " +$($deferred.Count - 1) more" })"
            $rows.Add([pscustomobject]@{
                Kind = 'defer'; Name = $label; Ms = $null; Count = $deferred.Count
                Note = "working in the background $([char]0x2014) results in psmm"
            })
        } else {
            # $PSMM_BackgroundStartup = $false: the user has explicitly asked
            # for the deferred work inline, network and all.
            foreach ($p in $deferred) {
                try {
                    $result = Invoke-PSMMPlanAction -Plan $p
                    $rows.Add($(
                        if ("$result" -like 'FAILED *') {
                            [pscustomobject]@{ Kind = 'warn'; Name = $p.FriendlyName; Ms = $null; Note = "missing $mid not installed, check-only" }
                        } else {
                            [pscustomobject]@{ Kind = 'skip'; Name = $p.FriendlyName; Ms = $null; Note = "$result, not imported" }
                        }
                    ))
                } catch {
                    $rows.Add([pscustomobject]@{ Kind = 'fail'; Name = $p.FriendlyName; Ms = $null; Note = "$($_.Exception.Message)" })
                    if (-not $report) { Write-Warning "Could not set up $($p.FriendlyName): $($_.Exception.Message)" }
                }
            }
        }
    }

    $sw.Stop()
    if ($report) {
        Write-Host ''
        foreach ($l in (Get-PSMMStartupReportLines -Rows $rows -TotalMs $sw.ElapsedMilliseconds)) { Write-Host $l }
    }
    $warnings = Get-PSMMWarning
    if ($warnings.Count -and -not $Quiet) {
        foreach ($w in $warnings) { Write-Host "psmm config: $w" -ForegroundColor Yellow }
    }

    # Self-update: print the cached result of a PREVIOUS session's background
    # check (never a network call in the profile hot path), then kick the
    # once-a-day background re-check. $PSMM_UpdateCheck = $false disables both.
    if (-not $Quiet) {
        $u = Test-PSMMUpdateAvailable
        if ($u) {
            $reset = Get-PSMMAnsiReset
            Write-Host ("$(Get-PSMMAnsi -Token 'warn')$([char]0x21E1) psmm v$($u.Latest) is out (you have v$($u.Current))$reset " +
                "$(Get-PSMMAnsi -Token 'mute')$([char]0x2014)$reset $([char]27)[96m$($u.Command)$reset" +
                "$(Get-PSMMAnsi -Token 'mute'), then restart pwsh$reset")
        }
    }
    $null = Start-PSMMSelfUpdateCheck
}
