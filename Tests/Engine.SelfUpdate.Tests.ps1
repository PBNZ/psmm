# SelfUpdate engine: version string, semver compare, update-check cache and
# the update-available verdict + verified command selection.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    # redirect the cache next to a TestDrive main config
    function Set-UpdateTestConfig {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $global:PSMM_MainConfigPath = Join-Path $root 'psmm-config.json'
        $root
    }
}

AfterAll {
    Remove-Variable -Name PSMM_MainConfigPath, PSMM_UpdateCheck -Scope Global -ErrorAction SilentlyContinue
}

Describe 'psmm version + semver compare' -Tag Engine {

    It 'reports the running module version including the prerelease label' {
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..' 'psmm.psd1')
        $expected = "$($manifest.ModuleVersion)-$($manifest.PrivateData.PSData.Prerelease)"
        InModuleScope psmm -Parameters @{ expected = $expected } {
            Get-PSMMVersionString | Should -Be $expected
        }
    }

    It 'compares versions by NuGet semver rules' {
        InModuleScope psmm {
            Compare-PSMMVersion -A '0.1.0-beta3' -B '0.1.0-beta2' | Should -Be 1
            Compare-PSMMVersion -A '0.1.0-beta2' -B '0.1.0-beta3' | Should -Be -1
            Compare-PSMMVersion -A '0.1.0-beta3' -B '0.1.0-beta3' | Should -Be 0
            Compare-PSMMVersion -A '0.1.0' -B '0.1.0-beta9'       | Should -Be 1   # stable > prerelease
            Compare-PSMMVersion -A '0.2.0-beta1' -B '0.1.0'       | Should -Be 1   # base version wins
            Compare-PSMMVersion -A '0.1.0-beta.10' -B '0.1.0-beta.9' | Should -Be 1 # numeric segments
            Compare-PSMMVersion -A '0.1.0-beta.2.1' -B '0.1.0-beta.2' | Should -Be 1 # more segments
        }
    }
}

Describe 'update-check cache and verdict' -Tag Engine {

    BeforeEach { $script:cfgRoot = Set-UpdateTestConfig }
    AfterEach { Remove-Variable -Name PSMM_MainConfigPath, PSMM_UpdateCheck -Scope Global -ErrorAction SilentlyContinue }

    It 'cache path follows the main config directory (test seam)' {
        InModuleScope psmm -Parameters @{ root = $script:cfgRoot } {
            Get-PSMMUpdateCachePath | Should -Be (Join-Path $root 'psmm-update-check.json')
        }
    }

    It 'no cache -> no verdict' {
        InModuleScope psmm { Test-PSMMUpdateAvailable | Should -BeNullOrEmpty }
    }

    It 'a newer prerelease in the cache yields a verdict with the verified reinstall command' {
        InModuleScope psmm {
            ([pscustomobject]@{
                CheckedAt = [datetime]::UtcNow.ToString('o')
                LatestStable = $null
                LatestPrerelease = '9.9.9-beta1'
            } | ConvertTo-Json) | Set-Content -LiteralPath (Get-PSMMUpdateCachePath)
            $u = Test-PSMMUpdateAvailable
            $u | Should -Not -BeNullOrEmpty
            $u.Latest | Should -Be '9.9.9-beta1'
            $u.Current | Should -Be (Get-PSMMVersionString)
            # prerelease-label bumps are invisible to Update-PSResource
            # (verified against PSResourceGet 1.2.0) - the reinstall form is
            # the one that works
            $u.Command | Should -Be 'Install-PSResource psmm -Prerelease -Reinstall'
        }
    }

    It 'a cache matching the running version yields no verdict' {
        InModuleScope psmm {
            ([pscustomobject]@{
                CheckedAt = [datetime]::UtcNow.ToString('o')
                LatestStable = $null
                LatestPrerelease = (Get-PSMMVersionString)
            } | ConvertTo-Json) | Set-Content -LiteralPath (Get-PSMMUpdateCachePath)
            Test-PSMMUpdateAvailable | Should -BeNullOrEmpty
        }
    }

    It 'a corrupt cache file is treated as no cache' {
        InModuleScope psmm {
            '{ not json' | Set-Content -LiteralPath (Get-PSMMUpdateCachePath)
            Test-PSMMUpdateAvailable | Should -BeNullOrEmpty
        }
    }

    It 'the background check is throttled to once a day and honours $PSMM_UpdateCheck' {
        InModuleScope psmm {
            Mock Start-PSMMTask { }
            # fresh cache: throttled, no job
            ([pscustomobject]@{ CheckedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json) |
                Set-Content -LiteralPath (Get-PSMMUpdateCachePath)
            $null = Start-PSMMSelfUpdateCheck
            Should -Invoke Start-PSMMTask -Times 0 -Exactly
            # stale cache (2 days old): job starts
            ([pscustomobject]@{ CheckedAt = [datetime]::UtcNow.AddDays(-2).ToString('o') } | ConvertTo-Json) |
                Set-Content -LiteralPath (Get-PSMMUpdateCachePath)
            $null = Start-PSMMSelfUpdateCheck
            Should -Invoke Start-PSMMTask -Times 1 -Exactly
            # knob off: never, even with -Force
            $global:PSMM_UpdateCheck = $false
            $null = Start-PSMMSelfUpdateCheck -Force
            Should -Invoke Start-PSMMTask -Times 1 -Exactly
        }
    }
}

Describe 'prerelease-aware module update' -Tag Engine {

    It 'detects an installed prerelease from the manifest PSData' {
        # psmm itself is imported from the repo and carries a Prerelease
        # label; a random built-in module does not
        InModuleScope psmm {
            Mock Get-Module {
                [pscustomobject]@{
                    Version = [version]'0.1.0'
                    PrivateData = @{ PSData = @{ Prerelease = 'beta3' } }
                }
            } -ParameterFilter { $ListAvailable -and $Name -eq 'FakePre' }
            Mock Get-Module {
                [pscustomobject]@{ Version = [version]'1.0.0'; PrivateData = @{ PSData = @{} } }
            } -ParameterFilter { $ListAvailable -and $Name -eq 'FakeStable' }
            Test-PSMMInstalledPrerelease -Name 'FakePre' | Should -BeTrue
            Test-PSMMInstalledPrerelease -Name 'FakeStable' | Should -BeFalse
            Test-PSMMInstalledPrerelease -Name 'DefinitelyNotInstalled' | Should -BeFalse
        }
    }
}
