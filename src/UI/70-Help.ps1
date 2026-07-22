# 70-Help.ps1 — tabbed help (design-system-v2 §7): '?' opens the current
# screen's help as tabs `this screen | keys | config | startup | about`;
# left/right switches, '/' filters within the visible tab, 'c' copies it,
# esc backs out (clearing an active filter first).
#
# EVERY tab is Spectre MARKUP, not escaped plain text (gh#8): help that
# describes a coloured, capsuled screen in flat monospace does not look like
# the thing it documents. Keys render as real capsules through Get-PSMMKeyCap,
# state glyphs carry their live colours, code goes through Format-PSMMCode and
# URLs through Get-PSMMLinkMarkup. Get-PSMMHelpText flattens all of it back to
# plain text for `c` copy and the tests.

# --- section building blocks ---------------------------------------------

# 14, not 12: a key capsule renders as ' key ', i.e. two columns wider than the
# key itself, and the widest key in the help is 'left/right' (12 columns). At
# 12 the pad floor of 1 pushed long-key rows one column right of everything
# else - the description column has to line up or the block reads as ragged.
$script:PSMM_HelpKeyWidth = 14

function script:Get-PSMMHelpHead {
    param([Parameter(Mandatory)][string]$Text)
    @(
        "[$script:PSMM_ColAccent]$(ConvertTo-PSMMSafe $Text)[/]"
        "[$script:PSMM_ColDim]$('-' * $Text.Length)[/]"
    )
}

# "  <capsule>   description" - the shape the live screens use.
function script:Get-PSMMHelpRow {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Text
    )
    $pad = ' ' * [Math]::Max(1, $script:PSMM_HelpKeyWidth - ($Key.Length + 2))
    "  $(Get-PSMMKeyCap -Key $Key)$pad[$script:PSMM_ColMute]$(ConvertTo-PSMMSafe $Text)[/]"
}

# Continuation line under a key row, aligned with its description column.
function script:Get-PSMMHelpCont {
    param([AllowEmptyString()][string]$Text)
    "  $(' ' * $script:PSMM_HelpKeyWidth)[$script:PSMM_ColMute]$(ConvertTo-PSMMSafe $Text)[/]"
}

# "  term        <markup>" for column/field explanations (term in accent).
# An empty term is the continuation line of the term above it.
function script:Get-PSMMHelpTerm {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Term,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Markup
    )
    $pad = ' ' * [Math]::Max(1, $script:PSMM_HelpKeyWidth - $Term.Length)
    if (-not $Term) { return "  $(' ' * $script:PSMM_HelpKeyWidth)$Markup" }
    "  [$script:PSMM_ColAccent]$(ConvertTo-PSMMSafe $Term)[/]$pad$Markup"
}

function script:Get-PSMMHelpText1 {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return '' }
    "[$script:PSMM_ColMute]$(ConvertTo-PSMMSafe $Text)[/]"
}

