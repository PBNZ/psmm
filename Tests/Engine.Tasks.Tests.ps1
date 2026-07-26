# Background-task lifecycle: bounded output, cancellation, and disposal at
# session end (gh#24, gh#28).
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

Describe 'Task output is bounded (gh#24)' -Tag Engine {

    AfterEach { InModuleScope psmm { Clear-PSMMTask } }

    It 'harvests incrementally instead of re-reading the whole buffer' {
        # Receive-Job -Keep never drained the job, so every 500 ms poll
        # re-materialised everything. Two polls must not double the output.
        $r = InModuleScope psmm {
            $t = Start-PSMMTask -Label 'harvest' -ScriptBlock { 'a'; 'b'; 'c' }
            $null = $t.Job | Wait-Job
            Update-PSMMTask
            $first = $t.Output.Count
            Update-PSMMTask          # second poll: nothing new to find
            [pscustomobject]@{ First = $first; Second = $t.Output.Count; Count = $t.LineCount }
        }
        $r.First  | Should -Be 3
        $r.Second | Should -Be 3
        $r.Count  | Should -Be 3
    }

    It 'caps the buffer at the stated line cap and reports what it dropped' {
        $r = InModuleScope psmm {
            $cap = $script:PSMM_TaskLineCap
            $t = Start-PSMMTask -Label 'chatty' -ArgumentList (, ($cap + 250)) -ScriptBlock {
                param($n)
                1..$n | ForEach-Object { "line $_" }
            }
            $null = $t.Job | Wait-Job
            Update-PSMMTask
            [pscustomobject]@{
                Cap = $cap; Held = $t.Output.Count; Total = $t.LineCount; Dropped = $t.Dropped
                Newest = "$($t.Output[$t.Output.Count - 1])"
            }
        }
        $r.Held    | Should -Be $r.Cap
        $r.Total   | Should -Be ($r.Cap + 250)     # the count is never capped
        $r.Dropped | Should -Be 250
        $r.Newest  | Should -Be "line $($r.Cap + 250)"   # a ring buffer keeps the NEWEST
    }

    It 'caps a single very long line' {
        $r = InModuleScope psmm {
            $t = Start-PSMMTask -Label 'longline' -ArgumentList (, ($script:PSMM_TaskCharCap * 3)) -ScriptBlock {
                param($n) ('x' * $n)
            }
            $null = $t.Job | Wait-Job
            Update-PSMMTask
            [pscustomobject]@{ Cap = $script:PSMM_TaskCharCap; Len = "$($t.Output[0])".Length }
        }
        $r.Len | Should -BeLessThan ($r.Cap * 3)
        $r.Len | Should -BeGreaterThan $r.Cap
    }

    It 'keeps emitted OBJECTS whole - the scan and update-check read them by property' {
        $r = InModuleScope psmm {
            $t = Start-PSMMTask -Label 'objects' -ScriptBlock {
                [pscustomobject]@{ Name = 'AlphaMod'; Latest = '9.9.9' }
            }
            $null = $t.Job | Wait-Job
            Update-PSMMTask
            $t.Output[0]
        }
        $r.Name   | Should -Be 'AlphaMod'
        $r.Latest | Should -Be '9.9.9'
    }

    It 'the fingerprint tracks the running count, not the capped buffer' {
        $fp = InModuleScope psmm {
            $t = Start-PSMMTask -Label 'fp' -ScriptBlock { 'one'; 'two' }
            $null = $t.Job | Wait-Job
            Update-PSMMTask
            Get-PSMMTaskFingerprint
        }
        $fp | Should -Match '^\d+:Completed:2$'
    }

    It 'a job that reaches Completed but reported FAILED counts as failed (gh#26)' {
        $r = InModuleScope psmm {
            $t = Start-PSMMTask -Label 'soft-fail' -ScriptBlock { 'ok A'; 'FAILED B: nope' }
            $null = $t.Job | Wait-Job
            Update-PSMMTask
            [pscustomobject]@{ State = "$($t.Job.State)"; Failed = $t.Failed; Done = $t.Done }
        }
        $r.State  | Should -Be 'Completed'
        $r.Done   | Should -BeTrue
        $r.Failed | Should -BeTrue -Because 'Update-Help could fail for every module and still report done'
    }
}

Describe 'Tasks can be cancelled (gh#24)' -Tag Engine {

    AfterEach { InModuleScope psmm { Clear-PSMMTask } }

    It 'stops a running task and marks it cancelled rather than failed' {
        $r = InModuleScope psmm {
            $t = Start-PSMMTask -Label 'long' -ScriptBlock { while ($true) { Start-Sleep -Milliseconds 50 } }
            $stopped = Stop-PSMMTask -Task $t
            [pscustomobject]@{
                Stopped = $stopped; Done = $t.Done; Cancelled = $t.Cancelled; Failed = $t.Failed
            }
        }
        $r.Stopped   | Should -BeTrue
        $r.Done      | Should -BeTrue
        $r.Cancelled | Should -BeTrue
        $r.Failed    | Should -BeFalse -Because 'you asked for it - that is not a failure'
    }

    It 'declines to cancel a task that has already finished' {
        $r = InModuleScope psmm {
            $t = Start-PSMMTask -Label 'quick' -ScriptBlock { 'done' }
            $null = $t.Job | Wait-Job
            Update-PSMMTask
            Stop-PSMMTask -Task $t
        }
        $r | Should -BeFalse
    }

    It 'a cancelled task says so in the grid summary' {
        $text = InModuleScope psmm {
            $t = Start-PSMMTask -Label 'cancelme' -ScriptBlock { while ($true) { Start-Sleep -Milliseconds 50 } }
            $null = Stop-PSMMTask -Task $t
            (Get-PSMMTaskSummary).Text
        }
        $text | Should -Match 'cancelme cancelled'
    }
}

