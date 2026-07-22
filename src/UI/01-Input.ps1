# 01-Input.ps1 — key reading with resize + background-activity wake-ups.

# Is this key the universal hard-quit chord (Ctrl+Q / Ctrl+X)?
function script:Test-PSMMHardQuitKey {
    param([Parameter(Mandatory)] $KeyInfo)
    ((($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -and
     ($KeyInfo.Key -in [ConsoleKey]::Q, [ConsoleKey]::X))
}

# Is this the "go home" alias? Ctrl+H where the terminal reports it
# distinctly (Windows Terminal/conhost deliver full key records; over VT
# paths Ctrl+H IS backspace). The primary route home is the g goto overlay
# ('g' then 'h', 03-Goto.ps1) - plain 'g' is handled by each screen loop,
# so this test answers immediately without a second key read.
function script:Test-PSMMHomeKey {
    param([Parameter(Mandatory)] $KeyInfo)
    ((($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -and
     ($KeyInfo.Key -eq [ConsoleKey]::H))
}

# Key read that also notices terminal resizes and background-task activity:
# returns $null when the window size changed OR a background job/task changed
# state or produced output (caller should re-render, typically via continue).
# Falls back to a plain blocking read where KeyAvailable is unsupported.
function script:Read-PSMMKeyResize {
    $w0 = Get-PSMMWinSize
    $fp0 = Get-PSMMTaskFingerprint
    $tick = 0
    while ($true) {
        try { if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) } }
        catch { return [Console]::ReadKey($true) }
        Start-Sleep -Milliseconds 100
        $w = Get-PSMMWinSize
        if ($w.Width -ne $w0.Width -or $w.Height -ne $w0.Height) { return $null }
        # every 500 ms: wake when background activity changed, so the grid's
        # overlay and job lines update by themselves (#25)
        $tick++
        if ($tick % 5 -eq 0) {
            $fp = Get-PSMMTaskFingerprint
            if ($fp -ne $fp0) { return $null }
        }
    }
}

# Consistent "press a key" pause that honours Ctrl+Q / Ctrl+X (hard quit).
# Returns $false when hard-quitting so callers can bail out immediately.
function script:Wait-PSMMKey {
    param([string]$Message = 'press any key to continue')
    Write-PSMMLine (Get-PSMMHint -Pairs @("any key=$Message", '^q=quit'))
    $k = [Console]::ReadKey($true)
    if (Test-PSMMHardQuitKey $k) {
        $script:PSMM_UI.HardQuit = $true
        return $false
    }
    return $true
}

# left/right = back out / drill in, the same on EVERY screen (gh#7). Returns
# 'out', 'in' or ''. Screens with nothing to drill into answer 'in' with
# Get-PSMMNoDrillStatus instead of silently doing nothing - a key that does
# nothing on some screens is worse than no key.
function script:Get-PSMMDrillKey {
    param([Parameter(Mandatory)] $KeyInfo)
    switch ($KeyInfo.Key) {
        ([ConsoleKey]::LeftArrow)  { return 'out' }
        ([ConsoleKey]::RightArrow) { return 'in' }
    }
    ''
}

function script:Get-PSMMNoDrillStatus {
    "[$script:PSMM_ColMute]nothing to open on this row $([char]0x00B7) left backs out[/]"
}

# Typed-phrase confirmation for destructive, hard-to-undo actions (gh#13).
# y/n and enter are one keystroke away from navigation; moving a whole module
# tree must not be. The user has to type the phrase - anything else, including
# empty input and esc, cancels. Comparison ignores case and extra whitespace,
# not content.
function script:Read-PSMMConfirmPhrase {
    param(
        [Parameter(Mandatory)][string]$Phrase,
        [string]$Warning
    )
    if ($Warning) { Write-PSMMProse -Text $Warning -Colour $script:PSMM_ColWarn }
    Write-PSMMLine "[$script:PSMM_ColMute]this cannot be undone from psmm $([char]0x2014) type [/][$script:PSMM_ColAccent]$(ConvertTo-PSMMSafe $Phrase)[/][$script:PSMM_ColMute] to go ahead, anything else cancels[/]"
    $typed = Read-PSMMText -Message "confirm" -AllowEmpty
    if ($null -eq $typed) { return $false }
    $norm = ("$typed".Trim() -replace '\s+', ' ')
    [string]::Equals($norm, $Phrase, [System.StringComparison]::OrdinalIgnoreCase)
}

# Bounded number picker (gh#14): a small panel with a sensible default
# preselected, up/dn to adjust, enter to accept, esc to cancel. $MaxReason is
# shown verbatim - a bare "max 16" tells the user nothing about why.
# Returns the chosen [int], or $null when cancelled.
function script:Read-PSMMNumber {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is used inside the live-display scriptblock; the rule cannot see into it.')]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Message,
        [int]$Default = 1,
        [int]$Min = 1,
        [int]$Max = 8,
        [string]$MaxReason,
        [string]$Unit = ''
    )
    $state = @{ Value = [Math]::Max($Min, [Math]::Min($Max, $Default)); Cancelled = $false }
    Invoke-PSMMLive -Body {
        param($ctx)
        while ($true) {
            $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
            $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColAccent]$(ConvertTo-PSMMSafe $Title)[/]"))
            if ($Message) {
                foreach ($l in (Get-PSMMProseMarkup -Text $Message)) { $items.Add([Spectre.Console.Markup]::new($l)) }
            }
            $bar = ('#' * ($state.Value - $Min + 1)).PadRight([Math]::Max(1, $Max - $Min + 1), '.')
            $items.Add([Spectre.Console.Markup]::new(
                    "[$script:PSMM_ColOk]$($state.Value)[/][$script:PSMM_ColMute]$(if ($Unit) { " $(ConvertTo-PSMMSafe $Unit)" })[/]  [$script:PSMM_ColDim]$bar  (min $Min, max $Max)[/]"))
            if ($MaxReason) {
                foreach ($l in (Get-PSMMProseMarkup -Text $MaxReason -Colour $script:PSMM_ColDim)) { $items.Add([Spectre.Console.Markup]::new($l)) }
            }
            $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('up/dn=change', 'enter=go', 'esc=cancel') -NoLegend)))
            $panel = [Spectre.Console.Panel]::new([Spectre.Console.Rows]::new($items))
            $panel.Border = [Spectre.Console.BoxBorder]::Rounded
            $panel.BorderStyle = [Spectre.Console.Style]::Parse($script:PSMM_ColAccent)
            $ctx.UpdateTarget($panel)
            $ctx.Refresh()
            $k = [Console]::ReadKey($true)
            if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; $state.Cancelled = $true; return }
            switch ($k.Key) {
                ([ConsoleKey]::UpArrow)    { $state.Value = [Math]::Min($Max, $state.Value + 1) }
                ([ConsoleKey]::RightArrow) { $state.Value = [Math]::Min($Max, $state.Value + 1) }
                ([ConsoleKey]::DownArrow)  { $state.Value = [Math]::Max($Min, $state.Value - 1) }
                ([ConsoleKey]::LeftArrow)  { $state.Value = [Math]::Max($Min, $state.Value - 1) }
                ([ConsoleKey]::Home)       { $state.Value = $Min }
                ([ConsoleKey]::End)        { $state.Value = $Max }
                ([ConsoleKey]::Enter)      { return }
                ([ConsoleKey]::Escape)     { $state.Cancelled = $true; return }
            }
        }
    }
    if ($state.Cancelled) { return $null }
    $state.Value
}
