# 10-Grid.ps1 — the main module grid: the psmm home screen.
# Direct Spectre.Console construction in the hot path (~1-2 ms/frame; the
# cmdlet wrappers cost ~60 ms/call - unacceptable per keypress).

# Targets for a bulk action: selected rows, else the cursor row.
function script:Get-PSMMTargets {
    if ($script:PSMM_UI.Sel.Count) { return @($script:PSMM_UI.Sel | Sort-Object) }
    if ($script:PSMM_UI.View.Count) { return @($script:PSMM_UI.View[$script:PSMM_UI.Cursor]) }
    @()
}

# Build the grid renderable (table + header + hints + overlays) from cached
# state only - no disk or network access here.
function script:Build-PSMMGrid {
    $ui = $script:PSMM_UI
    $entries = $ui.Entries
    # filtered view: array of entry indices currently visible
    $ui.View = if ($ui.Filter) {
        @(0..([Math]::Max(0, $entries.Count - 1)) | Where-Object {
            $entries[$_].Name -like "*$($ui.Filter)*" -or $entries[$_].FriendlyName -like "*$($ui.Filter)*"
        })
    } elseif ($entries.Count) { @(0..($entries.Count - 1)) } else { @() }
    $n = $ui.View.Count
    $win = Get-PSMMWinSize
    $vp = Get-PSMMViewport -State $ui -Count $n -Rows ($win.Height - 11)   # heading + footer + overlay rows

    # name column width budget from window width (scope column costs ~6)
    $nameCap = [Math]::Max(14, $win.Width - 84)

    $T = [Spectre.Console.Table]::new()
    $T.Border = [Spectre.Console.TableBorder]::Rounded
    foreach ($h in ' ', 'Sel', 'Name', 'Src', 'Mode', 'Inst', 'Scope', 'State', 'Ver', '!') {
        [void][Spectre.Console.TableExtensions]::AddColumn($T, $h)
    }
    for ($v = $vp.First; $v -le $vp.Last; $v++) {
        $idx = $ui.View[$v]
        $e = $entries[$idx]
        $isCur = ($v -eq $ui.Cursor)
        $isUnmanaged = [bool]$e.PSObject.Properties['Unmanaged']
        $box = if ($ui.Sel.Contains($idx)) { '[green][[x]][/]' } else { "[$script:PSMM_ColMute][[ ]][/]" }
        $state = if ($isUnmanaged) { '[dodgerblue1]unmanaged[/]' }
                 elseif ($e.Loaded) { '[green]loaded[/]' }
                 elseif ($e.Installed) { '[yellow]installed[/]' }
                 else { '[red]missing[/]' }
        $src = switch ($e.Source) {
            '<profile inline>' { 'profile' }
            '<unmanaged>'      { '-' }
            default            { Split-Path $e.Source -Leaf }
        }
        $rw = if ($isUnmanaged) { '' } elseif ($e.Writable) { ' [grey]rw[/]' } else { ' [grey]ro[/]' }
        $name = ConvertTo-PSMMSafe (Get-PSMMTrunc $e.Name $nameCap)
        if ($isCur) { $name = "[$script:PSMM_ColAccent]$name[/]" }
        $scope = switch ($e.InstallScope) {
            'CurrentUser' { 'user' }
            'AllUsers'    { if ($ui.Elevated) { 'all' } else { 'all [grey]ro[/]' } }
            'mixed'       { '[yellow]mixed[/]' }
            default       { '-' }
        }
        $ver = if ($e.LoadedVersion) { "$($e.LoadedVersion)" } elseif ($e.InstalledVersion) { "$($e.InstalledVersion)" } else { '-' }
        if ($e.UpdateAvailable) { $ver = "$ver [yellow]^[/]" }
        if ($e.PinnedExact) { $ver = "$ver [grey]pin[/]" }
        $cur = if ($isCur) { "[$script:PSMM_ColAccent]>[/]" } else { ' ' }
        $flag = if ($e.Issues.Count) { '[red]![/]' } else { ' ' }
        [void][Spectre.Console.TableExtensions]::AddRow($T, [string[]]@(
                $cur, $box, $name, "$(ConvertTo-PSMMSafe (Get-PSMMTrunc $src 16))$rw",
                $e.Mode, $e.Install, $scope, $state, $ver, $flag))
    }

    $sel = $ui.Sel.Count
    $pos = Get-PSMMPositionMarkup -State $ui -Count $n -Viewport $vp
    $flt = Get-PSMMFilterMarkup -State $ui
    $head = if ($sel) { "[green]$sel selected[/]$pos$flt" } else { "[$script:PSMM_ColMute]none selected[/]$pos$flt" }

    # two short hint rows (a single long row collapses to '...' when narrow)
    $hintNav, $hintAct = if ($ui.FilterMode) {
        (Get-PSMMHint -Pairs @('type=filter', 'enter=apply', 'esc=clear & exit filter')),
        (Get-PSMMHint -Pairs @('up/dn=move'))
    } else {
        (Get-PSMMHint -Pairs @('up/dn=move', 'space=select', 'enter=actions', '/=search', '?=help', 'esc=quit')),
        (Get-PSMMHint -Pairs @('^L=load', '^U=unload', '^P=install', 'u=updates', 'a=add', 'g=gallery', 'x=cleanup', 'f=files', 'c=conflicts', 't=tasks', 'm=unmanaged', 'r=reload'))
    }

    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColAccent]PS Session Module Manager[/] [$script:PSMM_ColMute](psmm · $($ui.Engine)$(if ($ui.Elevated) { ' · elevated' }))[/]"))
    $items.Add($T)
    $items.Add([Spectre.Console.Markup]::new($head))
    $items.Add([Spectre.Console.Markup]::new($hintNav))
    $items.Add([Spectre.Console.Markup]::new($hintAct))

    # deferred-startup job status (from Invoke-PSMMStartup)
    $jline = Get-PSMMStartupJobMarkup
    if ($jline) { $items.Add([Spectre.Console.Markup]::new($jline)) }

    # background tasks side overlay (#25) - one unobtrusive line
    $ts = Get-PSMMTaskSummary
    if ($ts) {
        $spin = if ($ts.RunningCount) { '[deepskyblue1]~[/] ' } else { '' }
        $items.Add([Spectre.Console.Markup]::new("$spin[$script:PSMM_ColMute]tasks: $(ConvertTo-PSMMSafe $ts.Text)  (t=details)[/]"))
    }

    # unmanaged notice, once the scan is in and the rows are hidden
    if ($ui.Unmanaged -and -not $ui.ShowUnmanaged -and @($ui.Unmanaged).Count) {
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColMute]$(@($ui.Unmanaged).Count) installed module(s) not in your config - m shows them[/]"))
    }

    $warnings = Get-PSMMWarning
    if ($warnings.Count) { $items.Add([Spectre.Console.Markup]::new("[yellow]$($warnings.Count) config warning(s) - press f or c for details[/]")) }
    if ($ui.Status) { $items.Add([Spectre.Console.Markup]::new($ui.Status)) }
    [Spectre.Console.Rows]::new($items)
}

