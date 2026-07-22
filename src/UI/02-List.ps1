# 02-List.ps1 — the shared list/navigation/filter machinery every screen
# uses, so navigation feels identical everywhere (#22).
#
# A list state is a hashtable: @{ Cursor; Top; Filter; FilterMode }.
# Conventions (uniform across ALL psmm screens):
#   up/dn pgup/pgdn home/end  move          /        enter filter (search) mode
#   enter                     act on row    esc      clear filter, else back
#   ?                         screen help   Ctrl+Q/X hard quit

function script:New-PSMMListState {
    @{ Cursor = 0; Top = 0; Filter = ''; FilterMode = $false }
}

# Handle a movement key against a list of $Count rows. Returns $true when the
# key was a movement key (handled), $false otherwise.
function script:Invoke-PSMMListNav {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $KeyInfo,
        [Parameter(Mandatory)][int]$Count,
        [int]$Page = 10
    )
    $max = [Math]::Max(0, $Count - 1)
    switch ($KeyInfo.Key) {
        ([ConsoleKey]::UpArrow)   { $State.Cursor = [Math]::Max(0, $State.Cursor - 1); return $true }
        ([ConsoleKey]::DownArrow) { $State.Cursor = [Math]::Min($max, $State.Cursor + 1); return $true }
        ([ConsoleKey]::PageUp)    { $State.Cursor = [Math]::Max(0, $State.Cursor - $Page); return $true }
        ([ConsoleKey]::PageDown)  { $State.Cursor = [Math]::Min($max, $State.Cursor + $Page); return $true }
        ([ConsoleKey]::Home)      { $State.Cursor = 0; return $true }
        ([ConsoleKey]::End)       { $State.Cursor = $max; return $true }
    }
    return $false
}

# Handle a key while in filter mode. Mutates $State; returns one of:
#   'edited'  filter text changed / still editing
#   'apply'   user pressed enter (keep filter, leave editing)
#   'clear'   user pressed esc (filter cleared, left editing)
#   ''        not a filter key (caller may treat as movement)
function script:Invoke-PSMMFilterKey {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $KeyInfo
    )
    $ctrl = ($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    switch ($KeyInfo.Key) {
        ([ConsoleKey]::Escape)    { $State.Filter = ''; $State.FilterMode = $false; $State.Cursor = 0; return 'clear' }
        ([ConsoleKey]::Enter)     { $State.FilterMode = $false; return 'apply' }
        ([ConsoleKey]::Backspace) {
            if ($State.Filter.Length) { $State.Filter = $State.Filter.Substring(0, $State.Filter.Length - 1); $State.Cursor = 0 }
            return 'edited'
        }
        default {
            if (-not $ctrl -and $KeyInfo.KeyChar -and $KeyInfo.KeyChar -ne '/' -and -not [char]::IsControl($KeyInfo.KeyChar)) {
                $State.Filter += $KeyInfo.KeyChar; $State.Cursor = 0
                return 'edited'
            }
            return ''
        }
    }
}

# Clamp cursor + viewport top for $Count rows in a $Rows-tall viewport.
# Returns @{ First; Last; Rows } of the visible slice.
function script:Get-PSMMViewport {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][int]$Rows
    )
    $rows = [Math]::Max(3, $Rows)
    if ($State.Cursor -ge $Count) { $State.Cursor = [Math]::Max(0, $Count - 1) }
    if ($State.Cursor -lt $State.Top) { $State.Top = $State.Cursor }
    elseif ($State.Cursor -ge $State.Top + $rows) { $State.Top = $State.Cursor - $rows + 1 }
    $State.Top = [Math]::Max(0, [Math]::Min($State.Top, [Math]::Max(0, $Count - $rows)))
    @{ First = $State.Top; Last = [Math]::Min($Count - 1, $State.Top + $rows - 1); Rows = $rows }
}

# Position indicator "row X/n" (+ scroll range when clipped) - every
# scrollable list shows this (#12).
function script:Get-PSMMPositionMarkup {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)] $Viewport
    )
    if (-not $Count) { return '' }
    $pos = "[$script:PSMM_ColMute]  row $($State.Cursor + 1)/$Count[/]"
    if ($Count -gt $Viewport.Rows) {
        # arrows, not '^'/'v': the design system reserves '^' for the ctrl legend
        $up = if ($Viewport.First -gt 0) { " $([char]0x2191)" } else { '' }
        $dn = if ($Viewport.Last -lt $Count - 1) { " $([char]0x2193)" } else { '' }
        $pos += "[$script:PSMM_ColMute]  showing $($Viewport.First + 1)-$($Viewport.Last + 1)$up$dn[/]"
    }
    $pos
}

