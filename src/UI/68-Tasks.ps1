# 68-Tasks.ps1 — background-task screen (#25) + the completion handler the
# grid loop calls, + background Update-Help (#35).

# React to freshly finished tasks: refresh state, surface a status line.
# Called from the grid loop on every wake-up.
function script:Receive-PSMMUITask {
    Update-PSMMTask
    $ui = $script:PSMM_UI
    foreach ($t in @(Get-PSMMTask | Where-Object { $_.Done -and -not $_.Seen })) {
        switch ($t.Kind) {
            'unmanagedscan' {
                # no status line here: Build-PSMMGrid renders a standing
                # notice for unshown unmanaged modules - a status too would
                # print the same text twice
                $ui.Unmanaged = @($t.Output)
            }
            'install' {
                $names = @($t.Data)
                if ($names.Count) {
                    Update-PSMMAvailable -Entries $ui.Entries -Name $names
                    Update-PSMMLoaded -Entries $ui.Entries
                }
                $fails = @($t.Output | Where-Object { "$_" -like 'FAILED *' })
                $ui.Status = if ($fails.Count) { "[yellow]install/update: $($fails.Count) of $($names.Count) failed (t=details)[/]" }
                             else { "[green]install/update done: $($names -join ', ')[/]" }
            }
            'updatecheck' {
                $found = 0
                $byName = @{}
                foreach ($o in $t.Output) { if ($o.Name) { $byName[$o.Name] = "$($o.Latest)" } }
                foreach ($e in $ui.Entries) {
                    if (-not $byName.ContainsKey($e.Name)) { continue }
                    $e.LatestVersion = $byName[$e.Name]
                    $e.UpdateAvailable = $false
                    if ($e.PinnedExact) { continue }
                    if ($e.InstalledVersion) {
                        $lv = $byName[$e.Name] -replace '-.*$', ''
                        try { $e.UpdateAvailable = ([version]$lv -gt [version]"$($e.InstalledVersion)") } catch { }
                    }
                    if ($e.UpdateAvailable) { $found++ }
                }
                $ui.Status = if ($found) { "[yellow]$found update(s) available (^ in the Ver column)[/]" } else { '[green]everything up to date[/]' }
            }
            'updatehelp' {
                $ui.Status = if ($t.Failed) { '[yellow]Update-Help finished with errors (t=details)[/]' } else { '[green]Update-Help done[/]' }
            }
            default {
                $ui.Status = if ($t.Failed) { "[yellow]task '$(ConvertTo-PSMMSafe $t.Label)' failed (t=details)[/]" }
                             else { "[green]task '$(ConvertTo-PSMMSafe $t.Label)' done[/]" }
            }
        }
        $t.Seen = $true
    }
}

# Kick off Update-Help for all installed modules in the background (#35).
function script:Start-PSMMUpdateHelpTask {
    $running = @(Get-PSMMTask | Where-Object { $_.Kind -eq 'updatehelp' -and -not $_.Done })
    if ($running.Count) { $script:PSMM_UI.Status = '[yellow]Update-Help is already running[/]'; return }
    $null = Start-PSMMTask -Label 'Update-Help (all modules)' -Kind 'updatehelp' -ScriptBlock {
        try {
            Update-Help -Scope CurrentUser -Force -ErrorAction SilentlyContinue -ErrorVariable errs 3>$null
            foreach ($e in @($errs)) { "note: $($e.Exception.Message)" }
            'help update finished'
        } catch { "FAILED: $($_.Exception.Message)" }
    }
    $script:PSMM_UI.Status = "[$script:PSMM_ColAccent]Update-Help started in the background[/]"
}

