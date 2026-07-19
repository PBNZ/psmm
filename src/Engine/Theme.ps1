# Theme.ps1 — design tokens shared by the TUI (Spectre markup names) and the
# startup report (raw 256-colour escapes). One source of truth: the UI layer
# (src/UI/00-Theme.ps1) reads its palette from here, and the report renders
# the same tokens without Spectre being loaded at profile time.
# Markup names verified against the Spectre.Console colour table; Index is
# the matching xterm-256 number the escape sequences use.

function Get-PSMMThemeName { 'glacier' }

function Get-PSMMThemeTable {
    [CmdletBinding()]
    param([string]$Name = (Get-PSMMThemeName))
    switch ($Name) {
        # glacier (default) - docs/design-system-v2.md §1; unknown names fall
        # back here too
        default {
            @{
                key     = @{ Markup = 'salmon1';      Index = 209 }
                mute    = @{ Markup = 'grey66';       Index = 248 }
                accent  = @{ Markup = 'deepskyblue1'; Index = 39 }
                ok      = @{ Markup = 'green3';       Index = 34 }
                warn    = @{ Markup = 'orange1';      Index = 214 }
                err     = @{ Markup = 'indianred1';   Index = 203 }
                info    = @{ Markup = 'steelblue1';   Index = 75 }
                dim     = @{ Markup = 'grey42';       Index = 242 }
                capsule = @{ Markup = 'grey19';       Index = 236 }
                rowbg   = @{ Markup = 'grey15';       Index = 235 }
                border  = @{ Markup = 'grey27';       Index = 238 }
                brandfg = @{ Markup = 'black';        Index = 0 }
                brandbg = @{ Markup = 'salmon1';      Index = 209 }
                capsdim = @{ Markup = 'grey11';       Index = 234 }
            }
        }
    }
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
