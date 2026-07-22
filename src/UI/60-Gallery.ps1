# 60-Gallery.ps1 — search & browse the PowerShell Gallery from the UI (#38);
# Enter adds a result straight into a config file.

function script:Build-PSMMGalleryView {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Results,
        [Parameter(Mandatory)][string]$Query,
        [string]$StatusMarkup
    )
    if (Test-PSMMWinTooSmall) { return (Get-PSMMTooSmallView) }
    $n = $Results.Count
    $win = Get-PSMMWinSize
    $vp = Get-PSMMViewport -State $State -Count $n -Rows ($win.Height - 11)
    $descCap = [Math]::Max(20, $win.Width - 78)
    $rows = [System.Collections.Generic.List[string[]]]::new()
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        $r = $Results[$i]
        $nm = ConvertTo-PSMMSafe (Get-PSMMTrunc $r.Name 40)
        if ($i -eq $State.Cursor) { $nm = "[bold $script:PSMM_ColAccent]$nm[/]" }
        $rows.Add([string[]]@(
                $nm, (ConvertTo-PSMMSafe $r.Version),
                (ConvertTo-PSMMSafe (Get-PSMMTrunc "$($r.Author)" 18)),
                (ConvertTo-PSMMSafe (Get-PSMMTrunc ($r.Description -replace '\s+', ' ') $descCap))))
    }
    $T = New-PSMMTable -Headers @('name', 'version', 'by', 'description') -Rows $rows -CursorRow ($State.Cursor - $vp.First)
    $pos = Get-PSMMPositionMarkup -State $State -Count $n -Viewport $vp
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb @('home', 'gallery') -CountsMarkup "[$script:PSMM_ColDim]search: $(ConvertTo-PSMMSafe $Query)[/]$pos")))
    $items.Add($T)
    if ($n) {
        $cur = $Results[$State.Cursor]
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColMute]$(ConvertTo-PSMMSafe (Get-PSMMTrunc "by $($cur.Author) - $($cur.Description -replace '\s+', ' ')" ($win.Width - 6)))[/]"))
    }
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('enter=add to config', 'left/right=back / add', '/=new search'))))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", '?=help', 'esc=back', '^q=quit'))))
    if ($StatusMarkup) { $items.Add([Spectre.Console.Markup]::new($StatusMarkup)) }
    [Spectre.Console.Rows]::new($items)
}

function script:Show-PSMMGallery {
    $ui = $script:PSMM_UI
    $query = ''
    $results = @()
    while ($true) {
        if ($ui.HardQuit -or $ui.Goto) { return }
        # prompt for a (new) search
        Clear-PSMMScreen
        Write-PSMMLine "[$script:PSMM_ColAccent]Search the PowerShell Gallery[/]"
        Write-PSMMLine "[$script:PSMM_ColMute]name or wildcard pattern, e.g. 'excel', 'Az.*', 'Microsoft.Graph*'; empty cancels[/]"
        $query = Read-PSMMText -Message 'Search' -AllowEmpty
        if ([string]::IsNullOrWhiteSpace($query)) { return }
        Write-PSMMLine "[$script:PSMM_ColAccent]searching the gallery for '$(ConvertTo-PSMMSafe $query)'...[/]"
        $results = @(Find-PSMMGalleryModule -Query $query)
        if (-not $results.Count) {
            Write-PSMMLine "[$script:PSMM_ColWarn]No results.[/]"
            if (-not (Wait-PSMMKey -Message 'search again')) { return }
            continue
        }

        $st = New-PSMMListState
        $st.Status = "[$script:PSMM_ColOk]$($results.Count) result(s)[/]"
        $action = @{ Name = $null }
        Clear-PSMMScreen
        Invoke-PSMMLive -Body {
            param($ctx)
            while ($true) {
                if ($script:PSMM_UI.HardQuit) { return }
                $ctx.UpdateTarget((Build-PSMMGalleryView -State $st -Results $results -Query $query -StatusMarkup $st.Status))
                $ctx.Refresh()
                $k = Read-PSMMKeyResize
                if ($null -eq $k) { continue }
                if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; return }
                if ($k.KeyChar -eq 'g') {
                    $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMGalleryView -State $st -Results $results -Query $query -StatusMarkup $st.Status)
                    if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                    continue
                }
                if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
                $st.Status = ''
                if (Invoke-PSMMListNav -State $st -KeyInfo $k -Count $results.Count) { continue }
                # left/right: same everywhere (gh#7) - right adds, like enter
                $drill = Get-PSMMDrillKey -KeyInfo $k
                if ($drill -eq 'out') { $action.Name = 'back'; return }
                if ($drill -eq 'in') { $action.Name = 'add'; return }
                switch ($k.Key) {
                    ([ConsoleKey]::Enter)  { $action.Name = 'add'; return }
                    ([ConsoleKey]::Escape) { $action.Name = 'back'; return }
                    ([ConsoleKey]::Oem2)   {
                        if ($k.KeyChar -eq '?') { $action.Name = 'help'; return }
                        $action.Name = 'newsearch'; return
                    }
                    default {
                        if ($k.KeyChar -eq '/') { $action.Name = 'newsearch'; return }
                        if ($k.KeyChar -eq '?') { $action.Name = 'help'; return }
                    }
                }
            }
        }
        if ($ui.HardQuit) { return }
        switch ($action.Name) {
            'back' { return }
            'help' { Show-PSMMHelpScreen -Topic 'gallery' }
            'add'  {
                $pick = $results[$st.Cursor]
                $pseudo = [pscustomobject]@{ Name = $pick.Name; Description = $pick.Description }
                $null = Add-PSMMUnmanagedEntry -Entry $pseudo
            }
            # 'newsearch' just falls through to the outer loop's prompt
        }
    }
}
