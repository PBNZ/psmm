# 04-Render.ps1 — the cross-cutting rendering primitives every screen must go
# through (design system §11): code and commands, links, prose, versions.
#
# The rule these exist to enforce: a screen never hand-formats one of these
# four things. Before this file, code was flat text, one command was
# hand-coloured cyan, URLs were dead text and prose ran the full terminal
# width. Colours come from the theme tokens only (00-Theme.ps1), so all three
# themes keep working and the palette guard test stays green.

# --- prose ----------------------------------------------------------------

# The measure prose wraps at: never wider than the window (less a margin),
# never wider than ~84 columns, because a paragraph running a 200-column
# terminal edge to edge is unreadable (gh#11).
function script:Get-PSMMProseWidth {
    param([int]$Max = 84, [int]$Margin = 4)
    $win = Get-PSMMWinSize
    [Math]::Max(24, [Math]::Min($Max, $win.Width - $Margin))
}

# Word-wrap PLAIN text (no markup - see Get-PSMMProseMarkup for the styled
# version). Existing line breaks are kept; blank lines survive as blank lines.
# A single token longer than the measure is NOT broken: a hard-broken URL or
# path stops being copyable, which is worse than one over-long line. Long
# paths in the UI go through Get-PSMMTrunc instead.
function script:Get-PSMMWrapText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$Width = 0
    )
    if ($Width -le 0) { $Width = Get-PSMMProseWidth }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($para in ("$Text" -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($para)) { $out.Add(''); continue }
        # keep the paragraph's own leading indent on continuation lines
        $indent = ''
        if ($para -match '^(\s+)') { $indent = $Matches[1] }
        $line = ''
        foreach ($w in ($para -split '\s+' | Where-Object { $_ })) {
            if (-not $line) { $line = "$indent$w"; continue }
            if (($line.Length + 1 + $w.Length) -le $Width) { $line += " $w" }
            else { $out.Add($line); $line = "$indent$w" }
        }
        if ($line) { $out.Add($line) }
    }
    @($out)
}

# Wrap a filesystem path at SEPARATOR boundaries. Neither of the two obvious
# options works for a path: word wrap does nothing (a path is one long token,
# so the grid reflows it into ragged nonsense and blows the label column out),
# and truncation throws away the tail - which is the half that says WHICH
# module and WHICH version. Breaking after a '\' keeps every character and
# stays readable.
function script:Get-PSMMWrapPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [int]$Width = 0
    )
    if ($Width -le 0) { $Width = Get-PSMMProseWidth }
    $Width = [Math]::Max(12, $Width)
    if ([string]::IsNullOrEmpty($Path)) { return @('') }
    if ($Path.Length -le $Width) { return @($Path) }
    # each separator stays attached to the segment before it, so a wrapped
    # path still reads as a path
    $parts = @([regex]::Matches($Path, '[^\\/]*[\\/]?') | ForEach-Object { $_.Value } | Where-Object { $_ -ne '' })
    $lines = [System.Collections.Generic.List[string]]::new()
    $cur = ''
    foreach ($part in $parts) {
        $p = $part
        if ($cur -and ($cur.Length + $p.Length) -gt $Width) { $lines.Add($cur); $cur = '' }
        # one segment longer than the measure: hard-split it, there is no
        # better break point inside a single folder name
        while ($p.Length -gt $Width) {
            if ($cur) { $lines.Add($cur); $cur = '' }
            $lines.Add($p.Substring(0, $Width))
            $p = $p.Substring($Width)
        }
        $cur += $p
    }
    if ($cur) { $lines.Add($cur) }
    @($lines)
}