Describe 'Background jobs are disposed at session end (gh#28)' -Tag Engine {

    It 'registers exactly one PowerShell.Exiting subscriber, lazily and once' {
        $r = InModuleScope psmm {
            $before = @(Get-EventSubscriber -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue).Count
            $t1 = Start-PSMMTask -Label 'r1' -ScriptBlock { 'x' }
            $t2 = Start-PSMMTask -Label 'r2' -ScriptBlock { 'x' }
            $null = $t1.Job, $t2.Job | Wait-Job
            $after = @(Get-EventSubscriber -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue).Count
            Clear-PSMMTask
            [pscustomobject]@{ Before = $before; After = $after }
        }
        $r.After | Should -BeGreaterThan 0 -Because 'starting a task must arm the disposal handler'
        $r.After | Should -BeLessOrEqual ($r.Before + 1) -Because 'registration is idempotent'
    }

    It 'Clear-PSMMJob stops psmm jobs and leaves everything else alone' {
        $r = InModuleScope psmm {
            $mine = Start-PSMMTask -Label 'mine' -ScriptBlock { while ($true) { Start-Sleep -Milliseconds 50 } }
            $theirs = Start-ThreadJob -Name 'not-a-psmm-job' -ScriptBlock { Start-Sleep -Seconds 30 }
            $null = Clear-PSMMJob
            $out = [pscustomobject]@{
                MineGone    = -not (Get-Job -Id $mine.Job.Id -ErrorAction SilentlyContinue)
                TheirsAlive = [bool](Get-Job -Id $theirs.Id -ErrorAction SilentlyContinue)
                Registry    = @(Get-PSMMTask).Count
            }
            Stop-Job -Job $theirs -ErrorAction SilentlyContinue
            Remove-Job -Job $theirs -Force -ErrorAction SilentlyContinue
            $out
        }
        $r.MineGone    | Should -BeTrue
        $r.TheirsAlive | Should -BeTrue -Because 'psmm disposes ITS jobs, not the session'
        $r.Registry    | Should -Be 0
    }

    It 'both layers dispose end to end: PowerShell.Exiting and module removal' {
        # In a child pwsh, because the second layer removes the module. The
        # engine event is raised directly - New-Event runs the registered
        # action, which is the same path a real session exit takes.
        $script = @'
param([string]$Repo)
Import-Module (Join-Path $Repo 'psmm.psd1') -Force
& (Get-Module psmm) { $null = Start-PSMMTask -Label 'p1' -ScriptBlock { while ($true) { Start-Sleep -Milliseconds 100 } } }
"armed=$([bool](Get-EventSubscriber -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue))"
$null = New-Event -SourceIdentifier PowerShell.Exiting
Start-Sleep -Milliseconds 800
"afterExiting=$(@(Get-Job | Where-Object Name -like 'psmm-task-*').Count)"
& (Get-Module psmm) { $null = Start-PSMMTask -Label 'p2' -ScriptBlock { while ($true) { Start-Sleep -Milliseconds 100 } } }
"beforeRemove=$(@(Get-Job | Where-Object Name -like 'psmm-task-*').Count)"
Remove-Module psmm
"afterRemove=$(@(Get-Job | Where-Object Name -like 'psmm-task-*').Count)"
'@
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "psmm-disposal-$([guid]::NewGuid().ToString('N')).ps1"
        Set-Content -LiteralPath $path -Value $script -Encoding utf8
        try {
            $out = @(& (Get-Process -Id $PID).Path -NoProfile -File $path -Repo $script:RepoRoot) -join "`n"
        } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
        $out | Should -Match 'armed=True'
        $out | Should -Match 'afterExiting=0'
        $out | Should -Match 'beforeRemove=1'
        $out | Should -Match 'afterRemove=0'
    }
}

