# Cross-cutting rendering rules (design system §11) and the screens that
# consume them: syntax-highlighted code (gh#9), clickable links (gh#10),
# wrapped prose (gh#11), prerelease-aware version cells (gh#6), one left/right
# notation everywhere (gh#7), and the coloured "this screen" help (gh#8).
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

    InModuleScope psmm {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:PSMMRoot 'src/UI') -Filter '*.ps1' | Sort-Object Name) { . $f.FullName }
        $script:PSMMUISourced = $true
        $script:PSMM_UI = @{
            Entries = [System.Collections.Generic.List[object]]::new()
            Cursor = 0; Top = 0
            Sel = [System.Collections.Generic.HashSet[int]]::new()
            Filter = ''; FilterMode = $false; View = @()
            Status = ''; Dirty = $false; HardQuit = $false
            Unmanaged = $null; ShowUnmanaged = $false
            Elevated = $false; Engine = 'PSResourceGet'
            Version = '0.0.0'; SelfUpdate = $null
        }
    }

    # markup -> plain text, the way every screen ends up on the terminal
    function Get-Plain([string[]]$Markup) {
        @($Markup | ForEach-Object {
                InModuleScope psmm -Parameters @{ l = "$_" } { [Spectre.Console.Markup]::Remove($l) }
            }) -join "`n"
    }

    function Assert-Parses([string[]]$Markup) {
        InModuleScope psmm -Parameters @{ lines = $Markup } {
            foreach ($l in $lines) { { [void][Spectre.Console.Markup]::new("$l") } | Should -Not -Throw }
        }
    }

    # render any psmm view to plain text through an injected console (the
    # scriptblock is re-created inside the module so it binds to module scope)
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
                $console.Write((& $build))
                $sw.ToString() -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
            } finally { Set-PSMMConsole -Console $null }
        }
    }
}

Describe 'Code highlighting' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'colours PowerShell tokens by kind and keeps the text intact' {
        $lines = InModuleScope psmm {
            Format-PSMMCode -Text @('Import-Module psmm -Force   # a comment', '$x = "hi"; 42')
        }
        @($lines).Count | Should -Be 2
        Assert-Parses $lines
        (Get-Plain $lines) | Should -Be "Import-Module psmm -Force   # a comment`n`$x = `"hi`"; 42"
        # commands, parameters, comments, variables, strings and numbers all
        # get a token - the exact colours come from the theme
        $joined = $lines -join "`n"
        $joined | Should -Match ([regex]::Escape('[deepskyblue1]Import-Module[/]'))
        $joined | Should -Match ([regex]::Escape('[salmon1]-Force[/]'))
        $joined | Should -Match ([regex]::Escape('[grey42]# a comment[/]'))
        $joined | Should -Match ([regex]::Escape('[steelblue1]$x[/]'))
        $joined | Should -Match ([regex]::Escape('[green3]"hi"[/]'))
        $joined | Should -Match ([regex]::Escape('[orange1]42[/]'))
    }

    It 'highlights JSON keys, strings, literals, numbers and // comments' {
        $lines = InModuleScope psmm {
            Format-PSMMCode -Language json -Text @('  "Enabled": true,   // a note', '  "Version": "1.2.3"')
        }
        Assert-Parses $lines
        $joined = $lines -join "`n"
        $joined | Should -Match ([regex]::Escape('[deepskyblue1]"Enabled"[/]'))
        $joined | Should -Match ([regex]::Escape('[salmon1]true[/]'))
        $joined | Should -Match ([regex]::Escape('[grey42]// a note[/]'))
        $joined | Should -Match ([regex]::Escape('[green3]"1.2.3"[/]'))
    }

    It 'escapes markup delimiters in the code it highlights (a range pin killed the UI once)' {
        $lines = InModuleScope psmm { Format-PSMMCode -Text @('$v = ''[1.0,2.0)''') }
        Assert-Parses $lines
        (Get-Plain $lines) | Should -Match '\[1\.0,2\.0\)'
    }

    It 'every line balances its own tags, even when a comment spans lines' {
        $lines = InModuleScope psmm {
            Format-PSMMCode -Text @('<# block', 'comment #>', 'Get-Module')
        }
        Assert-Parses $lines
        @($lines).Count | Should -Be 3
    }

    It 'unparseable input degrades to escaped plain text instead of throwing' {
        $lines = InModuleScope psmm { Format-PSMMCode -Text @('function {{{ broken') }
        Assert-Parses $lines
        (Get-Plain $lines) | Should -Match 'broken'
    }
}

