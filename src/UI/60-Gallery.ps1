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
    # Column budget. New-PSMMTable pads every cell by two, and the panel adds
    # its two borders plus a two-wide cursor slot, so the sum of the COLUMN
    # WIDTHS has to fit in (window - 4 - 2 per column). Spectre does not
    # overflow a table that is too wide, it REFLOWS it: every row bursts into
    # fragments stacked over several lines and the screen becomes unreadable.
    # The caps here used to be constants (name 40, by 18, description
    # window-78), which the widest real rows walk straight through -
    # Microsoft.Online.SharePoint.PowerShell at 16.0.27424.12000 is 53
    # characters of name and version on its own.
    $showDownloads = $win.Width -ge 100     # narrower than that there is no room
    $showBy = $win.Width -ge 80
    $byCap = if ($win.Width -ge 110) { 18 } elseif ($win.Width -ge 90) { 14 } else { 10 }
    # measure the rows actually on screen. Each header word is its column's
    # floor, and the version is never truncated (§11: the prerelease label is
    # part of it) - so the version is what the rest has to fit around.
    $nameW = 4; $verW = 7; $byW = 2; $dlW = 9
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        $r = $Results[$i]
        $nameW = [Math]::Max($nameW, [Math]::Min(40, "$($r.Name)".Length))
        $verW = [Math]::Max($verW, (Get-PSMMVersionText -Version $r.Version -Prerelease $r.Prerelease).Length)
        $byW = [Math]::Max($byW, [Math]::Min($byCap, "$($r.Author)".Length))
    }
    # name and description share what the fixed columns leave. A description
    # too narrow to say anything is worse than none at all, so in that case it
    # is dropped and the name gets the space - the context line under the
    # table carries the full description for the cursor row anyway.
    $showDesc = $true
    $nameCap = $nameW
    $descCap = 0
    foreach ($pass in 1, 2) {
        $count = 2 + [int]$showBy + [int]$showDownloads + [int]$showDesc
        $budget = [Math]::Max(20, $win.Width - 4 - (2 * $count))
        $fixed = $verW + $(if ($showBy) { $byW } else { 0 }) + $(if ($showDownloads) { $dlW } else { 0 })
        $room = [Math]::Max(10, $budget - $fixed)
        if (-not $showDesc) { $nameCap = [int][Math]::Max(8, [Math]::Min($nameW, $room)); break }
        $nameCap = [int][Math]::Max(10, [Math]::Min($nameW, [Math]::Floor($room * 0.6)))
        $descCap = [int]($room - $nameCap)
        if ($descCap -ge 12) { break }
        $showDesc = $false
    }
    $headers = [System.Collections.Generic.List[string]]::new()
    $headers.Add('name'); $headers.Add('version')
    if ($showBy) { $headers.Add('by') }
    if ($showDownloads) { $headers.Add('downloads') }
    if ($showDesc) { $headers.Add('description') }
    $rows = [System.Collections.Generic.List[string[]]]::new()
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        $r = $Results[$i]
        $nm = ConvertTo-PSMMSafe (Get-PSMMTrunc $r.Name $nameCap)
        if ($i -eq $State.Cursor) { $nm = "[bold $script:PSMM_ColAccent]$nm[/]" }
        $cells = [System.Collections.Generic.List[string]]::new()
        $cells.Add($nm)
        # gallery results can now BE prereleases (Search-PSMMGallery retries
        # with them when nothing stable matches), so the label has to show
        $cells.Add((Get-PSMMVersionMarkup -Version $r.Version -Prerelease $r.Prerelease))
        if ($showBy) { $cells.Add((ConvertTo-PSMMSafe (Get-PSMMTrunc "$($r.Author)" $byW))) }
        if ($showDownloads) { $cells.Add("[$script:PSMM_ColDim]$(ConvertTo-PSMMSafe (Format-PSMMDownloadCount $r.Downloads))[/]") }
        if ($showDesc) { $cells.Add((ConvertTo-PSMMSafe (Get-PSMMTrunc ($r.Description -replace '\s+', ' ') $descCap))) }
        $rows.Add([string[]]$cells)
    }
    $T = New-PSMMTable -Headers ([string[]]$headers) -Rows $rows -CursorRow ($State.Cursor - $vp.First)
    $pos = Get-PSMMPositionMarkup -State $State -Count $n -Viewport $vp
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb @('home', 'gallery') -CountsMarkup "[$script:PSMM_ColDim]search: $(ConvertTo-PSMMSafe $Query)[/]$pos")))
    $items.Add($T)
    if ($n) {
        $cur = $Results[$State.Cursor]
        # §5 context line: the cursor row spelled out, including the two facts
        # the columns cannot carry - which repository it came from (only worth
        # saying when it is NOT the public gallery) and the exact download count
        $bits = [System.Collections.Generic.List[string]]::new()
        $bits.Add("by $($cur.Author)")
        if ("$($cur.Repository)" -and "$($cur.Repository)" -ne 'PSGallery') { $bits.Add("from $($cur.Repository)") }
        if ([long]"0$($cur.Downloads)" -gt 0) { $bits.Add("$('{0:N0}' -f [long]$cur.Downloads) downloads") }
        $bits.Add(($cur.Description -replace '\s+', ' '))
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColMute]$(ConvertTo-PSMMSafe (Get-PSMMTrunc ($bits -join ' - ') ($win.Width - 6)))[/]"))
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
        Write-PSMMLine "[$script:PSMM_ColMute]a word searches names, descriptions and tags ('excel'); a pattern matches[/]"
        Write-PSMMLine "[$script:PSMM_ColMute]names only ('Az.*', 'Microsoft.Graph*'); empty cancels[/]"
        $query = Read-PSMMText -Message 'Search' -AllowEmpty
        if ([string]::IsNullOrWhiteSpace($query)) { return }
        Write-PSMMLine "[$script:PSMM_ColAccent]searching the gallery for '$(ConvertTo-PSMMSafe $query)'...[/]"
        $search = Search-PSMMGallery -Query $query
        $results = @($search.Results)
        if (-not $results.Count) {
            # never a bare "No results." - an empty screen has to say whether
            # the gallery had nothing or the search itself failed (gh#17)
            Write-PSMMLine "[$script:PSMM_ColWarn]No results.[/]"
            if ($search.Note) { Write-PSMMProse -Text $search.Note -Colour $script:PSMM_ColMute }
            if (-not (Wait-PSMMKey -Message 'search again')) { return }
            continue
        }

        $st = New-PSMMListState
        $st.Status = "[$script:PSMM_ColOk]$($results.Count) result(s)[/]"
        # a fallback fired (pattern found nothing, or the endpoint was down):
        # the results on screen are not the ones that were asked for, so say so
        if ($search.Note) { $st.Status += "  [$script:PSMM_ColMute]$(ConvertTo-PSMMSafe $search.Note)[/]" }
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
