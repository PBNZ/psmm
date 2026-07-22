# 00-Theme.ps1 — palette, markup helpers, console plumbing, alternate screen.
#
# The palette (docs/design-system-v2.md §1) is read from the shared token
# table in src/Engine/Theme.ps1, so the $PSMM_Theme knob (glacier | ember |
# moss) swaps every token in one place and the startup report renders the
# same colours without Spectre. Explicit 256-colour names render identically
# in every terminal. Nothing outside the theme sources may name a colour.

$psmmThemeTable = Get-PSMMThemeTable
$script:PSMM_ColKey        = $psmmThemeTable['key'].Markup
$script:PSMM_ColMute       = $psmmThemeTable['mute'].Markup
$script:PSMM_ColAccent     = $psmmThemeTable['accent'].Markup
$script:PSMM_ColOk         = $psmmThemeTable['ok'].Markup
$script:PSMM_ColWarn       = $psmmThemeTable['warn'].Markup
$script:PSMM_ColErr        = $psmmThemeTable['err'].Markup
$script:PSMM_ColInfo       = $psmmThemeTable['info'].Markup
$script:PSMM_ColDim        = $psmmThemeTable['dim'].Markup       # de-emphasised cells, legends
$script:PSMM_ColCapsule    = $psmmThemeTable['capsule'].Markup   # key-capsule background
$script:PSMM_ColRowBg      = $psmmThemeTable['rowbg'].Markup     # cursor-row background
$script:PSMM_ColBorder     = $psmmThemeTable['border'].Markup    # ALL table/panel borders
$script:PSMM_ColBrandFg    = $psmmThemeTable['brandfg'].Markup   # the ' psmm ' brand block
$script:PSMM_ColBrandBg    = $psmmThemeTable['brandbg'].Markup
$script:PSMM_ColCapsuleDim = $psmmThemeTable['capsdim'].Markup   # persistent-row capsule background

# Shared border style: every table/panel border goes through this so the
# border colour is themed in one place.
function script:Get-PSMMBorderStyle { [Spectre.Console.Style]::Parse($script:PSMM_ColBorder) }

# Standard table chrome (§1/§5): rounded border in the border token,
# lowercase dim headers. Screens add rows themselves.
# Visible width of a markup cell. [Spectre.Console.Markup]::Remove collapses
# whitespace-ONLY strings to '' (verified against the vendored 2.6.3) - a
# blank mark slot measured as 0 gets extra padding, its column stretches,
# and every other row gets unstyled fill: a black hole in the cursor-row
# background right next to the bar (live-run feedback 2026-07-20 round 5).
function script:Get-PSMMCellWidth {
    param([string]$Cell)
    if ([string]::IsNullOrWhiteSpace($Cell)) { return $Cell.Length }
    [Spectre.Console.Markup]::Remove($Cell).Length
}