# Wrapped, escaped, styled prose as one markup string per line. Each line
# carries its own balanced tags, which is mandatory: every Markup/Write-PSMMLine
# is parsed on its own (there is a test for it).
function script:Get-PSMMProseMarkup {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Colour,
        [int]$Width = 0
    )
    $c = if ($Colour) { $Colour } else { $script:PSMM_ColMute }
    @(Get-PSMMWrapText -Text $Text -Width $Width | ForEach-Object {
            if ($_) { "[$c]$(ConvertTo-PSMMSafe $_)[/]" } else { '' }
        })
}

# Same, written straight to the console (full-screen prompt flows).
function script:Write-PSMMProse {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Colour,
        [int]$Width = 0
    )
    foreach ($l in (Get-PSMMProseMarkup -Text $Text -Colour $Colour -Width $Width)) { Write-PSMMLine $l }
}

# --- links ----------------------------------------------------------------

# A real terminal hyperlink (OSC 8) via Spectre's [link=...] style, so the URL
# is ctrl+clickable in Windows Terminal and friends (gh#10). Falls back to
# plain styled text for anything that cannot be expressed safely as a link -
# markup delimiters or whitespace in the URL would break the tag.
function script:Get-PSMMLinkMarkup {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Text,
        [string]$Colour
    )
    $c = if ($Colour) { $Colour } else { $script:PSMM_ColInfo }
    $label = ConvertTo-PSMMSafe $(if ($Text) { $Text } else { $Url })
    if ($Url -match '[\[\]\s]' -or [string]::IsNullOrWhiteSpace($Url)) { return "[$c]$label[/]" }
    "[$c link=$Url]$label[/]"
}

# Does this string look like something worth linking?
function script:Test-PSMMUrl {
    param([string]$Text)
    "$Text" -match '^(https?|ftp)://[^\s\[\]]+$'
}

# --- code and commands ----------------------------------------------------

# Token kind -> theme token. PSParser's type names, mapped once.
function script:Get-PSMMCodeColour {
    param([string]$Kind)
    switch ($Kind) {
        'Command'            { $script:PSMM_ColAccent }
        'CommandParameter'   { $script:PSMM_ColKey }
        'Keyword'            { $script:PSMM_ColKey }
        'String'             { $script:PSMM_ColOk }
        'Variable'           { $script:PSMM_ColInfo }
        'Type'               { $script:PSMM_ColInfo }
        'Attribute'          { $script:PSMM_ColInfo }
        'Comment'            { $script:PSMM_ColDim }
        'Number'             { $script:PSMM_ColWarn }
        'Operator'           { $script:PSMM_ColMute }
        'StatementSeparator' { $script:PSMM_ColMute }
        'GroupStart'         { $script:PSMM_ColMute }
        'GroupEnd'           { $script:PSMM_ColMute }
        'Member'             { $script:PSMM_ColMute }
        default              { '' }
    }
}

# Highlight one JSON line. Regex rather than a parser because the JSON psmm
# shows is a documentation sample with // comments - not valid JSON, so no
# parser would take it. Order matters: strings win over comments, so a '//'
# inside a quoted value stays a string.
function script:Format-PSMMJsonLine {
    param([AllowEmptyString()][string]$Line)
    $rx = '(?<key>"(?:[^"\\]|\\.)*")(?=\s*:)|(?<str>"(?:[^"\\]|\\.)*")|(?<comment>//.*$)|(?<lit>\b(?:true|false|null)\b)|(?<num>-?\b\d+(?:\.\d+)?\b)'
    $out = [System.Text.StringBuilder]::new()
    $pos = 0
    foreach ($m in [regex]::Matches("$Line", $rx)) {
        if ($m.Index -gt $pos) { [void]$out.Append((ConvertTo-PSMMSafe $Line.Substring($pos, $m.Index - $pos))) }
        $colour = if ($m.Groups['key'].Success) { $script:PSMM_ColAccent }
                  elseif ($m.Groups['str'].Success) { $script:PSMM_ColOk }
                  elseif ($m.Groups['comment'].Success) { $script:PSMM_ColDim }
                  elseif ($m.Groups['lit'].Success) { $script:PSMM_ColKey }
                  else { $script:PSMM_ColWarn }
        [void]$out.Append("[$colour]$(ConvertTo-PSMMSafe $m.Value)[/]")
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt "$Line".Length) { [void]$out.Append((ConvertTo-PSMMSafe $Line.Substring($pos))) }
    $out.ToString()
}

