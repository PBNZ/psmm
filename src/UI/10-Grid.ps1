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
    $issueFlags = [System.Collections.Generic.List[bool]]::new()
    $verCol = 5
    $verGhost = 0   # widest version cell WITH its ⇡ target: targets render on
                    # the cursor row only, but the column must reserve their
                    # width so moving the cursor never resizes the table
    for ($v = 0; $v -lt $n; $v++) {
        $idx = $ui.View[$v]
        $e = $entries[$idx]
        $isCur = ($v -eq $ui.Cursor)
        $isUnmanaged = [bool]$e.PSObject.Properties['Unmanaged']
        $state = Get-PSMMStateMarkup -Entry $e
        $src = switch ($e.Source) {
            '<profile inline>' { 'profile' }
            '<unmanaged>'      { '-' }
            default            { [System.IO.Path]::GetFileNameWithoutExtension($e.Source) }
        }
        # read-only is the exception worth marking; rw is the silent default
        $ro = if (-not $isUnmanaged -and -not $e.Writable) { " [$script:PSMM_ColDim]ro[/]" } else { '' }
        $file = "[$script:PSMM_ColDim]$(ConvertTo-PSMMSafe (Get-PSMMTrunc $src 16))[/]$ro"
        $name = "$($e.Name)"
        $scope = switch ($e.InstallScope) {
            'CurrentUser' { "[$script:PSMM_ColDim]user[/]" }
            'AllUsers'    { if ($ui.Elevated) { "[$script:PSMM_ColDim]all[/]" } else { "[$script:PSMM_ColDim]all ro[/]" } }
            'mixed'       { "[$script:PSMM_ColWarn]mixed[/]" }
            default       { "[$script:PSMM_ColDim]-[/]" }
        }
        $startupWord = Get-PSMMStartupWord $e.Mode
        $startup = if ($startupWord -in 'off', '-') { "[$script:PSMM_ColDim]$startupWord[/]" } else { $startupWord }
        $gallery = "[$script:PSMM_ColDim]$(Get-PSMMGalleryWord $e.Install)[/]"
        $verBase = if ($e.LoadedVersion) { "$($e.LoadedVersion)" } elseif ($e.InstalledVersion) { "$($e.InstalledVersion)" } else { '-' }
        $pin = if ($e.PinnedExact) { " [$script:PSMM_ColDim]pin[/]" } else { '' }
        # '⇡', not '^': the design system reserves '^' for the ctrl legend
        $ver = $verBase
        if ($e.UpdateAvailable) {
            $ver = if ($isCur -and $e.LatestVersion) { "$verBase [$script:PSMM_ColWarn]$([char]0x21E1) $($e.LatestVersion)[/]" }
                   else { "$verBase [$script:PSMM_ColWarn]$([char]0x21E1)[/]" }
            if ($e.LatestVersion) {
                $wide = $verBase.Length + 3 + "$($e.LatestVersion)".Length + $(if ($pin) { 4 } else { 0 })
                if ($wide -gt $verGhost) { $verGhost = $wide }
            }
        }
        $ver += $pin
        # the selection dot; the cursor bar is prepended into the same mark
        # slot at render time, one char to its LEFT (mockup 2a) - the bar
        # must never cover the dot (live-run feedback 2026-07-20)
        $mark = if ($ui.Sel.Contains($idx)) { "[$script:PSMM_ColOk]$([char]0x25AA)[/]" } else { ' ' }
        $issueFlags.Add([bool]$e.Issues.Count)
        $rows.Add([string[]]@($mark, $name, $state, $startup, $gallery, $ver, $scope, $file))
    }

    # lowercase + dim headers, plain-word column names (design §5); plain text
    # here for width maths, dim markup applied when the columns are created
    $headers = @(' ', 'module', 'state', 'startup', 'gallery', 'version', 'scope', 'file')
    $nameCol = 1
    $widths = @(foreach ($h in $headers) { $h.Length })
    for ($ci = 0; $ci -lt $headers.Count; $ci++) {
        for ($ri = 0; $ri -lt $rows.Count; $ri++) {
            # the module column is still raw text (styled after capping);
            # issues add a trailing ' ⚠' the width must account for
            $len = if ($ci -eq $nameCol) { $rows[$ri][$nameCol].Length + $(if ($issueFlags[$ri]) { 2 } else { 0 }) }
                   else { [Spectre.Console.Markup]::Remove($rows[$ri][$ci]).Length }
            if ($len -gt $widths[$ci]) { $widths[$ci] = $len }
        }
    }
    if ($verGhost -gt $widths[$verCol]) { $widths[$verCol] = $verGhost }
    # Exact fit: content + 2 padding per column + border verticals. The
    # module column flexes down to 14 chars; below the resulting minimum,
    # Spectre would collapse the table to a bare '...' - render a clear
    # too-small message instead (design system: too-small terminal).
    # column 0 is the mark slot: cursor bar ▌ + selection dot ▪ side by side
    $widths[0] = 2
    # per-column padding (2) + the panel's outer border (2); no inner
    # verticals any more (mockup 2a)
    $overhead = (2 * $headers.Count) + 2
    $fixed = ($widths | Measure-Object -Sum).Sum - $widths[$nameCol]
    $minName = [Math]::Min($widths[$nameCol], 14)
    if ($win.Width -lt ($fixed + $overhead + $minName) -or $win.Height -lt 14) {
        return (Get-PSMMTooSmallView -MinWidth ($fixed + $overhead + $minName) -MinHeight 14)
    }
    $nameCap = [Math]::Min($widths[$nameCol], [Math]::Max(14, $win.Width - $overhead - $fixed))
    $widths[$nameCol] = $nameCap
    for ($v = 0; $v -lt $n; $v++) {
        $cap = if ($issueFlags[$v]) { $nameCap - 2 } else { $nameCap }
        $nm = ConvertTo-PSMMSafe (Get-PSMMTrunc $rows[$v][$nameCol] $cap)
        if ($v -eq $ui.Cursor) { $nm = "[bold $script:PSMM_ColAccent]$nm[/]" }
        if ($issueFlags[$v]) { $nm += " [$script:PSMM_ColErr]$([char]0x26A0)[/]" }
        $rows[$v][$nameCol] = $nm
    }

    # borderless grid in a rounded panel (mockup 2a): outer frame only, no
    # column separators, no header rule. Padding lives INSIDE the cells so
    # the cursor row's background paints edge to edge. In the mark slot the
    # cursor bar sits immediately LEFT of the selection dot - it must never
    # cover it (live-run fix 4).
    $G = [Spectre.Console.Grid]::new()
    for ($ci = 0; $ci -lt $headers.Count; $ci++) {
        $col = [Spectre.Console.GridColumn]::new()
        $col.Padding = [Spectre.Console.Padding]::new(0, 0, 0, 0)
        $col.NoWrap = $true
        [void]$G.AddColumn($col)
    }
    $headerCells = [string[]]@(for ($ci = 0; $ci -lt $headers.Count; $ci++) {
        $h = $headers[$ci].Trim()
        if ($h) { " [$script:PSMM_ColDim]$h[/]" + (' ' * ([Math]::Max(0, $widths[$ci] - $h.Length) + 1)) }
        else { ' ' * ($widths[$ci] + 2) }
    })
    [void][Spectre.Console.GridExtensions]::AddRow($G, $headerCells)
    for ($v = $vp.First; $v -le $vp.Last; $v++) {
        $isCur = ($v -eq $ui.Cursor)
        $cells = [string[]]@(for ($ci = 0; $ci -lt $headers.Count; $ci++) {
            $cell = if ($ci -eq 0) {
                $bar = if ($isCur) { "[$script:PSMM_ColAccent]$([char]0x258C)[/]" } else { ' ' }
                $bar + $rows[$v][0]
            } else { $rows[$v][$ci] }
            $len = [Spectre.Console.Markup]::Remove($cell).Length
            $padded = ' ' + $cell + (' ' * ([Math]::Max(0, $widths[$ci] - $len) + 1))
            if ($isCur) { "[default on $script:PSMM_ColRowBg]$padded[/]" } else { $padded }
        })
        [void][Spectre.Console.GridExtensions]::AddRow($G, $cells)
    }
    # pad very short lists with blank rows so a fresh one-entry grid doesn't
    # look collapsed (2026-07-05 feedback)
    for ($pad = $n; $pad -lt 5; $pad++) {
        [void][Spectre.Console.GridExtensions]::AddRow($G, [string[]]@(foreach ($w in $widths) { ' ' * ($w + 2) }))
    }
    $T = [Spectre.Console.Panel]::new($G)
    $T.Border = [Spectre.Console.BoxBorder]::Rounded
    $T.BorderStyle = Get-PSMMBorderStyle
    $T.Padding = [Spectre.Console.Padding]::new(0, 0, 0, 0)

    $sel = $ui.Sel.Count
    $pos = Get-PSMMPositionMarkup -State $ui -Count $n -Viewport $vp
    $flt = Get-PSMMFilterMarkup -State $ui
    $head = if ($sel) { "[$script:PSMM_ColOk]$([char]0x25AA) $sel selected[/]$pos$flt" } else { "[$script:PSMM_ColMute]none selected[/]$pos$flt" }

    # two tiers (design v2 §3): contextual verb rows, then the persistent
    # strip - navigation letters live in the g goto overlay, not here
    $hintRows = if ($ui.FilterMode) {
        @(
            (Get-PSMMHint -Pairs @('type=filter', 'enter=apply', 'esc=clear & exit filter')),
            (Get-PSMMHint -Pairs @('up/dn=move'))
        )
    } else {
        @(
            (Get-PSMMHint -Pairs @('i=install', 'u=update', 'k=check updates', '^l=load', '^u=unload')),
            (Get-PSMMHint -Pairs @('space=select', 'enter=actions', 'a=add', 'r=reload', 'm=unmanaged')),
            (Get-PSMMPersistentHint)
        )
    }

    $loaded = @($entries | Where-Object { $_.Loaded }).Count
    $updates = @($entries | Where-Object { $_.UpdateAvailable }).Count
    $counts = "$($entries.Count) modules $([char]0x00B7) $loaded loaded$(if ($updates) { " $([char]0x00B7) $updates updates" })"
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb @('home') -CountsMarkup "[$script:PSMM_ColDim]$counts[/]")))
    $items.Add($T)
    $items.Add([Spectre.Console.Markup]::new($head))
    # context sentence for the cursor row (§5): the verbose explanation the
    # plain-word columns don't have to carry
    if ($n) { $items.Add([Spectre.Console.Markup]::new((Get-PSMMContextMarkup -Entry $entries[$ui.View[$ui.Cursor]]))) }
    foreach ($hr in $hintRows) { $items.Add([Spectre.Console.Markup]::new($hr)) }

    # deferred-startup job status (from Invoke-PSMMStartup)
    $jline = Get-PSMMStartupJobMarkup
    if ($jline) { $items.Add([Spectre.Console.Markup]::new($jline)) }

    # background tasks side overlay (#25) - one unobtrusive line
    $ts = Get-PSMMTaskSummary
    if ($ts) {
        $spin = if ($ts.RunningCount) { "[$script:PSMM_ColInfo]~[/] " } else { '' }
        $items.Add([Spectre.Console.Markup]::new("$spin[$script:PSMM_ColMute]tasks: $(ConvertTo-PSMMSafe $ts.Text)  (g t=details)[/]"))
    }

    # unmanaged notice, once the scan is in and the rows are hidden
    if ($ui.Unmanaged -and -not $ui.ShowUnmanaged -and @($ui.Unmanaged).Count) {
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColMute]$(@($ui.Unmanaged).Count) installed module(s) not in your config - m shows them[/]"))
    }

    # newer psmm available: the header bar carries the compact ⇡ flag; the
    # exact update command lives in help › about (v2 §2)

    # standing OneDrive diagnosis (cached at init - no per-frame path checks)
    if ($ui.OneDrivePrimary) {
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColWarn]primary module location is inside OneDrive - cloud-only files can break loading (g p=details)[/]"))
    }

    $warnings = Get-PSMMWarning
    if ($warnings.Count) { $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColWarn]$($warnings.Count) config warning(s) - g f / g c show details[/]")) }
    if ($ui.Status) { $items.Add([Spectre.Console.Markup]::new($ui.Status)) }
    [Spectre.Console.Rows]::new($items)
}