# ONE list-table builder for every sub-screen, with the SAME cursor
# treatment as the grid (mockup 2a): full-row rowbg background + a ▌
# accent bar in its own far-left slot + the caller's bold name cell.
# Widths are computed from ALL rows and padding lives inside the cells,
# so the background paints edge to edge. The grid builds its table
# inline for speed but uses this exact technique; the design
# consistency test holds both to it.
function script:New-PSMMTable {
    param(
        [Parameter(Mandatory)][string[]]$Headers,
        [AllowEmptyCollection()]$Rows = @(),   # one string[] of markup cells per row
        [int]$CursorRow = -1                   # index into $Rows; -1 = no cursor
    )
    $widths = @(foreach ($h in $Headers) { $h.Trim().Length })
    foreach ($r in $Rows) {
        for ($ci = 0; $ci -lt $Headers.Count; $ci++) {
            $len = Get-PSMMCellWidth "$($r[$ci])"
            if ($len -gt $widths[$ci]) { $widths[$ci] = $len }
        }
    }
    # borderless grid inside a rounded panel (mockup 2a: outer frame only,
    # no column separators, no header rule). Column 0 is the cursor-bar
    # slot; the bar never shares a slot with content, so it can't cover
    # anything (live-run feedback 2026-07-20 round 4).
    $G = [Spectre.Console.Grid]::new()
    for ($ci = 0; $ci -le $Headers.Count; $ci++) {
        $col = [Spectre.Console.GridColumn]::new()
        $col.Padding = [Spectre.Console.Padding]::new(0, 0, 0, 0)
        $col.NoWrap = $true
        [void]$G.AddColumn($col)
    }
    $headerCells = [string[]](@('  ') + @(for ($ci = 0; $ci -lt $Headers.Count; $ci++) {
        $h = $Headers[$ci].Trim()
        if ($h) { " [$script:PSMM_ColDim]$($h.ToLowerInvariant())[/]" + (' ' * ([Math]::Max(0, $widths[$ci] - $h.Length) + 1)) }
        else { ' ' * ($widths[$ci] + 2) }
    }))
    [void][Spectre.Console.GridExtensions]::AddRow($G, $headerCells)
    for ($ri = 0; $ri -lt $Rows.Count; $ri++) {
        $isCur = ($ri -eq $CursorRow)
        $mark = if ($isCur) { " [$script:PSMM_ColAccent]$([char]0x258C)[/]" } else { '  ' }
        $cells = [string[]](@($mark) + @(for ($ci = 0; $ci -lt $Headers.Count; $ci++) {
            $cell = "$($Rows[$ri][$ci])"
            $len = Get-PSMMCellWidth $cell
            ' ' + $cell + (' ' * ([Math]::Max(0, $widths[$ci] - $len) + 1))
        }))
        if ($isCur) { $cells = [string[]]@($cells | ForEach-Object { "[default on $script:PSMM_ColRowBg]$_[/]" }) }
        [void][Spectre.Console.GridExtensions]::AddRow($G, $cells)
    }
    $P = [Spectre.Console.Panel]::new($G)
    $P.Border = [Spectre.Console.BoxBorder]::Rounded
    $P.BorderStyle = Get-PSMMBorderStyle
    $P.Padding = [Spectre.Console.Padding]::new(0, 0, 0, 0)
    $P
}

# 1-based origin (@{ Top; Left }) for an overlay panel: dead centre of the
# CONTENT area on both axes (live-run feedback rounds 2-4: bottom,
# middle-left and window-centre all read as detached from the frame),
# clamped to the top-left when the panel is bigger than the area.
function script:Get-PSMMOverlayOrigin {
    param([int]$PanelHeight, [int]$PanelWidth, [int]$AreaHeight, [int]$AreaWidth)
    @{
        Top  = [Math]::Max(1, [Math]::Floor(($AreaHeight - $PanelHeight) / 2))
        Left = [Math]::Max(1, [Math]::Floor(($AreaWidth - $PanelWidth) / 2))
    }
}

# Visible size of a rendered frame: trailing blank lines dropped; the first
# line is EXCLUDED from the width because it is the header bar, padded to
# the full window width - including it would turn "centred over content"
# back into "centred over the window".
function script:Get-PSMMContentSize {
    param([Parameter(Mandatory)] $Renderable)
    $win = Get-PSMMWinSize
    $lines = @(ConvertTo-PSMMTextLines -Renderable $Renderable -Width $win.Width | ForEach-Object { "$_".TrimEnd() })
    while ($lines.Count -gt 0 -and [string]::IsNullOrEmpty($lines[$lines.Count - 1])) {
        $lines = @($lines | Select-Object -First ($lines.Count - 1))
    }
    $w = 0
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Length -gt $w) { $w = $lines[$i].Length }
    }
    if ($w -le 0) { $w = $win.Width }
    @{ Height = [Math]::Max(1, $lines.Count); Width = $w }
}

