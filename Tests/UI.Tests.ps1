# Headless UI smoke tests: source the UI into the module, inject a
# StringWriter-backed Spectre console, build every screen's renderable and
# assert on the actual rendered frames (see DECISIONS.md D-UI-ARCH).
# Requires the PwshSpectreConsole assembly: from an installed module or the
# local .tools folder. Skipped cleanly when unavailable (e.g. Linux CI).
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeDiscovery {
    $toolsSpectre = Join-Path $PSScriptRoot '..' '.tools' 'PwshSpectreConsole'
    $script:SpectreAvailable = [bool](
        (Get-Module -ListAvailable -Name PwshSpectreConsole) -or (Test-Path $toolsSpectre)
    )
}

BeforeAll {
    $toolsSpectre = Join-Path $PSScriptRoot '..' '.tools' 'PwshSpectreConsole'
    if (Test-Path $toolsSpectre) { Import-Module $toolsSpectre -Force }
    else { Import-Module PwshSpectreConsole -Force -ErrorAction SilentlyContinue }
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    # Source the UI layer into the module (what Show-PSModuleManager does on
    # first use) without starting the interactive loop.
    InModuleScope psmm {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:PSMMRoot 'src/UI') -Filter '*.ps1' | Sort-Object Name) { . $f.FullName }
        $script:PSMMUISourced = $true
    }

    # Render any psmm view to plain text through an injected console.
    # NB: the scriptblock is re-created inside the module so it binds to module
    # scope (a passed-in scriptblock stays bound to the test file's scope).
    function Get-RenderedText([scriptblock]$BuildInModule) {
        InModuleScope psmm -Parameters @{ buildText = $BuildInModule.ToString() } {
            $build = [scriptblock]::Create($buildText)
            $sw = [System.IO.StringWriter]::new()
            $settings = [Spectre.Console.AnsiConsoleSettings]::new()
            $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
            $settings.Interactive = [Spectre.Console.InteractionSupport]::No
            $settings.Ansi = [Spectre.Console.AnsiSupport]::No
            $console = [Spectre.Console.AnsiConsole]::Create($settings)
            $console.Profile.Width = 120
            Set-PSMMConsole -Console $console
            try {
                $r = & $build
                $console.Write($r)
                # Spectre force-enables ANSI when it detects CI (GITHUB_ACTIONS)
                # even though Ansi=No was requested - strip codes so the text
                # assertions hold everywhere.
                $sw.ToString() -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
            } finally { Set-PSMMConsole -Console $null }
        }
    }

    # Like Get-RenderedText, but with ANSI + 256-colour output kept, so tests
    # can assert actual colour escapes (borders, row backgrounds).
    function Get-RenderedAnsi([scriptblock]$BuildInModule) {
        InModuleScope psmm -Parameters @{ buildText = $BuildInModule.ToString() } {
            $build = [scriptblock]::Create($buildText)
            $sw = [System.IO.StringWriter]::new()
            $settings = [Spectre.Console.AnsiConsoleSettings]::new()
            $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
            $settings.Interactive = [Spectre.Console.InteractionSupport]::No
            $settings.Ansi = [Spectre.Console.AnsiSupport]::Yes
            $settings.ColorSystem = [Spectre.Console.ColorSystemSupport]::EightBit
            $console = [Spectre.Console.AnsiConsole]::Create($settings)
            $console.Profile.Width = 120
            Set-PSMMConsole -Console $console
            try {
                $r = & $build
                $console.Write($r)
                $sw.ToString()
            } finally { Set-PSMMConsole -Console $null }
        }
    }

    function Set-UITestConfig {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'main')
        $global:PSMM_MainConfigPath    = Join-Path $root 'main\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'profile\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'legacy\*.json')
        @{
            Modules = @(
                @{ Name = 'AlphaMod'; FriendlyName = 'Alpha Module'; Install = 'IfMissing'; Mode = 'Ignore' }
                @{ Name = 'BetaMod'; Install = 'CheckOnly'; Mode = 'Ignore'; Version = '2.0.0' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $global:PSMM_MainConfigPath -Encoding utf8
        # minimal UI state without the expensive full disk scan
        InModuleScope psmm {
            $script:PSMM_UI = @{
                Entries = [System.Collections.Generic.List[object]]::new()
                Cursor = 0; Top = 0
                Sel = [System.Collections.Generic.HashSet[int]]::new()
                Filter = ''; FilterMode = $false; View = @()
                Status = ''; Dirty = $false; HardQuit = $false
                Unmanaged = $null; ShowUnmanaged = $false
                Elevated = $false; Engine = Get-PSMMInstallEngine
                Version = Get-PSMMVersionString; SelfUpdate = $null
            }
            foreach ($e in (Get-PSMMEntry)) { $script:PSMM_UI.Entries.Add($e) }
        }
    }
}

AfterAll {
    Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath -Scope Global -ErrorAction SilentlyContinue
}

Describe 'UI rendering (headless)' -Tag UI -Skip:(-not $SpectreAvailable) {

    BeforeEach { Set-UITestConfig }
    AfterEach {
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath -Scope Global -ErrorAction SilentlyContinue
    }

    It 'the grid header shows the running psmm version, and the self-update notice when one is cached' {
        $text = Get-RenderedText { Build-PSMMGrid }
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..' 'psmm.psd1')
        $text | Should -Match ([regex]::Escape("psmm v$($manifest.ModuleVersion)-$($manifest.PrivateData.PSData.Prerelease)"))
        InModuleScope psmm {
            $script:PSMM_UI.SelfUpdate = [pscustomobject]@{
                Current = '0.1.0-beta3'; Latest = '0.1.0-beta4'
                Command = 'Install-PSResource psmm -Prerelease -Reinstall'
            }
        }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match 'psmm v0\.1\.0-beta4 is available'
        $text | Should -Match 'Install-PSResource psmm -Prerelease -Reinstall'
        InModuleScope psmm { $script:PSMM_UI.SelfUpdate = $null }
    }

    It 'renders the main grid with title, rows, position indicator and hints' {
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match 'PS Session Module Manager'
        $text | Should -Match 'AlphaMod'
        $text | Should -Match 'BetaMod'
        $text | Should -Match 'row 1/2'
        $text | Should -Match 'space'         # hint row
        $text | Should -Match 'Scope'         # new scope column (#28)
        $text | Should -Match 'pin'           # BetaMod's version pin marker
    }

    It 'filter narrows the grid view and shows the filter in the header' {
        InModuleScope psmm { $script:PSMM_UI.Filter = 'Alpha' }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match 'AlphaMod'
        $text | Should -Not -Match 'BetaMod'
        $text | Should -Match 'row 1/1'
        $text | Should -Match 'filter: Alpha'
    }

    It 'grid shows the unmanaged notice when a scan found modules and rows are hidden' {
        InModuleScope psmm {
            $script:PSMM_UI.Unmanaged = @([pscustomobject]@{ Name = 'RogueMod'; Version = [version]'1.0'; Scope = 'CurrentUser'; Description = '' })
        }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match '1 installed module\(s\) not in your config'
    }

    It 'grid includes unmanaged rows when toggled on' {
        InModuleScope psmm {
            $script:PSMM_UI.Unmanaged = @([pscustomobject]@{ Name = 'RogueMod'; Version = [version]'1.0'; Scope = 'CurrentUser'; Description = 'wild' })
            $script:PSMM_UI.ShowUnmanaged = $true
            Sync-PSMMUIEntries
        }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match 'RogueMod'
        $text | Should -Match 'unmanaged'
    }

    It 'renders the module menu with details, pin and import-time info' {
        $text = Get-RenderedText {
            $e = $script:PSMM_UI.Entries | Where-Object Name -eq 'BetaMod'
            $e.Loaded = $true; $e.LoadedVersion = [version]'2.0.0'; $e.ImportMs = 123
            Build-PSMMModuleMenuView -Entry $e -Auth $null
        }
        $text | Should -Match 'BetaMod'
        $text | Should -Match '2\.0\.0 \(exact\)'      # version pin display
        $text | Should -Match 'import took 123 ms'     # ImportMs surfaced
        $text | Should -Match 'CheckOnly / Ignore'
    }

    It 'module menu shows connection status when auth is known (#32)' {
        $text = Get-RenderedText {
            $e = $script:PSMM_UI.Entries[0]
            $auth = [pscustomobject]@{ Supported = $true; Connected = $true; Account = 'admin@contoso.com'; Detail = 'tenant xyz'; Slow = $false }
            Build-PSMMModuleMenuView -Entry $e -Auth $auth
        }
        $text | Should -Match 'connected'
        $text | Should -Match 'admin@contoso\.com'
        $text | Should -Match 'disconnect'   # hint renders 'O disconnect'
    }

    It 'renders the command detail tabs on separate rows (#10)' {
        $text = Get-RenderedText {
            $st = @{ Tab = 1; Scroll = 0 }
            Build-PSMMCommandDetailView -State $st -Name 'Get-Thing' -Tabs @('Overview', 'Parameters', 'Examples') -Content @{
                Overview = 'the overview'; Parameters = "param stuff`nline two"; Examples = 'examples here'
            }
        }
        $text | Should -Match 'Get-Thing'
        $text | Should -Match 'Overview\s+Parameters\s+Examples'
        $text | Should -Match 'param stuff'
    }

    It 'renders the files view with kind, enabled state and module count' {
        $text = Get-RenderedText {
            $st = New-PSMMListState
            Build-PSMMFilesView -State $st -Metas @((Get-PSMMFileMeta).Values)
        }
        $text | Should -Match 'Config files'
        $text | Should -Match 'psmm-config\.json'
        $text | Should -Match 'main'
        $text | Should -Match ' on '
    }

    It 'renders conflict lines including duplicates' {
        $lines = InModuleScope psmm {
            $one = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Dup' }) -Source 'a.json' -Writable $true
            $two = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Dup' }) -Source 'b.json' -Writable $true
            Build-PSMMConflictLines -Conflict (Get-PSMMConflict -Entries @($one, $two))
        }
        ($lines -join "`n") | Should -Match 'Duplicate module names'
        ($lines -join "`n") | Should -Match 'Dup'
        ($lines -join "`n") | Should -Match 'a\.json'
    }

    It 'renders the gallery view with results and add hint (#38)' {
        $text = Get-RenderedText {
            $st = New-PSMMListState
            $results = @(
                [pscustomobject]@{ Name = 'ImportExcel'; Version = '7.8.9'; Description = 'Excel without Excel'; Author = 'dfinke' }
            )
            Build-PSMMGalleryView -State $st -Results $results -Query 'excel'
        }
        $text | Should -Match 'PowerShell Gallery'
        $text | Should -Match 'ImportExcel'
        $text | Should -Match 'add to config'
    }

    It 'renders the cleanup view with keep/remove versions' {
        $text = Get-RenderedText {
            $st = New-PSMMListState
            $dupes = @([pscustomobject]@{
                Name = 'FatModule'; Latest = [version]'3.0'
                Obsolete = @(
                    [pscustomobject]@{ Version = [version]'2.0'; Path = 'x'; Scope = 'CurrentUser' }
                    [pscustomobject]@{ Version = [version]'1.0'; Path = 'y'; Scope = 'AllUsers' }
                )
            })
            Build-PSMMCleanupView -State $st -Dupes $dupes
        }
        $text | Should -Match 'FatModule'
        $text | Should -Match 'v3\.0'
        $text | Should -Match 'v2\.0, v1\.0'
    }

    It 'renders the tasks view' {
        $text = Get-RenderedText {
            $st = New-PSMMListState
            $tasks = @([pscustomobject]@{
                Id = 1; Label = 'update check (5 modules)'; Kind = 'updatecheck'; Data = $null
                Job = $null; StartedAt = [datetime]'2026-07-04 10:00:00'
                Output = @('a', 'b'); Done = $true; Failed = $false; Seen = $true
            })
            Build-PSMMTasksView -State $st -Tasks $tasks
        }
        $text | Should -Match 'Background tasks'
        $text | Should -Match 'update check'
        $text | Should -Match 'done'
        $text | Should -Match '2 line\(s\)'
    }

    It 'help text covers every topic plus config format and global keys (#13)' {
        foreach ($topic in 'grid', 'module', 'commands', 'files', 'gallery', 'cleanup', 'tasks') {
            $lines = InModuleScope psmm -Parameters @{ t = $topic } { Get-PSMMHelpText -Topic $t }
            $text = $lines -join "`n"
            $text | Should -Match 'KEYS THAT WORK EVERYWHERE'
            $text | Should -Match 'CONFIG - FILE FORMAT'
            $text | Should -Match 'Install and Mode are independent'
            $lines.Count | Should -BeGreaterThan 40 -Because "topic '$topic' should produce a full help document"
        }
        # per-screen sections actually differ
        $grid = (InModuleScope psmm { Get-PSMMHelpText -Topic 'grid' }) -join "`n"
        $files = (InModuleScope psmm { Get-PSMMHelpText -Topic 'files' }) -join "`n"
        $grid | Should -Match 'MAIN SCREEN'
        $files | Should -Match 'CONFIG FILES'
    }

    It 'grid hints follow the design system: lowercase keys, ^ = ctrl legend, i/u/k verbs' {
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match '\^ = ctrl'        # legend on the chord row (v2: at the end)
        $text | Should -Match '\^l\s+load'
        $text | Should -Match '\^u\s+unload'
        $text | Should -Match 'i\s+install'
        $text | Should -Match 'u\s+update'
        $text | Should -Match 'k\s+check updates'
        $text | Should -Not -Match 'Ctrl\+'      # the old uppercase chord style is gone
    }

    It 'Get-PSMMHint lowercases keys and only adds the ^ = ctrl legend when a chord is present' {
        InModuleScope psmm {
            $plain = [Spectre.Console.Markup]::Remove((Get-PSMMHint -Pairs @('I=install', 'esc=back')))
            $plain | Should -Match 'i\s+install'
            $plain | Should -Not -Match '\^ = ctrl'
            $chord = [Spectre.Console.Markup]::Remove((Get-PSMMHint -Pairs @('^Q=quit')))
            $chord | Should -Match '\^q\s+quit'
            $chord | Should -Match '\^ = ctrl\s*$'   # legend sits at the end of the row
        }
    }

    It 'module menu offers i=install for a missing module and u=update for an installed one' {
        $missing = Get-RenderedText {
            Build-PSMMModuleMenuView -Entry ($script:PSMM_UI.Entries[0]) -Auth $null
        }
        $missing | Should -Match 'i\s+install'
        $missing | Should -Not -Match 'u\s+update'
        $missing | Should -Match '\^l\s+load'
        $missing | Should -Match 'g h\s+home'
        $installed = Get-RenderedText {
            $e = $script:PSMM_UI.Entries[0]
            $e.Installed = $true; $e.InstalledVersion = [version]'1.0'
            Build-PSMMModuleMenuView -Entry $e -Auth $null
        }
        $installed | Should -Match 'u\s+update'
        $installed | Should -Not -Match 'i\s+install'
    }

    It 'cleanup screen binds clean-all to ^a (no shift bindings in hints)' {
        $text = Get-RenderedText {
            $st = New-PSMMListState
            Build-PSMMCleanupView -State $st -Dupes @([pscustomobject]@{
                Name = 'FatModule'; Latest = [version]'3.0'
                Obsolete = @([pscustomobject]@{ Version = [version]'2.0'; Path = 'x'; Scope = 'CurrentUser' })
            })
        }
        $text | Should -Match '\^a\s+clean all'
        $text | Should -Not -MatchExactly 'clean ALL'
    }

    It 'a too-small window renders a clear message instead of a collapsed table' {
        Mock -ModuleName psmm Get-PSMMWinSize { [pscustomobject]@{ Height = 10; Width = 40 } }
        foreach ($build in @(
            { Build-PSMMGrid },
            { Build-PSMMFilesView -State (New-PSMMListState) -Metas @((Get-PSMMFileMeta).Values) },
            { Build-PSMMTasksView -State (New-PSMMListState) -Tasks @() }
        )) {
            $text = Get-RenderedText $build
            $text | Should -Match 'window too small'
            $text | Should -Match 'need at least'
            $text | Should -Match 'current 40x10'
        }
    }

    It 'the grid update marker and scroll indicators use arrows, not ^ (reserved for ctrl)' {
        InModuleScope psmm {
            $e = $script:PSMM_UI.Entries[0]
            $e.Installed = $true; $e.InstalledVersion = [version]'1.0'; $e.UpdateAvailable = $true
        }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match ([regex]::Escape("1.0 $([char]0x21E1)"))   # ⇡ update marker (v2)
        InModuleScope psmm {
            $pos = [Spectre.Console.Markup]::Remove((Get-PSMMPositionMarkup -State @{ Cursor = 0 } -Count 50 -Viewport @{ First = 0; Last = 9; Rows = 10 }))
            $pos | Should -Match ([regex]::Escape([string][char]0x2193))
            $pos | Should -Not -Match '\sv\s*$'
        }
    }

    It 'i/u guard statuses: install skips installed targets, update skips missing ones' {
        InModuleScope psmm {
            # fixture entries are not installed: update has nothing to do
            $script:PSMM_UI.Cursor = 0
            Start-PSMMInstallTask -Update
            $script:PSMM_UI.Status | Should -Match 'nothing to update'
            # mark everything installed: install has nothing to do
            foreach ($e in $script:PSMM_UI.Entries) { $e.Installed = $true }
            Start-PSMMInstallTask
            $script:PSMM_UI.Status | Should -Match 'nothing to install'
        }
    }

    It 'Test-PSMMHomeKey accepts ctrl+h and rejects plain letters' {
        InModuleScope psmm {
            $ctrlH = [ConsoleKeyInfo]::new([char]8, [ConsoleKey]::H, $false, $false, $true)
            Test-PSMMHomeKey -KeyInfo $ctrlH | Should -BeTrue
            $plainH = [ConsoleKeyInfo]::new('h', [ConsoleKey]::H, $false, $false, $false)
            Test-PSMMHomeKey -KeyInfo $plainH | Should -BeFalse
        }
    }

    It 'the pager and command help offer c=copy and copy reports success' {
        $pager = Get-RenderedText {
            Build-PSMMPagerView -State @{ Scroll = 0 } -Lines @('line') -TitleMarkup 'T'
        }
        $pager | Should -Match 'c\s+copy'
        $detail = Get-RenderedText {
            Build-PSMMCommandDetailView -State @{ Tab = 0; Scroll = 0; Status = '' } -Name 'Get-Thing' -Tabs @('Overview') -Content @{ Overview = 'x' }
        }
        $detail | Should -Match 'c\s+copy tab'
        InModuleScope psmm {
            Mock Set-Clipboard { }
            [Spectre.Console.Markup]::Remove((Copy-PSMMText -Text 'hello')) | Should -Match 'copied to clipboard'
        }
    }

    It 'the paths screen lists PSModulePath entries with flags and OneDrive guidance' {
        $text = Get-RenderedText {
            $infos = @(
                [pscustomobject]@{ Order = 0; Path = 'C:\Users\p\OneDrive\Documents\PowerShell\Modules'; First = $true; Exists = $true; OneDrive = $true; UserDefault = $true }
                [pscustomobject]@{ Order = 1; Path = 'C:\Program Files\PowerShell\Modules'; First = $false; Exists = $true; OneDrive = $false; UserDefault = $false }
            )
            Build-PSMMPathsView -State (New-PSMMListState) -Infos $infos
        }
        $text | Should -Match 'Module locations'
        $text | Should -Match 'first'
        $text | Should -Match 'user default'
        $text | Should -Match 'onedrive'
        $text | Should -Match 'primary module location is inside OneDrive'
        $text | Should -Match 'd\s+download cloud-only files'
        $text | Should -Match 'k\s+keep on device'
        $text | Should -Match 's\s+set primary location'
    }

    It 'the grid offers p=paths and shows the OneDrive notice when the primary location is cloud-backed' {
        InModuleScope psmm { $script:PSMM_UI.OneDrivePrimary = $true }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match 'p\s+paths'
        $text | Should -Match 'primary module location is inside OneDrive'
        InModuleScope psmm { $script:PSMM_UI.OneDrivePrimary = $false }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Not -Match 'primary module location is inside OneDrive'
    }

    It 'alt-screen helpers no-op safely without a real console' {
        InModuleScope psmm {
            { Enter-PSMMAltScreen; Exit-PSMMAltScreen } | Should -Not -Throw
        }
    }

    It 'a machine with ZERO configs opens, syncs and renders without errors (regression)' {
        # Peter's first live run: no ~/.psmm, no profile config -> empty
        # entry set -> Get-PSMMAllEntries returned $null (empty-array
        # unrolling) and Sync-PSMMUIEntries crashed binding it.
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:PSMM_MainConfigPath    = Join-Path $root 'nope\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'nope2\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'nope3\*.json')
        InModuleScope psmm {
            { Sync-PSMMUIEntries -FullScan:$false } | Should -Not -Throw
            $script:PSMM_UI.Entries.Count | Should -Be 0
            # and toggling unmanaged rows on the empty grid must work (the
            # dead 'm' key from the same live run)
            $script:PSMM_UI.Unmanaged = @([pscustomobject]@{ Name = 'RogueMod'; Version = [version]'1.0'; Scope = 'CurrentUser'; Description = '' })
            $script:PSMM_UI.ShowUnmanaged = $true
            { Sync-PSMMUIEntries } | Should -Not -Throw
            $script:PSMM_UI.Entries.Count | Should -Be 1
        }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match 'RogueMod'
    }

    It 'a machine with exactly ONE managed entry full-scans without errors (fresh-install regression, gh#1)' {
        # Fresh install: Initialize-PSMMMainConfig seeds ONE module, so
        # Get-PSMMAllEntries unrolled to a scalar PSObject on return and
        # ($all + @(...)) in Sync-PSMMUIEntries threw op_Addition. The @()
        # inside the accessor cannot survive pipeline unrolling - the caller
        # must wrap.
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'main')
        $global:PSMM_MainConfigPath    = Join-Path $root 'main\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'nope\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'nope2\*.json')
        @{
            Modules = @(
                @{ Name = 'PwshSpectreConsole'; Install = 'IfMissing'; Mode = 'InstallOnly' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $global:PSMM_MainConfigPath -Encoding utf8
        InModuleScope psmm {
            # the disk sweep is not under test - the crash was in the argument
            # expression, which still evaluates against a mock
            Mock Update-PSMMAvailable { }
            { Sync-PSMMUIEntries -FullScan } | Should -Not -Throw
            $script:PSMM_UI.Entries.Count | Should -Be 1
        }
    }

    It 'the pager accepts text with blank lines (help/? crashed on this, regression)' {
        # Mandatory [string[]] rejects empty-string ELEMENTS unless
        # AllowEmptyString is declared - every help/conflict document has
        # blank lines, so ? crashed the pager in the ConPTY keystroke test.
        InModuleScope psmm {
            $lines = @('title', '', 'body after a blank line')
            { $null = Build-PSMMPagerView -State @{ Scroll = 0 } -Lines $lines -TitleMarkup 'T' } | Should -Not -Throw
            Mock Invoke-PSMMLive { }   # binding-only check for the interactive wrapper
            { Show-PSMMPager -Lines $lines -TitleMarkup 'T' } | Should -Not -Throw
            # and the real help text (which contains many blank lines) binds too
            { Show-PSMMPager -Lines (Get-PSMMHelpText -Topic 'grid') -TitleMarkup 'T' } | Should -Not -Throw
        }
    }

    It 'grid table width is identical at the top and bottom of a scrolled list (no width jitter, regression)' {
        # Column widths must come from ALL rows, not the visible viewport -
        # otherwise the table resizes while scrolling (2026-07-05 live run).
        InModuleScope psmm {
            # enough rows to force scrolling at any window height, with the
            # single widest name at the very END of the list
            $script:PSMM_UI.Entries.Clear()
            foreach ($i in 1..60) {
                $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = "Mod$i"; Install = 'IfMissing'; Mode = 'Ignore' }) -Source $global:PSMM_MainConfigPath -Writable $true
                $script:PSMM_UI.Entries.Add($e)
            }
            $wide = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'An.Extremely.Long.Module.Name.At.The.Bottom'; Install = 'IfMissing'; Mode = 'Ignore' }) -Source $global:PSMM_MainConfigPath -Writable $true
            $script:PSMM_UI.Entries.Add($wide)
        }
        $topBorder = { ($text -split "`r?`n" | Where-Object { $_ -match '^\s*╭' } | Select-Object -First 1).TrimEnd().Length }
        InModuleScope psmm { $script:PSMM_UI.Cursor = 0; $script:PSMM_UI.Top = 0 }
        $text = Get-RenderedText { Build-PSMMGrid }
        $wTop = & $topBorder
        InModuleScope psmm { $script:PSMM_UI.Cursor = 60 }   # scroll to the bottom
        $text = Get-RenderedText { Build-PSMMGrid }
        $wBottom = & $topBorder
        $text | Should -Match 'An\.Extremely\.Long'   # the wide row is actually visible now
        $wBottom | Should -BeGreaterThan 0
        $wTop | Should -Be $wBottom
    }

    It 'a short list is padded to at least 5 table rows so it does not look collapsed' {
        # fixture has 2 entries -> expect 2 real + 3 blank padding rows
        $text = Get-RenderedText { Build-PSMMGrid }
        $dataLines = @($text -split "`r?`n" | Where-Object { $_ -match '^\s*│' })
        # 1 header line + at least 5 data rows
        $dataLines.Count | Should -BeGreaterOrEqual 6
    }

    It 'Clear-PSMMScreen actually clears the screen (was a silent no-op, regression)' {
        # IAnsiConsole zero-arg Clear() is a C# extension PowerShell cannot
        # call - the old code threw into an empty catch on EVERY clear, so
        # sub-screens appended below the grid (2026-07-05 live run).
        $out = InModuleScope psmm {
            $sw = [System.IO.StringWriter]::new()
            $settings = [Spectre.Console.AnsiConsoleSettings]::new()
            $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
            $settings.Interactive = [Spectre.Console.InteractionSupport]::No
            $settings.Ansi = [Spectre.Console.AnsiSupport]::Yes
            Set-PSMMConsole -Console ([Spectre.Console.AnsiConsole]::Create($settings))
            try { Clear-PSMMScreen; $sw.ToString() } finally { Set-PSMMConsole -Console $null }
        }
        $out | Should -Match "\x1b\[2J"    # clear screen ...
        $out | Should -Match "\x1b\[1;1H"  # ... and home the cursor
    }

    It 'adding with no writable config offers to create the main config (regression)' {
        # zero-config sandbox: point everything at empty dirs
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:PSMM_MainConfigPath    = Join-Path $root 'a\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'b\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'c\*.json')
        InModuleScope psmm {
            $null = Get-PSMMEntry
            Mock Read-SpectreConfirm { $true }
            $targets = @(Get-PSMMAddTargets)
            $targets | Should -Be @($global:PSMM_MainConfigPath)
            Test-Path (Split-Path -Parent $global:PSMM_MainConfigPath) | Should -BeTrue
            # declining creates nothing and returns no target
            Mock Read-SpectreConfirm { $false }
            @(Get-PSMMAddTargets).Count | Should -Be 0
        }
    }

    It 'first manager run with zero configs creates the main config managing PwshSpectreConsole' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:PSMM_MainConfigPath    = Join-Path $root 'a\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'b\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'c\*.json')
        InModuleScope psmm {
            Initialize-PSMMMainConfig
            Test-Path $global:PSMM_MainConfigPath | Should -BeTrue
            $cfg = Get-Content $global:PSMM_MainConfigPath -Raw | ConvertFrom-Json
            @($cfg.Modules).Count | Should -Be 1
            $cfg.Modules[0].Name | Should -Be 'PwshSpectreConsole'
            $cfg.Modules[0].Mode | Should -Be 'InstallOnly'   # never imports at profile time
            # idempotent: a second call must not touch the existing file
            $stamp = (Get-Item $global:PSMM_MainConfigPath).LastWriteTimeUtc
            Initialize-PSMMMainConfig
            (Get-Item $global:PSMM_MainConfigPath).LastWriteTimeUtc | Should -Be $stamp
            # and once a config exists, discovery sees the seeded entry
            @(Get-PSMMEntry).Name | Should -Contain 'PwshSpectreConsole'
        }
    }

    It 'scan completion sets no duplicate status (the grid notice covers it)' {
        InModuleScope psmm {
            $script:PSMM_UI.Status = ''
            $t = Start-PSMMTask -Label 'scan: unmanaged modules' -Kind 'unmanagedscan' -ScriptBlock {
                [pscustomobject]@{ Name = 'RogueMod'; Version = [version]'1.0'; Scope = 'CurrentUser'; Description = '' }
            }
            $null = $t.Job | Wait-Job
            Receive-PSMMUITask
            $script:PSMM_UI.Status | Should -BeNullOrEmpty
            @($script:PSMM_UI.Unmanaged).Count | Should -Be 1
            Clear-PSMMTask
        }
    }
}

