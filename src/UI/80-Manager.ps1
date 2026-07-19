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
        try { $oldTitle = $Host.UI.RawUI.WindowTitle; $Host.UI.RawUI.WindowTitle = "psmm v$($script:PSMM_UI.Version) - PS Session Module Manager" } catch { }

        while ($true) {
            $ui = $script:PSMM_UI
            if ($ui.HardQuit) { return }
            # a pending goto (set by any sub-screen via the g overlay) routes
            # straight to its screen; 'home' - and no goto - lands on the grid
            $goto = $ui.Goto
            $ui.Goto = $null
            $cmd = $null
            $index = $null
            if ($goto -and $goto -ne 'home') {
                $cmd = $goto
            } else {
                $r = Invoke-PSMMGrid
                if ($script:PSMM_UI.HardQuit) { return }
                if ($r.Cmd -eq 'quit') { return }
                $cmd = $r.Cmd
                $index = $r.Index
            }
            switch ($cmd) {
                'submenu'   {
                    Show-PSMMModuleMenu -Entry $script:PSMM_UI.Entries[$index]
                    Update-PSMMLoaded -Entries $script:PSMM_UI.Entries
                }
                'add'       { New-PSMMEntry }
                'conflicts' { Show-PSMMConflicts }
                'files'     { Show-PSMMFiles }
                'paths'     { Show-PSMMPaths }
                'gallery'   { Show-PSMMGallery }
                'cleanup'   { Show-PSMMCleanup }
                'tasks'     { Show-PSMMTasks }
                'help'      {
                    # g ? lands on the key reference; the screen's own ? opens
                    # "this screen" (the default tab)
                    $tab = if ($goto -eq 'help') { 'keys' } else { 'this screen' }
                    Show-PSMMHelpScreen -Topic 'grid' -InitialTab $tab
                }
                'unmanaged' { Invoke-PSMMUnmanagedToggle }
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