# Markup line for the deferred startup job ('' when idle/no job).
function script:Get-PSMMStartupJobMarkup {
    $j = Get-PSMMStartupJob
    if (-not $j) { return '' }
    $total = Get-PSMMStartupJobTotal
    if ($j.State -in 'NotStarted', 'Running') {
        $done = 0; try { $done = @(Receive-Job -Job $j -Keep -ErrorAction SilentlyContinue).Count } catch { }
        return "[$script:PSMM_ColMute]background startup: $done/$total module task(s) done...[/]"
    }
    if ($j.State -eq 'Completed') {
        $out = @(); try { $out = @(Receive-Job -Job $j -Keep -ErrorAction SilentlyContinue) } catch { }
        $fails = @($out | Where-Object { "$_" -like 'FAILED *' } | ForEach-Object { if ("$_" -match '^FAILED\s+([^:]+)') { $Matches[1] } })
        if ($fails.Count) { return "[yellow]background startup: $($fails.Count) of $total FAILED - $(ConvertTo-PSMMSafe ($fails -join ', ')) (Ctrl+P on the row retries)[/]" }
        return "[green]background startup: all $total module task(s) ok[/]"
    }
    if ($j.State -in 'Failed', 'Stopped') { return '[red]background startup job failed - see t (tasks)[/]' }
    ''
}