# Draw a renderable ON TOP of the current frame via raw VT cursor
# positioning - Spectre's live display has no z-layers, and appending the
# panel below a full-height frame pushed the screen (live-run feedback).
# The panel floats dead centre over the CONTENT ($Content = the frame's
# renderable, measured via Get-PSMMContentSize; window when omitted).
# DECSC/DECRC keep the live display's cursor bookkeeping intact; the
# caller erases the region (Clear-PSMMOverlay) before the next repaint.
# Returns the drawn region (@{ Top; Left; Count; Width }) or $null when
# output is redirected.
function script:Write-PSMMOverlay {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Raw VT cursor positioning must bypass any host/stream formatting.')]
    param(
        [Parameter(Mandatory)] $Renderable,
        $Content
    )
    try {
        if ([Console]::IsOutputRedirected) { return $null }
        $sw = [System.IO.StringWriter]::new()
        $settings = [Spectre.Console.AnsiConsoleSettings]::new()
        $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
        $settings.Interactive = [Spectre.Console.InteractionSupport]::No
        $settings.Ansi = [Spectre.Console.AnsiSupport]::Yes
        $settings.ColorSystem = [Spectre.Console.ColorSystemSupport]::EightBit
        $console = [Spectre.Console.AnsiConsole]::Create($settings)
        $console.Profile.Width = [Math]::Max(40, (Get-PSMMWinSize).Width - 2)
        $console.Write($Renderable)
        $lines = @($sw.ToString() -split "`r?`n" | Where-Object { $_ -ne '' })
        if (-not $lines.Count) { return $null }
        $win = Get-PSMMWinSize
        $panelWidth = 0
        foreach ($l in $lines) {
            $w = ($l -replace '\x1b\[[0-9;?]*[A-Za-z]', '').Length
            if ($w -gt $panelWidth) { $panelWidth = $w }
        }
        $area = if ($Content) { Get-PSMMContentSize -Renderable $Content }
                else { @{ Height = $win.Height; Width = $win.Width } }
        $origin = Get-PSMMOverlayOrigin -PanelHeight $lines.Count -PanelWidth $panelWidth -AreaHeight $area.Height -AreaWidth $area.Width
        $esc = [char]27
        $out = [System.Text.StringBuilder]::new()
        [void]$out.Append("$esc" + '7')                     # DECSC save cursor
        for ($i = 0; $i -lt $lines.Count; $i++) {
            [void]$out.Append("$esc[$($origin.Top + $i);$($origin.Left)H").Append($lines[$i]).Append("$esc[0m")
        }
        [void]$out.Append("$esc" + '8')                     # DECRC restore
        [Console]::Write($out.ToString())
        @{ Top = $origin.Top; Left = $origin.Left; Count = $lines.Count; Width = $panelWidth }
    } catch { $null }
}

# Erase the rectangle an overlay was drawn in (blank spaces, not whole
# lines - a centred panel must not wipe the frame text beside it); the
# caller's next repaint restores the content underneath.
function script:Clear-PSMMOverlay {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Raw VT cursor positioning must bypass any host/stream formatting.')]
    param($Region)
    if (-not $Region) { return }
    try {
        if ([Console]::IsOutputRedirected) { return }
        $esc = [char]27
        $blank = ' ' * [Math]::Max(1, [int]$Region.Width)
        $left = [Math]::Max(1, [int]$Region.Left)
        $out = [System.Text.StringBuilder]::new()
        [void]$out.Append("$esc" + '7')
        for ($i = 0; $i -lt $Region.Count; $i++) {
            [void]$out.Append("$esc[$($Region.Top + $i);${left}H").Append("$esc[0m").Append($blank)
        }
        [void]$out.Append("$esc" + '8')
        [Console]::Write($out.ToString())
    } catch { }
}

# The console every UI write goes through. Production: the real AnsiConsole.
# Tests inject a StringWriter-backed console via Set-PSMMConsole and assert on
# the rendered frames (see D-UI-ARCH).
function script:Get-PSMMConsole {
    if (-not $script:PSMM_Console) { $script:PSMM_Console = [Spectre.Console.AnsiConsole]::Console }
    $script:PSMM_Console
}
function script:Set-PSMMConsole { param($Console) $script:PSMM_Console = $Console }

# Write one markup line through the psmm console.
function script:Write-PSMMLine {
    param([string]$Markup = '')
    (Get-PSMMConsole).Write([Spectre.Console.Markup]::new($Markup + "`n"))
}

function script:Write-PSMMRenderable {
    param([Parameter(Mandatory)] $Renderable)
    (Get-PSMMConsole).Write($Renderable)
}

function script:Clear-PSMMScreen {
    # MUST be Clear($true): IAnsiConsole's zero-arg Clear() is a C# extension
    # method PowerShell cannot see, so .Clear() throws and the catch made every
    # "clear" a silent no-op - sub-screens appended below the grid instead of
    # replacing it (2026-07-05 live-run bug).
    try { (Get-PSMMConsole).Clear($true) } catch { }
}

# Run a live display on the psmm console. $Body is param($ctx) { ... } and
# runs synchronously in module scope (verified - see D-UI-ARCH).
function script:Invoke-PSMMLive {
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        $Initial
    )
    if (-not $Initial) { $Initial = [Spectre.Console.Markup]::new(' ') }
    $live = [Spectre.Console.LiveDisplay]::new((Get-PSMMConsole), $Initial)
    $live.Start([Action[Spectre.Console.LiveDisplayContext]]$Body)
}

