# 70-Help.ps1 — tabbed help (design-system-v2 §7): '?' opens the current
# screen's help as tabs `this screen | keys | config | startup | about`;
# left/right switches, '/' filters within the visible tab, 'c' copies it,
# esc backs out (clearing an active filter first).
# Tab content lines are Spectre MARKUP strings (plain text pre-escaped), so
# the keys tab renders capsules; Get-PSMMHelpText flattens to plain text.

function script:Get-PSMMHelpSection {
    param([Parameter(Mandatory)][string]$Topic)
    switch ($Topic) {
        'grid' { @(
            'MAIN SCREEN (module grid)'
            '-------------------------'
            'Every module your config files declare, one row each.'
            ''
            '  state    ' + [char]0x25CF + ' loaded (this session) · ' + [char]0x25D0 + ' installed (on disk) ·'
            '           ' + [char]0x25CB + ' missing · ' + [char]0x25CC + ' unmanaged (in no config file - g m shows them)'
            '  startup  what happens at shell start: load / install (background) / off'
            '  gallery  what the gallery may do: if-missing / check-only / latest'
            '  version  loaded (or newest installed). ' + [char]0x21E1 + ' = update available (after'
            '           a k check); the cursor row names the target. pin = pinned.'
            '  scope    user (CurrentUser) / all (AllUsers) / mixed. "all ro" means'
            '           the session is not elevated, so AllUsers copies are read-only.'
            '  ' + [char]0x26A0 + '        after the name: the entry has validation issues (g c details)'
            ''
            'The muted sentence under the table explains the cursor row in full'
            'words. The last hint row is the same on every screen: g goto,'
            '/ filter, ? help, ^q quit.'
            ''
            '  space    select/deselect row (bulk actions target the selection,'
            '           or just the cursor row when nothing is selected)'
            '  enter    open the module action menu (right-arrow does the same;'
            '           left-arrow backs out of any menu)'
            '  ^l load    ^u unload    (^ means ctrl)'
            '  i        install the targeted modules that are missing (background)'
            '  u        update the targeted installed modules (background) -'
            '           install and update are always separate keys'
            '  k        check the gallery for updates (background)'
            '  a        add a new entry     r    reload everything from disk'
        ) }
        'module' { @(
            'MODULE MENU'
            '-----------'
            'Facts and actions for one module, grouped by what they touch:'
            'session (this pwsh), gallery (disk/network), entry (the config'
            'file line), connection (Connect-* modules). Only actions that'
            'make sense for the row are offered.'
            ''
            '  ^l / ^u  load / unload in this session (^ means ctrl)'
            '  i / u    install (when missing) / update (when installed) -'
            '           foreground, with progress; always separate keys'
            '  b        browse the module''s commands with full help'
            '  v        pin the entry to a version: exact "1.2.3" or a NuGet range'
            '           like "[1.0,2.0)". Pinned modules are never nagged to update.'
            '  x        remove all but the newest installed version'
            '  s        check connection status (Connect-* modules: Graph, Az, EXO,'
            '           PnP, Teams)   o  disconnect the active session'
            '  a        (unmanaged modules) add to a config file'
            '  e/d/m    edit fields / delete entry / move entry to another file'
        ) }
        'commands' { @(
            'COMMAND BROWSER'
            '---------------'
            'All commands the module exports. / filters (same as everywhere);'
            'enter opens tabbed help: Overview | Parameters | Examples,'
            'left/right switches tab, up/down scrolls, c copies the tab you'
            'are viewing to the clipboard.'
            'Tip: help is much richer once the module is imported.'
        ) }
        'files' { @(
            'CONFIG FILES'
            '------------'
            'Every config source psmm found, in load order. space toggles a whole'
            'file on/off (saved immediately - a applies the load/unload changes to'
            'the running session). n creates a new config, blank or from a scenario'
            'template. m moves a file and keeps it discoverable (Includes updated).'
            ''
            'A disabled file''s entries are kept in the file untouched - disabling'
            'is how you park a whole module set ("work", "lab", ...).'
        ) }
        'paths' { @(
            'MODULE LOCATIONS'
            '----------------'
            'Every folder PowerShell searches for modules ($env:PSModulePath), in'
            'search order. The FIRST entry is the CurrentUser location, which'
            'PowerShell derives from your Documents folder - when OneDrive backs'
            'up Documents (a common org policy), your modules silently live in'
            'OneDrive, and "Files On-Demand" can make them cloud-only'
            'placeholders that stall or fail module loading.'
            ''
            '  d        scan the highlighted path and download (hydrate) every'
            '           cloud-only file, with progress'
            '  k        keep on this device: pin the folder so OneDrive keeps all'
            '           files local from now on (downloads in the background)'
            '  s        set the primary (CurrentUser) module location - creates the'
            '           folder if needed (suggests one in your user profile,'
            '           outside OneDrive) and writes the documented PSModulePath'
            '           override to your user powershell.config.json. Takes effect'
            '           in this session immediately and in every new pwsh session.'
            '           Caveat: Install-Module/Install-PSResource still install to'
            '           the default Documents location.'
            '  r        remove that override again'
            ''
            'psmm also checks for cloud-only files before loading a module (with'
            'a prompt in the module menu / apply, silently with a status line in'
            'grid bulk loads).'
        ) }
        'gallery' { @(
            'GALLERY SEARCH'
            '--------------'
            'Searches the PowerShell Gallery (read-only). Wildcards work: Az.*,'
            'Microsoft.Graph*. enter adds the highlighted module to one of your'
            'config files - pick install policy and mode, done. / starts a new'
            'search.'
        ) }
        'cleanup' { @(
            'VERSION CLEANUP'
            '---------------'
            'Update-Module and Update-PSResource never delete old versions - they'
            'accumulate on disk forever. This screen lists every module with more'
            'than one installed version; enter prunes one module to its newest'
            'version, ctrl+a prunes all. Without elevation, AllUsers copies are'
            'skipped automatically.'
        ) }
        'tasks' { @(
            'BACKGROUND TASKS'
            '----------------'
            'Everything psmm runs in the background lands here: install batches'
            '(i), update batches (u), update checks (k), the unmanaged-module'
            'scan, and Update-Help (start it with u on this screen). enter shows'
            'a task''s full output. The grid keeps working while tasks run; a'
            'one-line overlay shows progress.'
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
        (Get-PSMMHint -NoLegend -Pairs @("$([char]0x2192)=drill in", "$([char]0x2190)=back out"))
        ''
        "[$script:PSMM_ColAccent]go places[/]"
        (Get-PSMMHint -NoLegend -Pairs @('g=goto: h g f p t c x m ?'))
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

# config tab: discovery order, file format, rules (plain text, escaped).
function script:Get-PSMMHelpConfigLines {
    $raw = [System.Collections.Generic.List[string]]::new()
    $raw.Add('WHERE PSMM LOOKS (in load order)')
    $raw.Add('--------------------------------')
    $raw.Add('  1. inline JSON in $PSMM_InlineJson       (set in $PROFILE; read-only)')
    $raw.Add("  2. MAIN config:    $(Get-PSMMMainConfigPath)")
    $raw.Add('  3. files listed in the MAIN config''s "Includes" (one level, main only)')
    $profileCfg = Get-PSMMProfileConfigPath
    if ($profileCfg) { $raw.Add("  4. profile-dir:    $profileCfg") }
    $raw.Add('  5. legacy globs in $PSMM_JsonPath (default: psmodules.d next to $PROFILE)')
    $raw.Add('')
    $raw.Add('FILE FORMAT (psmm-config.json)')
    $raw.Add('------------------------------')
    $raw.Add('  {')
    $raw.Add('    "Enabled": true,          // false = file parsed but nothing actioned')
    $raw.Add('    "Includes": ["C:\\path\\more.json"],   // MAIN config only')
    $raw.Add('    "Modules": [')
    $raw.Add('      {')
    $raw.Add('        "Name": "ImportExcel",           // required: gallery name')
    $raw.Add('        "FriendlyName": "Import Excel",  // optional display name')
    $raw.Add('        "Description": "what/why",       // optional')
    $raw.Add('        "Install": "IfMissing",          // CheckOnly | IfMissing | Latest')
    $raw.Add('        "Mode": "Load",                  // Load | InstallOnly | Ignore')
    $raw.Add('        "Version": "1.2.3"               // optional pin (or "[1.0,2.0)")')
    $raw.Add('      }')
    $raw.Add('    ]')
    $raw.Add('  }')
    $raw.Add('')
    $raw.Add('  The UI shows Mode as the startup column (load / install / off) and')
    $raw.Add('  Install as the gallery column (if-missing / check-only / latest).')
    $raw.Add('')
    $raw.Add('RULES')
    $raw.Add('-----')
    $raw.Add('  - Only the MAIN config may include other files (one level deep, so')
    $raw.Add('    circular references are impossible). Includes anywhere else are')
    $raw.Add('    ignored with a warning.')
    $raw.Add('  - Same module in several files: the MAIN config wins (warning);')
    $raw.Add('    otherwise the first-loaded file wins (error-style warning).')
    $raw.Add('  - "Enabled": false switches a whole file off without losing entries.')
    @($raw | ForEach-Object { ConvertTo-PSMMSafe $_ })
}

# startup tab: the $PROFILE bootstrap and its knobs (plain text, escaped).
function script:Get-PSMMHelpStartupLines {
    $raw = @(
        '$PROFILE BOOTSTRAP'
        '------------------'
        '  Import-Module psmm; Invoke-PSMMStartup'
        ''
        '  Knobs (set before Import-Module): $PSMM_StartupReport = $false,'
        '  $PSMM_BackgroundStartup = $false, $PSMM_UpdateCheck = $false,'
        '  $PSMM_InlineJson, $PSMM_JsonPath,'
        '  $PSMM_Theme = ''glacier'' (default) | ''ember'' | ''moss''.'
        ''
        '  Install and Mode are independent: Mode decides load / install-only /'
        '  ignore (and foreground vs background at startup); Install decides the'
        '  disk/gallery policy (never install / install when missing / update).'
        ''
        '  Mode = Load         imported into this session, in the foreground.'
        '  Mode = InstallOnly  disk/gallery work only - deferred to a background'
        '                      job so your prompt appears sooner.'
        '  Mode = Ignore       parsed but not actioned.'
        ''
        '  Each imported module''s import time is measured and reported, so you'
        '  always know which module is slowing your shell down.'
    )
    @($raw | ForEach-Object { ConvertTo-PSMMSafe $_ })
}

# about tab: version, engine, self-update detail (the header bar shows only
# the compact flag - the exact command lives here).
function script:Get-PSMMHelpAboutLines {
    $ui = $script:PSMM_UI
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('psmm - PS Session Module Manager')
    $ver = if ($ui -and $ui.Version) { "v$($ui.Version)" } else { '' }
    $eng = if ($ui -and $ui.Engine) { "$($ui.Engine)" } else { '' }
    $lines.Add((ConvertTo-PSMMSafe ("$ver $([char]0x00B7) install engine $eng$(if ($ui -and $ui.Elevated) { " $([char]0x00B7) elevated" })").Trim()))
    $lines.Add((ConvertTo-PSMMSafe 'github.com/PBNZ/psmm'))
    $lines.Add('')
    if ($ui -and $ui.SelfUpdate) {
        $u = $ui.SelfUpdate
        $lines.Add("[$script:PSMM_ColWarn]$([char]0x21E1) psmm v$($u.Latest) is available (you have v$($u.Current))[/]")
        $lines.Add("[$script:PSMM_ColMute]update:[/] [$script:PSMM_ColInfo]$(ConvertTo-PSMMSafe $u.Command)[/][$script:PSMM_ColMute], then restart pwsh[/]")
    } else {
        $lines.Add((ConvertTo-PSMMSafe 'psmm checks the gallery for its own updates once a day (cached,'))
        $lines.Add((ConvertTo-PSMMSafe 'never in the profile hot path); the header bar flags one with ' + [char]0x21E1 + ','))
        $lines.Add((ConvertTo-PSMMSafe 'and this tab then shows the exact update command.'))
    }
    $lines.Add('')
    $lines.Add((ConvertTo-PSMMSafe 'While psmm is in prerelease, beta-to-beta updates need a forced'))
    $lines.Add((ConvertTo-PSMMSafe 'reinstall: Install-PSResource psmm -Prerelease -Reinstall, then'))
    $lines.Add((ConvertTo-PSMMSafe 'restart pwsh. u on psmm''s own grid row handles this correctly.'))
    @($lines)
}

# The five tabs for a topic. Values are arrays of markup lines.
function script:Get-PSMMHelpTabs {
    param([string]$Topic = 'grid')
    [ordered]@{
        'this screen' = @(Get-PSMMHelpSection -Topic $Topic | ForEach-Object { ConvertTo-PSMMSafe $_ })
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
        $lines = @($lines | Where-Object { [Spectre.Console.Markup]::Remove($_) -like "*$needle*" })
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
                $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMHelpView -State $st -Tabs $tabs) -Context $ctx
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