# Quiet, fast actions that stay inside the live grid. $Context lets us
# repaint a "working on X..." status BEFORE each module so the user always
# sees the keypress registered (#5).
function script:Invoke-PSMMBulk {
    param([ValidateSet('Load', 'Unload')][string]$Action, $Context)
    $ui = $script:PSMM_UI
    $targets = Get-PSMMTargets
    $ok = 0; $fail = 0; $i = 0
    foreach ($t in $targets) {
        $e = $ui.Entries[$t]; $i++
        $verbing = if ($Action -eq 'Load') { 'loading' } else { 'unloading' }
        $ui.Status = "[$script:PSMM_ColAccent]$verbing $(ConvertTo-PSMMSafe $e.Name) ($i/$($targets.Count))...[/]"
        if ($Context) { $Context.UpdateTarget((Build-PSMMGrid)); $Context.Refresh() }
        try {
            if ($Action -eq 'Load') { $null = Import-Module -Name $e.Name -Force -ErrorAction Stop -WarningAction SilentlyContinue }
            else { Remove-Module -Name $e.Name -Force -ErrorAction Stop }
            $ok++
        } catch { $fail++ }
        Update-PSMMLoaded -Entries $ui.Entries
        if ($Context) { $Context.UpdateTarget((Build-PSMMGrid)); $Context.Refresh() }
    }
    $ui.Sel.Clear()
    $verb = if ($Action -eq 'Load') { 'loaded' } else { 'unloaded' }
    $ui.Status = if ($fail) { "[yellow]$verb $ok, $fail failed[/]" } else { "[green]$verb $ok[/]" }
}

# Launch install/update of the targeted rows as a BACKGROUND task (#25):
# the grid stays fully usable; the overlay shows progress; state refreshes
# when the task lands (see Receive-PSMMUITask).
function script:Start-PSMMInstallTask {
    $ui = $script:PSMM_UI
    $targets = Get-PSMMTargets
    if (-not $targets.Count) { return }
    $mods = @(foreach ($t in $targets) {
        $e = $ui.Entries[$t]
        [pscustomobject]@{ Name = $e.Name; Update = [bool]$e.Installed; Version = $e.Version }
    })
    $names = @($mods.Name)
    $null = Start-PSMMTask -Label "install/update: $($names -join ', ')" -Kind 'install' -Data $names -ArgumentList (, $mods) -ScriptBlock {
        param($mods)
        foreach ($m in $mods) {
            try {
                $psrg = [bool](Get-Command Install-PSResource -ErrorAction SilentlyContinue)
                if ($psrg) {
                    if ($m.Version) { Install-PSResource -Name $m.Name -Version $m.Version -Scope CurrentUser -TrustRepository -Reinstall:$m.Update -ErrorAction Stop }
                    elseif ($m.Update -and (Get-Command Update-PSResource -ErrorAction SilentlyContinue) -and (Get-Module -ListAvailable -Name $m.Name)) { Update-PSResource -Name $m.Name -ErrorAction Stop }
                    else { Install-PSResource -Name $m.Name -Scope CurrentUser -TrustRepository -ErrorAction Stop }
                } else {
                    Install-Module -Name $m.Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                }
                "ok $($m.Name)"
            } catch { "FAILED $($m.Name): $($_.Exception.Message)" }
        }
    }
    $ui.Sel.Clear()
    $ui.Status = "[$script:PSMM_ColAccent]install/update of $($names.Count) module(s) started in the background - grid stays usable[/]"
}

# Opt-in update check (key 'u') as a background task - network-bound, so it
# never blocks the grid and never runs automatically.
function script:Start-PSMMUpdateCheckTask {
    $ui = $script:PSMM_UI
    $installed = @($ui.Entries | Where-Object { $_.Installed -and -not $_.PSObject.Properties['Unmanaged'] })
    if (-not $installed.Count) { $ui.Status = '[yellow]no installed modules to check[/]'; return }
    $payload = @($installed | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Installed = "$($_.InstalledVersion)" } })
    $null = Start-PSMMTask -Label "update check ($($payload.Count) modules)" -Kind 'updatecheck' -ArgumentList (, $payload) -ScriptBlock {
        param($mods)
        $psrg = [bool](Get-Command Find-PSResource -ErrorAction SilentlyContinue)
        foreach ($m in $mods) {
            try {
                $latest = if ($psrg) {
                    (Find-PSResource -Name $m.Name -ErrorAction Stop |
                        Sort-Object { [version]($_.Version -replace '-.*$', '') } -Descending |
                        Select-Object -First 1).Version
                } else {
                    (Find-Module -Name $m.Name -ErrorAction Stop).Version
                }
                if ($latest) { [pscustomobject]@{ Name = $m.Name; Latest = "$latest" } }
            } catch { }
        }
    }
    $ui.Status = "[$script:PSMM_ColAccent]update check started in the background (t=details)[/]"
}

