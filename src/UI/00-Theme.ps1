# 00-Theme.ps1 — palette, markup helpers, console plumbing, alternate screen.
#
# Palette (2026-07-06 refresh, Claude-Code-inspired warm scheme; the blue
# accent is the original look and stays):
#   key    = keyboard shortcuts (coral)
#   mute   = action labels / separators / hints (bright enough to read!)
#   accent = cursor row, titles
# Status colours across the UI are explicit 256-colour names (green3 /
# orange1 / indianred1 / steelblue1) so they render identically in every
# terminal instead of following the terminal's ANSI scheme.

$script:PSMM_ColKey    = 'salmon1'
$script:PSMM_ColMute   = 'grey66'
$script:PSMM_ColAccent = 'deepskyblue1'

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
            [Console]::Write("$([char]27)[?1049h$([char]27)[H")
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
            [Console]::Write("$([char]27)[?1049l")
            $script:PSMM_AltScreenActive = $false
        }
    } catch { }
}

# Render any renderable to plain text lines at the current window width.
# Used to feed tables into the shared pager: inside the alternate screen
# buffer there is no scrollback, so anything potentially tall must scroll.
function script:ConvertTo-PSMMTextLines {
    param([Parameter(Mandatory)] $Renderable)
    $sw = [System.IO.StringWriter]::new()
    $settings = [Spectre.Console.AnsiConsoleSettings]::new()
    $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
    $settings.Interactive = [Spectre.Console.InteractionSupport]::No
    $settings.Ansi = [Spectre.Console.AnsiSupport]::No
    $console = [Spectre.Console.AnsiConsole]::Create($settings)
    $console.Profile.Width = (Get-PSMMWinSize).Width - 4
    $console.Write($Renderable)
    ($sw.ToString() -split "`r?`n")
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

# Render "key=action" pairs as one consistently-styled hint line.
function script:Get-PSMMHint {
    param([Parameter(Mandatory)][string[]]$Pairs)
    $parts = foreach ($p in $Pairs) {
        $k, $v = $p -split '=', 2
        "[$script:PSMM_ColKey]$k[/] [$script:PSMM_ColMute]$v[/]"
    }
    $parts -join " [$script:PSMM_ColMute]·[/] "
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