# One muted sentence explaining the cursor row in full words (§5): what the
# entry does at shell start, whether it is imported now, and what is on disk.
function script:Get-PSMMContextMarkup {
    param([Parameter(Mandatory)] $Entry)
    $isUnmanaged = [bool]$Entry.PSObject.Properties['Unmanaged']
    $startup = if ($isUnmanaged) { 'installed but not in any config file' }
               else {
                   switch ("$($Entry.Mode)") {
                       'Load' {
                           switch ("$($Entry.Install)") {
                               'Latest'    { 'imports at shell start, updating to latest first' }
                               'CheckOnly' { 'imports at shell start, never auto-installed' }
                               default     { 'imports at shell start, installing first when missing' }
                           }
                       }
                       'InstallOnly' {
                           switch ("$($Entry.Install)") {
                               'Latest'    { 'background-updates to latest at shell start' }
                               'CheckOnly' { 'checked at shell start, never installed' }
                               default     { 'background-installs at shell start when missing' }
                           }
                       }
                       'Ignore' { 'off - nothing happens at shell start' }
                       default  { 'no startup action' }
                   }
               }
    $session = if ($Entry.Loaded) { "imported this session (v$($Entry.LoadedVersion))" } else { 'not imported this session' }
    $disk = if ($Entry.Installed) {
        $d = "v$($Entry.InstalledVersion) on disk"
        if ($Entry.UpdateAvailable -and $Entry.LatestVersion) { $d += ", v$($Entry.LatestVersion) available (u updates)" }
        if ($Entry.Version) { $d += " - pinned to $($Entry.Version)" }
        $d
    } else { 'not installed' }
    "[$script:PSMM_ColAccent]$(ConvertTo-PSMMSafe $Entry.Name)[/] [$script:PSMM_ColMute]$([char]0x2014) $startup $([char]0x00B7) $session $([char]0x00B7) $(ConvertTo-PSMMSafe $disk)[/]"
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
        if ($fails.Count) { return "[$script:PSMM_ColWarn]background startup: $($fails.Count) of $total FAILED - $(ConvertTo-PSMMSafe ($fails -join ', ')) (i on the row retries)[/]" }
        return "[$script:PSMM_ColOk]background startup: all $total module task(s) ok[/]"
    }
    if ($j.State -in 'Failed', 'Stopped') { return "[$script:PSMM_ColErr]background startup job failed - see t (tasks)[/]" }
    ''
}