function script:Build-PSMMTasksView {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Tasks,
        [string]$StatusMarkup
    )
    $n = $Tasks.Count
    $win = Get-PSMMWinSize
    $vp = Get-PSMMViewport -State $State -Count $n -Rows ($win.Height - 10)
    $T = [Spectre.Console.Table]::new()
    $T.Border = [Spectre.Console.TableBorder]::Rounded
    foreach ($h in ' ', 'Task', 'State', 'Started', 'Output') { [void][Spectre.Console.TableExtensions]::AddColumn($T, $h) }
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        # NB: $task, not $t - PowerShell variables are case-insensitive and $T
        # is the table right above.
        $task = $Tasks[$i]
        $nm = ConvertTo-PSMMSafe (Get-PSMMTrunc $task.Label 44)
        if ($i -eq $State.Cursor) { $nm = "[$script:PSMM_ColAccent]$nm[/]" }
        $state = if (-not $task.Done) { "[deepskyblue1]running[/]" }
                 elseif ($task.Failed) { '[red]failed[/]' }
                 else { '[green]done[/]' }
        [void][Spectre.Console.TableExtensions]::AddRow($T, [string[]]@(
                $(if ($i -eq $State.Cursor) { "[$script:PSMM_ColAccent]>[/]" } else { ' ' }),
                $nm, $state, $task.StartedAt.ToString('HH:mm:ss'), "$($task.Output.Count) line(s)"))
    }
    $pos = Get-PSMMPositionMarkup -State $State -Count $n -Viewport $vp
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColAccent]Background tasks[/]$pos"))
    $items.Add($T)
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('up/dn=move', 'enter=view output', 'u=run Update-Help', 'c=clear finished', '?=help', 'esc=back', 'Ctrl+Q=quit'))))
    if ($StatusMarkup) { $items.Add([Spectre.Console.Markup]::new($StatusMarkup)) }
    [Spectre.Console.Rows]::new($items)
}

function script:Show-PSMMTasks {
    $ui = $script:PSMM_UI
    $status = ''
    while ($true) {
        if ($ui.HardQuit) { return }
        Update-PSMMTask
        $tasks = @(Get-PSMMTask)
        $st = New-PSMMListState
        $st.Status = $status
        $status = ''
        $action = @{ Name = $null }
        if (-not $tasks.Count) {
            Clear-PSMMScreen
            Write-PSMMLine "[$script:PSMM_ColAccent]Background tasks[/]"
            Write-PSMMLine '[grey]No tasks yet. u starts a background Update-Help; installs/updates/scans appear here too.[/]'
            Write-PSMMLine (Get-PSMMHint -Pairs @('u=run Update-Help', 'esc=back'))
            $k = [Console]::ReadKey($true)
            if (Test-PSMMHardQuitKey $k) { $ui.HardQuit = $true; return }
            if ($k.Key -eq [ConsoleKey]::U) { Start-PSMMUpdateHelpTask; continue }
            return
        }
        Clear-PSMMScreen
        Invoke-PSMMLive -Body {
            param($ctx)
            while ($true) {
                if ($script:PSMM_UI.HardQuit) { return }
                Update-PSMMTask
                $tasks = @(Get-PSMMTask)
                $ctx.UpdateTarget((Build-PSMMTasksView -State $st -Tasks $tasks -StatusMarkup $st.Status))
                $ctx.Refresh()
                $k = Read-PSMMKeyResize
                if ($null -eq $k) { continue }
                if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; return }
                $st.Status = ''
                if (Invoke-PSMMListNav -State $st -KeyInfo $k -Count $tasks.Count) { continue }
                switch ($k.Key) {
                    ([ConsoleKey]::Enter)  { $action.Name = 'view'; return }
                    ([ConsoleKey]::U)      { Start-PSMMUpdateHelpTask; continue }
                    ([ConsoleKey]::C)      { Clear-PSMMTask; $st.Cursor = 0; $st.Status = '[green]finished tasks cleared[/]'; continue }
                    ([ConsoleKey]::Escape) { $action.Name = 'back'; return }
                    default { if ($k.KeyChar -eq '?') { $action.Name = 'help'; return } }
                }
            }
        }
        if ($ui.HardQuit) { return }
        switch ($action.Name) {
            'back' { return }
            'help' { Show-PSMMHelpScreen -Topic 'tasks' }
            'view' {
                $tasks = @(Get-PSMMTask)
                if ($tasks.Count -and $st.Cursor -lt $tasks.Count) {
                    $t = $tasks[$st.Cursor]
                    $lines = @("task: $($t.Label)", "state: $(if (-not $t.Done) { 'running' } elseif ($t.Failed) { 'failed' } else { 'done' })", '') + @($t.Output | ForEach-Object { "$_" })
                    Show-PSMMPager -Lines $lines -TitleMarkup "[$script:PSMM_ColAccent]Task output[/]"
                }
            }
        }
    }
}