Describe 'Links' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'renders a URL as a Spectre link that flattens back to its label' {
        InModuleScope psmm {
            $m = Get-PSMMLinkMarkup -Url 'https://github.com/PBNZ/psmm' -Text 'github.com/PBNZ/psmm'
            $m | Should -Match ([regex]::Escape('link=https://github.com/PBNZ/psmm'))
            { [void][Spectre.Console.Markup]::new($m) } | Should -Not -Throw
            [Spectre.Console.Markup]::Remove($m) | Should -Be 'github.com/PBNZ/psmm'
        }
    }

    It 'falls back to plain styled text for anything that cannot be a link tag' {
        InModuleScope psmm {
            $m = Get-PSMMLinkMarkup -Url 'not a url [with brackets]' -Text 'x'
            $m | Should -Not -Match 'link='
            { [void][Spectre.Console.Markup]::new($m) } | Should -Not -Throw
        }
    }

    It 'the about tab carries the project URL as a real link' {
        $about = InModuleScope psmm { @((Get-PSMMHelpTabs -Topic 'grid')['about']) }
        ($about -join "`n") | Should -Match 'link=https://github.com/PBNZ/psmm'
        Assert-Parses $about
    }
}

Describe 'Prose wrapping' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'wraps a path at separator boundaries, keeping every character' {
        InModuleScope psmm {
            $p = 'C:\Users\someone\OneDrive - A Long Org Name\Documents\PowerShell\Modules\Some.Module\1.2.3'
            $lines = @(Get-PSMMWrapPath -Path $p -Width 50)
            $lines.Count | Should -BeGreaterThan 1
            foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual 50 }
            ($lines -join '') | Should -Be $p          # nothing lost, nothing added
            $lines[0] | Should -Match '\\$'            # broke after a separator
            # short paths come back untouched, on one line
            @(Get-PSMMWrapPath -Path 'C:\short' -Width 50) | Should -Be @('C:\short')
            # a single folder name longer than the measure still fits somehow
            $long = 'C:\' + ('x' * 120)
            $hard = @(Get-PSMMWrapPath -Path $long -Width 40)
            ($hard -join '') | Should -Be $long
            foreach ($l in $hard) { $l.Length | Should -BeLessOrEqual 40 }
        }
    }

    It 'wraps at a readable measure, never the raw window width' {
        InModuleScope psmm {
            $long = 'word ' * 120
            $lines = @(Get-PSMMWrapText -Text $long -Width 40)
            $lines.Count | Should -BeGreaterThan 10
            foreach ($l in $lines) { $l.Length | Should -BeLessOrEqual 40 }
            # the default measure is capped well below a wide terminal
            (Get-PSMMProseWidth) | Should -BeLessOrEqual 84
        }
    }

    It 'keeps blank lines and returns balanced markup per line' {
        $lines = InModuleScope psmm { @(Get-PSMMProseMarkup -Text "one`n`ntwo" -Width 40) }
        @($lines).Count | Should -Be 3
        $lines[1] | Should -Be ''
        Assert-Parses $lines
    }

    It 'the paths screen OneDrive explanation no longer runs the full width' {
        $text = InModuleScope psmm {
            $st = New-PSMMListState
            $infos = @([pscustomobject]@{
                    Order = 0; Path = 'C:\Users\x\OneDrive\Documents\PowerShell\Modules'; First = $true
                    Exists = $true; OneDrive = $true; UserDefault = $true; Writable = $true; ModuleCount = 3
                })
            $sw = [System.IO.StringWriter]::new()
            $settings = [Spectre.Console.AnsiConsoleSettings]::new()
            $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
            $settings.Interactive = [Spectre.Console.InteractionSupport]::No
            $settings.Ansi = [Spectre.Console.AnsiSupport]::No
            $console = [Spectre.Console.AnsiConsole]::Create($settings)
            $console.Profile.Width = 200
            $console.Write((Build-PSMMPathsView -State $st -Infos $infos))
            $sw.ToString() -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
        }
        $prose = @($text -split "`r?`n" | Where-Object { $_ -match 'OneDrive backs up' })
        @($prose).Count | Should -Be 1
        $prose[0].TrimEnd().Length | Should -BeLessOrEqual 90 -Because 'prose wraps at ~84 columns even on a 200-column terminal (gh#11)'
    }
}