function script:Get-PSMMHelpSection {
    param([Parameter(Mandatory)][string]$Topic)
    $mid = [char]0x00B7
    switch ($Topic) {
        'grid' { @(
            (Get-PSMMHelpHead 'MAIN SCREEN (module grid)')
            (Get-PSMMHelpText1 'Every module your config files declare, one row each.')
            ''
            (Get-PSMMHelpTerm 'state' ("[$script:PSMM_ColOk]$([char]0x25CF) loaded[/][$script:PSMM_ColMute] (this session) $mid [/][$script:PSMM_ColWarn]$([char]0x25D0) installed[/][$script:PSMM_ColMute] (on disk)[/]"))
            (Get-PSMMHelpTerm '' ("[$script:PSMM_ColErr]$([char]0x25CB) missing[/][$script:PSMM_ColMute] $mid [/][$script:PSMM_ColInfo]$([char]0x25CC) unmanaged[/][$script:PSMM_ColMute] (in no config file - m shows them)[/]"))
            (Get-PSMMHelpTerm 'startup' (Get-PSMMHelpText1 'what happens at shell start: load / install (background) / off'))
            (Get-PSMMHelpTerm 'upkeep' (Get-PSMMHelpText1 'how psmm keeps it on disk: if-missing / check-only / latest'))
            (Get-PSMMHelpTerm '' (Get-PSMMHelpText1 '+pre means prerelease versions are allowed for that entry'))
            (Get-PSMMHelpTerm 'version' (Get-PSMMHelpText1 'loaded (or newest installed), prerelease label and all:'))
            (Get-PSMMHelpTerm '' ("$(Get-PSMMVersionMarkup -Version '0.1.0' -Prerelease 'beta8')[$script:PSMM_ColMute] is not [/]$(Get-PSMMVersionMarkup -Version '0.1.0')"))
            (Get-PSMMHelpTerm '' ("[$script:PSMM_ColWarn]$([char]0x21E1)[/][$script:PSMM_ColMute] = update available (after a k check); the cursor row[/]"))
            (Get-PSMMHelpTerm '' (Get-PSMMHelpText1 'names the target. pin = pinned to a version.'))
            (Get-PSMMHelpTerm 'scope' (Get-PSMMHelpText1 'user (CurrentUser) / all (AllUsers) / mixed. "all ro" means'))
            (Get-PSMMHelpTerm '' (Get-PSMMHelpText1 'the session is not elevated, so AllUsers copies are read-only.'))
            (Get-PSMMHelpTerm '' ("[$script:PSMM_ColErr]$([char]0x26A0)[/][$script:PSMM_ColMute] after the name: the entry has validation issues (g c details)[/]"))
            ''
            (Get-PSMMHelpText1 'The muted sentence under the table explains the cursor row in full')
            (Get-PSMMHelpText1 'words. The last hint row is the same on every screen: g goto,')
            (Get-PSMMHelpText1 '/ filter, ? help, ^q quit.')
            ''
            (Get-PSMMHelpRow 'space' 'select/deselect row (bulk actions target the selection,')
            (Get-PSMMHelpCont 'or just the cursor row when nothing is selected)')
            (Get-PSMMHelpRow 'enter' 'open the module action menu')
            (Get-PSMMHelpRow 'left/right' 'back out / open the row - the same pair on every screen')
            (Get-PSMMHelpRow '^l' 'load into this session')
            (Get-PSMMHelpRow '^u' 'unload from this session   (^ means ctrl)')
            (Get-PSMMHelpRow 'i' 'install the targeted modules that are missing (background)')
            (Get-PSMMHelpRow 'u' 'update the targeted installed modules (background) -')
            (Get-PSMMHelpCont 'install and update are always separate keys')
            (Get-PSMMHelpRow 'k' 'check the gallery for updates (background)')
            (Get-PSMMHelpRow 'a' 'add a new entry')
            (Get-PSMMHelpRow 'r' 'reload everything from disk')
            (Get-PSMMHelpRow 'm' 'show/hide installed-but-unmanaged modules')
        ) }
        'module' { @(
            (Get-PSMMHelpHead 'MODULE MENU')
            (Get-PSMMHelpText1 'Facts and actions for one module, grouped by what they touch:')
            (Get-PSMMHelpText1 'session (this pwsh), upkeep (install/update/clean), entry (the config')
            (Get-PSMMHelpText1 'file line), files (the folders on disk), connection (Connect-*')
            (Get-PSMMHelpText1 'modules). Only actions that make sense for the row are offered.')
            ''
            (Get-PSMMHelpText1 'The facts panel answers "which copy is being used, and from where?":')
            (Get-PSMMHelpTerm 'path' (Get-PSMMHelpText1 'the folder the newest installed version lives in'))
            (Get-PSMMHelpTerm 'location' (Get-PSMMHelpText1 'the search-path root above it, its search order, and'))
            (Get-PSMMHelpTerm '' (Get-PSMMHelpText1 'whether that root is OneDrive-backed'))
            (Get-PSMMHelpTerm 'versions' (Get-PSMMHelpText1 'every installed version with its scope (x cleans up)'))
            (Get-PSMMHelpTerm 'cloud' (Get-PSMMHelpText1 'files still cloud-only - downloaded before the next load'))
            ''
            (Get-PSMMHelpRow '^l' 'load into this session')
            (Get-PSMMHelpRow '^u' 'unload from this session   (^ means ctrl)')
            (Get-PSMMHelpRow 'i' 'install (when missing) - foreground, with progress')
            (Get-PSMMHelpRow 'u' 'update (when installed) - always a separate key')
            (Get-PSMMHelpRow 'b' "browse the module's commands with full help")
            (Get-PSMMHelpRow 'v' 'pin the entry to a version: pick from the versions on disk')
            (Get-PSMMHelpCont 'and in the gallery, or type a NuGet range like "[1.0,2.0)".')
            (Get-PSMMHelpCont 'Pinned modules are never nagged to update.')
            (Get-PSMMHelpRow 'w' 'allow / disallow prerelease versions for this entry')
            (Get-PSMMHelpRow 'x' 'remove all but the newest installed version')
            (Get-PSMMHelpRow 'p' 'move the module folder to another module location')
            (Get-PSMMHelpRow 's' 'check connection status (Connect-* modules: Graph, Az, EXO,')
            (Get-PSMMHelpCont 'PnP, Teams)')
            (Get-PSMMHelpRow 'o' 'disconnect the active session')
            (Get-PSMMHelpRow 'a' '(unmanaged modules) add to a config file')
            (Get-PSMMHelpRow 'e' 'edit the entry fields')
            (Get-PSMMHelpRow 'd' 'delete the entry')
            (Get-PSMMHelpRow 'm' 'move the entry to another config file')
            (Get-PSMMHelpRow 'left/right' 'back out / browse commands')
        ) }
        'commands' { @(
            (Get-PSMMHelpHead 'COMMAND BROWSER')
            (Get-PSMMHelpText1 'All commands the module exports.')
            ''
            (Get-PSMMHelpRow '/' 'filter (the same everywhere)')
            (Get-PSMMHelpRow 'enter' 'open tabbed help: Overview | Parameters | Examples')
            (Get-PSMMHelpRow 'left/right' 'back out / open - and, inside the help, switch tab')
            (Get-PSMMHelpRow 'up/dn' 'scroll')
            (Get-PSMMHelpRow 'c' 'copy the tab you are viewing to the clipboard')
            ''
            (Get-PSMMHelpText1 'Tip: help is much richer once the module is imported.')
        ) }
        'files' { @(
            (Get-PSMMHelpHead 'CONFIG FILES')
            (Get-PSMMHelpText1 'Every config source psmm found, in load order.')
            ''
            (Get-PSMMHelpRow 'space' 'toggle a whole file on/off (saved immediately)')
            (Get-PSMMHelpRow 'a' 'apply the load/unload changes to the running session')
            (Get-PSMMHelpRow 'n' 'create a new config, blank or from a scenario template')
            (Get-PSMMHelpRow 'm' 'move a file and keep it discoverable (Includes updated)')
            (Get-PSMMHelpRow 'left' 'back out')
            ''
            (Get-PSMMHelpText1 "A disabled file's entries are kept in the file untouched - disabling")
            (Get-PSMMHelpText1 'is how you park a whole module set ("work", "lab", ...).')
        ) }
        'paths' { @(
            (Get-PSMMHelpHead 'MODULE LOCATIONS')
            (Get-PSMMHelpText1 'Every folder PowerShell searches for modules, in search order.')
            (Get-PSMMHelpText1 'The FIRST entry is the CurrentUser location, which PowerShell')
            (Get-PSMMHelpText1 'derives from your Documents folder - when OneDrive backs up')
            (Get-PSMMHelpText1 'Documents (a common org policy), your modules silently live in')
            (Get-PSMMHelpText1 'OneDrive, and "Files On-Demand" can make them cloud-only')
            (Get-PSMMHelpText1 'placeholders that stall or fail module loading.')
            ''
            (Get-PSMMHelpRow 'd' 'download (hydrate) every cloud-only file under the')
            (Get-PSMMHelpCont 'highlighted path - asks how many to fetch at once first')
            (Get-PSMMHelpRow 'k' 'keep on this device: pin the folder so OneDrive keeps all')
            (Get-PSMMHelpCont 'files local from now on (downloads in the background)')
            (Get-PSMMHelpRow 'n' 'add a module location (creates the folder when needed) and')
            (Get-PSMMHelpCont 'optionally persist it for new sessions')
            (Get-PSMMHelpRow 'm' 'move every module folder from here to another location -')
            (Get-PSMMHelpCont 'gated behind typing "really move"; loaded modules and name')
            (Get-PSMMHelpCont 'collisions are skipped, never forced')
            (Get-PSMMHelpRow 's' 'set the primary (CurrentUser) module location - creates the')
            (Get-PSMMHelpCont 'folder if needed and writes the documented PSModulePath')
            (Get-PSMMHelpCont 'override to your user powershell.config.json. Caveat:')
            (Get-PSMMHelpCont 'Install-PSResource still installs to the Documents default.')
            (Get-PSMMHelpRow 'r' 'remove that override again')
            (Get-PSMMHelpRow 'left/right' 'back out / show what a location holds')
            ''
            (Get-PSMMHelpText1 'psmm also checks for cloud-only files before loading a module (with')
            (Get-PSMMHelpText1 'a prompt in the module menu / apply, silently with a status line in')
            (Get-PSMMHelpText1 'grid bulk loads).')
        ) }
        'gallery' { @(
            (Get-PSMMHelpHead 'GALLERY SEARCH')
            (Get-PSMMHelpText1 'Searches the PowerShell Gallery (read-only). Wildcards work:')
            (Get-PSMMHelpText1 'Az.*, Microsoft.Graph*.')
            ''
            (Get-PSMMHelpRow 'enter' 'add the highlighted module to one of your config files -')
            (Get-PSMMHelpCont 'pick install policy and mode, done')
            (Get-PSMMHelpRow '/' 'start a new search')
            (Get-PSMMHelpRow 'left/right' 'back out / add')
        ) }
        'cleanup' { @(
            (Get-PSMMHelpHead 'VERSION CLEANUP')
            (Get-PSMMHelpText1 'Update-Module and Update-PSResource never delete old versions -')
            (Get-PSMMHelpText1 'they accumulate on disk forever. This screen lists every module')
            (Get-PSMMHelpText1 'with more than one installed version.')
            ''
            (Get-PSMMHelpRow 'enter' 'prune one module to its newest version')
            (Get-PSMMHelpRow '^a' 'prune all of them   (^ means ctrl)')
            (Get-PSMMHelpRow 'r' 'rescan')
            (Get-PSMMHelpRow 'left/right' 'back out / prune the row')
            ''
            (Get-PSMMHelpText1 'Without elevation, AllUsers copies are skipped automatically.')
        ) }
        'tasks' { @(
            (Get-PSMMHelpHead 'BACKGROUND TASKS')
            (Get-PSMMHelpText1 'Everything psmm runs in the background lands here: install batches')
            (Get-PSMMHelpText1 '(i), update batches (u), update checks (k), the unmanaged-module')
            (Get-PSMMHelpText1 'scan, and Update-Help.')
            ''
            (Get-PSMMHelpRow 'enter' "show a task's full output")
            (Get-PSMMHelpRow 'u' 'start a background Update-Help')
            (Get-PSMMHelpRow 'c' 'clear finished tasks')
            (Get-PSMMHelpRow 'left/right' 'back out / open the output')
            ''
            (Get-PSMMHelpText1 'The grid keeps working while tasks run; a one-line overlay shows')
            (Get-PSMMHelpText1 'progress.')
        ) }
        default { @() }
    }
}

