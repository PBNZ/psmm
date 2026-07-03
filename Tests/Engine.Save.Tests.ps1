# Save round-trip: nothing is ever silently dropped or reshaped.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    function Set-TestConfigRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $global:PSMM_MainConfigPath    = Join-Path $root 'main\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'profile\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'legacy\*.json')
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'main'), (Join-Path $root 'profile'), (Join-Path $root 'legacy')
        $root
    }
}

Describe 'Save-PSMMFile' -Tag Engine {

    AfterEach {
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath, PSMM_InlineJson -Scope Global -ErrorAction SilentlyContinue
    }

    It 'round-trips a config file stably (load -> save -> reload identical)' {
        $null = Set-TestConfigRoot
        $original = [ordered]@{
            Enabled  = $true
            Includes = @()
            _legend  = [ordered]@{ Install = 'CheckOnly | IfMissing (default) | Latest' }
            Modules  = @(
                [ordered]@{ Name = 'A'; FriendlyName = 'Mod A'; Description = 'd'; Install = 'IfMissing'; Mode = 'Load' }
                [ordered]@{ Name = 'B'; Install = 'Latest'; Mode = 'InstallOnly' }
                [ordered]@{ Name = 'C'; Install = 'IfMissing'; Mode = 'Ignore'; Version = '1.2.3' }
            )
        }
        ($original | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $global:PSMM_MainConfigPath -Encoding utf8

        $null = InModuleScope psmm { Get-PSMMEntry }
        InModuleScope psmm {
            Save-PSMMFile -Path (Get-PSMMMainConfigPath) -Entries (Get-PSMMAllEntries)
        }
        $reloaded = Get-Content -LiteralPath $global:PSMM_MainConfigPath -Raw | ConvertFrom-Json

        $reloaded.Enabled | Should -BeTrue
        @($reloaded.Modules).Count | Should -Be 3
        $reloaded.Modules[0].Name | Should -Be 'A'
        $reloaded.Modules[0].FriendlyName | Should -Be 'Mod A'
        $reloaded.Modules[1].Name | Should -Be 'B'
        $reloaded.Modules[1].Mode | Should -Be 'InstallOnly'
        $reloaded.Modules[2].Version | Should -Be '1.2.3'
        $reloaded._legend.Install | Should -Match 'CheckOnly'

        # save again -> byte-identical (stability)
        $first = Get-Content -LiteralPath $global:PSMM_MainConfigPath -Raw
        $null = InModuleScope psmm { Get-PSMMEntry }
        InModuleScope psmm { Save-PSMMFile -Path (Get-PSMMMainConfigPath) -Entries (Get-PSMMAllEntries) }
        (Get-Content -LiteralPath $global:PSMM_MainConfigPath -Raw) | Should -Be $first
    }

    It 'preserves a DISABLED file''s entries on save (never silently dropped)' {
        $null = Set-TestConfigRoot
        @{ Enabled = $false; Modules = @(@{ Name = 'KeepMe'; Install = 'IfMissing'; Mode = 'Load' }) } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $global:PSMM_ProfileConfigPath -Encoding utf8

        $null = InModuleScope psmm { Get-PSMMEntry }
        InModuleScope psmm {
            Save-PSMMFile -Path (Get-PSMMProfileConfigPath) -Entries (Get-PSMMAllEntries)
        }
        $reloaded = Get-Content -LiteralPath $global:PSMM_ProfileConfigPath -Raw | ConvertFrom-Json
        $reloaded.Enabled | Should -BeFalse
        @($reloaded.Modules).Name | Should -Contain 'KeepMe'
    }

    It 'omits Enabled for files that never had it, writes Includes only for main' {
        $null = Set-TestConfigRoot
        @{ Modules = @(@{ Name = 'X' }) } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $global:PSMM_ProfileConfigPath -Encoding utf8

        $null = InModuleScope psmm { Get-PSMMEntry }
        InModuleScope psmm { Save-PSMMFile -Path (Get-PSMMProfileConfigPath) -Entries (Get-PSMMAllEntries) }
        $raw = Get-Content -LiteralPath $global:PSMM_ProfileConfigPath -Raw | ConvertFrom-Json
        $raw.PSObject.Properties.Name | Should -Not -Contain 'Enabled'
        $raw.PSObject.Properties.Name | Should -Not -Contain 'Includes'
    }

    It 'FriendlyName equal to Name is not written out (keeps files lean)' {
        $null = Set-TestConfigRoot
        @{ Modules = @(@{ Name = 'X'; FriendlyName = 'X' }) } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $global:PSMM_ProfileConfigPath -Encoding utf8

        $null = InModuleScope psmm { Get-PSMMEntry }
        InModuleScope psmm { Save-PSMMFile -Path (Get-PSMMProfileConfigPath) -Entries (Get-PSMMAllEntries) }
        $raw = Get-Content -LiteralPath $global:PSMM_ProfileConfigPath -Raw | ConvertFrom-Json
        $raw.Modules[0].PSObject.Properties.Name | Should -Not -Contain 'FriendlyName'
    }
}

Describe 'Test-PSMMWritable' -Tag Engine {

    It 'reports an existing writable file as writable' {
        $p = Join-Path $TestDrive 'w.json'
        Set-Content -LiteralPath $p -Value '{}'
        InModuleScope psmm -Parameters @{ p = $p } { Test-PSMMWritable -Path $p } | Should -BeTrue
    }

    It 'reports a nonexistent file in a writable directory as writable' {
        $p = Join-Path $TestDrive 'new-file.json'
        InModuleScope psmm -Parameters @{ p = $p } { Test-PSMMWritable -Path $p } | Should -BeTrue
    }

    It 'reports a nonexistent directory as not writable' {
        $p = Join-Path $TestDrive 'no-such-dir\x.json'
        InModuleScope psmm -Parameters @{ p = $p } { Test-PSMMWritable -Path $p } | Should -BeFalse
    }
}
