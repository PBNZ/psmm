# Zero-config / empty-entry-set robustness: an empty set is a NORMAL state
# (fresh machine), and PowerShell returns empty arrays from functions as
# $null - engine functions must tolerate both.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force
}

Describe 'Empty-state robustness' -Tag Engine {

    AfterEach {
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath -Scope Global -ErrorAction SilentlyContinue
    }

    It 'discovery with zero config sources yields an empty active set, no warnings, no crash' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:PSMM_MainConfigPath    = Join-Path $root 'a\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'b\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'c\*.json')
        $active = InModuleScope psmm { Get-PSMMEntry }
        @($active).Count | Should -Be 0
        (InModuleScope psmm { Get-PSMMWarning }) | Should -BeNullOrEmpty
        (InModuleScope psmm { Get-PSMMAllEntries }) | Should -BeNullOrEmpty
    }

    It 'state/conflict/gallery functions accept a null or empty entry set' {
        InModuleScope psmm {
            { Update-PSMMLoaded -Entries $null } | Should -Not -Throw
            { Update-PSMMLoaded -Entries @() } | Should -Not -Throw
            { Update-PSMMAvailable -Entries $null } | Should -Not -Throw
            { Update-PSMMAvailable -Entries @() -Name 'X' } | Should -Not -Throw
            { Update-PSMMLatestVersion -Entries $null } | Should -Not -Throw
            $c = Get-PSMMConflict -Entries $null
            @($c.Validation).Count | Should -Be 0
            @($c.Duplicates).Count | Should -Be 0
        }
    }

    It 'Invoke-PSMMStartup with zero configs is a quiet no-op' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:PSMM_MainConfigPath    = Join-Path $root 'a\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'b\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'c\*.json')
        InModuleScope psmm {
            Mock Import-Module { }
            Mock Install-PSMMModule { }
            Mock Start-PSMMDeferredJob { }
            { Invoke-PSMMStartup -Quiet } | Should -Not -Throw
            Should -Invoke Import-Module -Times 0 -Exactly
            Should -Invoke Install-PSMMModule -Times 0 -Exactly
            Should -Invoke Start-PSMMDeferredJob -Times 0 -Exactly
        }
    }
}