Describe 'Versions carry their prerelease label' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'a prerelease version cell is visibly different from the stable one' {
        InModuleScope psmm {
            $pre = Get-PSMMVersionMarkup -Version '0.1.0' -Prerelease 'beta8'
            $stable = Get-PSMMVersionMarkup -Version '0.1.0'
            [Spectre.Console.Markup]::Remove($pre) | Should -Be '0.1.0-beta8'
            [Spectre.Console.Markup]::Remove($stable) | Should -Be '0.1.0'
            $pre | Should -Not -Be $stable
            { [void][Spectre.Console.Markup]::new($pre) } | Should -Not -Throw
        }
    }

    It 'the grid version column shows the label and the gallery column flags the opt-in' {
        $text = InModuleScope psmm {
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'PreMod'; Prerelease = $true }) -Source 'x.json' -Writable $true
            $e.Installed = $true
            $e.InstalledVersion = [version]'0.1.0'
            $e.InstalledPrerelease = 'beta8'
            $script:PSMM_UI.Entries = [System.Collections.Generic.List[object]]::new()
            $script:PSMM_UI.Entries.Add($e)
            $script:PSMM_UI.Cursor = 0
            $sw = [System.IO.StringWriter]::new()
            $settings = [Spectre.Console.AnsiConsoleSettings]::new()
            $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
            $settings.Interactive = [Spectre.Console.InteractionSupport]::No
            $settings.Ansi = [Spectre.Console.AnsiSupport]::No
            $console = [Spectre.Console.AnsiConsole]::Create($settings)
            $console.Profile.Width = 140
            $console.Write((Build-PSMMGrid))
            $sw.ToString() -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
        }
        $text | Should -Match '0\.1\.0-beta8'
        $text | Should -Match '\+pre'
        $text | Should -Match 'prereleases allowed'    # the context sentence says it in words
    }
}

Describe 'left/right is one notation, everywhere' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'no key is ever RENDERED as an arrow glyph' {
        # Arrow glyphs are for indicators (scroll position, "next step"), never
        # for key names - a key is spelled out and wrapped in a capsule. Only
        # the key-rendering call sites are checked; prose arrows are fine.
        $keyCalls = 'Get-PSMMHint', 'Get-PSMMPersistentHint', 'Get-PSMMKeyCap', 'Get-PSMMHelpRow'
        $bad = foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '..' 'src') -Recurse -Filter '*.ps1') {
            $i = 0
            foreach ($line in Get-Content -LiteralPath $f.FullName) {
                $i++
                if ($line.TrimStart().StartsWith('#')) { continue }
                if (-not ($keyCalls | Where-Object { $line -match [regex]::Escape($_) })) { continue }
                if ($line -match '0x2190|0x2192' -or $line -match "[$([char]0x2190)$([char]0x2192)]") {
                    "$($f.Name):${i}: $($line.Trim())"
                }
            }
        }
        $bad | Should -BeNullOrEmpty -Because 'keys are spelled out as left/right (gh#7)'
    }

    It 'Get-PSMMDrillKey maps left to out and right to in, and nothing else' {
        InModuleScope psmm {
            Get-PSMMDrillKey -KeyInfo ([pscustomobject]@{ Key = [ConsoleKey]::LeftArrow }) | Should -Be 'out'
            Get-PSMMDrillKey -KeyInfo ([pscustomobject]@{ Key = [ConsoleKey]::RightArrow }) | Should -Be 'in'
            Get-PSMMDrillKey -KeyInfo ([pscustomobject]@{ Key = [ConsoleKey]::Enter }) | Should -Be ''
        }
    }

    It 'the grid legend advertises left/right' {
        $text = InModuleScope psmm {
            $script:PSMM_UI.Entries = [System.Collections.Generic.List[object]]::new()
            $script:PSMM_UI.Entries.Add((Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'A' }) -Source 'x.json' -Writable $true))
            $sw = [System.IO.StringWriter]::new()
            $settings = [Spectre.Console.AnsiConsoleSettings]::new()
            $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
            $settings.Interactive = [Spectre.Console.InteractionSupport]::No
            $settings.Ansi = [Spectre.Console.AnsiSupport]::No
            $console = [Spectre.Console.AnsiConsole]::Create($settings)
            $console.Profile.Width = 160
            $console.Write((Build-PSMMGrid))
            $sw.ToString() -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
        }
        $text | Should -Match 'left/right'
    }

    It 'the keys tab spells it out instead of drawing arrows' {
        $keys = InModuleScope psmm { @((Get-PSMMHelpTabs -Topic 'grid')['keys']) }
        $plain = Get-Plain $keys
        $plain | Should -Match 'left/right'
        $plain | Should -Not -Match "$([char]0x2192)"
        $plain | Should -Not -Match "$([char]0x2190)"
    }
}

