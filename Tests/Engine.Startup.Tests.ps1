# Startup loader mechanics: what the loader DOES with the plans it is handed —
# the foreground/background split and failure resilience. The matrix itself is
# decided (and tested cell by cell) in Engine.Plan.Tests.ps1.
#
# The governing rule since gh#19: the import is the only foreground action.
# No install, update or gallery lookup ever happens before the prompt.
# All disk/gallery operations are mocked — nothing is really installed.
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

    It 'Load+IfMissing defers the install when the module is genuinely missing (gh#19)' {
        # The old behaviour installed in the FOREGROUND and imported the result.
        # Under D-2 the install is background work and the module is available
        # next session (Q-2) - it is never imported behind a live prompt.
        Set-StartupConfig @(@{ Name = 'MissingMod'; Install = 'IfMissing'; Mode = 'Load' })
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { throw [System.IO.FileNotFoundException]::new('not found') }
            Mock Install-PSMMModule { }
            Mock Start-PSMMDeferredJob { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Install-PSMMModule -Times 0 -Exactly       # never in the foreground
            Should -Invoke Import-Module -Times 1 -Exactly            # tried once, no retry
            Should -Invoke Start-PSMMDeferredJob -Times 1 -Exactly -ParameterFilter {
                @($Plans).Count -eq 1 -and $Plans[0].Name -eq 'MissingMod' -and $Plans[0].Install -eq 'ifmissing'
            }
        }
    }

    It 'Load+IfMissing schedules NO background work when the module is already present' {
        # the successful import is the presence check, so IfMissing has nothing
        # left to do - and no job is started at all
        Set-StartupConfig @(@{ Name = 'PresentMod'; Install = 'IfMissing'; Mode = 'Load' })
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { }
            Mock Install-PSMMModule { }
            Mock Start-PSMMDeferredJob { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Start-PSMMDeferredJob -Times 0 -Exactly
            Should -Invoke Install-PSMMModule -Times 0 -Exactly
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

    It 'Load+Latest imports what is on disk and defers the update (gh#19)' {
        # THE headline fix: this cell used to perform a synchronous
        # Install-PSMMModule -Update - a gallery round trip - before the
        # prompt, on every single shell start.
        Set-StartupConfig @(@{ Name = 'LatestMod'; Install = 'Latest'; Mode = 'Load' })
        InModuleScope psmm {
            Mock Get-Module { [pscustomobject]@{ Name = 'LatestMod' } } -ParameterFilter { $ListAvailable }
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { }
            Mock Install-PSMMModule { }
            Mock Start-PSMMDeferredJob { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Install-PSMMModule -Times 0 -Exactly
            Should -Invoke Import-Module -Times 1 -Exactly
            Should -Invoke Start-PSMMDeferredJob -Times 1 -Exactly -ParameterFilter {
                $Plans[0].Name -eq 'LatestMod' -and $Plans[0].Install -eq 'latest'
            }
        }
    }

    It 'NOTHING on the foreground startup path touches the gallery (gh#19 gate)' {
        # The rc02 exit gate, as a test: every install engine entry point is
        # instrumented, and one config exercises all three Install policies
        # against both Modes. Any foreground network call trips this.
        Set-StartupConfig @(
            @{ Name = 'GateA'; Install = 'Latest'; Mode = 'Load' }
            @{ Name = 'GateB'; Install = 'IfMissing'; Mode = 'Load'; Version = '1.2.3' }
            @{ Name = 'GateC'; Install = 'CheckOnly'; Mode = 'Load' }
            @{ Name = 'GateD'; Install = 'Latest'; Mode = 'InstallOnly' }
            @{ Name = 'GateE'; Install = 'IfMissing'; Mode = 'InstallOnly'; Prerelease = $true }
            @{ Name = 'GateF'; Install = 'CheckOnly'; Mode = 'InstallOnly' }
        )
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { }
            Mock Start-PSMMDeferredJob { }
            # engine entry points are always present; the provider cmdlets
            # depend on which of PSResourceGet / PowerShellGet is installed,
            # and Mock needs a command that exists
            $watch = @('Install-PSMMModule', 'Invoke-PSMMPlanAction', 'Get-PSMMGalleryLatest')
            $watch += @('Install-PSResource', 'Update-PSResource', 'Install-Module',
                        'Find-PSResource', 'Find-Module') |
                Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
            foreach ($fn in $watch) { Mock -CommandName $fn -MockWith { } }
            Invoke-PSMMStartup -Quiet
            foreach ($fn in $watch) {
                Should -Invoke $fn -Times 0 -Exactly -Because "$fn is gallery/disk work and must never run in the foreground"
            }
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

    It 'an exact version pin is honoured on import, and carried into the deferred plan' {
        Set-StartupConfig @(@{ Name = 'PinMod'; Install = 'IfMissing'; Mode = 'Load'; Version = '2.5.0' })
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { throw [System.IO.FileNotFoundException]::new('nope') }
            Mock Install-PSMMModule { }
            Mock Start-PSMMDeferredJob { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Import-Module -ParameterFilter { "$RequiredVersion" -eq '2.5.0' }
            Should -Invoke Start-PSMMDeferredJob -ParameterFilter { $Plans[0].Version -eq '2.5.0' }
        }
    }

    It "the entry's prerelease policy survives the fast path (gh#21)" {
        # Load+IfMissing used to call Install-PSMMModule with no -Prerelease at
        # all, so "Prerelease": true with no pin quietly installed the newest
        # STABLE version. The plan carries the policy now.
        Set-StartupConfig @(@{ Name = 'PreMod'; Install = 'IfMissing'; Mode = 'Load'; Prerelease = $true })
        InModuleScope psmm {
            Mock Get-Module { $null } -ParameterFilter { -not $ListAvailable }
            Mock Import-Module { throw [System.IO.FileNotFoundException]::new('nope') }
            Mock Start-PSMMDeferredJob { }
            Invoke-PSMMStartup -Quiet
            Should -Invoke Start-PSMMDeferredJob -ParameterFilter { $Plans[0].Prerelease -eq $true }
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
        $plans = InModuleScope psmm {
            @(
                Get-PSMMEntryPlan -Entry (Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'No-Such-Module-psmm-A'; Install = 'CheckOnly'; Mode = 'InstallOnly' }) -Source 'x.json' -Writable $true)
                Get-PSMMEntryPlan -Entry (Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = 'Pester'; Install = 'CheckOnly'; Mode = 'InstallOnly' }) -Source 'x.json' -Writable $true)
            )
        }
        $job = InModuleScope psmm -Parameters @{ plans = $plans } {
            Start-PSMMDeferredJob -Plans $plans
        }
        $out = @($job | Wait-Job | Receive-Job)
        Remove-Job $job -Force
        @($out).Count | Should -Be 2
        ($out -join ' ') | Should -Match 'FAILED No-Such-Module-psmm-A'
        ($out -join ' ') | Should -Match 'ok Pester'
    }

    It 'the job runs the ENGINE actuator, not a hand-written copy of it (gh#25, gh#29)' {
        # The prelude is what kills implementations 3 and 4: the ThreadJob
        # dot-sources psmm's real functions instead of re-deriving policy.
        # If the prelude ever stops carrying them, this fails loudly.
        $probe = InModuleScope psmm {
            $prelude = Get-PSMMJobPrelude
            $wanted = @('Install-PSMMModule', 'Invoke-PSMMPlanAction', 'Test-PSMMVersionInstalled',
                        'Test-PSMMInstalledPrerelease', 'Get-PSMMPrereleaseLabel', 'Get-PSMMNormalVersion')
            $job = Start-ThreadJob -Name 'psmm-task-prelude-probe' -ScriptBlock {
                . ([scriptblock]::Create($using:prelude))
                $using:wanted | ForEach-Object { "$_=$([bool](Get-Command $_ -ErrorAction SilentlyContinue))" }
                # and the real thing actually executes
                Invoke-PSMMPlanAction -Plan ([pscustomobject]@{
                        Name = 'No-Such-Module-psmm-B'; Install = 'none'; Version = $null
                        Prerelease = $false; Scope = 'CurrentUser'
                    })
            }
            $o = @($job | Wait-Job | Receive-Job)
            Remove-Job $job -Force
            $o
        }
        ($probe -join ' ') | Should -Not -Match '=False'
        ($probe -join ' ') | Should -Match 'FAILED No-Such-Module-psmm-B'
    }

    It 'Latest + an exact pin never reinstalls what is already on disk (gh#20)' {
        # Pester is installed here, so a Latest plan pinned to its exact
        # installed version must resolve to "nothing to do" - no gallery call.
        $result = InModuleScope psmm {
            $v = @(Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending)[0].Version
            $entry = Resolve-PSMMEntry -Raw ([pscustomobject]@{
                    Name = 'Pester'; Install = 'Latest'; Mode = 'InstallOnly'; Version = "$v"
                }) -Source 'x.json' -Writable $true
            $plan = Get-PSMMEntryPlan -Entry $entry
            [pscustomobject]@{
                Install = $plan.Install
                Check   = $plan.Check
                Action  = (Invoke-PSMMPlanAction -Plan $plan)
            }
        }
        $result.Install | Should -Be 'ifmissing'   # Latest degraded by the pin
        $result.Check   | Should -BeFalse          # and never flagged
        $result.Action  | Should -Be 'ok Pester'   # present: nothing done
    }

    It 'a version pin never force-reinstalls, exact or range (gh#20)' {
        # The exact-pin case is caught earlier by Test-PSMMVersionInstalled.
        # The RANGE case is not, and cannot be - "newest in range" is a moving
        # target - so the actuator must simply never pass -Reinstall for a pin.
        #
        # Measured against a local feed before writing this: with -Reinstall
        # the module folder is deleted and re-extracted even when the range is
        # already satisfied (sentinel file inside it disappears), so
        # Latest + "[1.0,2.0)" re-downloaded on EVERY shell start. Without it,
        # PSResourceGet skips the satisfied range and still takes a newer
        # in-range version the moment one is published.
        InModuleScope psmm {
            Mock Install-PSResource { }
            Mock Get-Module { @([pscustomobject]@{ Name = 'RangeMod'; Version = [version]'1.5.0' }) } -ParameterFilter { $ListAvailable }
            Install-PSMMModule -Name 'RangeMod' -Update -Version '[1.0,2.0)'
            Should -Invoke Install-PSResource -Times 1 -Exactly
            Should -Invoke Install-PSResource -Times 0 -Exactly -ParameterFilter { $Reinstall } `
                -Because 'a range pin that is already satisfied must not be re-downloaded every shell start'
            Should -Invoke Install-PSResource -Times 1 -Exactly -ParameterFilter { $Version -eq '[1.0,2.0)' } `
                -Because 'the range still has to reach the provider - it is what makes Latest mean newest-in-range'
        }
    }

    It 'Latest + prerelease reaches the job with -Prerelease and -Scope intact (gh#25)' {
        # The old job body called `Update-PSResource -Name $m.Name` with
        # neither, so a prerelease-tracking module silently fell back to the
        # stable track in the background but not in the foreground.
        InModuleScope psmm {
            Mock Install-PSMMModule { }
            $entry = Resolve-PSMMEntry -Raw ([pscustomobject]@{
                    Name = 'SomePreMod'; Install = 'Latest'; Mode = 'InstallOnly'; Prerelease = $true
                }) -Source 'x.json' -Writable $true
            $null = Invoke-PSMMPlanAction -Plan (Get-PSMMEntryPlan -Entry $entry)
            Should -Invoke Install-PSMMModule -Times 1 -Exactly -ParameterFilter {
                $Update -eq $true -and $Prerelease -eq $true -and $Scope -eq 'CurrentUser'
            }
        }
    }
}
