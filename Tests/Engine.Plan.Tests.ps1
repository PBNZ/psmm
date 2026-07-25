# The Mode x Install matrix, one It per cell, each asserting install / import /
# check / report INDEPENDENTLY (rust-ui-plan §3.4, S8/V9). Plus the cases
# nothing covered before: exact pin under Latest, range pin under Latest,
# range-pin flag clearing, Prerelease:true through Load+IfMissing, Ignore
# reaching the interactive check.
#
# And the static guard: the matrix must be decided in exactly ONE function.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    function New-Plan {
        param([hashtable]$Raw, [string]$Intent = 'Startup')
        InModuleScope psmm -Parameters @{ raw = $Raw; intent = $Intent } {
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]$raw) -Source 'x.json' -Writable $true
            Get-PSMMEntryPlan -Entry $e -Intent $intent
        }
    }
}

Describe 'Get-PSMMEntryPlan - the nine cells' -Tag Engine {

    # ---- Mode = Load -------------------------------------------------------

    It 'cell 1: Load + CheckOnly - imports, never installs, still checks' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'CheckOnly' }
        $p.Import   | Should -BeTrue
        $p.Install  | Should -Be 'none'
        $p.Check    | Should -BeTrue
        $p.Schedule | Should -Be 'foreground'   # an import touches no disk/gallery
        $p.Reason   | Should -Be 'imports at shell start, never auto-installed'
        $p.Notices  | Should -BeNullOrEmpty
    }

    It 'cell 2: Load + IfMissing - imports, installs when absent, in the background' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'IfMissing' }
        $p.Import   | Should -BeTrue
        $p.Install  | Should -Be 'ifmissing'
        $p.Check    | Should -BeTrue
        $p.Schedule | Should -Be 'background'
        $p.Reason   | Should -Be 'imports at shell start, background-installs if missing'
    }

    It 'cell 3: Load + Latest - imports, updates in the background (never foreground)' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'Latest' }
        $p.Import   | Should -BeTrue
        $p.Install  | Should -Be 'latest'
        $p.Check    | Should -BeTrue
        $p.Schedule | Should -Be 'background'
        $p.Reason   | Should -Be 'imports at shell start, background-updates afterwards'
    }

    # ---- Mode = InstallOnly ------------------------------------------------

    It 'cell 4: InstallOnly + CheckOnly - watch only, and it says so in words' {
        $p = New-Plan @{ Name = 'M'; Mode = 'InstallOnly'; Install = 'CheckOnly' }
        $p.Import   | Should -BeFalse
        $p.Install  | Should -Be 'none'
        $p.Check    | Should -BeTrue
        # background, not 'none': even a bare presence report is a disk sweep
        $p.Schedule | Should -Be 'background'
        $p.Reason   | Should -Be 'watch only - psmm will never install or load this'
    }

    It 'cell 5: InstallOnly + IfMissing - installs when absent, never imports' {
        $p = New-Plan @{ Name = 'M'; Mode = 'InstallOnly'; Install = 'IfMissing' }
        $p.Import   | Should -BeFalse
        $p.Install  | Should -Be 'ifmissing'
        $p.Check    | Should -BeTrue
        $p.Schedule | Should -Be 'background'
    }

    It 'cell 6: InstallOnly + Latest - keeps newest on disk, never imports' {
        $p = New-Plan @{ Name = 'M'; Mode = 'InstallOnly'; Install = 'Latest' }
        $p.Import   | Should -BeFalse
        $p.Install  | Should -Be 'latest'
        $p.Check    | Should -BeTrue
        $p.Schedule | Should -Be 'background'
    }

    # ---- Mode = Ignore (cells 7-9) ----------------------------------------

    It 'cells 7-9: Ignore + any Install - nothing, and no gallery I/O of any kind' {
        foreach ($i in 'CheckOnly', 'IfMissing', 'Latest') {
            $p = New-Plan @{ Name = 'M'; Mode = 'Ignore'; Install = $i }
            $p.Import   | Should -BeFalse -Because "Ignore+$i must not import"
            $p.Install  | Should -Be 'none' -Because "Ignore+$i must not install"
            $p.Check    | Should -BeFalse  -Because "Ignore+$i must not reach the gallery"
            $p.Schedule | Should -Be 'none'
            $p.Reason   | Should -Be 'off - nothing happens at shell start'
        }
    }

    It 'cells 7-9: an EXPLICIT Install policy under Ignore gets the cross-field notice' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Ignore'; Install = 'Latest' }
        @($p.Notices) | Should -Contain 'Install policy has no effect while Mode is Ignore'
    }

    It 'cells 7-9: an INHERITED Install default under Ignore says nothing' {
        # nagging every Ignore entry that never mentioned Install is noise
        $p = New-Plan @{ Name = 'M'; Mode = 'Ignore' }
        $p.Notices | Should -BeNullOrEmpty
    }

    It 'the Install value is preserved for saving even where it has no effect' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Ignore'; Install = 'Latest' }
        $p.Declared | Should -Be 'Latest'
    }
}

