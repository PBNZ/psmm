# 03-Goto.ps1 — the g goto layer (design-system-v2 §4): pressing g anywhere
# draws a small accent-bordered panel floating dead centre over the current
# frame (raw VT positioning via Write-PSMMOverlay); the next key jumps to
# a named screen. Identical on every screen, so the per-screen switch letters are
# freed for verbs. Show/hide unmanaged is NOT here - that is a grid verb
# ('m'), not a place to go (live-run feedback 2026-07-20).

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
    for ($r = 0; $r * 3 -lt $cells.Count; $r++) {
        $row = @(for ($c = 0; $c -lt 3; $c++) {
            $j = 3 * $r + $c
            if ($j -lt $cells.Count) { $cells[$j] } else { '' }
        })
        [void][Spectre.Console.GridExtensions]::AddRow($g, [string[]]$row)
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

# Draw the overlay on top of whatever is on screen and read the second key.
# $BaseRenderable is the frame currently showing - the panel centres over
# its content box (window centre when omitted). Returns the destination
# string, or $null (esc / unknown key swallowed / hard quit). Every caller
# repaints its frame right after, which restores anything the erased
# overlay rows covered.
function script:Read-PSMMGotoKey {
    [CmdletBinding()] param($BaseRenderable)
    $region = Write-PSMMOverlay -Renderable (Build-PSMMGotoPanel) -Content $BaseRenderable
    $k2 = [Console]::ReadKey($true)
    Clear-PSMMOverlay -Region $region
    if (Test-PSMMHardQuitKey $k2) { $script:PSMM_UI.HardQuit = $true; return $null }
    if ($k2.Key -eq [ConsoleKey]::Escape) { return $null }
    $table = Get-PSMMGotoTable
    $key = "$($k2.KeyChar)".ToLowerInvariant()
    if ($key -and $table.Contains($key)) { return $table[$key].Target }
    $null   # anything else is swallowed
}