# --- alternate screen buffer (#4: preserve the user's scrollback) ---------
# Entering flips the terminal to the alt buffer exactly like edit/vim/less;
# leaving restores the previous screen contents untouched. No-ops when
# output is redirected (tests, CI).

function script:Enter-PSMMAltScreen {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Raw VT escape for the alternate screen buffer must bypass any host/stream formatting.')]
    param()
    try {
        if (-not [Console]::IsOutputRedirected) {
            # ?25l: hide the console cursor for the TUI - it blinked over the
            # frames (live-run feedback); text prompts show it again
            [Console]::Write("$([char]27)[?1049h$([char]27)[H$([char]27)[?25l")
            $script:PSMM_AltScreenActive = $true
        }
    } catch { }
}

function script:Exit-PSMMAltScreen {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Raw VT escape for the alternate screen buffer must bypass any host/stream formatting.')]
    param()
    try {
        if ($script:PSMM_AltScreenActive) {
            [Console]::Write("$([char]27)[?25h$([char]27)[?1049l")
            $script:PSMM_AltScreenActive = $false
        }
    } catch { }
}

# Render any renderable to plain text lines at the current window width.
# Used to feed tables into the shared pager: inside the alternate screen
# buffer there is no scrollback, so anything potentially tall must scroll.
function script:ConvertTo-PSMMTextLines {
    param(
        [Parameter(Mandatory)] $Renderable,
        [int]$Width = 0
    )
    $sw = [System.IO.StringWriter]::new()
    $settings = [Spectre.Console.AnsiConsoleSettings]::new()
    $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
    $settings.Interactive = [Spectre.Console.InteractionSupport]::No
    $settings.Ansi = [Spectre.Console.AnsiSupport]::No
    $console = [Spectre.Console.AnsiConsole]::Create($settings)
    $console.Profile.Width = if ($Width -gt 0) { $Width } else { (Get-PSMMWinSize).Width - 4 }
    $console.Write($Renderable)
    # Ansi=No is NOT always honoured: Spectre's environment detection (e.g.
    # GITHUB_ACTIONS=true) force-enables ANSI over the explicit setting, and
    # escape codes here would end up as literal garbage in the pager. Strip.
    (($sw.ToString() -replace '\x1b\[[0-9;?]*[A-Za-z]', '') -split "`r?`n")
}

# --- small shared formatting helpers --------------------------------------

# Fast markup escape for the hot render path (avoids a cmdlet call per cell).
function script:ConvertTo-PSMMSafe { param([string]$s) if ($null -eq $s) { '' } else { $s.Replace('[', '[[').Replace(']', ']]') } }

# Truncate with an ellipsis so rows never wrap to a second line.
function script:Get-PSMMTrunc {
    param([string]$s, [int]$max)
    if ($null -eq $s) { return '' }
    if ($s.Length -le $max) { return $s }
    if ($max -le 1) { return $s.Substring(0, [Math]::Max(0, $max)) }
    $s.Substring(0, $max - 1) + [char]0x2026   # …
}

# Console size, defaulting safely when there is no real console.
function script:Get-PSMMWinSize {
    $h = 25; $w = 120
    try { $h = [Console]::WindowHeight; $w = [Console]::WindowWidth } catch { }
    if ($h -le 0) { $h = 25 }
    if ($w -le 0) { $w = 120 }
    [pscustomobject]@{ Height = $h; Width = $w }
}

# ONE key capsule (§3): reverse-video key block on the capsule background.
# Every rendering of a key - hint rows, help tabs, prose - goes through here,
# so the capsule is defined exactly once. Keys are always lowercase, and
# multi-key names are spelled out ('left/right', 'up/dn', 'pgup/pgdn'), never
# drawn as arrow glyphs: the arrows are reserved for the scroll indicator
# (design system §9, gh#7).
function script:Get-PSMMKeyCap {
    param([Parameter(Mandatory)][string]$Key)
    "[$script:PSMM_ColKey on $script:PSMM_ColCapsule] $($Key.ToLowerInvariant()) [/]"
}

