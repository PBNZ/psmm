# 70-Help.ps1 — the real help system (#13, replaces the old placeholder):
# per-screen topics, a full key reference, and the config guide, all in the
# shared pager. '?' anywhere opens help for the current screen.

function script:Get-PSMMHelpSection {
    param([Parameter(Mandatory)][string]$Topic)
    switch ($Topic) {
        'grid' { @(
            'MAIN SCREEN (module grid)'
            '-------------------------'
            'Every module your config files declare, one row each.'
            ''
            '  State    loaded (in this session) / installed (on disk) / missing /'
            '           unmanaged (installed but in no config file - toggle with m)'
            '  Scope    user (CurrentUser) / all (AllUsers) / mixed. "all ro" means'
            '           the session is not elevated, so AllUsers copies are read-only.'
            '  Ver      version loaded (or newest installed). ' + [char]0x2191 + ' = update available'
            '           (after a k check). pin = version pinned in the config.'
            '  !        the entry has validation issues (c shows details).'
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
            '  a        add a new entry   g  search the PowerShell Gallery'
            '  x        clean up duplicate module versions   t  background tasks'
            '  m        show/hide unmanaged modules   f  config files   c  conflicts'
            '  p        module locations (PSModulePath, OneDrive diagnostics)'
            '  r        reload everything from disk'
        ) }
        'module' { @(
            'MODULE MENU'
            '-----------'
            'Actions for one module. Only the actions that make sense for the row'
            'are offered (e.g. no edit for read-only sources, no disconnect when'
            'not signed in).'
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
            'scan, and Update-Help (start it with u on this screen). enter shows a task''s'
            'full output. The grid keeps working while tasks run; a one-line'
            'overlay shows progress.'
        ) }
        default { @() }
    }
}

function script:Get-PSMMHelpText {
    param([string]$Topic = 'grid')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('psmm - PowerShell Session Module Manager')
    $lines.Add('========================================')
    $lines.Add('')
    foreach ($l in (Get-PSMMHelpSection -Topic $Topic)) { $lines.Add($l) }
    $lines.Add('')
    $lines.Add('KEYS THAT WORK EVERYWHERE')
    $lines.Add('-------------------------')
    $lines.Add('  In key hints, ^ means ctrl: ^q is ctrl+q. Keys are shown lowercase.')
    $lines.Add('')
    $lines.Add('  up/down, pgup/pgdn, home/end   move / scroll (home = top of list)')
    $lines.Add('  /        search: type to filter, enter keeps it, esc clears it')
    $lines.Add('  esc      back (clears an active filter first)')
    $lines.Add('  g then h go straight to the home screen (the module grid) from any')
    $lines.Add('           sub-screen; ctrl+h works too in Windows Terminal/conhost')
    $lines.Add('  ?        help for the current screen')
    $lines.Add('  c        (help and other text pages) copy the page to the clipboard')
    $lines.Add('  ^q or ^x quit psmm immediately, from anywhere')
    $lines.Add('')
    $lines.Add('  Every list shows "row X/n"; every action reports its progress in')
    $lines.Add('  the status line - if nothing changed, the keypress did nothing.')
    $lines.Add('')
    $lines.Add('CONFIG - WHERE PSMM LOOKS (in load order)')
    $lines.Add('-----------------------------------------')
    $lines.Add('  1. inline JSON in $PSMM_InlineJson       (set in $PROFILE; read-only)')
    $lines.Add("  2. MAIN config:    $(Get-PSMMMainConfigPath)")
    $lines.Add('  3. files listed in the MAIN config''s "Includes" (one level, main only)')
    $profileCfg = Get-PSMMProfileConfigPath
    if ($profileCfg) { $lines.Add("  4. profile-dir:    $profileCfg") }
    $lines.Add('  5. legacy globs in $PSMM_JsonPath (default: psmodules.d next to $PROFILE)')
    $lines.Add('')
    $lines.Add('CONFIG - FILE FORMAT (psmm-config.json)')
    $lines.Add('---------------------------------------')
    $lines.Add('  {')
    $lines.Add('    "Enabled": true,          // false = file parsed but nothing actioned')
    $lines.Add('    "Includes": ["C:\\path\\more.json"],   // MAIN config only')
    $lines.Add('    "Modules": [')
    $lines.Add('      {')
    $lines.Add('        "Name": "ImportExcel",           // required: gallery name')
    $lines.Add('        "FriendlyName": "Import Excel",  // optional display name')
    $lines.Add('        "Description": "what/why",       // optional')
    $lines.Add('        "Install": "IfMissing",          // CheckOnly | IfMissing | Latest')
    $lines.Add('        "Mode": "Load",                  // Load | InstallOnly | Ignore')
    $lines.Add('        "Version": "1.2.3"               // optional pin (or "[1.0,2.0)")')
    $lines.Add('      }')
    $lines.Add('    ]')
    $lines.Add('  }')
    $lines.Add('')
    $lines.Add('  Install and Mode are independent: Mode decides load / install-only /')
    $lines.Add('  ignore (and foreground vs background at startup); Install decides the')
    $lines.Add('  disk/gallery policy (never install / install when missing / update).')
    $lines.Add('')
    $lines.Add('CONFIG - RULES')
    $lines.Add('--------------')
    $lines.Add('  - Only the MAIN config may include other files (one level deep, so')
    $lines.Add('    circular references are impossible). Includes anywhere else are')
    $lines.Add('    ignored with a warning.')
    $lines.Add('  - Same module in several files: the MAIN config wins (warning);')
    $lines.Add('    otherwise the first-loaded file wins (error-style warning).')
    $lines.Add('  - "Enabled": false switches a whole file off without losing entries.')
    $lines.Add('')
    $lines.Add('STARTUP - $PROFILE bootstrap')
    $lines.Add('----------------------------')
    $lines.Add('  Import-Module psmm; Invoke-PSMMStartup')
    $lines.Add('')
    $lines.Add('  Knobs (set before Import-Module): $PSMM_StartupReport = $false,')
    $lines.Add('  $PSMM_BackgroundStartup = $false, $PSMM_UpdateCheck = $false,')
    $lines.Add('  $PSMM_InlineJson, $PSMM_JsonPath.')
    $lines.Add('')
    $lines.Add('UPDATING PSMM ITSELF')
    $lines.Add('--------------------')
    $lines.Add('  A daily background check caches whether a newer psmm exists; the')
    $lines.Add('  profile report and the grid tell you when one does. While psmm is in')
    $lines.Add('  prerelease, beta-to-beta updates need a forced reinstall:')
    $lines.Add('      Install-PSResource psmm -Prerelease -Reinstall')
    $lines.Add('  then restart pwsh. (Update-PSResource cannot see a prerelease-label')
    $lines.Add('  bump; u on psmm''s own grid row handles this correctly.)')
    $lines
}

function script:Show-PSMMHelpScreen {
    param([string]$Topic = 'grid')
    $lines = Get-PSMMHelpText -Topic $Topic
    Show-PSMMPager -Lines $lines -TitleMarkup "[$script:PSMM_ColAccent]Help[/]"
}
