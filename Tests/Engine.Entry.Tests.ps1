# Entry resolution + file-level JSON parsing.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force
}

Describe 'Resolve-PSMMEntry' -Tag Engine {

    It 'applies defaults: Install=IfMissing, Mode=Load, FriendlyName=Name' {
        $e = InModuleScope psmm {
            Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Foo' }) -Source 'x.json' -Writable $true
        }
        $e.Install | Should -Be 'IfMissing'
        $e.Mode | Should -Be 'Load'
        $e.FriendlyName | Should -Be 'Foo'
        $e.Issues | Should -BeNullOrEmpty
    }

    It 'flags a missing Name' {
        $e = InModuleScope psmm {
            Resolve-PSMMEntry -Raw ([pscustomobject]@{ Description = 'no name' }) -Source 'x.json' -Writable $true
        }
        $e.Issues | Should -Contain 'Missing Name'
    }

    It 'degrades an invalid Install to IfMissing with an issue' {
        $e = InModuleScope psmm {
            Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Foo'; Install = 'Sometimes' }) -Source 'x.json' -Writable $true
        }
        $e.Install | Should -Be 'IfMissing'
        $e.Issues | Should -Match "Invalid Install 'Sometimes'"
    }

    It 'degrades an invalid Mode to Load with an issue' {
        $e = InModuleScope psmm {
            Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Foo'; Mode = 'Maybe' }) -Source 'x.json' -Writable $true
        }
        $e.Mode | Should -Be 'Load'
        $e.Issues | Should -Match "Invalid Mode 'Maybe'"
    }

    It 'accepts an exact version pin and marks it exact' {
        $e = InModuleScope psmm {
            Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Foo'; Version = '1.2.3' }) -Source 'x.json' -Writable $true
        }
        $e.Version | Should -Be '1.2.3'
        $e.PinnedExact | Should -BeTrue
    }

    It 'accepts a NuGet range pin without marking it exact' {
        $e = InModuleScope psmm {
            Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Foo'; Version = '[1.0,2.0)' }) -Source 'x.json' -Writable $true
        }
        $e.Version | Should -Be '[1.0,2.0)'
        $e.PinnedExact | Should -BeFalse
        $e.Issues | Should -BeNullOrEmpty
    }

    It 'rejects a garbage version pin with an issue and no pin' {
        $e = InModuleScope psmm {
            Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Foo'; Version = 'latest please' }) -Source 'x.json' -Writable $true
        }
        $e.Version | Should -BeNullOrEmpty
        $e.Issues | Should -Match 'Invalid Version'
    }

    It 'keeps orthogonal Mode x Install combinations untouched' {
        $e = InModuleScope psmm {
            Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Foo'; Install = 'CheckOnly'; Mode = 'Load' }) -Source 'x.json' -Writable $true
        }
        $e.Install | Should -Be 'CheckOnly'
        $e.Mode | Should -Be 'Load'
    }
}

Describe 'ConvertFrom-PSMMJson' -Tag Engine {

    It 'defaults Enabled to true when absent and reports HasEnabled=false' {
        $r = InModuleScope psmm { ConvertFrom-PSMMJson -Json '{"Modules":[]}' }
        $r.Enabled | Should -BeTrue
        $r.HasEnabled | Should -BeFalse
    }

    It 'honours an explicit Enabled=false' {
        $r = InModuleScope psmm { ConvertFrom-PSMMJson -Json '{"Enabled":false,"Modules":[]}' }
        $r.Enabled | Should -BeFalse
        $r.HasEnabled | Should -BeTrue
    }

    It 'drops null/empty include values' {
        $r = InModuleScope psmm { ConvertFrom-PSMMJson -Json '{"Includes":["a.json", null, ""],"Modules":[]}' }
        @($r.Includes) | Should -Be @('a.json')
    }

    It 'throws on invalid JSON' {
        { InModuleScope psmm { ConvertFrom-PSMMJson -Json '{oops' } } | Should -Throw
    }
}
