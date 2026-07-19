# 30-Commands.ps1 — command browser + tabbed per-command help.
# Search here now matches every other screen: '/' enters filter mode, typing
# outside filter mode does nothing (#19, #20, #21).

function script:Build-PSMMCommandListView {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Commands,   # full list
        [Parameter(Mandatory)] $View,       # filtered list
        [Parameter(Mandatory)][string]$ModuleName
    )
    if (Test-PSMMWinTooSmall) { return (Get-PSMMTooSmallView) }
    $n = $View.Count
    $win = Get-PSMMWinSize
    $vp = Get-PSMMViewport -State $State -Count $n -Rows ($win.Height - 9)
    $T = [Spectre.Console.Table]::new()
    $T.Border = [Spectre.Console.TableBorder]::Rounded
    foreach ($h in ' ', 'Command', 'Type') { [void][Spectre.Console.TableExtensions]::AddColumn($T, $h) }
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        $c = $View[$i]
        $nm = ConvertTo-PSMMSafe $c.Name
        if ($i -eq $State.Cursor) { $nm = "[$script:PSMM_ColAccent]$nm[/]" }
        [void][Spectre.Console.TableExtensions]::AddRow($T, [string[]]@(
                $(if ($i -eq $State.Cursor) { "[$script:PSMM_ColAccent]>[/]" } else { ' ' }), $nm, "$($c.CommandType)"))
    }
    $pos = Get-PSMMPositionMarkup -State $State -Count $n -Viewport $vp
    $of = if ($n -ne $Commands.Count) { " [$script:PSMM_ColMute](of $($Commands.Count))[/]" } else { '' }
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColAccent]Commands in $(ConvertTo-PSMMSafe $ModuleName)[/]$pos$of$(Get-PSMMFilterMarkup -State $State)"))
    $items.Add($T)
    if ($State.FilterMode) {
        $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('type=filter', 'enter=apply', 'esc=clear & exit filter', 'up/dn=move'))))
    } else {
        $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('enter=details'))))
        $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", '/=filter', '?=help', 'esc=back', '^q=quit'))))
    }
    [Spectre.Console.Rows]::new($items)
}

function script:Show-PSMMCommands {
    param([Parameter(Mandatory)] $Entry)
    $ui = $script:PSMM_UI
    $cmds = @()
    try { $cmds = @(Get-Command -Module $Entry.Name -ErrorAction Stop | Sort-Object CommandType, Name) } catch { }
    if (-not $cmds.Count) {
        Clear-PSMMScreen
        Write-PSMMLine "[$script:PSMM_ColAccent]Commands in $(ConvertTo-PSMMSafe $Entry.Name)[/]"
        Write-PSMMLine '[orange1]No commands available (install/import the module first).[/]'
        $null = Wait-PSMMKey -Message 'back'
        return
    }

    $st = New-PSMMListState
    $pick = @{ Name = $null }
    while ($true) {
        if ($ui.HardQuit -or $ui.Goto) { return }
        $pick.Name = $null
        Clear-PSMMScreen
        Invoke-PSMMLive -Body {
            param($ctx)
            while ($true) {
                if ($script:PSMM_UI.HardQuit) { return }
                $view = if ($st.Filter) { @($cmds | Where-Object { $_.Name -like "*$($st.Filter)*" }) } else { $cmds }
                $ctx.UpdateTarget((Build-PSMMCommandListView -State $st -Commands $cmds -View $view -ModuleName $Entry.Name))
                $ctx.Refresh()
                $k = Read-PSMMKeyResize
                if ($null -eq $k) { continue }
                if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; return }
                if ($st.FilterMode) {
                    $r = Invoke-PSMMFilterKey -State $st -KeyInfo $k
                    if ($r) { continue }
                    $null = Invoke-PSMMListNav -State $st -KeyInfo $k -Count $view.Count
                    continue
                }
                if ($k.KeyChar -eq 'g') {
                    $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMCommandListView -State $st -Commands $cmds -View $view -ModuleName $Entry.Name) -Context $ctx
                    if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                    continue
                }
                if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
                if (Invoke-PSMMListNav -State $st -KeyInfo $k -Count $view.Count) { continue }
                switch ($k.Key) {
                    ([ConsoleKey]::Escape) {
                        if ($st.Filter) { $st.Filter = ''; $st.Cursor = 0; continue }
                        return
                    }
                    ([ConsoleKey]::Enter) {
                        if ($view.Count) { $pick.Name = $view[$st.Cursor].Name; return }
                        continue
                    }
                    ([ConsoleKey]::RightArrow) {
                        # drill into the command's help (#24)
                        if ($view.Count) { $pick.Name = $view[$st.Cursor].Name; return }
                        continue
                    }
                    ([ConsoleKey]::LeftArrow) { if (-not $st.Filter) { return }; continue }   # back out (#24)
                    ([ConsoleKey]::Oem2) {
                        if ($k.KeyChar -ne '?') { $st.FilterMode = $true; continue }
                    }
                    default { if ($k.KeyChar -eq '/') { $st.FilterMode = $true } }
                }
                if ($k.KeyChar -eq '?') { Show-PSMMHelpScreen -Topic 'commands'; Clear-PSMMScreen }
            }
        }
        if ($ui.HardQuit) { return }
        if ($pick.Name) { Show-PSMMCommandDetail -Name $pick.Name }   # runs its own live display AFTER this one ended
        else { return }                                               # esc with no filter -> back
    }
}