Describe 'Help looks like the screens it documents' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'the "this screen" tab renders key capsules, not bare letters' {
        foreach ($topic in 'grid', 'module', 'commands', 'files', 'paths', 'gallery', 'cleanup', 'tasks') {
            $lines = InModuleScope psmm -Parameters @{ t = $topic } { @((Get-PSMMHelpTabs -Topic $t)['this screen']) }
            ($lines -join "`n") | Should -Match ([regex]::Escape('[salmon1 on grey19]')) -Because "topic '$topic' should render capsules (gh#8)"
            Assert-Parses $lines
        }
    }

    It 'the grid section paints the state glyphs in their live colours' {
        $lines = InModuleScope psmm { @((Get-PSMMHelpTabs -Topic 'grid')['this screen']) }
        $joined = $lines -join "`n"
        $joined | Should -Match ([regex]::Escape("[green3]$([char]0x25CF) loaded[/]"))
        $joined | Should -Match ([regex]::Escape("[orange1]$([char]0x25D0) installed[/]"))
        $joined | Should -Match ([regex]::Escape("[indianred1]$([char]0x25CB) missing[/]"))
        $joined | Should -Match ([regex]::Escape("[steelblue1]$([char]0x25CC) unmanaged[/]"))
    }

    It 'the config tab highlights the JSON sample and documents the prerelease field' {
        $lines = InModuleScope psmm { @((Get-PSMMHelpTabs -Topic 'grid')['config']) }
        ($lines -join "`n") | Should -Match ([regex]::Escape('[deepskyblue1]"Name"[/]'))
        (Get-Plain $lines) | Should -Match '"Prerelease": true'
        Assert-Parses $lines
    }

    It 'flattened help is still readable plain text for c=copy and the tests' {
        $flat = (InModuleScope psmm { Get-PSMMHelpText -Topic 'paths' }) -join "`n"
        $flat | Should -Match 'MODULE LOCATIONS'
        $flat | Should -Match 'really move'
        $flat | Should -Not -Match '\[/\]'   # no markup leaked through
    }
}

Describe 'The upkeep column' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'is called upkeep, not gallery - it names the behaviour, not the source' {
        $text = Get-RenderedText {
            $script:PSMM_UI.Entries = [System.Collections.Generic.List[object]]::new()
            $script:PSMM_UI.Entries.Add((Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'A'; Install = 'IfMissing' }) -Source 'x.json' -Writable $true))
            Build-PSMMGrid
        }
        ($text -replace '\s+', ' ') | Should -Match 'module state startup upkeep version scope file'
        $text | Should -Not -Match '\bgallery\b'
    }

    It 'reads correctly with every value the config can hold' {
        InModuleScope psmm {
            Get-PSMMUpkeepWord 'IfMissing' | Should -Be 'if-missing'
            Get-PSMMUpkeepWord 'CheckOnly' | Should -Be 'check-only'
            Get-PSMMUpkeepWord 'Latest' | Should -Be 'latest'
        }
    }
}

