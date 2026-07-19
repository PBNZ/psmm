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
                          Install policy CheckOnly/IfMissing uses a fast path
                          (try the import first, install only if genuinely
                          missing); Latest asks the gallery for updates first.
      Mode = InstallOnly  disk/gallery work only - deferred to a background
                          thread job so your prompt appears sooner (set
                          $PSMM_BackgroundStartup = $false to run inline).
      Mode = Ignore       parsed but not actioned.

    Mode and Install are orthogonal: Mode decides load-vs-not and
    foreground-vs-background; Install decides the disk/gallery policy.

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
    $failed = [System.Collections.Generic.List[string]]::new()
    $mid = [char]0x00B7

    # Partition: Mode=Load must run in THIS session (imports do not cross job
    # boundaries). InstallOnly only touches disk/gallery -> deferrable.
    $sync     = @($entries | Where-Object { $_.Mode -eq 'Load' })
    $deferred = @($entries | Where-Object { $_.Mode -eq 'InstallOnly' })

    foreach ($e in $sync) {
        try {
            # FAST PATH: try the import first; install only if the module is
            # actually missing. Skips one Get-Module -ListAvailable disk scan
            # per module on the happy path.
            $result = $null
            if ($e.Install -ne 'Latest') {
                try {
                    if (-not (Get-Module -Name $e.Name)) { Import-PSMMModuleTimed -Entry $e }
                    $result = 'present + loaded'
                } catch [System.IO.FileNotFoundException] {
                    if ($e.Install -eq 'CheckOnly') { $result = 'not installed (check-only)' }
                    else {
                        Install-PSMMModule -Name $e.Name -Version $e.Version
                        Import-PSMMModuleTimed -Entry $e
                        $result = 'installed + loaded'
                    }
                }
            } else {
                $result = Invoke-PSMMEntryAction -Entry $e   # Latest: must hit the gallery anyway
            }
            $rows.Add($(
                if ($result -match 'not installed|check-only') {
                    [pscustomobject]@{ Kind = 'skip'; Name = $e.FriendlyName; Ms = $null; Note = "not installed $mid check-only, nothing done" }
                } elseif ($result -match 'not loaded') {
                    [pscustomobject]@{ Kind = 'skip'; Name = $e.FriendlyName; Ms = $null; Note = 'installed, not imported' }
                } elseif ($result -match 'loaded') {
                    $note = if ($result -match 'installed \+') { 'installed first' } else { '' }
                    [pscustomobject]@{ Kind = 'ok'; Name = $e.FriendlyName; Ms = [int]$e.ImportMs; Note = $note }
                } else {
                    [pscustomobject]@{ Kind = 'skip'; Name = $e.FriendlyName; Ms = $null; Note = "$result" }
                }
            ))
        } catch {
            $failed.Add($e.FriendlyName)
            $rows.Add([pscustomobject]@{ Kind = 'fail'; Name = $e.FriendlyName; Ms = $null; Note = "$($_.Exception.Message)" })
            if (-not $report) { Write-Warning "Could not set up $($e.FriendlyName): $($_.Exception.Message)" }
        }
    }

    if ($deferred.Count) {
        $useBackground = (Get-PSMMSetting -Name 'PSMM_BackgroundStartup' -Default $true) -and
                         (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
        if ($useBackground) {
            $null = Start-PSMMDeferredJob -Entries $deferred
            $label = "$($deferred[0].FriendlyName)$(if ($deferred.Count -gt 1) { " +$($deferred.Count - 1) more" })"
            $rows.Add([pscustomobject]@{
                Kind = 'defer'; Name = $label; Ms = $null; Count = $deferred.Count
                Note = "installing in the background $([char]0x2014) results in psmm"
            })
        } else {
            # No ThreadJob or backgrounding disabled: run them inline.
            foreach ($e in $deferred) {
                try {
                    $result = Invoke-PSMMEntryAction -Entry $e
                    $rows.Add($(
                        if ($result -match 'not installed') {
                            [pscustomobject]@{ Kind = 'fail'; Name = $e.FriendlyName; Ms = $null; Note = "$result" }
                        } else {
                            [pscustomobject]@{ Kind = 'skip'; Name = $e.FriendlyName; Ms = $null; Note = 'installed, not imported' }
                        }
                    ))
                } catch {
                    $failed.Add($e.FriendlyName)
                    $rows.Add([pscustomobject]@{ Kind = 'fail'; Name = $e.FriendlyName; Ms = $null; Note = "$($_.Exception.Message)" })
                    if (-not $report) { Write-Warning "Could not set up $($e.FriendlyName): $($_.Exception.Message)" }
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
