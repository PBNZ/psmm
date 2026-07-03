# Multi-source discovery, precedence and conflict warnings.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    # Point every discovery source at TestDrive; return the paths.
    function Set-TestConfigRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $global:PSMM_MainConfigPath    = Join-Path $root 'main\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'profile\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'legacy\*.json')
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'main'), (Join-Path $root 'profile'), (Join-Path $root 'legacy')
        $root
    }

    function Write-Cfg([string]$Path, [hashtable]$Content) {
        ($Content | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding utf8
    }
}

Describe 'Get-PSMMEntry discovery' -Tag Engine {

    AfterEach {
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath, PSMM_InlineJson -Scope Global -ErrorAction SilentlyContinue
    }

    It 'discovers all five sources in order' {
        $root = Set-TestConfigRoot
        $global:PSMM_InlineJson = '{"Modules":[{"Name":"InlineMod"}]}'
        Write-Cfg $global:PSMM_MainConfigPath @{ Includes = @(Join-Path $root 'inc.json'); Modules = @(@{ Name = 'MainMod' }) }
        Write-Cfg (Join-Path $root 'inc.json') @{ Modules = @(@{ Name = 'IncMod' }) }
        Write-Cfg $global:PSMM_ProfileConfigPath @{ Modules = @(@{ Name = 'ProfMod' }) }
        Write-Cfg (Join-Path $root 'legacy\a.json') @{ Modules = @(@{ Name = 'LegacyMod' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        $active.Name | Should -Be @('InlineMod', 'MainMod', 'IncMod', 'ProfMod', 'LegacyMod')
    }

    It 'main config wins a conflict against a later file, with a warning' {
        $root = Set-TestConfigRoot
        Write-Cfg $global:PSMM_MainConfigPath @{ Modules = @(@{ Name = 'Dup'; Description = 'from main' }) }
        Write-Cfg $global:PSMM_ProfileConfigPath @{ Modules = @(@{ Name = 'Dup'; Description = 'from profile' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        @($active | Where-Object Name -eq 'Dup').Count | Should -Be 1
        ($active | Where-Object Name -eq 'Dup').Description | Should -Be 'from main'
        (InModuleScope psmm { Get-PSMMWarning }) -join ' ' | Should -Match 'overridden by main config'
    }

    It 'main config wins a conflict against an EARLIER source (inline), replacing in place' {
        $root = Set-TestConfigRoot
        $global:PSMM_InlineJson = '{"Modules":[{"Name":"Dup","Description":"from inline"}]}'
        Write-Cfg $global:PSMM_MainConfigPath @{ Modules = @(@{ Name = 'Dup'; Description = 'from main' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        ($active | Where-Object Name -eq 'Dup').Description | Should -Be 'from main'
        (InModuleScope psmm { Get-PSMMWarning }) -join ' ' | Should -Match 'main config wins'
    }

    It 'among non-main files, first-loaded wins with an ERROR-style warning' {
        $root = Set-TestConfigRoot
        Write-Cfg $global:PSMM_ProfileConfigPath @{ Modules = @(@{ Name = 'Dup'; Description = 'first' }) }
        Write-Cfg (Join-Path $root 'legacy\z.json') @{ Modules = @(@{ Name = 'Dup'; Description = 'second' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        ($active | Where-Object Name -eq 'Dup').Description | Should -Be 'first'
        (InModuleScope psmm { Get-PSMMWarning }) -join ' ' | Should -Match 'ERROR conflict'
    }

    It 'a disabled file is parsed but contributes no active entries' {
        $root = Set-TestConfigRoot
        Write-Cfg $global:PSMM_ProfileConfigPath @{ Enabled = $false; Modules = @(@{ Name = 'OffMod' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        $active.Name | Should -Not -Contain 'OffMod'
        # ...but the entry is still known (for save-preservation and the UI)
        (InModuleScope psmm { Get-PSMMAllEntries }).Name | Should -Contain 'OffMod'
        $meta = InModuleScope psmm { Get-PSMMFileMeta }
        $meta[$global:PSMM_ProfileConfigPath].Enabled | Should -BeFalse
    }

    It 'ignores Includes outside the main config, with a warning' {
        $root = Set-TestConfigRoot
        Write-Cfg $global:PSMM_ProfileConfigPath @{ Includes = @(Join-Path $root 'x.json'); Modules = @(@{ Name = 'P' }) }
        Write-Cfg (Join-Path $root 'x.json') @{ Modules = @(@{ Name = 'ShouldNotLoad' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        $active.Name | Should -Not -Contain 'ShouldNotLoad'
        (InModuleScope psmm { Get-PSMMWarning }) -join ' ' | Should -Match 'Includes .* ignored'
    }

    It 'includes are one level deep only (an include cannot include)' {
        $root = Set-TestConfigRoot
        Write-Cfg $global:PSMM_MainConfigPath @{ Includes = @(Join-Path $root 'inc.json'); Modules = @() }
        Write-Cfg (Join-Path $root 'inc.json') @{ Includes = @(Join-Path $root 'nested.json'); Modules = @(@{ Name = 'Inc' }) }
        Write-Cfg (Join-Path $root 'nested.json') @{ Modules = @(@{ Name = 'Nested' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        $active.Name | Should -Contain 'Inc'
        $active.Name | Should -Not -Contain 'Nested'
    }

    It 'warns about a missing included file' {
        $root = Set-TestConfigRoot
        Write-Cfg $global:PSMM_MainConfigPath @{ Includes = @(Join-Path $root 'gone.json'); Modules = @() }

        $null = InModuleScope psmm { Get-PSMMEntry }
        (InModuleScope psmm { Get-PSMMWarning }) -join ' ' | Should -Match 'included config not found'
    }

    It 'expands ~ and environment variables in include paths' {
        $root = Set-TestConfigRoot
        $env:PSMM_TEST_INCDIR = $root
        Write-Cfg $global:PSMM_MainConfigPath @{ Includes = @('%PSMM_TEST_INCDIR%\inc.json'); Modules = @() }
        Write-Cfg (Join-Path $root 'inc.json') @{ Modules = @(@{ Name = 'EnvInc' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        $active.Name | Should -Contain 'EnvInc'
        Remove-Item Env:PSMM_TEST_INCDIR
    }

    It 'never loads the same file twice (main also listed as its own include)' {
        $root = Set-TestConfigRoot
        Write-Cfg $global:PSMM_MainConfigPath @{ Includes = @($global:PSMM_MainConfigPath); Modules = @(@{ Name = 'Once' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        @($active | Where-Object Name -eq 'Once').Count | Should -Be 1
    }

    It 'a broken JSON file produces a warning, not a crash, and other files still load' {
        $root = Set-TestConfigRoot
        Set-Content -LiteralPath $global:PSMM_MainConfigPath -Value '{not json' -Encoding utf8
        Write-Cfg $global:PSMM_ProfileConfigPath @{ Modules = @(@{ Name = 'Survivor' }) }

        $active = InModuleScope psmm { Get-PSMMEntry }
        $active.Name | Should -Contain 'Survivor'
        (InModuleScope psmm { Get-PSMMWarning }) -join ' ' | Should -Match 'failed to parse'
    }
}