# Syntax-highlighted code as one markup string per input line (gh#9).
# PowerShell goes through PSParser, which hands back typed tokens with offsets
# into the whole snippet - accurate, in-box, no dependency. Colours are applied
# per CHARACTER and re-run per line, so a token that spans a newline (comment
# block, here-string) still leaves every emitted line individually balanced.
# Unparseable input degrades to escaped plain text rather than throwing.
function script:Format-PSMMCode {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Text,
        [ValidateSet('powershell', 'json')][string]$Language = 'powershell'
    )
    $lines = @(("$($Text -join "`n")") -split "`r?`n")
    if ($Language -eq 'json') { return @($lines | ForEach-Object { Format-PSMMJsonLine -Line $_ }) }
    $src = $lines -join "`n"
    if (-not $src) { return @($lines | ForEach-Object { ConvertTo-PSMMSafe $_ }) }
    $colours = [string[]]::new($src.Length)
    try {
        $errs = $null
        foreach ($t in [System.Management.Automation.PSParser]::Tokenize($src, [ref]$errs)) {
            $c = Get-PSMMCodeColour -Kind "$($t.Type)"
            if (-not $c) { continue }
            $end = [Math]::Min($src.Length, $t.Start + $t.Length)
            for ($i = [Math]::Max(0, $t.Start); $i -lt $end; $i++) { $colours[$i] = $c }
        }
    } catch {
        return @($lines | ForEach-Object { ConvertTo-PSMMSafe $_ })
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $pos = 0
    foreach ($line in $lines) {
        $sb = [System.Text.StringBuilder]::new()
        $i = 0
        while ($i -lt $line.Length) {
            $c = $colours[$pos + $i]
            $j = $i
            while ($j -lt $line.Length -and $colours[$pos + $j] -eq $c) { $j++ }
            $chunk = ConvertTo-PSMMSafe $line.Substring($i, $j - $i)
            if ($c) { [void]$sb.Append("[$c]$chunk[/]") } else { [void]$sb.Append($chunk) }
            $i = $j
        }
        $out.Add($sb.ToString())
        $pos += $line.Length + 1   # +1 for the newline the lines were joined with
    }
    @($out)
}

# One command, highlighted, for inline use in a sentence.
function script:Get-PSMMCommandMarkup {
    param([Parameter(Mandatory)][string]$Command)
    @(Format-PSMMCode -Text @($Command) -Language powershell) -join ' '
}

# --- versions -------------------------------------------------------------

# A version cell: base version in the caller's colour, prerelease label
# attached and tinted so "0.1.0-beta8" can never be mistaken for "0.1.0"
# (gh#6). Returns escaped markup.
function script:Get-PSMMVersionMarkup {
    param(
        $Version,
        [string]$Prerelease,
        [string]$Colour,
        [string]$Empty = '-'
    )
    if ($null -eq $Version -or "$Version" -eq '') { return "[$script:PSMM_ColDim]$Empty[/]" }
    $base = ConvertTo-PSMMSafe "$Version"
    $txt = if ($Colour) { "[$Colour]$base[/]" } else { $base }
    if ([string]::IsNullOrWhiteSpace($Prerelease)) { return $txt }
    "$txt[$script:PSMM_ColInfo]-$(ConvertTo-PSMMSafe ($Prerelease.TrimStart('-')))[/]"
}

# Plain "1.2.0-beta3" for prose and status lines.
function script:Get-PSMMVersionText {
    param($Version, [string]$Prerelease)
    Get-PSMMVersionDisplay -Version $Version -Prerelease $Prerelease
}