Describe 'Get-PSMMEntryPlan - pins' -Tag Engine {

    It 'an exact pin degrades Latest to IfMissing, with a notice (gh#20)' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'Latest'; Version = '1.2.3' }
        $p.Install     | Should -Be 'ifmissing'
        $p.Declared    | Should -Be 'Latest'      # what the file says is untouched
        $p.PinnedExact | Should -BeTrue
        ($p.Notices -join ' ') | Should -Match 'pinned to 1\.2\.3'
    }

    It 'an exact pin is never update-checked (docs: "never flagged update available")' {
        foreach ($i in 'CheckOnly', 'IfMissing', 'Latest') {
            (New-Plan @{ Name = 'M'; Mode = 'Load'; Install = $i; Version = '1.2.3' }).Check |
                Should -BeFalse -Because "an exact pin under $i has nothing to be flagged about"
        }
    }

    It 'a RANGE pin leaves Latest alone and IS checked, so the flag can clear (gh#23)' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'Latest'; Version = '[1.0,2.0)' }
        $p.Install     | Should -Be 'latest'
        $p.PinnedExact | Should -BeFalse
        $p.PinnedRange | Should -BeTrue
        $p.Check       | Should -BeTrue
        $p.Version     | Should -Be '[1.0,2.0)'
        $p.Reason      | Should -Be 'imports at shell start, background-updates inside the pin'
    }

    It 'a prerelease pin implies the prerelease track even without the opt-in' {
        (New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'IfMissing'; Version = '1.2.3-beta4' }).Prerelease |
            Should -BeTrue
    }

    It 'Prerelease:true survives Load + IfMissing with no pin at all (gh#21)' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'IfMissing'; Prerelease = $true }
        $p.Prerelease | Should -BeTrue
        $p.Version    | Should -BeNullOrEmpty
    }
}

Describe 'Get-PSMMEntryPlan - explicit user intent (Q-4)' -Tag Engine {

    It 'i on an Ignore row still installs - the policy governs AUTOMATIC behaviour only' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Ignore'; Install = 'CheckOnly' } 'Install'
        $p.Install  | Should -Be 'ifmissing'
        $p.Import   | Should -BeFalse
        $p.Schedule | Should -Be 'background'
    }

    It 'u on an unpinned row means latest' {
        (New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'CheckOnly' } 'Update').Install | Should -Be 'latest'
    }

    It 'u on an exactly pinned row cannot move past the pin' {
        (New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'Latest'; Version = '1.2.3' } 'Update').Install |
            Should -Be 'ifmissing'
    }

    It 'u on a range-pinned row means newest-in-range' {
        $p = New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'Latest'; Version = '[1.0,2.0)' } 'Update'
        $p.Install | Should -Be 'latest'
        $p.Version | Should -Be '[1.0,2.0)'
    }
}