# keys tab: the grouped two-column capsule layout (mock 2c).
function script:Get-PSMMHelpKeysLines {
    $col1 = @(
        "[$script:PSMM_ColAccent]navigate[/]"
        (Get-PSMMHint -NoLegend -Pairs @('up/dn=move', 'pgup/pgdn=page'))
        (Get-PSMMHint -NoLegend -Pairs @('home/end=top / bottom'))
        (Get-PSMMHint -NoLegend -Pairs @('/=filter (enter keeps, esc clears)'))
        # spelled out, never as arrow glyphs - one notation everywhere (gh#7)
        (Get-PSMMHint -NoLegend -Pairs @('left/right=back out / drill in'))
        ''
        "[$script:PSMM_ColAccent]go places[/]"
        (Get-PSMMHint -NoLegend -Pairs @('g=goto: h g f p t c x ?'))
        (Get-PSMMHint -NoLegend -Pairs @('esc=back one level'))
        (Get-PSMMHint -NoLegend -Pairs @('^q=quit from anywhere'))
        "[$script:PSMM_ColDim]^ = ctrl[/]"
    )
    $col2 = @(
        "[$script:PSMM_ColAccent]act on modules[/]"
        (Get-PSMMHint -NoLegend -Pairs @('space=select', 'enter=actions'))
        (Get-PSMMHint -NoLegend -Pairs @('i=install missing (background)'))
        (Get-PSMMHint -NoLegend -Pairs @('u=update installed (background)'))
        (Get-PSMMHint -NoLegend -Pairs @('k=check the gallery for updates'))
        (Get-PSMMHint -NoLegend -Pairs @('^l=load', '^u=unload'))
        (Get-PSMMHint -NoLegend -Pairs @('a=add entry', 'r=reload from disk'))
        (Get-PSMMHint -NoLegend -Pairs @('m=show/hide unmanaged'))
        ''
        "[$script:PSMM_ColAccent]everywhere[/]"
        (Get-PSMMHint -NoLegend -Pairs @('?=help', 'c=copy (text screens)'))
        "[$script:PSMM_ColDim]bulk verbs target the selection, or[/]"
        "[$script:PSMM_ColDim]the cursor row when none is selected[/]"
    )
    $w = 0
    foreach ($l in $col1) {
        $len = [Spectre.Console.Markup]::Remove($l).Length
        if ($len -gt $w) { $w = $len }
    }
    $w += 4
    $rows = for ($i = 0; $i -lt [Math]::Max($col1.Count, $col2.Count); $i++) {
        $l = if ($i -lt $col1.Count) { $col1[$i] } else { '' }
        $r = if ($i -lt $col2.Count) { $col2[$i] } else { '' }
        $pad = ' ' * [Math]::Max(0, $w - [Spectre.Console.Markup]::Remove($l).Length)
        "$l$pad$r"
    }
    @($rows)
}