# Show/hide the unmanaged rows (grid verb 'm').
function script:Invoke-PSMMUnmanagedToggle {
    $ui = $script:PSMM_UI
    if ($ui.Unmanaged) {
        $ui.ShowUnmanaged = -not $ui.ShowUnmanaged
        Sync-PSMMUIEntries
        $ui.Status = if ($ui.ShowUnmanaged) { "[$script:PSMM_ColOk]showing $(@($ui.Unmanaged).Count) unmanaged module(s)[/]" }
                     else { "[$script:PSMM_ColMute]unmanaged modules hidden[/]" }
    } else {
        $ui.Status = "[$script:PSMM_ColWarn]unmanaged scan still running (g t=details)[/]"
    }
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
                $ui.Status = "[$script:PSMM_ColWarn]downloading $($cloud.Count) cloud-only file(s) for $(ConvertTo-PSMMSafe $e.Name) from OneDrive...[/]"
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
    $ui.Status = if ($fail) { "[$script:PSMM_ColWarn]$verb $ok, $fail failed[/]" } else { "[$script:PSMM_ColOk]$verb $ok[/]" }
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
        $ui.Status = if ($Update) { "[$script:PSMM_ColWarn]nothing to update - no installed module targeted (i installs missing ones)[/]" }
                     else { "[$script:PSMM_ColWarn]nothing to install - every targeted module is already installed (u updates)[/]" }
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
                    # prerelease label of the newest installed copy: a
                    # label-only bump needs Install -Prerelease -Reinstall,
                    # Update-PSResource cannot see it (same logic as
                    # Install-PSMMModule; module functions are out of reach
                    # in this thread job)
                    $pre = $null
                    $newest = @(Get-Module -ListAvailable -Name $m.Name -ErrorAction SilentlyContinue | Sort-Object Version -Descending) | Select-Object -First 1
                    if ($newest) { try { $pre = $newest.PrivateData.PSData.Prerelease } catch { } }
                    if ($m.Version) { Install-PSResource -Name $m.Name -Version $m.Version -Scope CurrentUser -TrustRepository -Reinstall:$m.Update -ErrorAction Stop }
                    elseif ($m.Update -and $newest -and $pre) { Install-PSResource -Name $m.Name -Prerelease -Reinstall -Scope CurrentUser -TrustRepository -ErrorAction Stop }
                    elseif ($m.Update -and (Get-Command Update-PSResource -ErrorAction SilentlyContinue) -and $newest) { Update-PSResource -Name $m.Name -ErrorAction Stop }
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
    if (-not $installed.Count) { $ui.Status = "[$script:PSMM_ColWarn]no installed modules to check[/]"; return }
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
    $ui.Status = "[$script:PSMM_ColAccent]update check started in the background (g t=details)[/]"
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
            # first run ever: float the welcome tips over the freshly painted
            # grid; the next loop pass repaints whatever the erase left behind
            if ($script:PSMM_UI.WelcomeDue) {
                $script:PSMM_UI.WelcomeDue = $false
                Show-PSMMWelcomeOverlay -BaseRenderable (Build-PSMMGrid)
                if ($script:PSMM_UI.HardQuit) { $result.Cmd = 'quit'; return }
                continue
            }
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

            # the g goto layer (v2 §4): overlay + second key; single letters
            # below are verbs only
            if ($k.KeyChar -eq 'g') {
                $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMGrid)
                if ($script:PSMM_UI.HardQuit) { $result.Cmd = 'quit'; return }
                if ($dest -and $dest -ne 'home') {
                    # route through Goto (not Cmd) so the manager knows the
                    # overlay was the source - g ? lands on help - keys
                    $script:PSMM_UI.Goto = $dest
                    $result.Cmd = 'goto'
                    return
                }
                continue
            }

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
                ([ConsoleKey]::A) { if (-not $ctrl) { $result.Cmd = 'add'; return }; continue }
                ([ConsoleKey]::R) { if (-not $ctrl) { $result.Cmd = 'reload'; return }; continue }
                ([ConsoleKey]::M) { if (-not $ctrl) { Invoke-PSMMUnmanagedToggle }; continue }
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