Describe 'Update-Help failure classification (gh#26)' -Tag Engine {

    # These exercise the PRODUCTION classifier, Get-PSMMUpdateHelpReport. An
    # earlier version of this file re-implemented the switch inside its own job
    # scriptblock, which tested a copy and would have sat green through any
    # regression in the real one.
    #
    # The four ids were captured from live Update-Help runs on a real machine,
    # not recalled:
    #   Update-Help -Module NonExistent      -> ModuleNotFound
    #   Update-Help -Module PwshSpectreConsole -> HelpInfoUriNotFound
    #   Update-Help -UICulture zz-ZZ         -> HelpCultureNotSupported
    #   Update-Help -Scope AllUsers (unelev) -> UpdatableHelpSystemRequiresElevation

    BeforeAll {
        function New-HelpError([string]$Id, [string]$Message = 'boom') {
            [System.Management.Automation.ErrorRecord]::new(
                [Exception]::new($Message),
                "$Id,Microsoft.PowerShell.Commands.UpdateHelpCommand",
                [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
        }
    }

    It 'reports no errors at all as a plain finish' {
        $out = InModuleScope psmm { (Get-PSMMUpdateHelpReport -ErrorRecords @()) -join "`n" }
        $out | Should -Be 'help update finished'
        $out | Should -Not -Match 'FAILED'
    }

    It 'treats "ships no updatable help" and "no such module" as benign notes' {
        $out = InModuleScope psmm -Parameters @{ recs = @((New-HelpError 'HelpInfoUriNotFound'), (New-HelpError 'ModuleNotFound')) } {
            (Get-PSMMUpdateHelpReport -ErrorRecords $recs) -join "`n"
        }
        $out | Should -Match 'note: 2 module\(s\) ship no updatable help'
        $out | Should -Not -Match 'FAILED'
    }

    It 'classifies elevation and UI-culture failures by name, and fails on them' {
        $out = InModuleScope psmm -Parameters @{ recs = @(
                (New-HelpError 'UpdatableHelpSystemRequiresElevation' 'Access is denied.')
                (New-HelpError 'HelpCultureNotSupported' 'The specified culture is not supported: zz-ZZ.')
            ) } { (Get-PSMMUpdateHelpReport -ErrorRecords $recs) -join "`n" }
        $out | Should -Match 'FAILED elevation required: Access is denied\.'
        $out | Should -Match 'FAILED UI culture not supported:.*zz-ZZ'
    }

    It 'reports an UNKNOWN id with the id attached, rather than swallowing it' {
        # the network/proxy class lands here - it has no dedicated branch, but
        # it must still be visible and must still fail the task
        $out = InModuleScope psmm -Parameters @{ recs = @((New-HelpError 'UnableToConnectToHelpUri' 'The remote name could not be resolved.')) } {
            (Get-PSMMUpdateHelpReport -ErrorRecords $recs) -join "`n"
        }
        $out | Should -Match 'FAILED \[UnableToConnectToHelpUri\]'
        $out | Should -Match 'remote name could not be resolved'
    }

    It 'flattens multi-line messages so one failure stays one line' {
        $out = InModuleScope psmm -Parameters @{ recs = @((New-HelpError 'HelpCultureNotSupported' "line one`nline two")) } {
            (Get-PSMMUpdateHelpReport -ErrorRecords $recs) -join "`n"
        }
        @($out -split "`n" | Where-Object { $_ -like 'FAILED*' }).Count | Should -Be 1
    }

    It 'a classified failure makes the TASK fail, though the job completed fine' {
        $out = InModuleScope psmm {
            $prelude = Get-PSMMJobPrelude -FunctionName @('Get-PSMMUpdateHelpReport')
            $t = Start-PSMMTask -Label 'uh-endtoend' -Kind 'updatehelp' -ArgumentList (, $prelude) -ScriptBlock {
                param($defs)
                . ([scriptblock]::Create($defs))
                Get-PSMMUpdateHelpReport -ErrorRecords @(
                    [System.Management.Automation.ErrorRecord]::new(
                        [Exception]::new('Access is denied.'),
                        'UpdatableHelpSystemRequiresElevation,Microsoft.PowerShell.Commands.UpdateHelpCommand',
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null))
            }
            $null = $t.Job | Wait-Job
            Update-PSMMTask
            $r = [pscustomobject]@{ State = "$($t.Job.State)"; Failed = $t.Failed; Text = ($t.Output -join "`n") }
            Clear-PSMMTask
            $r
        }
        $out.State  | Should -Be 'Completed' -Because 'Update-Help errors are non-terminating - that is the whole trap'
        $out.Failed | Should -BeTrue
        $out.Text   | Should -Match 'FAILED elevation required'
    }

    It 'a benign-only run does NOT fail the task' {
        $out = InModuleScope psmm {
            $prelude = Get-PSMMJobPrelude -FunctionName @('Get-PSMMUpdateHelpReport')
            $t = Start-PSMMTask -Label 'uh-benign' -Kind 'updatehelp' -ArgumentList (, $prelude) -ScriptBlock {
                param($defs)
                . ([scriptblock]::Create($defs))
                Get-PSMMUpdateHelpReport -ErrorRecords @(
                    [System.Management.Automation.ErrorRecord]::new(
                        [Exception]::new('does not support updatable help'),
                        'HelpInfoUriNotFound,Microsoft.PowerShell.Commands.UpdateHelpCommand',
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $null))
            }
            $null = $t.Job | Wait-Job
            Update-PSMMTask
            $r = [pscustomobject]@{ Failed = $t.Failed; Text = ($t.Output -join "`n") }
            Clear-PSMMTask
            $r
        }
        $out.Failed | Should -BeFalse
        $out.Text   | Should -Match 'ship no updatable help'
    }
}
