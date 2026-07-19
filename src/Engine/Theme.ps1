# Theme.ps1 — design tokens shared by the TUI (Spectre markup names) and the
# startup report (raw 256-colour escapes). One source of truth: the UI layer
# (src/UI/00-Theme.ps1) reads its palette from here, and the report renders
# the same tokens without Spectre being loaded at profile time.
# Markup names verified against the Spectre.Console colour table; Index is
# the matching xterm-256 number the escape sequences use.

# Theme knob: $PSMM_Theme = 'glacier' | 'ember' | 'moss', set in $PROFILE
# before Import-Module psmm. Unknown values fall back to glacier; the UI
# shows a one-line status note (Test-PSMMThemeFallback).
function Get-PSMMThemeName {
    $t = "$(Get-PSMMSetting -Name 'PSMM_Theme' -Default 'glacier')".ToLowerInvariant()
    if ($t -in 'glacier', 'ember', 'moss') { $t } else { 'glacier' }
}

function Test-PSMMThemeFallback {
    $t = Get-PSMMSetting -Name 'PSMM_Theme'
    [bool]($t -and ("$t".ToLowerInvariant() -notin 'glacier', 'ember', 'moss'))
}

function Get-PSMMThemeTable {
    [CmdletBinding()]
    param([string]$Name = (Get-PSMMThemeName))
    # glacier (default) - docs/design-system-v2.md §1; variants are token
    # swaps on top of it (mockup 2g), nothing else changes
    $t = @{
        key     = @{ Markup = 'salmon1';      Index = 209 }
        mute    = @{ Markup = 'grey66';       Index = 248 }
        accent  = @{ Markup = 'deepskyblue1'; Index = 39 }
        ok      = @{ Markup = 'green3';       Index = 34 }
        warn    = @{ Markup = 'orange1';      Index = 214 }
        err     = @{ Markup = 'indianred1';   Index = 203 }
        info    = @{ Markup = 'steelblue1';   Index = 75 }
        dim     = @{ Markup = 'grey42';       Index = 242 }
        capsule = @{ Markup = 'grey19';       Index = 236 }
        # grey23, not the spec's grey15: once the cursor bar left the grid the
        # #262626 background all but vanished on black (live-run feedback
        # 2026-07-20); #3a3a3a reads as a highlight and stays below the border
        rowbg   = @{ Markup = 'grey23';       Index = 237 }
        # grey35, not the spec's grey27: #444 had too little contrast on a
        # black terminal background (live-run feedback 2026-07-20)
        border  = @{ Markup = 'grey35';       Index = 240 }
        brandfg = @{ Markup = 'black';        Index = 0 }
        brandbg = @{ Markup = 'salmon1';      Index = 209 }
        capsdim = @{ Markup = 'grey11';       Index = 234 }
    }
    switch ($Name) {
        'ember' {
            # all-warm, Claude-Code adjacent
            $t.accent  = @{ Markup = 'sandybrown';        Index = 215 }
            $t.ok      = @{ Markup = 'darkolivegreen3_1'; Index = 113 }
            $t.warn    = @{ Markup = 'gold1';             Index = 220 }
            $t.brandbg = @{ Markup = 'sandybrown';        Index = 215 }
        }
        'moss' {
            # terminal-classic
            $t.accent  = @{ Markup = 'palegreen3_1';    Index = 114 }
            $t.key     = @{ Markup = 'lightgoldenrod3'; Index = 179 }
            $t.brandbg = @{ Markup = 'palegreen3_1';    Index = 114 }
        }
    }
    $t
}

# 256-colour escape for a token (foreground, or background with -Background).
function Get-PSMMAnsi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$Background
    )
    $t = (Get-PSMMThemeTable)[$Token]
    if (-not $t) { return '' }
    "$([char]27)[$(if ($Background) { 48 } else { 38 });5;$($t.Index)m"
}

function Get-PSMMAnsiReset { "$([char]27)[0m" }