# config tab: discovery order, file format, rules. The JSON sample is
# syntax-highlighted (gh#9) - it is the densest block of text in the whole UI.
function script:Get-PSMMHelpConfigLines {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Get-PSMMHelpHead 'WHERE PSMM LOOKS (in load order)')) { $out.Add($l) }
    $out.Add((Get-PSMMHelpText1 '  1. inline JSON in $PSMM_InlineJson       (set in $PROFILE; read-only)'))
    $out.Add((Get-PSMMHelpText1 "  2. MAIN config:    $(Get-PSMMMainConfigPath)"))
    $out.Add((Get-PSMMHelpText1 '  3. files listed in the MAIN config''s "Includes" (one level, main only)'))
    $profileCfg = Get-PSMMProfileConfigPath
    if ($profileCfg) { $out.Add((Get-PSMMHelpText1 "  4. profile-dir:    $profileCfg")) }
    $out.Add((Get-PSMMHelpText1 '  5. legacy globs in $PSMM_JsonPath (default: psmodules.d next to $PROFILE)'))
    $out.Add('')
    foreach ($l in (Get-PSMMHelpHead 'FILE FORMAT (psmm-config.json)')) { $out.Add($l) }
    $json = @(
        '  {'
        '    "Enabled": true,          // false = file parsed but nothing actioned'
        '    "Includes": ["C:\\path\\more.json"],   // MAIN config only'
        '    "Modules": ['
        '      {'
        '        "Name": "ImportExcel",           // required: gallery name'
        '        "FriendlyName": "Import Excel",  // optional display name'
        '        "Description": "what/why",       // optional'
        '        "Install": "IfMissing",          // CheckOnly | IfMissing | Latest'
        '        "Mode": "Load",                  // Load | InstallOnly | Ignore'
        '        "Version": "1.2.3",              // optional pin (or "[1.0,2.0)")'
        '        "Prerelease": true               // optional: allow prerelease versions'
        '      }'
        '    ]'
        '  }'
    )
    foreach ($l in (Format-PSMMCode -Text $json -Language json)) { $out.Add($l) }
    $out.Add('')
    $out.Add((Get-PSMMHelpText1 '  The UI shows Mode as the startup column (load / install / off) and'))
    $out.Add((Get-PSMMHelpText1 '  Install as the upkeep column (if-missing / check-only / latest);'))
    $out.Add((Get-PSMMHelpText1 '  Prerelease shows there too, as "+pre".'))
    $out.Add('')
    foreach ($l in (Get-PSMMHelpHead 'RULES')) { $out.Add($l) }
    $out.Add((Get-PSMMHelpText1 '  - Only the MAIN config may include other files (one level deep, so'))
    $out.Add((Get-PSMMHelpText1 '    circular references are impossible). Includes anywhere else are'))
    $out.Add((Get-PSMMHelpText1 '    ignored with a warning.'))
    $out.Add((Get-PSMMHelpText1 '  - Same module in several files: the MAIN config wins (warning);'))
    $out.Add((Get-PSMMHelpText1 '    otherwise the first-loaded file wins (error-style warning).'))
    $out.Add((Get-PSMMHelpText1 '  - "Enabled": false switches a whole file off without losing entries.'))
    @($out)
}

