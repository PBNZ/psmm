# 80-Manager.ps1 — the top-level manager loop Show-PSModuleManager runs.

function script:Invoke-PSMMManagerLoop {
    [CmdletBinding()] param()
    Initialize-PSMMUIState
    Start-PSMMUnmanagedScan

    $oldTitle = $null
    try {
        # alternate screen buffer: whatever the terminal showed before psmm
        # is exactly restored on exit (#4)
        Enter-PSMMAltScreen
        try { $oldTitle = $Host.UI.RawUI.WindowTitle; $Host.UI.RawUI.WindowTitle = 'psmm - PS Session Module Manager' } catch { }

        while ($true) {
            $ui = $script:PSMM_UI
            if ($ui.HardQuit) { return }
            $ui.GoHome = $false   # the grid IS home - the chord has unwound
            $r = Invoke-PSMMGrid
            if ($script:PSMM_UI.HardQuit) { return }
            switch ($r.Cmd) {
                'quit'      { return }
                'submenu'   {
                    Show-PSMMModuleMenu -Entry $script:PSMM_UI.Entries[$r.Index]
                    Update-PSMMLoaded -Entries $script:PSMM_UI.Entries
                }
                'add'       { New-PSMMEntry }
                'conflicts' { Show-PSMMConflicts }
                'files'     { Show-PSMMFiles }
                'gallery'   { Show-PSMMGallery }
                'cleanup'   { Show-PSMMCleanup }
                'tasks'     { Show-PSMMTasks }
                'help'      { Show-PSMMHelpScreen -Topic 'grid' }
                'reload'    { $script:PSMM_UI.Dirty = $true }
            }
            if ($script:PSMM_UI.HardQuit) { return }
            if ($script:PSMM_UI.Dirty) { Sync-PSMMUIEntries -FullScan }
            if ($script:PSMM_UI.Cursor -ge $script:PSMM_UI.Entries.Count) {
                $script:PSMM_UI.Cursor = [Math]::Max(0, $script:PSMM_UI.Entries.Count - 1)
            }
        }
    } finally {
        if ($null -ne $oldTitle) { try { $Host.UI.RawUI.WindowTitle = $oldTitle } catch { } }
        Exit-PSMMAltScreen
    }
}
