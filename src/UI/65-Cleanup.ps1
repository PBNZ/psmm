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
    $T = [Spectre.Console.Table]::new()
    $T.Border = [Spectre.Console.TableBorder]::Rounded
    foreach ($h in ' ', 'Module', 'Keep', 'Remove', 'Scopes') { [void][Spectre.Console.TableExtensions]::AddColumn($T, $h) }
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        $d = $Dupes[$i]
        $nm = ConvertTo-PSMMSafe (Get-PSMMTrunc $d.Name 40)
        if ($i -eq $State.Cursor) { $nm = "[$script:PSMM_ColAccent]$nm[/]" }
        $obsVers = (@($d.Obsolete | ForEach-Object { "v$($_.Version)" }) -join ', ')
        $scopes = (@($d.Obsolete.Scope | Select-Object -Unique) -join ', ')
        [void][Spectre.Console.TableExtensions]::AddRow($T, [string[]]@(
                $(if ($i -eq $State.Cursor) { "[$script:PSMM_ColAccent]>[/]" } else { ' ' }),
                $nm, "[green3]v$($d.Latest)[/]", (ConvertTo-PSMMSafe (Get-PSMMTrunc $obsVers 40)), $scopes))
    }
    $pos = Get-PSMMPositionMarkup -State $State -Count $n -Viewport $vp
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb @('home', 'cleanup') -CountsMarkup "[$script:PSMM_ColDim]$n module(s) with multiple versions on disk[/]$pos")))
    $items.Add($T)
    if (-not $script:PSMM_UI.Elevated) {
        $items.Add([Spectre.Console.Markup]::new('[grey66]session is not elevated: AllUsers copies are skipped automatically[/]'))
    }
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('enter=clean this module', '^a=clean all', 'r=rescan'))))
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
            Write-PSMMLine '[green3]No module has more than one installed version - nothing to clean.[/]'
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
                    $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMCleanupView -State $st -Dupes $dupes -StatusMarkup $st.Status) -Context $ctx
                    if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                    continue
                }
                if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
                $st.Status = ''
                if (Invoke-PSMMListNav -State $st -KeyInfo $k -Count $dupes.Count) { continue }
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
                $status = '[green3]rescanned[/]'
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
    if ($skipped) { Write-PSMMLine "[orange1]$skipped AllUsers version(s) skipped - session is not elevated[/]" }
    if (-not $work.Count) { $null = Wait-PSMMKey; return '[orange1]nothing removable without elevation[/]' }
    foreach ($w in $work) { Write-PSMMLine "  $(ConvertTo-PSMMSafe $w.Name) v$($w.Version) [grey66]($($w.Scope))[/]" }
    if (-not (Read-SpectreConfirm -Message "Remove these $($work.Count) old version(s)?" -DefaultAnswer 'n')) { return '[grey66]cleanup cancelled[/]' }
    $ok = 0; $failed = 0
    foreach ($w in $work) {
        Write-PSMMLine "[$script:PSMM_ColAccent]removing $(ConvertTo-PSMMSafe $w.Name) v$($w.Version)...[/]"
        try { Uninstall-PSMMModuleVersion -Name $w.Name -Version "$($w.Version)"; $ok++ }
        catch { $failed++; Write-PSMMLine "[indianred1]  $(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
    }
    if ($failed) { "[orange1]removed $ok, $failed failed[/]" } else { "[green3]removed $ok old version(s)[/]" }
}