# startup tab: the $PROFILE bootstrap and its knobs. The code is highlighted
# (gh#9); the prose around it is not.
function script:Get-PSMMHelpStartupLines {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Get-PSMMHelpHead '$PROFILE BOOTSTRAP')) { $out.Add($l) }
    foreach ($l in (Format-PSMMCode -Text @('  Import-Module psmm; Invoke-PSMMStartup'))) { $out.Add($l) }
    $out.Add('')
    $out.Add((Get-PSMMHelpText1 '  Knobs, set before Import-Module:'))
    $knobs = @(
        '  $PSMM_StartupReport = $false      # no per-module report at startup'
        '  $PSMM_BackgroundStartup = $false  # run InstallOnly work inline'
        '  $PSMM_UpdateCheck = $false        # no self-update check'
        '  $PSMM_InlineJson = ''{ ... }''      # config in the profile itself'
        '  $PSMM_JsonPath = ''~/psmodules.d/*.json'''
        '  $PSMM_Theme = ''glacier''           # glacier (default) | ember | moss'
    )
    foreach ($l in (Format-PSMMCode -Text $knobs)) { $out.Add($l) }
    $out.Add('')
    $out.Add((Get-PSMMHelpText1 '  Install and Mode are independent: Mode decides load / install-only /'))
    $out.Add((Get-PSMMHelpText1 '  ignore (and foreground vs background at startup); Install decides the'))
    $out.Add((Get-PSMMHelpText1 '  disk/gallery policy (never install / install when missing / update).'))
    $out.Add('')
    $out.Add((Get-PSMMHelpTerm '  Load' (Get-PSMMHelpText1 'imported into this session, in the foreground.')))
    $out.Add((Get-PSMMHelpTerm '  InstallOnly' (Get-PSMMHelpText1 'disk/gallery work only - deferred to a')))
    $out.Add((Get-PSMMHelpTerm '' (Get-PSMMHelpText1 'background job so your prompt appears sooner.')))
    $out.Add((Get-PSMMHelpTerm '  Ignore' (Get-PSMMHelpText1 'parsed but not actioned.')))
    $out.Add('')
    $out.Add((Get-PSMMHelpText1 '  Modules are imported into YOUR session (Import-Module -Global), so'))
    $out.Add((Get-PSMMHelpText1 '  their commands work at the prompt and Get-Module lists them.'))
    $out.Add('')
    $out.Add((Get-PSMMHelpText1 '  Each imported module''s import time is measured and reported, so you'))
    $out.Add((Get-PSMMHelpText1 '  always know which module is slowing your shell down.'))
    @($out)
}

