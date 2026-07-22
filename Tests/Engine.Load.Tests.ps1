# Load scope (gh#2): psmm must import modules into the USER's session, not
# into its own module session state.
#
# Import-Module called from inside a module imports into THAT module's session
# state unless -Global is passed (about_Modules / Import-Module -Scope). psmm
# is a module, so every import it performs is affected: without -Global the
# module is invisible at the prompt, `Get-Module` does not list it, and its
# commands are "not recognized" - while psmm's own `Get-Module` (global + its
# private state) reports it as loaded for the rest of the session.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:ManifestPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'psmm.psd1')).Path
    Import-Module $script:ManifestPath -Force
}

Describe 'Import scope' -Tag Engine {

    It 'every Import-Module psmm actually RUNS passes -Global' {
        # Static guard: the failure mode is silent and only shows up at the
        # user's prompt, so it must be impossible to reintroduce by editing.
        # AST, not regex - Import-Module appears in help text and doc comments
        # all over the UI, and those are strings, not invocations.
        $bad = foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '..' 'src') -Recurse -Filter '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $calls = $ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    "$($n.GetCommandName())" -eq 'Import-Module'
                }, $true)
            foreach ($c in $calls) {
                $hasGlobal = @($c.CommandElements | Where-Object {
                        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $_.ParameterName -eq 'Global'
                    }).Count -gt 0
                if (-not $hasGlobal) { "$($f.Name):$($c.Extent.StartLineNumber): $($c.Extent.Text)" }
            }
        }
        $bad | Should -BeNullOrEmpty -Because 'an import without -Global lands in psmm''s private session state (gh#2)'
    }

    It 'Import-PSMMModuleTimed makes the module visible in the CALLER''s session, not just psmm''s' {
        $root = Join-Path $TestDrive 'mods'
        $base = Join-Path $root 'PsmmFixtureMod\1.0.0'
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $base 'PsmmFixtureMod.psm1') -Value 'function Get-PsmmFixtureThing { 42 }'
        # FunctionsToExport = '*' mirrors the module that exposed this bug:
        # PowerShell cannot auto-load a command from a wildcard-export manifest,
        # so nothing masks a failed import
        New-ModuleManifest -Path (Join-Path $base 'PsmmFixtureMod.psd1') `
            -RootModule 'PsmmFixtureMod.psm1' -ModuleVersion '1.0.0' -FunctionsToExport '*'

        $probe = Join-Path $TestDrive 'probe.ps1'
        @"
`$env:PSModulePath = '$root' + [IO.Path]::PathSeparator + `$env:PSModulePath
Import-Module '$script:ManifestPath' -Force
`$psmm = Get-Module psmm
# exactly what the startup loader and the module menu's ctrl+l do, run inside
# psmm's own session state
& `$psmm {
    `$e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'PsmmFixtureMod' }) -Source 'test' -Writable `$false
    Import-PSMMModuleTimed -Entry `$e
}
if (Get-Module -Name PsmmFixtureMod) { 'VISIBLE-GLOBALLY' } else { 'HIDDEN-IN-PSMM' }
"@ | Set-Content -LiteralPath $probe -Encoding utf8

        $out = (& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $probe) -join "`n"
        $out | Should -Match 'VISIBLE-GLOBALLY'
    }
}