Describe 'UI v2 design system (docs/design-system-v2.md)' -Tag UI -Skip:(-not $SpectreAvailable) {

    BeforeEach { Set-UITestConfig }
    AfterEach {
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath -Scope Global -ErrorAction SilentlyContinue
    }

    # --- step 1: borders grey27, lowercase dim headers, cursor row bg -------

    It 'v2 palette tokens exist and name the spec colours (step 1)' {
        InModuleScope psmm {
            $script:PSMM_ColDim     | Should -Be 'grey42'
            $script:PSMM_ColCapsule | Should -Be 'grey19'
            $script:PSMM_ColRowBg   | Should -Be 'grey15'
            $script:PSMM_ColBorder  | Should -Be 'grey27'
            $script:PSMM_ColOk      | Should -Be 'green3'
            $script:PSMM_ColWarn    | Should -Be 'orange1'
            $script:PSMM_ColErr     | Should -Be 'indianred1'
            $script:PSMM_ColInfo    | Should -Be 'steelblue1'
        }
    }

    It 'grid borders render grey27 and the cursor row paints a grey15 full-row background (step 1)' {
        $out = Get-RenderedAnsi { Build-PSMMGrid }
        # grey27 = 238, grey15 = 235 in the xterm-256 palette
        $out | Should -Match '38;5;238'
        $out | Should -Match '48;5;235'
        # the row background must span up to the cell edge, not just the text:
        # a painted cell ends with the background still open right before the reset
        ($out -split "`r?`n" | Where-Object { $_ -match '48;5;235' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'grid headers are lowercase + dim and the checkbox column is gone (step 1)' {
        $text = Get-RenderedText { Build-PSMMGrid }
        $header = ($text -split "`r?`n" | Where-Object { $_ -match '│.*module' } | Select-Object -First 1)
        $header | Should -Not -BeNullOrEmpty
        $header | Should -CMatch 'module'
        $header | Should -Not -CMatch 'Module'
        $text | Should -Not -CMatch 'Sel'
        $text | Should -Not -Match '\[\[x\]\]|\[ \]'   # checkbox cells retired
        $ansi = Get-RenderedAnsi { Build-PSMMGrid }
        $ansi | Should -Match '38;5;242'               # grey42 dim headers
    }

    It 'the cursor row shows the accent bar and bold accent name; the bare > cursor is retired (step 1)' {
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match ([regex]::Escape([string][char]0x258C))   # ▌
        # no data row starts with the old '>' cursor marker
        @($text -split "`r?`n" | Where-Object { $_ -match '^\s*│\s*>' }).Count | Should -Be 0
    }

    It 'a selected row is marked with a filled square, and the status area counts the selection (step 1)' {
        InModuleScope psmm { [void]$script:PSMM_UI.Sel.Add(1) }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match ([regex]::Escape([string][char]0x25AA))   # ▪
        $text | Should -Match '1 selected'
    }

    # --- step 2: capsule hint rendering ------------------------------------

    It 'Get-PSMMHint renders keys as capsules: key-on-capsule-bg block plus mute label (step 2)' {
        InModuleScope psmm {
            $m = Get-PSMMHint -Pairs @('i=install', 'esc=back')
            $m | Should -Match ([regex]::Escape('[salmon1 on grey19] i [/]'))
            $m | Should -Match ([regex]::Escape('[grey66]install[/]'))
            $m | Should -Match ([regex]::Escape('[salmon1 on grey19] esc [/]'))
            # two-space separator between pairs, no interleaved dot
            $m | Should -Not -Match ([regex]::Escape("[$script:PSMM_ColMute]·[/]"))
            { [void][Spectre.Console.Markup]::new($m) } | Should -Not -Throw
        }
    }

    It 'the persistent hint row uses accent capsules on the darker background with dim labels (step 2)' {
        InModuleScope psmm {
            $m = Get-PSMMPersistentHint
            $m | Should -Match ([regex]::Escape('[deepskyblue1 on grey11] g [/]'))
            $m | Should -Match "goto$([char]0x2026)"
            $m | Should -Match ([regex]::Escape('[deepskyblue1 on grey11] / [/]'))
            $m | Should -Match ([regex]::Escape('[deepskyblue1 on grey11] ? [/]'))
            $plain = [Spectre.Console.Markup]::Remove($m)
            $plain | Should -Match '\^q\s+quit'
            $plain | Should -Match '\^ = ctrl\s*$'   # chord visible -> legend, at the end
            { [void][Spectre.Console.Markup]::new($m) } | Should -Not -Throw
        }
    }

    # --- step 3: plain-word columns, state glyphs, context line -------------

    It 'grid columns speak plain words: module state startup gallery version scope file (step 3)' {
        $text = Get-RenderedText { Build-PSMMGrid }
        $header = ($text -split "`r?`n" | Where-Object { $_ -match '│.*module' } | Select-Object -First 1)
        $header | Should -Match 'module\s*│\s*state\s*│\s*startup\s*│\s*gallery\s*│\s*version\s*│\s*scope\s*│\s*file'
        $text | Should -Not -Match '│\s*mode\s*│'
        $text | Should -Not -Match '│\s*inst\s*│'
    }

    It 'startup and gallery cells map the config enums to display words (step 3)' {
        # fixture: AlphaMod = IfMissing/Ignore, BetaMod = CheckOnly/Ignore
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match 'off'
        $text | Should -Match 'if-missing'
        $text | Should -Match 'check-only'
        $text | Should -Not -Match 'IfMissing'
        $text | Should -Not -Match 'CheckOnly'
        InModuleScope psmm {
            $script:PSMM_UI.Entries[0].Mode = 'Load'
            $script:PSMM_UI.Entries[1].Mode = 'InstallOnly'
            $script:PSMM_UI.Entries[1].Install = 'Latest'
        }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match '│\s*load\s*│'
        $text | Should -Match '│\s*install\s*│'
        $text | Should -Match 'latest'
    }

    It 'the state column pairs a glyph with the word, never the glyph alone (step 3)' {
        InModuleScope psmm {
            $script:PSMM_UI.Entries[0].Loaded = $true
            $script:PSMM_UI.Entries[1].Installed = $true
        }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match "$([char]0x25CF) loaded"      # ● loaded
        $text | Should -Match "$([char]0x25D0) installed"   # ◐ installed
        InModuleScope psmm { $script:PSMM_UI.Entries[0].Loaded = $false }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match "$([char]0x25CB) missing"     # ○ missing
    }

    It 'entry issues render as an err warning sign after the module name; the ! column is gone (step 3)' {
        InModuleScope psmm { $script:PSMM_UI.Entries[0].Issues = @('Version pin is invalid') }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match "AlphaMod $([char]0x26A0)"    # ⚠ after the name
        $text | Should -Not -Match '│\s*!\s*│'
    }

    It 'the update marker is an up arrow-from-bar and the cursor row names the target version (step 3)' {
        InModuleScope psmm {
            foreach ($e in $script:PSMM_UI.Entries) {
                $e.Installed = $true; $e.InstalledVersion = [version]'1.0'
                $e.UpdateAvailable = $true; $e.LatestVersion = '9.9.9'
            }
            $script:PSMM_UI.Cursor = 0
        }
        $text = Get-RenderedText { Build-PSMMGrid }
        $text | Should -Match ([regex]::Escape("1.0 $([char]0x21E1) 9.9.9"))   # cursor row: target shown
        # non-cursor row keeps the bare marker
        ($text -split "`r?`n" | Where-Object { $_ -match 'BetaMod' }) | Should -Match ([regex]::Escape("1.0 $([char]0x21E1)"))
        ($text -split "`r?`n" | Where-Object { $_ -match 'BetaMod' }) | Should -Not -Match '9\.9\.9'
    }

    It 'the context line explains the cursor row in full words (step 3)' {
        InModuleScope psmm {
            $e = $script:PSMM_UI.Entries[0]
            $e.Mode = 'InstallOnly'; $e.Install = 'IfMissing'
            $e.Installed = $true; $e.InstalledVersion = [version]'7.8.10'
            $e.UpdateAvailable = $true; $e.LatestVersion = '7.9.0'
            $script:PSMM_UI.Cursor = 0
        }
        # the sentence may wrap at the console width - compare on one line
        $flat = (Get-RenderedText { Build-PSMMGrid }) -replace '\s+', ' '
        $flat | Should -Match 'AlphaMod .* background-installs at shell start when missing'
        $flat | Should -Match 'not imported this session'
        $flat | Should -Match 'v7\.8\.10 on disk, v7\.9\.0 available \(u updates\)'
    }

    It 'moving the cursor onto a row with a pending update does not change the table width (step 3)' {
        InModuleScope psmm {
            $e = $script:PSMM_UI.Entries[1]
            $e.Installed = $true; $e.InstalledVersion = [version]'2.0.0'
            $e.UpdateAvailable = $true; $e.LatestVersion = '2.0.1'
            $script:PSMM_UI.Cursor = 0
        }
        $topBorder = { ($text -split "`r?`n" | Where-Object { $_ -match '^\s*╭' } | Select-Object -First 1).TrimEnd().Length }
        $text = Get-RenderedText { Build-PSMMGrid }
        $wOff = & $topBorder
        InModuleScope psmm { $script:PSMM_UI.Cursor = 1 }
        $text = Get-RenderedText { Build-PSMMGrid }
        $wOn = & $topBorder
        $wOn | Should -BeGreaterThan 0
        $wOff | Should -Be $wOn
    }
}

Describe 'Task registry (engine)' -Tag Engine {

    It 'runs a task, harvests output, fingerprints and summarises' {
        $summary = InModuleScope psmm {
            $t = Start-PSMMTask -Label 'test task' -Kind 'generic' -ScriptBlock { 'line1'; 'line2' }
            $null = $t.Job | Wait-Job
            $fp1 = Get-PSMMTaskFingerprint
            Update-PSMMTask
            $s = Get-PSMMTaskSummary
            [pscustomobject]@{
                Fingerprint = $fp1
                Done = $t.Done; Failed = $t.Failed; OutCount = $t.Output.Count
                SummaryText = $s.Text
            }
        }
        $summary.Done | Should -BeTrue
        $summary.Failed | Should -BeFalse
        $summary.OutCount | Should -Be 2
        $summary.SummaryText | Should -Match 'test task done'
        $summary.Fingerprint | Should -Match '^\d+:Completed:\d+$'   # id:state:outputCount
        InModuleScope psmm { Clear-PSMMTask; @(Get-PSMMTask).Count } | Should -Be 0
    }

    It 'Receive-PSMMUITask applies update-check results to entries' {
        Set-UITestConfig
        InModuleScope psmm {
            $e = $script:PSMM_UI.Entries | Where-Object Name -eq 'AlphaMod'
            $e.Installed = $true; $e.InstalledVersion = [version]'1.0'
            $t = Start-PSMMTask -Label 'update check' -Kind 'updatecheck' -ScriptBlock {
                [pscustomobject]@{ Name = 'AlphaMod'; Latest = '9.9.9' }
            }
            $null = $t.Job | Wait-Job
            Receive-PSMMUITask
            $e.UpdateAvailable | Should -BeTrue
            $e.LatestVersion | Should -Be '9.9.9'
            $script:PSMM_UI.Status | Should -Match '1 update'
            Clear-PSMMTask
        }
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a pinned entry is never marked update-available (#research pinning)' {
        Set-UITestConfig
        InModuleScope psmm {
            $e = $script:PSMM_UI.Entries | Where-Object Name -eq 'BetaMod'   # pinned 2.0.0
            $e.Installed = $true; $e.InstalledVersion = [version]'2.0.0'
            $t = Start-PSMMTask -Label 'update check' -Kind 'updatecheck' -ScriptBlock {
                [pscustomobject]@{ Name = 'BetaMod'; Latest = '9.9.9' }
            }
            $null = $t.Job | Wait-Job
            Receive-PSMMUITask
            $e.UpdateAvailable | Should -BeFalse
            Clear-PSMMTask
        }
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Auth providers (engine)' -Tag Engine {

    It 'knows the five Connect-* modules and their disconnect commands (#32)' {
        $table = InModuleScope psmm { Get-PSMMAuthProviderTable }
        $table.Module | Should -Contain 'ExchangeOnlineManagement'
        $table.Module | Should -Contain 'Microsoft.Graph.Authentication'
        $table.Module | Should -Contain 'Az.Accounts'
        $table.Module | Should -Contain 'PnP.PowerShell'
        $table.Module | Should -Contain 'MicrosoftTeams'
        foreach ($p in $table) {
            $p.StatusCmd | Should -Not -BeNullOrEmpty
            $p.DisconnectCmd | Should -Not -BeNullOrEmpty
        }
    }

    It 'reports unknown modules as unsupported' {
        $s = InModuleScope psmm { Get-PSMMConnectionStatus -ModuleName 'ImportExcel' }
        $s.Supported | Should -BeFalse
        $s.Connected | Should -BeFalse
    }

    It 'reports a known module as supported but disconnected when its cmdlets are absent' {
        $s = InModuleScope psmm { Get-PSMMConnectionStatus -ModuleName 'ExchangeOnlineManagement' }
        $s.Supported | Should -BeTrue
        $s.Connected | Should -BeFalse
    }

    It 'refuses to disconnect an unsupported module' {
        { InModuleScope psmm { Disconnect-PSMMModule -ModuleName 'ImportExcel' } } | Should -Throw
    }
}

Describe 'Module locations screen (75-Paths)' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'every literal Write-PSMMLine markup string in src parses (tags balanced PER LINE)' {
        # regression for the 's' crash (2026-07-15): one [orange1] tag spanned
        # three Write-PSMMLine calls; each call is its own Markup, so every
        # line must balance on its own or Spectre throws "Unbalanced markup
        # stack" and the whole TUI dies
        $bad = foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '..' 'src') -Recurse -Filter '*.ps1') {
            $i = 0
            foreach ($line in Get-Content -LiteralPath $f.FullName) {
                $i++
                foreach ($m in [regex]::Matches($line, "Write-PSMMLine\s+'([^']*)'")) {
                    try { $null = [Spectre.Console.Markup]::new($m.Groups[1].Value) }
                    catch { "$($f.Name):${i}: $($m.Groups[1].Value)" }
                }
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It "set-primary ('s') renders its caveat lines without crashing and cancels on empty input" {
        $status = InModuleScope psmm {
            Mock Read-SpectreText { '' }
            $sw = [System.IO.StringWriter]::new()
            $settings = [Spectre.Console.AnsiConsoleSettings]::new()
            $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
            $settings.Interactive = [Spectre.Console.InteractionSupport]::No
            $settings.Ansi = [Spectre.Console.AnsiSupport]::No
            Set-PSMMConsole -Console ([Spectre.Console.AnsiConsole]::Create($settings))
            try { Set-PSMMPrimaryLocationUI } finally { Set-PSMMConsole -Console $null }
        }
        $status | Should -Match 'cancelled'
    }

    It "set-primary ('s') creates the folder, writes the override and puts the path first in this session" {
        $global:PSMMTestTarget = Join-Path $TestDrive 'UserProfileModules'
        $prevPSMP = $env:PSModulePath
        try {
            $status = InModuleScope psmm {
                Mock Read-SpectreText { $global:PSMMTestTarget }
                Mock Read-SpectreConfirm { $true }
                Mock Set-PSMMUserModulePath { }   # never touch the real powershell.config.json
                $sw = [System.IO.StringWriter]::new()
                $settings = [Spectre.Console.AnsiConsoleSettings]::new()
                $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
                $settings.Interactive = [Spectre.Console.InteractionSupport]::No
                $settings.Ansi = [Spectre.Console.AnsiSupport]::No
                Set-PSMMConsole -Console ([Spectre.Console.AnsiConsole]::Create($settings))
                try { Set-PSMMPrimaryLocationUI } finally { Set-PSMMConsole -Console $null }
                Should -Invoke Set-PSMMUserModulePath -Times 1 -Exactly
            }
            $status | Should -Match 'primary location set'
            Test-Path -LiteralPath $global:PSMMTestTarget | Should -BeTrue
            @($env:PSModulePath -split [System.IO.Path]::PathSeparator)[0] | Should -Be $global:PSMMTestTarget
        } finally {
            $env:PSModulePath = $prevPSMP
            Remove-Variable -Name PSMMTestTarget -Scope Global -ErrorAction SilentlyContinue
        }
    }
}