# about tab: version, engine, self-update detail (the header bar shows only
# the compact flag - the exact command lives here).
function script:Get-PSMMHelpAboutLines {
    $ui = $script:PSMM_UI
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Get-PSMMHelpHead 'psmm - PS Session Module Manager')) { $lines.Add($l) }
    $ver = if ($ui -and $ui.Version) { "v$($ui.Version)" } else { '' }
    $eng = if ($ui -and $ui.Engine) { "$($ui.Engine)" } else { '' }
    $lines.Add((Get-PSMMHelpText1 ("$ver $([char]0x00B7) install engine $eng$(if ($ui -and $ui.Elevated) { " $([char]0x00B7) elevated" })").Trim()))
    # a real terminal hyperlink - ctrl+click it (gh#10)
    $lines.Add((Get-PSMMLinkMarkup -Url 'https://github.com/PBNZ/psmm' -Text 'github.com/PBNZ/psmm'))
    $lines.Add('')
    if ($ui -and $ui.SelfUpdate) {
        $u = $ui.SelfUpdate
        $lines.Add("[$script:PSMM_ColWarn]$([char]0x21E1) psmm v$($u.Latest) is available (you have v$($u.Current))[/]")
        $lines.Add((Get-PSMMHelpText1 'update with:'))
        foreach ($l in (Format-PSMMCode -Text @("  $($u.Command)"))) { $lines.Add($l) }
        $lines.Add((Get-PSMMHelpText1 'then restart pwsh.'))
    } else {
        $lines.Add((Get-PSMMHelpText1 'psmm checks the gallery for its own updates once a day (cached,'))
        # the string must be built BEFORE the call: passed as bare arguments,
        # 'a' + $glyph + ',' binds as five positional args and a non-advanced
        # function silently drops the surplus - the glyph vanished
        $lines.Add((Get-PSMMHelpText1 ('never in the profile hot path); the header bar flags one with ' + [char]0x21E1 + ',')))
        $lines.Add((Get-PSMMHelpText1 'and this tab then shows the exact update command.'))
    }
    $lines.Add('')
    $lines.Add((Get-PSMMHelpText1 'While psmm is in prerelease, beta-to-beta updates need a forced'))
    $lines.Add((Get-PSMMHelpText1 'reinstall:'))
    foreach ($l in (Format-PSMMCode -Text @('  Install-PSResource psmm -Prerelease -Reinstall'))) { $lines.Add($l) }
    $lines.Add((Get-PSMMHelpText1 'then restart pwsh. u on psmm''s own grid row handles this correctly.'))
    @($lines)
}