# Render "key=action" pairs as one consistently-styled hint line.
# Design system v2 (§3): every key is a capsule, mute label, two-space
# separator. '^' before a key means ctrl, and any line using a '^' chord
# carries the dim '^ = ctrl' legend at the end of the row.
function script:Get-PSMMHint {
    param(
        [Parameter(Mandatory)][string[]]$Pairs,
        # rows that sit above a persistent strip (which carries the legend
        # itself) suppress their own to avoid repeating it
        [switch]$NoLegend
    )
    $parts = foreach ($p in $Pairs) {
        $k, $v = $p -split '=', 2
        "$(Get-PSMMKeyCap -Key $k) [$script:PSMM_ColMute]$v[/]"
    }
    if (-not $NoLegend -and @($Pairs | Where-Object { ($_ -split '=', 2)[0] -match '\^' }).Count) {
        $parts = @($parts) + @("[$script:PSMM_ColDim]^ = ctrl[/]")
    }
    $parts -join '  '
}

# Tier-two hint row (§3): the persistent strip - always the same keys,
# always last, accent keys on the darker capsule with dim labels. A blank
# line above separates it from the verb rows (mockup 2a) - it is part of
# the returned markup so every screen gets it for free.
function script:Get-PSMMPersistentHint {
    param([string[]]$Pairs = @("g=goto$([char]0x2026)", '/=filter', '?=help', '^q=quit'))
    $parts = foreach ($p in $Pairs) {
        $k, $v = $p -split '=', 2
        "[$script:PSMM_ColAccent on $script:PSMM_ColCapsuleDim] $($k.ToLowerInvariant()) [/] [$script:PSMM_ColDim]$v[/]"
    }
    if (@($Pairs | Where-Object { ($_ -split '=', 2)[0] -match '\^' }).Count) {
        $parts = @($parts) + @("[$script:PSMM_ColDim]^ = ctrl[/]")
    }
    "`n" + ($parts -join '  ')
}

# One-line header bar (§2), every screen: brand block + breadcrumb (+ dim
# counts) with version · engine · elevated · ⇡ update right-aligned. Returns
# a markup string padded to the window width.
function script:Get-PSMMHeaderBar {
    param(
        [string[]]$Breadcrumb = @('home'),
        [string]$CountsMarkup,
        [string]$RightMarkup
    )
    $ui = $script:PSMM_UI
    $crumbs = @(for ($i = 0; $i -lt $Breadcrumb.Count; $i++) {
        if ($i -lt $Breadcrumb.Count - 1) { "[$script:PSMM_ColDim]$(ConvertTo-PSMMSafe $Breadcrumb[$i]) $([char]0x203A)[/]" }
        else { "[default]$(ConvertTo-PSMMSafe $Breadcrumb[$i])[/]" }
    })
    $left = "[$script:PSMM_ColBrandFg on $script:PSMM_ColBrandBg] psmm [/] " + ($crumbs -join ' ')
    if ($CountsMarkup) { $left += "  $CountsMarkup" }
    $right = if ($PSBoundParameters.ContainsKey('RightMarkup')) { $RightMarkup }
             else {
                 $parts = @()
                 if ($ui -and $ui.Version) { $parts += "v$($ui.Version)" }
                 if ($ui -and $ui.Engine) { $parts += "$($ui.Engine)" }
                 if ($ui -and $ui.Elevated) { $parts += 'elevated' }
                 $r = "[$script:PSMM_ColDim]$($parts -join " $([char]0x00B7) ")[/]"
                 if ($ui -and $ui.SelfUpdate) { $r += " [$script:PSMM_ColWarn]$([char]0x21E1) update[/]" }
                 $r
             }
    $lLen = [Spectre.Console.Markup]::Remove($left).Length
    $rLen = [Spectre.Console.Markup]::Remove($right).Length
    $pad = [Math]::Max(1, (Get-PSMMWinSize).Width - $lLen - $rLen - 1)
    # full-width bar background (§2); inner tags override only the foreground
    "[default on $script:PSMM_ColCapsuleDim]" + $left + (' ' * $pad) + $right + "[/]"
}

# v2 display language (§5): the JSON schema keeps the Mode/Install enums;
# these are the plain words the UI shows for them.
function script:Get-PSMMStartupWord {
    param($Mode)
    switch ("$Mode") {
        'Load'        { 'load' }
        'InstallOnly' { 'install' }
        'Ignore'      { 'off' }
        default       { '-' }
    }
}

function script:Get-PSMMGalleryWord {
    param($Install)
    switch ("$Install") {
        'IfMissing' { 'if-missing' }
        'CheckOnly' { 'check-only' }
        'Latest'    { 'latest' }
        default     { '-' }
    }
}

