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

    It 'imports land in the right session state: the user''s globally, psmm''s own privately' {
        # Static guard for BOTH halves of the invariant, because each failure
        # mode is silent:
        #   no -Global      -> the user's module lands in psmm's private state
        #                      and their prompt cannot see it (gh#2)
        #   -Global on ours -> psmm's UI engine pollutes the user's session and
        #                      shows up as if they had asked for it (gh#16)
        # An import is "psmm's own" when it is registered as a private import
        # on the spot, which is also what keeps Update-PSMMLoaded honest.
        # AST, not regex: Import-Module appears in help text all over the UI,
        # and those are strings, not invocations.
        $bad = foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '..' 'src') -Recurse -Filter '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $registrations = $ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    "$($n.GetCommandName())" -eq 'Register-PSMMPrivateImport'
                }, $true)
            $imports = $ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    "$($n.GetCommandName())" -eq 'Import-Module'
                }, $true)
            foreach ($c in $imports) {
                $hasGlobal = @($c.CommandElements | Where-Object {
                        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                        $_.ParameterName -eq 'Global'
                    }).Count -gt 0
                # is this import nested inside a Register-PSMMPrivateImport call?
                $isOwn = @($registrations | Where-Object {
                        $_.Extent.StartOffset -le $c.Extent.StartOffset -and
                        $_.Extent.EndOffset -ge $c.Extent.EndOffset
                    }).Count -gt 0
                if ($isOwn -and $hasGlobal) {
                    "$($f.Name):$($c.Extent.StartLineNumber): psmm's OWN import must not be -Global: $($c.Extent.Text)"
                } elseif (-not $isOwn -and -not $hasGlobal) {
                    "$($f.Name):$($c.Extent.StartLineNumber): user-facing import needs -Global: $($c.Extent.Text)"
                }
            }
        }
        $bad | Should -BeNullOrEmpty
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

Describe 'psmm''s own modules vs the user''s session' -Tag Engine {

    It 'knows which modules are its own, case-insensitively' {
        InModuleScope psmm {
            Test-PSMMOwnModule -Name 'psmm' | Should -BeTrue
            Test-PSMMOwnModule -Name 'PWSHSPECTRECONSOLE' | Should -BeTrue
            Test-PSMMOwnModule -Name 'ImportExcel' | Should -BeFalse
            Test-PSMMOwnModule -Name '' | Should -BeFalse
            Test-PSMMOwnModule -Name $null | Should -BeFalse
        }
    }

    It 'a privately-imported module is NOT reported as loaded in the user''s session' {
        InModuleScope psmm {
            # Pester itself is genuinely loaded, so it stands in for "a module
            # the user really has" - claim it as psmm's private import and the
            # entry must flip to not-loaded
            $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Pester' }) -Source 'x' -Writable $true
            Update-PSMMLoaded -Entries @($e)
            $e.Loaded | Should -BeTrue -Because 'baseline: Pester is loaded'

            $instance = @(Get-Module -Name Pester) | Select-Object -First 1
            Register-PSMMPrivateImport -Module $instance
            try {
                Update-PSMMLoaded -Entries @($e)
                $e.Loaded | Should -BeFalse -Because 'psmm''s own copy is not in the user''s session (gh#16)'
                $e.LoadedVersion | Should -BeNullOrEmpty
            } finally { $script:PSMM_PrivateImports = $null }

            Update-PSMMLoaded -Entries @($e)
            $e.Loaded | Should -BeTrue -Because 'and it comes back once the claim is dropped'
        }
    }

    It 'the private-import registry matches by INSTANCE, not by name' {
        # if the user imports the same module themselves, their instance must
        # still count as loaded - a by-name exclusion would hide it
        InModuleScope psmm {
            $mine = [pscustomobject]@{ Name = 'Pester' }        # a different object
            Register-PSMMPrivateImport -Module $mine
            try {
                Test-PSMMPrivateImport -Module $mine | Should -BeTrue
                $theirs = @(Get-Module -Name Pester) | Select-Object -First 1
                Test-PSMMPrivateImport -Module $theirs | Should -BeFalse
                $e = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Pester' }) -Source 'x' -Writable $true
                Update-PSMMLoaded -Entries @($e)
                $e.Loaded | Should -BeTrue
            } finally { $script:PSMM_PrivateImports = $null }
        }
    }

    It 'the unmanaged scan never offers psmm''s own modules for adoption' {
        $un = InModuleScope psmm {
            Mock Get-Module {
                @(
                    [pscustomobject]@{ Name = 'psmm'; Version = [version]'0.1.0'; ModuleBase = 'C:\m\psmm\0.1.0'; Description = '' }
                    [pscustomobject]@{ Name = 'PwshSpectreConsole'; Version = [version]'2.6.3'; ModuleBase = 'C:\m\Pwsh\2.6.3'; Description = '' }
                    [pscustomobject]@{ Name = 'Rogue'; Version = [version]'1.0'; ModuleBase = 'C:\m\Rogue\1.0'; Description = '' }
                )
            } -ParameterFilter { $ListAvailable }
            Get-PSMMUnmanagedModule -ManagedNames @('SomethingElse')
        }
        @($un).Name | Should -Be @('Rogue')
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