# The five tabs for a topic. Values are arrays of MARKUP lines - including
# 'this screen', which used to be escaped plain text (gh#8).
function script:Get-PSMMHelpTabs {
    param([string]$Topic = 'grid')
    [ordered]@{
        'this screen' = @(Get-PSMMHelpSection -Topic $Topic)
        'keys'        = @(Get-PSMMHelpKeysLines)
        'config'      = @(Get-PSMMHelpConfigLines)
        'startup'     = @(Get-PSMMHelpStartupLines)
        'about'       = @(Get-PSMMHelpAboutLines)
    }
}

# Flattened plain-text help (all tabs) - used by tests and as a plain doc.
function script:Get-PSMMHelpText {
    param([string]$Topic = 'grid')
    $tabs = Get-PSMMHelpTabs -Topic $Topic
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('psmm - PS Session Module Manager')
    $lines.Add('================================')
    foreach ($name in $tabs.get_Keys()) {
        $lines.Add('')
        $lines.Add("== $($name.ToUpperInvariant()) ==")
        $lines.Add('')
        foreach ($l in $tabs[$name]) { $lines.Add([Spectre.Console.Markup]::Remove($l)) }
    }
    $lines
}

# One frame of the tabbed help. $State: @{ Tab; Scroll; Filter; FilterMode;
# Status }.
function script:Build-PSMMHelpView {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Tabs
    )
    $names = @($Tabs.get_Keys())
    $State.Tab = [Math]::Max(0, [Math]::Min($State.Tab, $names.Count - 1))
    $lines = @($Tabs[$names[$State.Tab]])
    if ($State.Filter) {
        $needle = $State.Filter
        $lines = @($lines | Where-Object { Test-PSMMFilterMatch -Text ([Spectre.Console.Markup]::Remove($_)) -Filter $needle })
    }
    $win = Get-PSMMWinSize
    $page = [Math]::Max(5, $win.Height - 9)
    $State.Scroll = [Math]::Max(0, [Math]::Min($State.Scroll, [Math]::Max(0, $lines.Count - $page)))
    $visible = @($lines | Select-Object -Skip $State.Scroll -First $page)
    $tabBar = (0..($names.Count - 1) | ForEach-Object {
        if ($_ -eq $State.Tab) { "[$script:PSMM_ColAccent underline]$($names[$_])[/]" } else { "[$script:PSMM_ColDim]$($names[$_])[/]" }
    }) -join '  '
    $pos = if ($lines.Count -gt $page) {
        "  [$script:PSMM_ColMute]lines $($State.Scroll + 1)-$([Math]::Min($lines.Count, $State.Scroll + $page))/$($lines.Count)[/]"
    } else { '' }
    $flt = Get-PSMMFilterMarkup -State $State
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb @('home', 'help') -CountsMarkup "$pos$flt")))
    $items.Add([Spectre.Console.Markup]::new($tabBar))
    $panel = [Spectre.Console.Panel]::new([Spectre.Console.Markup]::new(($visible -join "`n")))
    $panel.Border = [Spectre.Console.BoxBorder]::Rounded
    $panel.BorderStyle = Get-PSMMBorderStyle
    $items.Add($panel)
    if ($State.FilterMode) {
        $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('type=filter', 'enter=apply', 'esc=clear & exit filter'))))
    } else {
        $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('left/right=switch tab', 'up/dn=scroll', 'c=copy tab') -NoLegend)))
        $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", '/=filter', 'esc=back', '^q=quit'))))
    }
    if ($State.Status) { $items.Add([Spectre.Console.Markup]::new($State.Status)) }
    [Spectre.Console.Rows]::new($items)
}

