# 65-Cleanup.ps1 — duplicate-version cleanup across ALL installed modules:
# Update-Module/-PSResource never remove old versions, so they pile up (the
# single most-requested module-management fix in the research for #36/#37).

function script:Build-PSMMCleanupView {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Dupes,
        [string]$StatusMarkup
    )
    if (Test-PSMMWinTooSmall) { return (Get-PSMMTooSmallView) }
    $n = $Dupes.Count
    $win = Get-PSMMWinSize
    $vp = Get-PSMMViewport -State $State -Count $n -Rows ($win.Height - 11)
    $rows = [System.Collections.Generic.List[string[]]]::new()
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        $d = $Dupes[$i]
        $nm = ConvertTo-PSMMSafe (Get-PSMMTrunc $d.Name 40)
        if ($i -eq $State.Cursor) { $nm = "[bold $script:PSMM_ColAccent]$nm[/]" }
        $obsVers = (@($d.Obsolete | ForEach-Object { "v$($_.Version)" }) -join ', ')
        $scopes = (@($d.Obsolete.Scope | Select-Object -Unique) -join ', ')
        $rows.Add([string[]]@($nm, "[$script:PSMM_ColOk]v$($d.Latest)[/]", (ConvertTo-PSMMSafe (Get-PSMMTrunc $obsVers 40)), $scopes))
    }
    $T = New-PSMMTable -Headers @('module', 'keep', 'remove', 'scopes') -Rows $rows -CursorRow ($State.Cursor - $vp.First)
    $pos = Get-PSMMPositionMarkup -State $State -Count $n -Viewport $vp
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb @('home', 'cleanup') -CountsMarkup "[$script:PSMM_ColDim]$n module(s) with multiple versions on disk[/]$pos")))
    $items.Add($T)
    if (-not $script:PSMM_UI.Elevated) {
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColMute]session is not elevated: AllUsers copies are skipped automatically[/]"))
    }
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('enter=clean this module', '^a=clean all', 'r=rescan', 'left/right=back / clean'))))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", '?=help', 'esc=back', '^q=quit'))))
    if ($StatusMarkup) { $items.Add([Spectre.Console.Markup]::new($StatusMarkup)) }
    [Spectre.Console.Rows]::new($items)
}

function script:Show-PSMMCleanup {
    $ui = $script:PSMM_UI
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]scanning installed modules for duplicate versions...[/]"
    $dupes = @(Get-PSMMDuplicateVersion)
    $status = ''
    while ($true) {
        if ($ui.HardQuit -or $ui.Goto) { return }
        if (-not $dupes.Count) {
            Clear-PSMMScreen
            Write-PSMMLine "[$script:PSMM_ColAccent]Clean up old module versions[/]"
            Write-PSMMLine "[$script:PSMM_ColOk]No module has more than one installed version - nothing to clean.[/]"
            $null = Wait-PSMMKey -Message 'back'
            return
        }
        $st = New-PSMMListState
        $st.Status = $status
        $action = @{ Name = $null }
        Clear-PSMMScreen
        Invoke-PSMMLive -Body {
            param($ctx)
            while ($true) {
                if ($script:PSMM_UI.HardQuit) { return }
                $ctx.UpdateTarget((Build-PSMMCleanupView -State $st -Dupes $dupes -StatusMarkup $st.Status))
                $ctx.Refresh()
                $k = Read-PSMMKeyResize
                if ($null -eq $k) { continue }
                if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; return }
                if ($k.KeyChar -eq 'g') {
                    $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMCleanupView -State $st -Dupes $dupes -StatusMarkup $st.Status)
                    if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                    continue
                }
                if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
                $st.Status = ''
                if (Invoke-PSMMListNav -State $st -KeyInfo $k -Count $dupes.Count) { continue }
                # left/right: same everywhere (gh#7) - right cleans, like enter
                $drill = Get-PSMMDrillKey -KeyInfo $k
                if ($drill -eq 'out') { $action.Name = 'back'; return }
                if ($drill -eq 'in') { $action.Name = 'one'; return }
                switch ($k.Key) {
                    ([ConsoleKey]::Enter)  { $action.Name = 'one'; return }
                    ([ConsoleKey]::A)      {
                        # ^a per the design system; shift+a kept as a legacy alias
                        if (($k.Modifiers -band ([ConsoleModifiers]::Control -bor [ConsoleModifiers]::Shift)) -ne 0) { $action.Name = 'all'; return }
                        continue
                    }
                    ([ConsoleKey]::R)      { $action.Name = 'rescan'; return }
                    ([ConsoleKey]::Escape) { $action.Name = 'back'; return }
                    default { if ($k.KeyChar -eq '?') { $action.Name = 'help'; return } }
                }
            }
        }
        if ($ui.HardQuit) { return }
        switch ($action.Name) {
            'back' { return }
            'help' { Show-PSMMHelpScreen -Topic 'cleanup' }
            'rescan' {
                Clear-PSMMScreen
                Write-PSMMLine "[$script:PSMM_ColAccent]rescanning...[/]"
                $dupes = @(Get-PSMMDuplicateVersion)
                $status = "[$script:PSMM_ColOk]rescanned[/]"
            }
            'one' {
                $d = $dupes[$st.Cursor]
                $status = Invoke-PSMMDupeCleanup -Dupes @($d)
                $dupes = @(Get-PSMMDuplicateVersion)
            }
            'all' {
                $status = Invoke-PSMMDupeCleanup -Dupes $dupes
                $dupes = @(Get-PSMMDuplicateVersion)
            }
        }
    }
}

# Remove obsolete versions for the given dupe records (with one confirm).
function script:Invoke-PSMMDupeCleanup {
    param([Parameter(Mandatory)] $Dupes)
    $ui = $script:PSMM_UI
    $work = @(foreach ($d in $Dupes) {
        foreach ($v in $d.Obsolete) {
            if ($v.Scope -eq 'AllUsers' -and -not $ui.Elevated) { continue }
            [pscustomobject]@{ Name = $d.Name; Version = $v.Version; Scope = $v.Scope }
        }
    })
    $skipped = @(foreach ($d in $Dupes) { @($d.Obsolete | Where-Object { $_.Scope -eq 'AllUsers' -and -not $ui.Elevated }) }).Count
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Clean up old versions[/]"
    if ($skipped) { Write-PSMMLine "[$script:PSMM_ColWarn]$skipped AllUsers version(s) skipped - session is not elevated[/]" }
    if (-not $work.Count) { $null = Wait-PSMMKey; return "[$script:PSMM_ColWarn]nothing removable without elevation[/]" }
    foreach ($w in $work) { Write-PSMMLine "  $(ConvertTo-PSMMSafe $w.Name) v$($w.Version) [$script:PSMM_ColMute]($($w.Scope))[/]" }
    if (-not (Read-SpectreConfirm -Message "Remove these $($work.Count) old version(s)?" -DefaultAnswer 'n')) { return "[$script:PSMM_ColMute]cleanup cancelled[/]" }
    $ok = 0; $failed = 0
    foreach ($w in $work) {
        Write-PSMMLine "[$script:PSMM_ColAccent]removing $(ConvertTo-PSMMSafe $w.Name) v$($w.Version)...[/]"
        try { Uninstall-PSMMModuleVersion -Name $w.Name -Version "$($w.Version)"; $ok++ }
        catch { $failed++; Write-PSMMLine "[$script:PSMM_ColErr]  $(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
    }
    if ($failed) { "[$script:PSMM_ColWarn]removed $ok, $failed failed[/]" } else { "[$script:PSMM_ColOk]removed $ok old version(s)[/]" }
}
