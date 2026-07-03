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
    if ($report) { Write-Host "`nPS Session Module Manager priority managed" }
    $failed = [System.Collections.Generic.List[string]]::new()

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
            if ($report) {
                if     ($result -match 'not installed|check-only') { $disp = $result;               $color = 'Red' }
                elseif ($result -match 'not loaded')               { $disp = 'installed, unloaded'; $color = 'Blue' }
                elseif ($result -match 'loaded')                   { $disp = 'installed, loaded';   $color = 'Green' }
                else                                               { $disp = $result;               $color = 'Gray' }
                if ($e.ImportMs -ge 0 -and $disp -match 'loaded') { $disp += " ($($e.ImportMs) ms)" }
                Write-Host "> $($e.FriendlyName) < " -NoNewline
                Write-Host $disp -ForegroundColor $color
            }
        } catch {
            $failed.Add($e.FriendlyName)
            Write-Warning "Could not set up > $($e.FriendlyName) < : $($_.Exception.Message)"
        }
    }

    if ($deferred.Count) {
        $useBackground = (Get-PSMMSetting -Name 'PSMM_BackgroundStartup' -Default $true) -and
                         (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
        if ($useBackground) {
            $null = Start-PSMMDeferredJob -Entries $deferred
            if ($report) {
                Write-Host ("> {0} background module task(s) started < " -f $deferred.Count) -NoNewline
                Write-Host 'deferred (psmm shows results)' -ForegroundColor DarkGray
            }
        } else {
            # No ThreadJob or backgrounding disabled: run them inline.
            foreach ($e in $deferred) {
                try {
                    $result = Invoke-PSMMEntryAction -Entry $e
                    if ($report) {
                        $disp  = if ($result -match 'not installed') { $result } else { 'installed, unloaded' }
                        $color = if ($result -match 'not installed') { 'Red' } else { 'Blue' }
                        Write-Host "> $($e.FriendlyName) < " -NoNewline
                        Write-Host $disp -ForegroundColor $color
                    }
                } catch {
                    $failed.Add($e.FriendlyName)
                    Write-Warning "Could not set up > $($e.FriendlyName) < : $($_.Exception.Message)"
                }
            }
        }
    }

    if ($failed.Count -and $report) {
        Write-Host ("[{0} failed: {1}]  Run 'psmm' and press Ctrl+P to retry." -f $failed.Count, ($failed -join ', ')) -ForegroundColor Yellow
    }
    $warnings = Get-PSMMWarning
    if ($warnings.Count -and -not $Quiet) {
        foreach ($w in $warnings) { Write-Host "psmm config: $w" -ForegroundColor Yellow }
    }
}
