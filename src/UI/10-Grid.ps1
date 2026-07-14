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
    $vp = Get-PSMMViewport -State $ui -Count $n -Rows ($win.Height - 12)   # heading + footer + overlay rows

    # Build EVERY row of the filtered view (not just the viewport) so column
    # widths come from ALL content: scrolling never resizes the table
    # (2026-07-05 live-run feedback: width jitter). ponytail: O(rows) markup
    # strip per frame - fine to a few hundred entries.
    # The Name cell stays RAW here; it is capped, escaped and styled below,
    # once the other columns' widths are known - the old fixed "width - 84"
    # budget under-reserved and let the table outgrow the terminal, which
    # Spectre renders as a bare '...'.
    $rows = [System.Collections.Generic.List[string[]]]::new()
    for ($v = 0; $v -lt $n; $v++) {
        $idx = $ui.View[$v]
        $e = $entries[$idx]
        $isCur = ($v -eq $ui.Cursor)
        $isUnmanaged = [bool]$e.PSObject.Properties['Unmanaged']
        $box = if ($ui.Sel.Contains($idx)) { '[green3][[x]][/]' } else { "[$script:PSMM_ColMute][[ ]][/]" }
        $state = if ($isUnmanaged) { '[steelblue1]unmanaged[/]' }
                 elseif ($e.Loaded) { '[green3]loaded[/]' }
                 elseif ($e.Installed) { '[orange1]installed[/]' }
                 else { '[indianred1]missing[/]' }
        $src = switch ($e.Source) {
            '<profile inline>' { 'profile' }
            '<unmanaged>'      { '-' }
            default            { Split-Path $e.Source -Leaf }
        }
        $rw = if ($isUnmanaged) { '' } elseif ($e.Writable) { ' [grey66]rw[/]' } else { ' [grey66]ro[/]' }
        $name = "$($e.Name)"
        $scope = switch ($e.InstallScope) {
            'CurrentUser' { 'user' }
            'AllUsers'    { if ($ui.Elevated) { 'all' } else { 'all [grey66]ro[/]' } }
            'mixed'       { '[orange1]mixed[/]' }
            default       { '-' }
        }
        $ver = if ($e.LoadedVersion) { "$($e.LoadedVersion)" } elseif ($e.InstalledVersion) { "$($e.InstalledVersion)" } else { '-' }
        # '↑', not '^': the design system reserves '^' for the ctrl legend
        if ($e.UpdateAvailable) { $ver = "$ver [orange1]$([char]0x2191)[/]" }
        if ($e.PinnedExact) { $ver = "$ver [grey66]pin[/]" }
        $cur = if ($isCur) { "[$script:PSMM_ColAccent]>[/]" } else { ' ' }
        $flag = if ($e.Issues.Count) { '[indianred1]![/]' } else { ' ' }
        $rows.Add([string[]]@(
                $cur, $box, $name, "$(ConvertTo-PSMMSafe (Get-PSMMTrunc $src 16))$rw",
                $e.Mode, $e.Install, $scope, $state, $ver, $flag))
    }

    $headers = @(' ', 'Sel', 'Name', 'Src', 'Mode', 'Inst', 'Scope', 'State', 'Ver', '!')
    $widths = @(foreach ($h in $headers) { $h.Length })
    for ($ci = 0; $ci -lt $headers.Count; $ci++) {
        foreach ($r in $rows) {
            # column 2 (Name) is still raw text, everything else is markup
            $len = if ($ci -eq 2) { $r[2].Length } else { [Spectre.Console.Markup]::Remove($r[$ci]).Length }
            if ($len -gt $widths[$ci]) { $widths[$ci] = $len }
        }
    }
    # Exact fit: content + 2 padding per column + 11 border verticals. The
    # Name column flexes down to 14 chars; below the resulting minimum,
    # Spectre would collapse the table to a bare '...' - render a clear
    # too-small message instead (design system: too-small terminal).
    $overhead = (2 * $headers.Count) + $headers.Count + 1
    $fixed = ($widths | Measure-Object -Sum).Sum - $widths[2]
    $minName = [Math]::Min($widths[2], 14)
    if ($win.Width -lt ($fixed + $overhead + $minName) -or $win.Height -lt 14) {
        return (Get-PSMMTooSmallView -MinWidth ($fixed + $overhead + $minName) -MinHeight 14)
    }
    $nameCap = [Math]::Min($widths[2], [Math]::Max(14, $win.Width - $overhead - $fixed))
    $widths[2] = $nameCap
    for ($v = 0; $v -lt $n; $v++) {
        $nm = ConvertTo-PSMMSafe (Get-PSMMTrunc $rows[$v][2] $nameCap)
        if ($v -eq $ui.Cursor) { $nm = "[$script:PSMM_ColAccent]$nm[/]" }
        $rows[$v][2] = $nm
    }

    $T = [Spectre.Console.Table]::new()
    $T.Border = [Spectre.Console.TableBorder]::Rounded
    for ($ci = 0; $ci -lt $headers.Count; $ci++) {
        $col = [Spectre.Console.TableColumn]::new($headers[$ci])
        $col.Width = $widths[$ci]
        $col.NoWrap = $true
        [void]$T.AddColumn($col)
    }
    for ($v = $vp.First; $v -le $vp.Last; $v++) {
        [void][Spectre.Console.TableExtensions]::AddRow($T, $rows[$v])
    }
    # pad very short lists with blank rows so a fresh one-entry grid doesn't
    # look collapsed (2026-07-05 feedback)
    for ($pad = $n; $pad -lt 5; $pad++) {
        [void][Spectre.Console.TableExtensions]::AddRow($T, [string[]](@('') * 10))
    }

    $sel = $ui.Sel.Count
    $pos = Get-PSMMPositionMarkup -State $ui -Count $n -Viewport $vp
    $flt = Get-PSMMFilterMarkup -State $ui
    $head = if ($sel) { "[green3]$sel selected[/]$pos$flt" } else { "[$script:PSMM_ColMute]none selected[/]$pos$flt" }

    # short hint rows (a single long row collapses to '...' when narrow):
    # navigation, module verbs, screen switching (design system row order)
    $hintRows = if ($ui.FilterMode) {
        @(
            (Get-PSMMHint -Pairs @('type=filter', 'enter=apply', 'esc=clear & exit filter')),
            (Get-PSMMHint -Pairs @('up/dn=move'))
        )
    } else {
        @(
            (Get-PSMMHint -Pairs @('up/dn=move', 'space=select', 'enter=actions', '/=search', '?=help', 'esc=quit')),
            (Get-PSMMHint -Pairs @('^l=load', '^u=unload', 'i=install', 'u=update', 'k=check updates', 'r=reload')),
            (Get-PSMMHint -Pairs @('a=add', 'g=gallery', 'x=cleanup', 'f=files', 'p=paths', 'c=conflicts', 't=tasks', 'm=unmanaged'))
        )
    }

    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColAccent]PS Session Module Manager[/] [$script:PSMM_ColMute](psmm · $($ui.Engine)$(if ($ui.Elevated) { ' · elevated' }))[/]"))
    $items.Add($T)
    $items.Add([Spectre.Console.Markup]::new($head))
    foreach ($hr in $hintRows) { $items.Add([Spectre.Console.Markup]::new($hr)) }

    # deferred-startup job status (from Invoke-PSMMStartup)
    $jline = Get-PSMMStartupJobMarkup
    if ($jline) { $items.Add([Spectre.Console.Markup]::new($jline)) }

    # background tasks side overlay (#25) - one unobtrusive line
    $ts = Get-PSMMTaskSummary
    if ($ts) {
        $spin = if ($ts.RunningCount) { '[steelblue1]~[/] ' } else { '' }
        $items.Add([Spectre.Console.Markup]::new("$spin[$script:PSMM_ColMute]tasks: $(ConvertTo-PSMMSafe $ts.Text)  (t=details)[/]"))
    }

    # unmanaged notice, once the scan is in and the rows are hidden
    if ($ui.Unmanaged -and -not $ui.ShowUnmanaged -and @($ui.Unmanaged).Count) {
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColMute]$(@($ui.Unmanaged).Count) installed module(s) not in your config - m shows them[/]"))
    }

    # standing OneDrive diagnosis (cached at init - no per-frame path checks)
    if ($ui.OneDrivePrimary) {
        $items.Add([Spectre.Console.Markup]::new('[orange1]primary module location is inside OneDrive - cloud-only files can break loading (p=details)[/]'))
    }

    $warnings = Get-PSMMWarning
    if ($warnings.Count) { $items.Add([Spectre.Console.Markup]::new("[orange1]$($warnings.Count) config warning(s) - press f or c for details[/]")) }
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
        if ($fails.Count) { return "[orange1]background startup: $($fails.Count) of $total FAILED - $(ConvertTo-PSMMSafe ($fails -join ', ')) (i on the row retries)[/]" }
        return "[green3]background startup: all $total module task(s) ok[/]"
    }
    if ($j.State -in 'Failed', 'Stopped') { return '[indianred1]background startup job failed - see t (tasks)[/]' }
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
        # cloud-only files hydrate silently here (no prompt inside the live
        # grid) - the status line shows what is happening and why it may wait
        if ($Action -eq 'Load') {
            $cloud = @(Get-PSMMModuleCloudOnlyFile -Name $e.Name)
            if ($cloud.Count) {
                $ui.Status = "[orange1]downloading $($cloud.Count) cloud-only file(s) for $(ConvertTo-PSMMSafe $e.Name) from OneDrive...[/]"
                if ($Context) { $Context.UpdateTarget((Build-PSMMGrid)); $Context.Refresh() }
                $null = Invoke-PSMMFileHydration -Files $cloud
            }
        }
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
    $ui.Status = if ($fail) { "[orange1]$verb $ok, $fail failed[/]" } else { "[green3]$verb $ok[/]" }
}