Describe 'Module details answer "which copy, from where?"' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'shows the FULL install path - the tail is the informative half' {
        # regression: the path was truncated at the window width, cutting off
        # the module and version folders, i.e. exactly what was being asked for
        $deep = 'C:\Users\someone\OneDrive - A Very Long Organisation Name Here\Documents\PowerShell\Modules\Some.Very.Long.Module.Name\16.0.27313.12000'
        $text = InModuleScope psmm -Parameters @{ p = $deep } {
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Some.Very.Long.Module.Name' }) -Source 'x.json' -Writable $true
            $e.Installed = $true
            $e.InstalledVersion = [version]'16.0.27313.12000'
            $e.InstalledVersions = @([pscustomobject]@{ Version = [version]'16.0.27313.12000'; Prerelease = ''; Path = $p; Scope = 'CurrentUser' })
            $sw = [System.IO.StringWriter]::new()
            $s = [Spectre.Console.AnsiConsoleSettings]::new()
            $s.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
            $s.Interactive = [Spectre.Console.InteractionSupport]::No
            $s.Ansi = [Spectre.Console.AnsiSupport]::No
            $c = [Spectre.Console.AnsiConsole]::Create($s); $c.Profile.Width = 118
            $c.Write((Build-PSMMModuleMenuView -Entry $e -Auth $null))
            $sw.ToString() -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
        }
        # the path wraps across lines rather than being cut - join them back up
        $joined = ($text -split "`r?`n" | ForEach-Object { ($_ -replace '^\s*.\s*', '') -replace '\s+.\s*$', '' }) -join ''
        # the WHOLE path survives, head and tail: the tail (module + version
        # folder) is the half the old truncation threw away
        $joined | Should -Match ([regex]::Escape($deep))
        # and the path row itself carries no ellipsis (the frame has one in
        # 'g goto…', so this must be scoped to the row)
        $pathRow = @($text -split "`r?`n" | Where-Object { $_ -match 'path\s+C:\\' })
        @($pathRow).Count | Should -Be 1
        $pathRow[0] | Should -Not -Match ([char]0x2026)
    }

    It 'warns when a manifest exports with wildcards - the reason a module cannot autoload' {
        InModuleScope psmm {
            $dir = Join-Path $TestDrive 'wild\WildMod\1.0.0'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'WildMod.psm1') -Value 'function Get-Wild { 1 }'
            New-ModuleManifest -Path (Join-Path $dir 'WildMod.psd1') -RootModule 'WildMod.psm1' `
                -ModuleVersion '1.0.0' -FunctionsToExport '*' -CmdletsToExport '*' -AliasesToExport '*'
            $prev = $env:PSModulePath
            $env:PSModulePath = (Join-Path $TestDrive 'wild') + [System.IO.Path]::PathSeparator + $prev
            try {
                $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'WildMod' }) -Source 'x.json' -Writable $true
                Update-PSMMAvailable -Entries @($e) -Name 'WildMod'
                $facts = Resolve-PSMMModuleFacts -Entry $e
                $facts.Exports | Should -Be 'wildcard'
                $facts.Bytes | Should -BeGreaterThan 0
                $facts.InstalledAt | Should -Not -BeNullOrEmpty
            } finally { $env:PSModulePath = $prev }
        }
    }
}

Describe 'Module details: the original screen' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'shows the install path, the search-path root it sits under and every version' {
        $text = InModuleScope psmm {
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Where' }) -Source 'x.json' -Writable $true
            $e.Installed = $true
            $e.InstalledVersion = [version]'2.0.0'
            $e.InstallScope = 'CurrentUser'
            $e.InstalledVersions = @(
                [pscustomobject]@{ Version = [version]'2.0.0'; Prerelease = ''; Path = 'C:\Mods\Where\2.0.0'; Scope = 'CurrentUser' }
                [pscustomobject]@{ Version = [version]'1.0.0'; Prerelease = ''; Path = 'C:\Mods\Where\1.0.0'; Scope = 'CurrentUser' }
            )
            $sw = [System.IO.StringWriter]::new()
            $settings = [Spectre.Console.AnsiConsoleSettings]::new()
            $settings.Out = [Spectre.Console.AnsiConsoleOutput]::new($sw)
            $settings.Interactive = [Spectre.Console.InteractionSupport]::No
            $settings.Ansi = [Spectre.Console.AnsiSupport]::No
            $console = [Spectre.Console.AnsiConsole]::Create($settings)
            $console.Profile.Width = 140
            # the location verdict is resolved ONCE, outside the render path
            $manifest = Resolve-PSMMModuleFacts -Entry $e
            $console.Write((Build-PSMMModuleMenuView -Entry $e -Auth $null -Manifest $manifest))
            $sw.ToString() -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
        }
        $text | Should -Match ([regex]::Escape('C:\Mods\Where\2.0.0'))
        $text | Should -Match ([regex]::Escape('C:\Mods'))
        $text | Should -Match 'not on the module search path'   # C:\Mods is not on PSModulePath here
        $text | Should -Match 'versions'
        $text | Should -Match 'v2\.0\.0'
        $text | Should -Match 'v1\.0\.0'
        $text | Should -Match 'p\s+move to another location'
    }
}

Describe 'User input never crashes a screen' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'a filter containing wildcard metacharacters filters instead of throwing' {
        # regression: '-like "*[*"' throws "the specified wildcard character
        # pattern is not valid" and took the screen down mid-keystroke
        InModuleScope psmm {
            { Test-PSMMFilterMatch -Text 'a[1]b' -Filter '[' } | Should -Not -Throw
            Test-PSMMFilterMatch -Text 'a[1]b' -Filter '[' | Should -BeTrue
            Test-PSMMFilterMatch -Text 'plain' -Filter '[' | Should -BeFalse
            Test-PSMMFilterMatch -Text 'MixedCase' -Filter 'mixed' | Should -BeTrue
            Test-PSMMFilterMatch -Text 'anything' -Filter '' | Should -BeTrue
        }
    }

    It 'the help filter survives a bracket without taking the screen down' {
        {
            $null = Get-RenderedText {
                $st = @{ Tab = 0; Scroll = 0; Filter = '['; FilterMode = $false; Status = '' }
                Build-PSMMHelpView -State $st -Tabs (Get-PSMMHelpTabs -Topic 'grid')
            }
        } | Should -Not -Throw
    }

    It 'the grid filter survives a bracket too' {
        {
            $null = Get-RenderedText {
                $script:PSMM_UI.Entries = [System.Collections.Generic.List[object]]::new()
                $script:PSMM_UI.Entries.Add((Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'A' }) -Source 'x.json' -Writable $true))
                $script:PSMM_UI.Filter = '['
                try { Build-PSMMGrid } finally { $script:PSMM_UI.Filter = '' }
            }
        } | Should -Not -Throw
    }

    It 'a path with markup delimiters is escaped before it reaches a Spectre prompt' {
        # Read-SpectreConfirm passes -Message straight into TextPrompt, which
        # parses it as markup: an unescaped C:\odd[1]\path threw
        $bad = foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '..' 'src') -Recurse -Filter '*.ps1') {
            $i = 0
            foreach ($line in Get-Content -LiteralPath $f.FullName) {
                $i++
                if ($line.TrimStart().StartsWith('#')) { continue }
                if ($line -notmatch 'Read-Spectre(Confirm|Selection)\s') { continue }
                # a message that interpolates TEXT must escape it. A count is
                # an integer and can never carry a markup delimiter, so those
                # interpolations are dropped before the check.
                $probe = $line -replace '\$\([^)]*\.Count\)', 'N'
                if ($probe -match '-Message\s+"[^"]*\$' -and $probe -notmatch 'ConvertTo-PSMMSafe') {
                    "$($f.Name):${i}: $($line.Trim())"
                }
            }
        }
        $bad | Should -BeNullOrEmpty -Because 'user-controlled text in a Spectre prompt must be markup-escaped'
    }
}

Describe 'psmm''s own modules read as infrastructure' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'shows "psmm''s own" instead of loaded/installed once the module is present' {
        InModuleScope psmm {
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'PwshSpectreConsole' }) -Source 'x.json' -Writable $true
            $e.Installed = $true
            [Spectre.Console.Markup]::Remove((Get-PSMMStateMarkup -Entry $e)) | Should -Match "psmm's own"
            $e.Loaded = $true
            [Spectre.Console.Markup]::Remove((Get-PSMMStateMarkup -Entry $e)) | Should -Match "psmm's own"
            # ... but a MISSING dependency is a real problem and still says so
            $e.Installed = $false; $e.Loaded = $false
            [Spectre.Console.Markup]::Remove((Get-PSMMStateMarkup -Entry $e)) | Should -Match 'missing'
            # and a normal module is unaffected
            $n = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'ImportExcel' }) -Source 'x.json' -Writable $true
            $n.Loaded = $true
            [Spectre.Console.Markup]::Remove((Get-PSMMStateMarkup -Entry $n)) | Should -Match 'loaded'
        }
    }

    It 'the "N loaded" count excludes psmm''s own even when it IS loaded' {
        $text = Get-RenderedText {
            $mine = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'PwshSpectreConsole' }) -Source 'x.json' -Writable $true
            $mine.Loaded = $true; $mine.Installed = $true; $mine.InstalledVersion = [version]'2.6.3'
            $yours = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'ImportExcel' }) -Source 'x.json' -Writable $true
            $yours.Loaded = $true; $yours.Installed = $true; $yours.InstalledVersion = [version]'7.8.10'
            $script:PSMM_UI.Entries = [System.Collections.Generic.List[object]]::new()
            $script:PSMM_UI.Entries.Add($mine); $script:PSMM_UI.Entries.Add($yours)
            $script:PSMM_UI.Cursor = 0
            Build-PSMMGrid
        }
        # both rows say loaded; only one of them is YOURS
        $text | Should -Match '2 modules'
        $text | Should -Match '1 loaded'
        $text | Should -Match "psmm's own"
    }

    It 'the context sentence tells the truth about whose session it is in' {
        $notYours = Get-RenderedText {
            $mine = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'PwshSpectreConsole' }) -Source 'x.json' -Writable $true
            $mine.Installed = $true; $mine.InstalledVersion = [version]'2.6.3'   # imported privately -> not Loaded
            $script:PSMM_UI.Entries = [System.Collections.Generic.List[object]]::new()
            $script:PSMM_UI.Entries.Add($mine)
            $script:PSMM_UI.Cursor = 0
            Build-PSMMGrid
        }
        $notYours | Should -Match 'not part of your session'

        $alsoYours = Get-RenderedText {
            $mine = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'PwshSpectreConsole' }) -Source 'x.json' -Writable $true
            $mine.Installed = $true; $mine.Loaded = $true; $mine.InstalledVersion = [version]'2.6.3'
            $script:PSMM_UI.Entries = [System.Collections.Generic.List[object]]::new()
            $script:PSMM_UI.Entries.Add($mine)
            $script:PSMM_UI.Cursor = 0
            Build-PSMMGrid
        }
        $alsoYours | Should -Match 'also imported in your own session'
    }

    It 'never unloads psmm or its UI engine, in bulk or from the module menu' {
        InModuleScope psmm {
            $mine = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'PwshSpectreConsole' }) -Source 'x.json' -Writable $true
            $mine.Loaded = $true; $mine.Installed = $true
            $script:PSMM_UI.Entries = [System.Collections.Generic.List[object]]::new()
            $script:PSMM_UI.Entries.Add($mine)
            $script:PSMM_UI.Cursor = 0
            $script:PSMM_UI.View = @(0)
            $script:PSMM_UI.Sel.Clear()
            Mock Remove-Module { }
            Invoke-PSMMBulk -Action Unload
            Should -Invoke Remove-Module -Times 0 -Exactly
            $script:PSMM_UI.Status | Should -Match "psmm's own"
        }
    }
}

Describe 'Destructive actions are gated' -Tag UI -Skip:(-not $SpectreAvailable) {

    It 'the typed confirmation accepts only the phrase - not y, not enter, not esc' {
        InModuleScope psmm {
            Mock Read-PSMMText { 'really move' }
            Read-PSMMConfirmPhrase -Phrase 'really move' | Should -BeTrue
            Mock Read-PSMMText { 'REALLY   move' }        # case and spacing are noise
            Read-PSMMConfirmPhrase -Phrase 'really move' | Should -BeTrue
            Mock Read-PSMMText { 'y' }
            Read-PSMMConfirmPhrase -Phrase 'really move' | Should -BeFalse
            Mock Read-PSMMText { '' }
            Read-PSMMConfirmPhrase -Phrase 'really move' | Should -BeFalse
            Mock Read-PSMMText { $null }                  # esc
            Read-PSMMConfirmPhrase -Phrase 'really move' | Should -BeFalse
        }
    }
}