Describe 'The update check consumes the plan, it does not re-decide' -Tag Engine {

    It 'skips exact pins and Ignore entries; checks a range pin against its range (gh#23)' {
        $seen = InModuleScope psmm {
            $mk = {
                param($raw)
                $e = Resolve-PSMMEntry -Raw ([pscustomobject]$raw) -Source 'x.json' -Writable $true
                $e.Installed = $true
                $e.InstalledVersion = [version]'1.5.0'
                $e
            }
            $entries = @(
                & $mk @{ Name = 'Plain';   Mode = 'Load'; Install = 'Latest' }
                & $mk @{ Name = 'Exact';   Mode = 'Load'; Install = 'Latest'; Version = '1.5.0' }
                & $mk @{ Name = 'Ranged';  Mode = 'Load'; Install = 'Latest'; Version = '[1.0,2.0)' }
                & $mk @{ Name = 'Ignored'; Mode = 'Ignore'; Install = 'Latest' }
            )
            $script:probe = [System.Collections.Generic.List[string]]::new()
            Mock Get-PSMMGalleryLatest {
                $script:probe.Add("$Name|$VersionRange")
                [pscustomobject]@{ Version = [version]'9.9.9'; Prerelease = '' }
            }
            $null = Update-PSMMLatestVersion -Entries $entries
            @($script:probe)
        }
        @($seen) | Should -Contain 'Plain|'
        @($seen) | Should -Contain 'Ranged|[1.0,2.0)'
        ($seen -join ' ') | Should -Not -Match 'Exact'
        ($seen -join ' ') | Should -Not -Match 'Ignored'
    }

    It 'a range-pinned module clears its flag once the in-range latest is installed (gh#23)' {
        $flag = InModuleScope psmm {
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{
                    Name = 'Ranged'; Mode = 'Load'; Install = 'Latest'; Version = '[1.0,2.0)'
                }) -Source 'x.json' -Writable $true
            $e.Installed = $true
            $e.InstalledVersion = [version]'1.9.0'
            # newest INSIDE the range - not the unconstrained gallery latest,
            # which is what used to be compared and could never be reached
            Mock Get-PSMMGalleryLatest { [pscustomobject]@{ Version = [version]'1.9.0'; Prerelease = '' } }
            $null = Update-PSMMLatestVersion -Entries @($e)
            $e.UpdateAvailable
        }
        $flag | Should -BeFalse
    }
}

Describe 'The matrix is decided in exactly one place (gh#29 static guard)' -Tag Engine {

    It 'no file outside Plan.ps1 branches on the CONFIG vocabulary to decide policy' {
        # The tell is comparing an entry's Mode/Install against the words a
        # config file uses - Load / InstallOnly / Ignore / CheckOnly /
        # IfMissing / Latest. Consuming a PLAN's verbs ($plan.Install -eq
        # 'latest') is the opposite of the defect: that is a caller executing
        # a decision it did not make.
        # CASE-SENSITIVE on purpose, and the casing is load-bearing: config
        # words are PascalCase ('Latest'), plan verbs are lowercase ('latest').
        # That is exactly the line between deciding and executing.
        $root = Join-Path $PSScriptRoot '..' 'src'
        $vocab = 'Load|InstallOnly|Ignore|CheckOnly|IfMissing|Latest'
        $patterns = @(
            "\.(Mode|Install)\b[)`"]*\s*-(c?eq|c?ne|c?in|c?notin)\s*[@(]*\s*'($vocab)'"   # $e.Mode -eq 'Load'
            "'($vocab)'\s*-(c?eq|c?ne)\s*[`"(\$]*\`$\w+\.(Mode|Install)\b"                 # the reverse
            "switch\s*\(\s*[`"(\$]*\`$\w+\.(Mode|Install)\b"                               # switch ($e.Install)
        )
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1)) {
            if ($f.Name -eq 'Plan.ps1') { continue }
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                $n++
                if ($line -match '^\s*#') { continue }        # prose may say anything
                foreach ($p in $patterns) {
                    if ($line -cmatch $p) { $offenders.Add("$($f.Name):$n  $($line.Trim())"); break }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "policy belongs in Get-PSMMEntryPlan, not in:`n$($offenders -join "`n")"
    }

    It 'the plan object carries every field its consumers need' {
        # a shape guard: the startup loader, the job payload, the grid context
        # sentence and the update check all read these by name
        $p = New-Plan @{ Name = 'M'; Mode = 'Load'; Install = 'Latest' }
        foreach ($f in 'Name', 'FriendlyName', 'Mode', 'Declared', 'Intent', 'Import', 'Install',
                       'Check', 'Schedule', 'Version', 'PinnedExact', 'PinnedRange', 'Prerelease',
                       'Scope', 'Reason', 'Notices') {
            $p.PSObject.Properties[$f] | Should -Not -BeNullOrEmpty -Because "consumers read .$f"
        }
    }
}