function script:Show-PSMMHelpScreen {
    param(
        [string]$Topic = 'grid',
        [string]$InitialTab = 'this screen'
    )
    $tabs = Get-PSMMHelpTabs -Topic $Topic
    $names = @($tabs.get_Keys())
    $start = [Array]::IndexOf($names, $InitialTab)
    $st = @{ Tab = [Math]::Max(0, $start); Scroll = 0; Filter = ''; FilterMode = $false; Status = '' }
    Clear-PSMMScreen
    Invoke-PSMMLive -Body {
        param($ctx)
        while ($true) {
            if ($script:PSMM_UI.HardQuit) { return }
            $ctx.UpdateTarget((Build-PSMMHelpView -State $st -Tabs $tabs))
            $ctx.Refresh()
            $k = Read-PSMMKeyResize
            if ($null -eq $k) { continue }
            if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; return }
            if ($st.FilterMode) {
                $r = Invoke-PSMMFilterKey -State $st -KeyInfo $k
                if ($r) { $st.Scroll = 0; continue }
                $null = Invoke-PSMMPagerNav -State $st -KeyInfo $k
                continue
            }
            if ($k.KeyChar -eq 'g') {
                $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMHelpView -State $st -Tabs $tabs)
                if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                continue
            }
            if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
            $st.Status = ''
            switch ($k.Key) {
                ([ConsoleKey]::LeftArrow)  { $st.Tab = ($st.Tab + $names.Count - 1) % $names.Count; $st.Scroll = 0; continue }
                ([ConsoleKey]::RightArrow) { $st.Tab = ($st.Tab + 1) % $names.Count; $st.Scroll = 0; continue }
                ([ConsoleKey]::Escape)     {
                    if ($st.Filter) { $st.Filter = ''; $st.Scroll = 0; continue }
                    return
                }
                default {
                    if ($k.KeyChar -eq '/') { $st.FilterMode = $true; continue }
                    if ($k.KeyChar -eq 'c') {
                        $plain = @($tabs[$names[$st.Tab]] | ForEach-Object { [Spectre.Console.Markup]::Remove($_) })
                        $st.Status = Copy-PSMMText -Text ($plain -join [Environment]::NewLine)
                        continue
                    }
                    $null = Invoke-PSMMPagerNav -State $st -KeyInfo $k
                }
            }
        }
    }
    Clear-PSMMScreen
}