# Launch install (or update, with -Update) of the targeted rows as a
# BACKGROUND task (#25): the grid stays fully usable; the overlay shows
# progress; state refreshes when the task lands (see Receive-PSMMUITask).
# Install and update are separate actions on separate keys (design system):
# 'i' installs the targets that are missing, 'u' updates the installed ones.
function script:Start-PSMMInstallTask {
    param([switch]$Update)
    $ui = $script:PSMM_UI
    $verb = if ($Update) { 'update' } else { 'install' }
    $targets = @(Get-PSMMTargets | Where-Object {
        $e = $ui.Entries[$_]
        if ($Update) { [bool]$e.Installed } else { -not $e.Installed }
    })
    if (-not $targets.Count) {
        $ui.Status = if ($Update) { '[orange1]nothing to update - no installed module targeted (i installs missing ones)[/]' }
                     else { '[orange1]nothing to install - every targeted module is already installed (u updates)[/]' }
        return
    }
    $mods = @(foreach ($t in $targets) {
        $e = $ui.Entries[$t]
        [pscustomobject]@{ Name = $e.Name; Update = [bool]$Update; Version = $e.Version }
    })
    $names = @($mods.Name)
    $null = Start-PSMMTask -Label "${verb}: $($names -join ', ')" -Kind 'install' -Data $names -ArgumentList (, $mods) -ScriptBlock {
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
    $ui.Status = "[$script:PSMM_ColAccent]$verb of $($names.Count) module(s) started in the background - grid stays usable[/]"
}

# Opt-in update check (key 'k') as a background task - network-bound, so it
# never blocks the grid and never runs automatically.
function script:Start-PSMMUpdateCheckTask {
    $ui = $script:PSMM_UI
    $installed = @($ui.Entries | Where-Object { $_.Installed -and -not $_.PSObject.Properties['Unmanaged'] })
    if (-not $installed.Count) { $ui.Status = '[orange1]no installed modules to check[/]'; return }
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
                    if ($ctrl) { Invoke-PSMMBulk -Action Unload -Context $ctx } else { Start-PSMMInstallTask -Update }
                    continue
                }
                ([ConsoleKey]::I) { if (-not $ctrl) { Start-PSMMInstallTask }; continue }
                ([ConsoleKey]::K) { if (-not $ctrl) { Start-PSMMUpdateCheckTask }; continue }
                ([ConsoleKey]::P) { if (-not $ctrl) { $result.Cmd = 'paths'; return }; continue }
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
                            $ui.Status = if ($ui.ShowUnmanaged) { "[green3]showing $(@($ui.Unmanaged).Count) unmanaged module(s)[/]" } else { '[grey66]unmanaged modules hidden[/]' }
                        } else {
                            $ui.Status = '[orange1]unmanaged scan still running (t=details)[/]'
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