# Does this text contain the filter? A plain case-insensitive substring test,
# deliberately NOT -like: a filter is free text the user types, and a single
# '[' makes -like throw "the specified wildcard character pattern is not
# valid" - which killed the screen mid-keystroke.
function script:Test-PSMMFilterMatch {
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [AllowEmptyString()][AllowNull()][string]$Filter
    )
    if ([string]::IsNullOrEmpty($Filter)) { return $true }
    "$Text".IndexOf($Filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

# Filter status markup for a list header ('' when no filter in play).
function script:Get-PSMMFilterMarkup {
    param([Parameter(Mandatory)] $State)
    if ($State.FilterMode) { return "  [$script:PSMM_ColAccent]filter: $(ConvertTo-PSMMSafe $State.Filter)_[/]" }
    if ($State.Filter)     { return "  [$script:PSMM_ColAccent]filter: $(ConvertTo-PSMMSafe $State.Filter)[/] [$script:PSMM_ColMute](esc clears)[/]" }
    ''
}

# --- shared scrolling text pager (help screens, command help tabs) --------

# Build the renderable for a page of text. $State: @{ Scroll }.
function script:Build-PSMMPagerView {
    param(
        [Parameter(Mandatory)] $State,
        # AllowEmptyString: Mandatory on [string[]] otherwise rejects the
        # blank lines every text document contains
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][string]$TitleMarkup,
        # when given, the v2 header bar replaces the plain title line
        [string[]]$Breadcrumb,
        [string[]]$HintPairs = @('up/dn=scroll', 'left=back', 'c=copy'),
        [string]$StatusMarkup,
        [int]$ReservedRows = 7
    )
    $win  = Get-PSMMWinSize
    $page = [Math]::Max(5, $win.Height - $ReservedRows)
    $State.Scroll = [Math]::Max(0, [Math]::Min($State.Scroll, [Math]::Max(0, $Lines.Count - $page)))
    $body = ($Lines | Select-Object -Skip $State.Scroll -First $page | ForEach-Object { ConvertTo-PSMMSafe $_ }) -join "`n"
    $pos = if ($Lines.Count -gt $page) {
        "  [$script:PSMM_ColMute]lines $($State.Scroll + 1)-$([Math]::Min($Lines.Count, $State.Scroll + $page))/$($Lines.Count)[/]"
    } else { '' }
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    if ($Breadcrumb) { $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb $Breadcrumb -CountsMarkup $pos))) }
    else { $items.Add([Spectre.Console.Markup]::new("$TitleMarkup$pos")) }
    $panel = [Spectre.Console.Panel]::new([Spectre.Console.Markup]::new($body))
    $panel.Border = [Spectre.Console.BoxBorder]::Rounded
    $panel.BorderStyle = Get-PSMMBorderStyle
    $items.Add($panel)
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs $HintPairs)))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", 'esc=back', '^q=quit'))))
    if ($StatusMarkup) { $items.Add([Spectre.Console.Markup]::new($StatusMarkup)) }
    [Spectre.Console.Rows]::new($items)
}

# Copy text to the OS clipboard; returns a status markup line either way.
function script:Copy-PSMMText {
    param([AllowEmptyString()][string]$Text)
    try {
        Set-Clipboard -Value $Text -ErrorAction Stop
        "[$script:PSMM_ColOk]copied to clipboard[/]"
    } catch {
        "[$script:PSMM_ColErr]clipboard copy failed: $(ConvertTo-PSMMSafe $_.Exception.Message)[/]"
    }
}

# Handle a pager key. Returns $true when handled.
function script:Invoke-PSMMPagerNav {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $KeyInfo
    )
    switch ($KeyInfo.Key) {
        ([ConsoleKey]::UpArrow)   { $State.Scroll = [Math]::Max(0, $State.Scroll - 1); return $true }
        ([ConsoleKey]::DownArrow) { $State.Scroll++; return $true }
        ([ConsoleKey]::PageUp)    { $State.Scroll = [Math]::Max(0, $State.Scroll - 10); return $true }
        ([ConsoleKey]::PageDown)  { $State.Scroll += 10; return $true }
        ([ConsoleKey]::Home)      { $State.Scroll = 0; return $true }
        ([ConsoleKey]::End)       { $State.Scroll = [int]::MaxValue; return $true }
    }
    return $false
}

# Full-screen interactive pager over prepared lines.
function script:Show-PSMMPager {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Lines and TitleMarkup are used inside the live-loop scriptblock; the rule cannot see into it.')]
    param(
        # AllowEmptyString: see Build-PSMMPagerView
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][string]$TitleMarkup,
        [string[]]$Breadcrumb
    )
    $st = @{ Scroll = 0; Status = '' }
    Clear-PSMMScreen
    Invoke-PSMMLive -Body {
        param($ctx)
        while ($true) {
            if ($script:PSMM_UI.HardQuit) { return }
            $ctx.UpdateTarget((Build-PSMMPagerView -State $st -Lines $Lines -TitleMarkup $TitleMarkup -Breadcrumb $Breadcrumb -StatusMarkup $st.Status))
            $ctx.Refresh()
            $k = Read-PSMMKeyResize
            if ($null -eq $k) { continue }
            if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; return }
            if ($k.KeyChar -eq 'g') {
                $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMPagerView -State $st -Lines $Lines -TitleMarkup $TitleMarkup -Breadcrumb $Breadcrumb -StatusMarkup $st.Status)
                if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                continue
            }
            if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
            $st.Status = ''
            if (Invoke-PSMMPagerNav -State $st -KeyInfo $k) { continue }
            # left backs out here too (gh#7); a text page has nothing to open
            $drill = Get-PSMMDrillKey -KeyInfo $k
            if ($drill -eq 'out') { return }
            if ($drill -eq 'in') { $st.Status = Get-PSMMNoDrillStatus; continue }
            if ($k.Key -eq [ConsoleKey]::Escape) { return }
            if ($k.KeyChar -eq 'c') { $st.Status = Copy-PSMMText -Text ($Lines -join [Environment]::NewLine) }
        }
    }
    Clear-PSMMScreen
}