# State glyph + word (§5): glyph and word travel together, never glyph alone.
# psmm's own modules read as infrastructure (◈, dim) rather than as something
# you asked for (gh#16) - but only once they are actually present: a MISSING
# dependency is a real problem and must still say so.
function script:Get-PSMMStateMarkup {
    param([Parameter(Mandatory)] $Entry)
    if ($Entry.PSObject.Properties['Unmanaged']) { return "[$script:PSMM_ColInfo]$([char]0x25CC) unmanaged[/]" }
    if ((Test-PSMMOwnModule -Name $Entry.Name) -and ($Entry.Loaded -or $Entry.Installed)) {
        return "[$script:PSMM_ColDim]$([char]0x25C8) psmm's own[/]"
    }
    if ($Entry.Loaded)    { return "[$script:PSMM_ColOk]$([char]0x25CF) loaded[/]" }
    if ($Entry.Installed) { return "[$script:PSMM_ColWarn]$([char]0x25D0) installed[/]" }
    "[$script:PSMM_ColErr]$([char]0x25CB) missing[/]"
}

# Minimum terminal size a table screen needs; below it Spectre collapses the
# table to '...'. Screens render Get-PSMMTooSmallView instead of the table.
function script:Test-PSMMWinTooSmall {
    param([int]$MinWidth = 60, [int]$MinHeight = 14)
    $win = Get-PSMMWinSize
    ($win.Width -lt $MinWidth) -or ($win.Height -lt $MinHeight)
}

function script:Get-PSMMTooSmallView {
    param([int]$MinWidth = 60, [int]$MinHeight = 14)
    $win = Get-PSMMWinSize
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColWarn]window too small to draw this screen[/]"))
    $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColMute]current $($win.Width)x$($win.Height), need at least ${MinWidth}x${MinHeight} - enlarge the terminal[/]"))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('esc=back', '^q=quit'))))
    [Spectre.Console.Rows]::new($items)
}

# Minimal single-line text prompt: enter accepts (empty input returns the
# default when one is set), ESC CANCELS and returns $null - the Spectre
# prompts have no abort path (live-run feedback). The console cursor is
# shown for the duration (hidden otherwise in the TUI).
function script:Read-PSMMText {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'A raw key-by-key line editor (esc-cancel) needs direct console echo.')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$DefaultAnswer = '',
        [switch]$AllowEmpty
    )
    $hint = if ($DefaultAnswer) { " [$script:PSMM_ColDim]($(ConvertTo-PSMMSafe $DefaultAnswer))[/]" } else { '' }
    Write-PSMMRenderable ([Spectre.Console.Markup]::new(
            "[$script:PSMM_ColMute]$(ConvertTo-PSMMSafe $Message)[/]$hint[$script:PSMM_ColMute]:[/] [$script:PSMM_ColDim](esc cancels)[/] "))
    $buf = [System.Text.StringBuilder]::new()
    try {
        try { [Console]::Write("$([char]27)[?25h") } catch { }
        while ($true) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Escape) { [Console]::WriteLine(); return $null }
            if ($k.Key -eq [ConsoleKey]::Enter) {
                [Console]::WriteLine()
                $text = $buf.ToString()
                if (-not $text -and $DefaultAnswer) { return $DefaultAnswer }
                if (-not $text -and -not $AllowEmpty) { return $null }   # nothing to accept
                return $text
            }
            if ($k.Key -eq [ConsoleKey]::Backspace) {
                if ($buf.Length) { $buf.Length--; [Console]::Write("`b `b") }
                continue
            }
            if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) {
                [void]$buf.Append($k.KeyChar)
                [Console]::Write($k.KeyChar)
            }
        }
    } finally {
        try { [Console]::Write("$([char]27)[?25l") } catch { }
    }
}

# Two-column label/value grid for detail panels.
function script:New-PSMMDetailGrid {
    param([Parameter(Mandatory)] $Rows)   # array of @(label, valueMarkup)
    $g = [Spectre.Console.Grid]::new()
    [void]$g.AddColumn([Spectre.Console.GridColumn]::new())
    [void]$g.AddColumn([Spectre.Console.GridColumn]::new())
    foreach ($r in $Rows) {
        [void][Spectre.Console.GridExtensions]::AddRow($g, [string[]]@("[$script:PSMM_ColAccent]$($r[0])[/]", $r[1]))
    }
    $g
}