# The live grid loop. Returns a command hashtable for full-screen actions.
function script:Invoke-PSMMGrid {
    $ui = $script:PSMM_UI
    $result = @{ Cmd = 'quit' }
    Clear-PSMMScreen
    Invoke-PSMMLive -Body {
        param($ctx)
        while ($true) {
            Receive-PSMMUITask
            $ctx.UpdateTarget((Build-PSMMGrid)); $ctx.Refresh()
            $k = Read-PSMMKeyResize
            if ($null -eq $k) { continue }   # resize or background activity: re-render
            $ui = $script:PSMM_UI
            $ui.Status = ''
            $n = $ui.View.Count
            $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
            if (Test-PSMMHardQuitKey $k) { $ui.HardQuit = $true; $result.Cmd = 'quit'; return }

            # ---- filter (search) mode: typed characters edit the filter ----
            if ($ui.FilterMode) {
                $r = Invoke-PSMMFilterKey -State $ui -KeyInfo $k
                if ($r) { continue }
                $null = Invoke-PSMMListNav -State $ui -KeyInfo $k -Count $n
                continue
            }

            if (Invoke-PSMMListNav -State $ui -KeyInfo $k -Count $n) { continue }

            switch ($k.Key) {
                ([ConsoleKey]::Spacebar) {
                    if ($n) {
                        $idx = $ui.View[$ui.Cursor]
                        if ($ui.Sel.Contains($idx)) { [void]$ui.Sel.Remove($idx) }
                        else { [void]$ui.Sel.Add($idx) }
                    }
                    continue
                }
                ([ConsoleKey]::Enter) {
                    if ($n) { $result.Cmd = 'submenu'; $result.Index = $ui.View[$ui.Cursor]; return }
                    continue
                }
                ([ConsoleKey]::RightArrow) {
                    # "move into" the module (#24) - same as enter
                    if ($n) { $result.Cmd = 'submenu'; $result.Index = $ui.View[$ui.Cursor]; return }
                    continue
                }
                ([ConsoleKey]::Escape) {
                    if ($ui.Filter) { $ui.Filter = ''; $ui.Cursor = 0; continue }
                    $result.Cmd = 'quit'; return
                }
                ([ConsoleKey]::L) { if ($ctrl) { Invoke-PSMMBulk -Action Load -Context $ctx }; continue }
                ([ConsoleKey]::U) {
                    if ($ctrl) { Invoke-PSMMBulk -Action Unload -Context $ctx } else { Start-PSMMUpdateCheckTask }
                    continue
                }
                ([ConsoleKey]::P) { if ($ctrl) { Start-PSMMInstallTask }; continue }
                ([ConsoleKey]::A) { if (-not $ctrl) { $result.Cmd = 'add'; return }; continue }
                ([ConsoleKey]::C) { if (-not $ctrl) { $result.Cmd = 'conflicts'; return }; continue }
                ([ConsoleKey]::R) { if (-not $ctrl) { $result.Cmd = 'reload'; return }; continue }
                ([ConsoleKey]::F) { if (-not $ctrl) { $result.Cmd = 'files'; return }; continue }
                ([ConsoleKey]::G) { if (-not $ctrl) { $result.Cmd = 'gallery'; return }; continue }
                ([ConsoleKey]::X) { if (-not $ctrl) { $result.Cmd = 'cleanup'; return }; continue }
                ([ConsoleKey]::T) { if (-not $ctrl) { $result.Cmd = 'tasks'; return }; continue }
                ([ConsoleKey]::H) { if (-not $ctrl) { $result.Cmd = 'help'; return }; continue }
                ([ConsoleKey]::M) {
                    if (-not $ctrl) {
                        if ($ui.Unmanaged) {
                            $ui.ShowUnmanaged = -not $ui.ShowUnmanaged
                            Sync-PSMMUIEntries
                            $ui.Status = if ($ui.ShowUnmanaged) { "[green]showing $(@($ui.Unmanaged).Count) unmanaged module(s)[/]" } else { '[grey]unmanaged modules hidden[/]' }
                        } else {
                            $ui.Status = '[yellow]unmanaged scan still running (t=details)[/]'
                        }
                    }
                    continue
                }
                ([ConsoleKey]::Oem2) {
                    # '/' and '?' share this key on most layouts - split by char
                    if ($k.KeyChar -eq '?') { $result.Cmd = 'help'; return }
                    $ui.FilterMode = $true
                    continue
                }
                default {
                    if ($k.KeyChar -eq '/') { $ui.FilterMode = $true }
                    elseif ($k.KeyChar -eq '?') { $result.Cmd = 'help'; return }
                }
            }
        }
    }
    $result
}