# Build one frame of the tabbed command help. Handles small terminals (#10):
# the tab bar is its own short row (never crops), and the body panel height
# adapts to the window with a hard minimum.
function script:Build-PSMMCommandDetailView {
    param(
        [Parameter(Mandatory)] $State,      # @{ Tab; Scroll; Status }
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)] $Content,    # @{ Overview; Parameters; Examples }
        [Parameter(Mandatory)][string[]]$Tabs
    )
    $lines = @($Content[$Tabs[$State.Tab]] -split "`r?`n")
    $win = Get-PSMMWinSize
    $page = [Math]::Max(3, $win.Height - 8)
    $State.Scroll = [Math]::Max(0, [Math]::Min($State.Scroll, [Math]::Max(0, $lines.Count - $page)))
    $body = ($lines | Select-Object -Skip $State.Scroll -First $page | ForEach-Object { ConvertTo-PSMMSafe $_ }) -join "`n"
    $tabBar = (0..($Tabs.Count - 1) | ForEach-Object {
        if ($_ -eq $State.Tab) { "[$script:PSMM_ColAccent underline]$($Tabs[$_])[/]" } else { "[$script:PSMM_ColMute]$($Tabs[$_])[/]" }
    }) -join '  '
    $pos = if ($lines.Count -gt $page) { "  [$script:PSMM_ColMute]lines $($State.Scroll + 1)-$([Math]::Min($lines.Count, $State.Scroll + $page))/$($lines.Count)[/]" } else { '' }
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    # name and tab bar on SEPARATE short rows: one long markup row collapses
    # to '...' on narrow terminals
    $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColAccent]$(ConvertTo-PSMMSafe $Name)[/]$pos"))
    $items.Add([Spectre.Console.Markup]::new($tabBar))
    $panel = [Spectre.Console.Panel]::new([Spectre.Console.Markup]::new($body))
    $panel.Border = [Spectre.Console.BoxBorder]::Rounded
    $panel.BorderStyle = [Spectre.Console.Style]::Parse($script:PSMM_ColMute)
    $items.Add($panel)
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('left/right=switch tab', 'up/dn=scroll', 'c=copy tab'))))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", 'esc=back', '^q=quit'))))
    if ($State.Status) { $items.Add([Spectre.Console.Markup]::new($State.Status)) }
    [Spectre.Console.Rows]::new($items)
}

# Tabbed, scrollable help for one command: <- -> switch tab, up/dn scroll.
function script:Show-PSMMCommandDetail {
    param([Parameter(Mandatory)][string]$Name)
    $tabs = @('Overview', 'Parameters', 'Examples')
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]loading help for $(ConvertTo-PSMMSafe $Name)...[/]"
    $content = @{
        Overview   = ((Get-Help -Name $Name -ErrorAction SilentlyContinue | Out-String).Trim())
        Parameters = ((Get-Help -Name $Name -Parameter * -ErrorAction SilentlyContinue | Out-String).Trim())
        Examples   = ((Get-Help -Name $Name -Examples -ErrorAction SilentlyContinue | Out-String).Trim())
    }
    foreach ($t in $tabs) { if (-not $content[$t]) { $content[$t] = '(no content - module may need importing for full help)' } }

    $st = @{ Tab = 0; Scroll = 0; Status = '' }
    Clear-PSMMScreen
    Invoke-PSMMLive -Body {
        param($ctx)
        while ($true) {
            if ($script:PSMM_UI.HardQuit) { return }
            $ctx.UpdateTarget((Build-PSMMCommandDetailView -State $st -Name $Name -Content $content -Tabs $tabs))
            $ctx.Refresh()
            $k = Read-PSMMKeyResize
            if ($null -eq $k) { continue }
            if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; return }
            if ($k.KeyChar -eq 'g') {
                $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMCommandDetailView -State $st -Name $Name -Content $content -Tabs $tabs) -Context $ctx
                if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                continue
            }
            if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
            $st.Status = ''
            switch ($k.Key) {
                ([ConsoleKey]::LeftArrow)  { $st.Tab = ($st.Tab + $tabs.Count - 1) % $tabs.Count; $st.Scroll = 0 }
                ([ConsoleKey]::RightArrow) { $st.Tab = ($st.Tab + 1) % $tabs.Count; $st.Scroll = 0 }
                ([ConsoleKey]::Escape)     { return }
                default {
                    if ($k.KeyChar -eq 'c') { $st.Status = Copy-PSMMText -Text $content[$tabs[$st.Tab]] }
                    else { $null = Invoke-PSMMPagerNav -State $st -KeyInfo $k }
                }
            }
        }
    }
    Clear-PSMMScreen
}