Describe 'Prerelease-aware versions' -Tag Engine {

    It 'Get-PSMMVersionDisplay attaches the label, and drops it when there is none' {
        InModuleScope psmm {
            Get-PSMMVersionDisplay -Version '0.1.0' -Prerelease 'beta8' | Should -Be '0.1.0-beta8'
            Get-PSMMVersionDisplay -Version '0.1.0' -Prerelease '' | Should -Be '0.1.0'
            Get-PSMMVersionDisplay -Version '0.1.0' -Prerelease '-beta8' | Should -Be '0.1.0-beta8'
            Get-PSMMVersionDisplay -Version $null -Prerelease 'x' | Should -Be ''
        }
    }

    It 'Get-PSMMPrereleaseLabel reads the manifest PSData, tolerating anything else' {
        InModuleScope psmm {
            Get-PSMMPrereleaseLabel -ModuleInfo ([pscustomobject]@{
                    PrivateData = @{ PSData = @{ Prerelease = 'beta8' } }
                }) | Should -Be 'beta8'
            Get-PSMMPrereleaseLabel -ModuleInfo ([pscustomobject]@{ PrivateData = @{} }) | Should -Be ''
            Get-PSMMPrereleaseLabel -ModuleInfo $null | Should -Be ''
        }
    }

    It 'Compare-PSMMEntryVersion orders base versions, then prerelease labels' {
        InModuleScope psmm {
            # base version wins
            Compare-PSMMEntryVersion -VersionA '1.1.0' -PrereleaseA '' -VersionB '1.0.0' -PrereleaseB '' | Should -Be 1
            # a release outranks a prerelease of the same base
            Compare-PSMMEntryVersion -VersionA '0.1.0' -PrereleaseA '' -VersionB '0.1.0' -PrereleaseB 'beta8' | Should -Be 1
            # label ordering: beta8 is newer than beta2
            Compare-PSMMEntryVersion -VersionA '0.1.0' -PrereleaseA 'beta8' -VersionB '0.1.0' -PrereleaseB 'beta2' | Should -Be 1
            Compare-PSMMEntryVersion -VersionA '0.1.0' -PrereleaseA 'beta2' -VersionB '0.1.0' -PrereleaseB 'beta2' | Should -Be 0
            # missing versions never throw
            Compare-PSMMEntryVersion -VersionA '' -PrereleaseA '' -VersionB '1.0.0' -PrereleaseB '' | Should -Be -1
            Compare-PSMMEntryVersion -VersionA 'not-a-version' -PrereleaseA '' -VersionB '1.0.0' -PrereleaseB '' | Should -Be 0
        }
    }

    It 'a prerelease version can actually be PINNED, and splits into base + label' {
        # regression: the pin picker offered "1.0.0-beta1" while the validator
        # rejected it, so the headline prerelease case could never be pinned
        InModuleScope psmm {
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'X'; Version = '1.2.3-beta4' }) -Source 'x' -Writable $true
            $e.Version | Should -Be '1.2.3-beta4'
            $e.PinnedExact | Should -BeTrue
            $e.PinnedBaseVersion | Should -Be '1.2.3'
            $e.PinnedPrerelease | Should -Be 'beta4'
            @($e.Issues).Count | Should -Be 0

            # a plain pin still has no label
            $p = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'X'; Version = '1.2.3' }) -Source 'x' -Writable $true
            $p.PinnedBaseVersion | Should -Be '1.2.3'
            $p.PinnedPrerelease | Should -Be ''

            # and genuine rubbish is still rejected
            $bad = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'X'; Version = 'not-a-version' }) -Source 'x' -Writable $true
            $bad.Version | Should -BeNullOrEmpty
            $bad.Issues -join ';' | Should -Match 'Invalid Version'
        }
    }

    It 'a prerelease pin imports by its BASE version (-RequiredVersion is [version])' {
        # Import-Module -RequiredVersion '1.2.3-beta4' throws
        # "Cannot convert value ... to type System.Version"
        InModuleScope psmm {
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'NoSuchModule-psmm'; Version = '1.2.3-beta4' }) -Source 'x' -Writable $true
            Mock Import-Module { } -ParameterFilter { $RequiredVersion }
            try { Import-PSMMModuleTimed -Entry $e } catch { }
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { "$RequiredVersion" -eq '1.2.3' }
        }
    }

    It 'an entry opts into prereleases through the config, and round-trips on save' {
        $file = Join-Path $TestDrive 'pre.json'
        InModuleScope psmm -Parameters @{ path = $file } {
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'X'; Prerelease = $true }) -Source $path -Writable $true
            $e.AllowPrerelease | Should -BeTrue
            $plain = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Y' }) -Source $path -Writable $true
            $plain.AllowPrerelease | Should -BeFalse

            Save-PSMMFile -Path $path -Entries @($e, $plain)
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            ($json.Modules | Where-Object Name -EQ 'X').Prerelease | Should -BeTrue
            # the default stays out of the file entirely
            ($json.Modules | Where-Object Name -EQ 'Y').PSObject.Properties['Prerelease'] | Should -BeNullOrEmpty
        }
    }
}
