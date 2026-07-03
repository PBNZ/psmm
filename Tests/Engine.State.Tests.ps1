# Session/disk state refresh, scope classification, duplicates, unmanaged.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    function New-TestEntry([string]$Name) {
        InModuleScope psmm -Parameters @{ n = $Name } {
            Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = $n }) -Source 'x.json' -Writable $true
        }
    }
}

Describe 'Get-PSMMScopeForPath' -Tag Engine {

    It 'classifies a path under $HOME as CurrentUser' {
        InModuleScope psmm {
            Get-PSMMScopeForPath -Path (Join-Path $HOME 'Documents\PowerShell\Modules\Foo\1.0')
        } | Should -Be 'CurrentUser'
    }

    It 'classifies a path outside $HOME as AllUsers' {
        InModuleScope psmm {
            Get-PSMMScopeForPath -Path 'C:\Program Files\PowerShell\Modules\Foo\1.0'
        } | Should -Be 'AllUsers'
    }
}

Describe 'Update-PSMMLoaded' -Tag Engine {

    It 'marks a loaded module and records its version' {
        # Pester itself is guaranteed loaded while tests run
        $e = New-TestEntry 'Pester'
        InModuleScope psmm -Parameters @{ e = $e } { Update-PSMMLoaded -Entries @($e) }
        $e.Loaded | Should -BeTrue
        $e.LoadedVersion | Should -Not -BeNullOrEmpty
    }

    It 'marks an unknown module as not loaded' {
        $e = New-TestEntry 'No-Such-Module-psmm-Test'
        InModuleScope psmm -Parameters @{ e = $e } { Update-PSMMLoaded -Entries @($e) }
        $e.Loaded | Should -BeFalse
    }
}

Describe 'Update-PSMMAvailable' -Tag Engine {

    It 'fills Installed, InstalledVersion(s) and InstallScope for a real module (name-filtered)' {
        $e = New-TestEntry 'Pester'
        InModuleScope psmm -Parameters @{ e = $e } { Update-PSMMAvailable -Entries @($e) -Name 'Pester' }
        $e.Installed | Should -BeTrue
        $e.InstalledVersion | Should -Not -BeNullOrEmpty
        @($e.InstalledVersions).Count | Should -BeGreaterOrEqual 1
        $e.InstalledVersions[0].Scope | Should -BeIn @('CurrentUser', 'AllUsers')
        $e.InstallScope | Should -BeIn @('CurrentUser', 'AllUsers', 'mixed')
    }

    It 'marks a nonexistent module as not installed' {
        $e = New-TestEntry 'No-Such-Module-psmm-Test'
        InModuleScope psmm -Parameters @{ e = $e } { Update-PSMMAvailable -Entries @($e) -Name 'No-Such-Module-psmm-Test' }
        $e.Installed | Should -BeFalse
        $e.InstallScope | Should -BeNullOrEmpty
    }
}

Describe 'Get-PSMMDuplicateVersion' -Tag Engine {

    It 'reports only modules with more than one installed version, newest kept' {
        $dupes = InModuleScope psmm {
            Mock Get-Module {
                @(
                    [pscustomobject]@{ Name = 'Multi'; Version = [version]'2.0'; ModuleBase = 'C:\pf\Multi\2.0' }
                    [pscustomobject]@{ Name = 'Multi'; Version = [version]'1.0'; ModuleBase = 'C:\pf\Multi\1.0' }
                    [pscustomobject]@{ Name = 'Single'; Version = [version]'1.0'; ModuleBase = 'C:\pf\Single\1.0' }
                )
            } -ParameterFilter { $ListAvailable }
            Get-PSMMDuplicateVersion
        }
        @($dupes).Count | Should -Be 1
        $dupes[0].Name | Should -Be 'Multi'
        $dupes[0].Latest | Should -Be ([version]'2.0')
        @($dupes[0].Obsolete).Version | Should -Be @([version]'1.0')
    }
}

Describe 'Get-PSMMUnmanagedModule' -Tag Engine {

    It 'returns installed modules not in the managed set, case-insensitively' {
        $un = InModuleScope psmm {
            Mock Get-Module {
                @(
                    [pscustomobject]@{ Name = 'Managed'; Version = [version]'1.0'; ModuleBase = 'C:\pf\Managed\1.0'; Description = '' }
                    [pscustomobject]@{ Name = 'Rogue'; Version = [version]'3.1'; ModuleBase = 'C:\pf\Rogue\3.1'; Description = 'wild' }
                )
            } -ParameterFilter { $ListAvailable }
            Get-PSMMUnmanagedModule -ManagedNames @('MANAGED')
        }
        @($un).Name | Should -Be @('Rogue')
        $un[0].Version | Should -Be ([version]'3.1')
    }
}

Describe 'Get-PSMMInstallEngine' -Tag Engine {

    It 'returns PSResourceGet when Install-PSResource exists, else PowerShellGet' {
        $engine = InModuleScope psmm { Get-PSMMInstallEngine }
        $engine | Should -BeIn @('PSResourceGet', 'PowerShellGet')
        # on this machine PSResourceGet is present, so:
        if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
            $engine | Should -Be 'PSResourceGet'
        }
    }
}

Describe 'Get-PSMMConflict' -Tag Engine {

    It 'reports validation issues and duplicate names' {
        $conf = InModuleScope psmm {
            $bad  = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Install = 'Nope' }) -Source 'a.json' -Writable $true
            $one  = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Dup' }) -Source 'a.json' -Writable $true
            $two  = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Dup' }) -Source 'b.json' -Writable $true
            Get-PSMMConflict -Entries @($bad, $one, $two)
        }
        @($conf.Validation).Count | Should -Be 1
        $conf.Validation[0].Issues | Should -Match 'Missing Name'
        @($conf.Duplicates).Count | Should -Be 1
        $conf.Duplicates[0].Name | Should -Be 'Dup'
        $conf.Duplicates[0].Sources | Should -Match 'a\.json'
        $conf.Duplicates[0].Sources | Should -Match 'b\.json'
    }
}
