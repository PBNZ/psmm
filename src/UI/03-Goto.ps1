# 03-Goto.ps1 — the g goto layer (design-system-v2 §4): pressing g anywhere
# re-renders the current view with a small accent-bordered panel appended;
# the next key jumps to a named screen. Identical on every screen, so the
# per-screen switch letters are freed for verbs.

# chord → destination registry. Tests assert completeness.
function script:Get-PSMMGotoTable {
    [ordered]@{
        'h' = @{ Target = 'home';      Label = 'home' }
        'g' = @{ Target = 'gallery';   Label = 'gallery' }
        'f' = @{ Target = 'files';     Label = 'files' }
        'p' = @{ Target = 'paths';     Label = 'paths' }
        't' = @{ Target = 'tasks';     Label = 'tasks' }
        'c' = @{ Target = 'conflicts'; Label = 'conflicts' }
        'x' = @{ Target = 'cleanup';   Label = 'cleanup' }
        'm' = @{ Target = 'unmanaged'; Label = 'unmanaged' }
        '?' = @{ Target = 'help';      Label = 'keys' }
    }
}

# The overlay panel: title, three-column chord grid, footer.
function script:Build-PSMMGotoPanel {
    $table = Get-PSMMGotoTable
    $cells = @(foreach ($k in $table.Keys) {
        "[$script:PSMM_ColKey on $script:PSMM_ColCapsuleDim] $k [/] [$script:PSMM_ColMute]$($table[$k].Label)[/]"
    })
    $g = [Spectre.Console.Grid]::new()
    for ($c = 0; $c -lt 3; $c++) {
        $col = [Spectre.Console.GridColumn]::new()
        $col.Padding = [Spectre.Console.Padding]::new(0, 0, 4, 0)
        [void]$g.AddColumn($col)
    }
    for ($r = 0; $r -lt 3; $r++) {
        [void][Spectre.Console.GridExtensions]::AddRow($g, [string[]]@($cells[(3 * $r)..(3 * $r + 2)]))
    }
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new(
        "[$script:PSMM_ColAccent on $script:PSMM_ColCapsule] g [/] [default]goto[/] [$script:PSMM_ColDim]$([char]0x2014) next key jumps, from anywhere[/]"))
    $items.Add($g)
    $items.Add([Spectre.Console.Markup]::new(
        "[$script:PSMM_ColDim]esc cancels $([char]0x00B7) anything else is swallowed[/]"))
    $panel = [Spectre.Console.Panel]::new([Spectre.Console.Rows]::new($items))
    $panel.Border = [Spectre.Console.BoxBorder]::Rounded
    $panel.BorderStyle = [Spectre.Console.Style]::Parse($script:PSMM_ColAccent)
    $panel
}

# Show the overlay under the current view and read the second key.
# Returns the destination string, or $null (esc / unknown key swallowed /
# hard quit). $Context: a LiveDisplayContext when called from a live loop;
# without one the frame is written directly (non-live screens).
function script:Read-PSMMGotoKey {
    param(
        $BaseRenderable,
        $Context
    )
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    if ($BaseRenderable) { $items.Add($BaseRenderable) }
    $items.Add((Build-PSMMGotoPanel))
    $frame = [Spectre.Console.Rows]::new($items)
    if ($Context) { $Context.UpdateTarget($frame); $Context.Refresh() }
    else { Clear-PSMMScreen; Write-PSMMRenderable $frame }
    $k2 = [Console]::ReadKey($true)
    if (Test-PSMMHardQuitKey $k2) { $script:PSMM_UI.HardQuit = $true; return $null }
    if ($k2.Key -eq [ConsoleKey]::Escape) { return $null }
    $table = Get-PSMMGotoTable
    $key = "$($k2.KeyChar)".ToLowerInvariant()
    if ($key -and $table.Contains($key)) { return $table[$key].Target }
    $null   # anything else is swallowed
}
