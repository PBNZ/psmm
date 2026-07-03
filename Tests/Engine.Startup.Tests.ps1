# Startup loader semantics: the orthogonal Mode x Install matrix, the
# foreground/background split, and failure resilience. All disk/gallery
# operations are mocked — nothing is really installed or imported.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    function Set-StartupConfig([object[]]$Modules) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'main')
        $global:PSMM_MainConfigPath    = Join-Path $root 'main\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'profile\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'legacy\*.json')
        @{ Modules = $Modules } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $global:PSMM_MainConfigPath -Encoding utf8
    }
}

Describe 'Invoke-PSMMStartup' -Tag Engine {

    AfterEach {
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath, PSMM_InlineJson, PSMM_BackgroundStartup -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Load+IfMissing takes the fast path: import first, no install when present' {
        Set-StartupConfig @(@{ Name = 'FastMod'; Install = 'IfMissing'; Mode = 'Load' })
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { }
            Mock Install-PSMMModule { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'FastMod' }
            Should -Invoke Install-PSMMModule -Times 0 -Exactly
        }
    }

    It 'Load+IfMissing installs then imports when the module is genuinely missing' {
        Set-StartupConfig @(@{ Name = 'MissingMod'; Install = 'IfMissing'; Mode = 'Load' })
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            $script:importAttempt = 0
            Mock Import-Module {
                $script:importAttempt++
                if ($script:importAttempt -eq 1) { throw [System.IO.FileNotFoundException]::new('not found') }
            }
            Mock Install-PSMMModule { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Install-PSMMModule -Times 1 -Exactly -ParameterFilter { $Name -eq 'MissingMod' }
            Should -Invoke Import-Module -Times 2 -Exactly
        }
    }

    It 'Load+CheckOnly never installs, even when missing' {
        Set-StartupConfig @(@{ Name = 'CheckMod'; Install = 'CheckOnly'; Mode = 'Load' })
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { throw [System.IO.FileNotFoundException]::new('not found') }
            Mock Install-PSMMModule { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Install-PSMMModule -Times 0 -Exactly
        }
    }

    It 'Load+Latest goes through the gallery path (update) then loads' {
        Set-StartupConfig @(@{ Name = 'LatestMod'; Install = 'Latest'; Mode = 'Load' })
        InModuleScope psmm {
            Mock Get-Module { [pscustomobject]@{ Name = 'LatestMod' } } -ParameterFilter { $ListAvailable }
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { }
            Mock Install-PSMMModule { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Install-PSMMModule -Times 1 -Exactly -ParameterFilter { $Update -eq $true }
            Should -Invoke Import-Module -Times 1 -Exactly
        }
    }

    It 'InstallOnly defers to the background job and does nothing in the foreground' {
        Set-StartupConfig @(@{ Name = 'DeferMod'; Install = 'IfMissing'; Mode = 'InstallOnly' })
        InModuleScope psmm {
            Mock Start-PSMMDeferredJob { }
            Mock Import-Module { }
            Mock Install-PSMMModule { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Start-PSMMDeferredJob -Times 1 -Exactly
            Should -Invoke Import-Module -Times 0 -Exactly
            Should -Invoke Install-PSMMModule -Times 0 -Exactly
        }
    }

    It 'InstallOnly runs inline when $PSMM_BackgroundStartup = $false' {
        Set-StartupConfig @(@{ Name = 'InlineMod'; Install = 'IfMissing'; Mode = 'InstallOnly' })
        $global:PSMM_BackgroundStartup = $false
        InModuleScope psmm {
            Mock Start-PSMMDeferredJob { }
            Mock Get-Module { $null } -ParameterFilter { $ListAvailable }
            Mock Install-PSMMModule { }
            Mock Import-Module { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Start-PSMMDeferredJob -Times 0 -Exactly
            Should -Invoke Install-PSMMModule -Times 1 -Exactly -ParameterFilter { $Name -eq 'InlineMod' }
            Should -Invoke Import-Module -Times 0 -Exactly   # InstallOnly NEVER loads
        }
    }

    It 'Ignore entries are parsed but not actioned' {
        Set-StartupConfig @(@{ Name = 'IgnoredMod'; Install = 'Latest'; Mode = 'Ignore' })
        InModuleScope psmm {
            Mock Import-Module { }
            Mock Install-PSMMModule { }
            Mock Start-PSMMDeferredJob { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Import-Module -Times 0 -Exactly
            Should -Invoke Install-PSMMModule -Times 0 -Exactly
            Should -Invoke Start-PSMMDeferredJob -Times 0 -Exactly
        }
    }

    It 'one failing module does not stop the others' {
        Set-StartupConfig @(
            @{ Name = 'BoomMod'; Install = 'IfMissing'; Mode = 'Load' }
            @{ Name = 'OkMod'; Install = 'IfMissing'; Mode = 'Load' }
        )
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module {
                if ($Name -eq 'BoomMod') { throw 'kaboom' }
            }
            Mock Install-PSMMModule { }
            { Invoke-PSMMStartup -Quiet 3>$null } | Should -Not -Throw
            Should -Invoke Import-Module -ParameterFilter { $Name -eq 'OkMod' }
        }
    }

    It 'an exact version pin is honoured on import and install' {
        Set-StartupConfig @(@{ Name = 'PinMod'; Install = 'IfMissing'; Mode = 'Load'; Version = '2.5.0' })
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            $script:pinAttempt = 0
            Mock Import-Module {
                $script:pinAttempt++
                if ($script:pinAttempt -eq 1) { throw [System.IO.FileNotFoundException]::new('nope') }
            }
            Mock Install-PSMMModule { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Import-Module -ParameterFilter { "$RequiredVersion" -eq '2.5.0' }
            Should -Invoke Install-PSMMModule -ParameterFilter { $Version -eq '2.5.0' }
        }
    }

    It 'measures and records import time for loaded modules' {
        Set-StartupConfig @(@{ Name = 'TimedMod'; Install = 'IfMissing'; Mode = 'Load' })
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { Start-Sleep -Milliseconds 20 }
            Invoke-PSMMStartup -Quiet
            $timed = Get-PSMMAllEntries | Where-Object Name -eq 'TimedMod'
            $timed.ImportMs | Should -BeGreaterOrEqual 15
        }
    }
}

Describe 'Start-PSMMDeferredJob (real ThreadJob, mocked gallery)' -Tag Engine {

    AfterEach {
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath -Scope Global -ErrorAction SilentlyContinue
    }

    It 'produces one status line per module and reports CheckOnly-missing as FAILED' {
        # CheckOnly + a module that certainly is not installed -> deterministic
        # job output without any gallery traffic.
        $entries = InModuleScope psmm {
            @(
                Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'No-Such-Module-psmm-A'; Install = 'CheckOnly'; Mode = 'InstallOnly' }) -Source 'x.json' -Writable $true
                Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Pester'; Install = 'CheckOnly'; Mode = 'InstallOnly' }) -Source 'x.json' -Writable $true
            )
        }
        $job = InModuleScope psmm -Parameters @{ entries = $entries } {
            Start-PSMMDeferredJob -Entries $entries
        }
        $out = @($job | Wait-Job | Receive-Job)
        Remove-Job $job -Force
        @($out).Count | Should -Be 2
        ($out -join ' ') | Should -Match 'FAILED No-Such-Module-psmm-A'
        ($out -join ' ') | Should -Match 'ok Pester'
    }
}
