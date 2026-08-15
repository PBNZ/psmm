# Tasks.ps1 — in-session background task registry (ThreadJob-based).
# Powers the UI's unobtrusive progress overlay (#25), the unmanaged-module
# scan (#26), background Update-Help (#35) and any user-initiated long work.
# No rendering here — the UI asks for summaries and draws them itself.
#
# Output is BOUNDED (gh#24). It used to be captured with `Receive-Job -Keep`,
# which never drains the job's buffer: every 500 ms poll re-materialised the
# entire output and replaced the stored array, so a chatty job grew both the
# job buffer and psmm's copy without limit. Now each poll harvests only what
# is new, into a ring buffer with a stated cap, and keeps a running count so
# nothing has to re-read a buffer just to measure it.

# Ring-buffer caps. Deliberately generous — they exist to bound a runaway job,
# not to truncate ordinary output — and both are reported when they bite.
$script:PSMM_TaskLineCap = 1000    # lines kept per task
$script:PSMM_TaskCharCap = 2000    # characters kept per line

function Start-PSMMTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [string]$Kind = 'generic',   # lets the UI react to completion (install/updatecheck/scan/...)
        $Data                        # optional payload for the completion handler
    )
    if (-not $script:PSMM_Tasks) { $script:PSMM_Tasks = [System.Collections.Generic.List[object]]::new() }
    $script:PSMM_TaskSeq = [int]$script:PSMM_TaskSeq + 1
    # the name is load-bearing: the session-exit handler finds psmm's jobs by
    # matching it, because it cannot reach module state (see Clear-PSMMJob)
    $job = Start-ThreadJob -Name "psmm-task-$($script:PSMM_TaskSeq)" -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $task = [pscustomobject]@{
        Id        = $script:PSMM_TaskSeq
        Label     = $Label
        Kind      = $Kind
        Data      = $Data
        Job       = $job
        StartedAt = [datetime]::Now
        # ring buffer, capped. [object], not [string]: the scan and
        # update-check tasks emit rich objects that Receive-PSMMUITask reads
        # by property - stringifying them here would silently break both.
        Output    = [System.Collections.Generic.List[object]]::new()
        LineCount = 0        # total lines ever produced (Output may hold fewer)
        Dropped   = 0        # lines evicted by the cap
        Done      = $false
        Failed    = $false
        Cancelled = $false
        SawFailure = $false  # a 'FAILED ...' line was harvested at some point
        Seen      = $false   # UI sets this after showing the completion notice
    }
    $script:PSMM_Tasks.Add($task)
    Register-PSMMJobDisposal
    $task
}

# Append harvested lines to one task's ring buffer, capping line length and
# total lines. The FAILED flag is latched HERE rather than derived from the
# buffer later, because the line that set it may since have been evicted.
function Add-PSMMTaskOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Task,
        [AllowNull()][AllowEmptyCollection()][object[]]$Lines
    )
    foreach ($l in @($Lines)) {
        # only STRINGS are length-capped; an emitted object is stored whole,
        # because the completion handlers read it by property
        $item = $l
        if ($l -is [string] -and $l.Length -gt $script:PSMM_TaskCharCap) {
            $item = $l.Substring(0, $script:PSMM_TaskCharCap) + " $([char]0x2026)[line truncated]"
        }
        if ("$l" -like 'FAILED*') { $Task.SawFailure = $true }
        $Task.LineCount++
        $Task.Output.Add($item)
    }
    if ($Task.Output.Count -gt $script:PSMM_TaskLineCap) {
        $drop = $Task.Output.Count - $script:PSMM_TaskLineCap
        $Task.Output.RemoveRange(0, $drop)
        $Task.Dropped += $drop
    }
}

# Harvest state + new output from every task. Cheap; safe to call per poll.
function Update-PSMMTask {
    [CmdletBinding()] param()
    foreach ($t in (Get-PSMMTask)) {
        if ($t.Done) { continue }
        $state = "$($t.Job.State)"
        Add-PSMMTaskOutput -Task $t -Lines @(Receive-Job -Job $t.Job -ErrorAction SilentlyContinue)
        if ($state -notin 'NotStarted', 'Running') {
            # final drain: anything the job emitted between reading its state
            # and the harvest above would otherwise be lost for good, now that
            # the buffer is actually being consumed
            Add-PSMMTaskOutput -Task $t -Lines @(Receive-Job -Job $t.Job -ErrorAction SilentlyContinue)
            $t.Done = $true
            # a job can reach Completed and still have failed at what it was
            # asked to do - Update-Help is the case that proved it (gh#26)
            $t.Failed = (-not $t.Cancelled) -and (($state -ne 'Completed') -or $t.SawFailure)
        }
    }
}

function Get-PSMMTask {
    [CmdletBinding()] param()
    if ($script:PSMM_Tasks) { @($script:PSMM_Tasks) } else { @() }
}

# Cancel one running task (gh#24 - there was no way to stop anything).
# Returns $true when it actually stopped something.
function Stop-PSMMTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Task)
    if ($Task.Done) { return $false }
    $Task.Cancelled = $true      # set BEFORE stopping: Update-PSMMTask reads it
    try { Stop-Job -Job $Task.Job -ErrorAction Stop } catch { $Task.Cancelled = $false; return $false }
    Update-PSMMTask
    $true
}

# Remove finished tasks from the registry (and their jobs).
function Clear-PSMMTask {
    [CmdletBinding()] param()
    if (-not $script:PSMM_Tasks) { return }
    foreach ($t in @($script:PSMM_Tasks | Where-Object Done)) {
        Remove-Job -Job $t.Job -Force -ErrorAction SilentlyContinue
        $null = $script:PSMM_Tasks.Remove($t)
    }
}

# Stop and remove every job psmm started, wherever it started it. The single
# implementation behind session exit, module removal and the tests.
#
# Jobs are found by NAME through the session job repository rather than from
# $script:PSMM_Tasks, because the startup job (Start-PSMMDeferredJob) was never
# in the task registry - and because this has to work when called from an
# engine-event handler, which cannot see module state at all.
function Clear-PSMMJob {
    [CmdletBinding()] param()
    $n = 0
    foreach ($j in @(Get-Job -ErrorAction SilentlyContinue)) {
        if ("$($j.Name)" -notmatch '^(PSMM-Startup|psmm-task-\d+)$') { continue }
        try { if ("$($j.State)" -in 'NotStarted', 'Running') { Stop-Job -Job $j -ErrorAction SilentlyContinue } } catch { }
        try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch { }
        $n++
    }
    if ($script:PSMM_Tasks) { $script:PSMM_Tasks.Clear() }
    $script:PSMM_StartupJob = $null
    $n
}

# Classify what Update-Help complained about, and turn it into task output
# lines (gh#26).
#
# Update-Help emits NON-terminating errors, so the job always reaches
# 'Completed' and job state alone can never say whether it worked. Classify by
# FullyQualifiedErrorId, never by message text: the ids are stable, the
# messages are localised. Lines beginning 'FAILED' are what Update-PSMMTask
# latches into the task's Failed flag.
#
# The four ids below were captured from live Update-Help runs, not recalled:
#   HelpInfoUriNotFound   - the module ships no updatable help (the common case)
#   ModuleNotFound        - the name matched nothing
#   UpdatableHelpSystemRequiresElevation - AllUsers scope without elevation
#   HelpCultureNotSupported - no help published for this UI culture
# Anything else - network, proxy, a corrupt HelpInfo.xml - falls to the
# default branch and is reported WITH its id, so an unclassified failure is
# still visible and still fails the task rather than being swallowed.
#
# Lives here, as a real function, so the tests exercise THIS code. It is
# shipped into the job by Get-PSMMJobPrelude like every other actuator.
function Get-PSMMUpdateHelpReport {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $ErrorRecords)
    $benign = 0
    foreach ($e in @($ErrorRecords)) {
        if (-not $e) { continue }
        $id = ("$($e.FullyQualifiedErrorId)" -split ',')[0]
        $msg = "$($e.Exception.Message)" -replace '\s+', ' '
        switch ($id) {
            'HelpInfoUriNotFound' { $benign++ }
            'ModuleNotFound'      { $benign++ }
            'UpdatableHelpSystemRequiresElevation' { "FAILED elevation required: $msg" }
            'HelpCultureNotSupported'              { "FAILED UI culture not supported: $msg" }
            default                                { "FAILED [$id]: $msg" }
        }
    }
    if ($benign) { "note: $benign module(s) ship no updatable help - nothing to download for them" }
    'help update finished'
}

# Dispose psmm's background jobs when the session ends (gh#28).
#
# Registered LAZILY - from Start-PSMMTask and Start-PSMMDeferredJob, never at
# import - so a zero-config startup pays nothing for machinery it never uses.
#
# The handler reaches module scope through `& (Get-Module psmm) { ... }`, which
# is verified to work from inside an exit handler. It cannot simply read
# $script: variables: a Register-EngineEvent -Action scriptblock does NOT see
# the defining module's script scope (they read as $null, and -MessageData did
# not survive either), so anything written that way would have silently
# disposed nothing while looking correct.
#
# PowerShell.Exiting does NOT fire on window close, on Stop-Process -Force, or
# on a crash. It can never be the only layer - which is why psmm also disposes
# on module removal (OnRemove in psmm.psm1), and why Start-ThreadJob stays the
# transport: those jobs are in-process and die with pwsh regardless.
function Register-PSMMJobDisposal {
    [CmdletBinding()] param()
    if ($script:PSMM_JobDisposalRegistered) { return }
    $script:PSMM_JobDisposalRegistered = $true
    try {
        $null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
            $m = Get-Module -Name psmm -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m) { $null = & $m { Clear-PSMMJob } }
        }
    } catch {
        $script:PSMM_JobDisposalRegistered = $false
    }
}

# A cheap change-fingerprint: the UI's key loop polls this and re-renders
# when it changes (task started/finished/produced output). LineCount, never
# Output.Count - the ring buffer stops growing at the cap, and a job that is
# still talking must still count as "changed" (gh#24).
function Get-PSMMTaskFingerprint {
    [CmdletBinding()] param()
    $parts = foreach ($t in (Get-PSMMTask)) { "$($t.Id):$($t.Job.State):$($t.LineCount)" }
    $job = Get-PSMMStartupJob
    if ($job) {
        $parts = @($parts) + "startup:$($job.State):$(Get-PSMMStartupJobLineCount)"
    }
    $parts -join '|'
}

# One-line summary for the grid's side overlay; $null when nothing to show.
function Get-PSMMTaskSummary {
    [CmdletBinding()] param()
    Update-PSMMTask
    $running = @(Get-PSMMTask | Where-Object { -not $_.Done })
    $fresh   = @(Get-PSMMTask | Where-Object { $_.Done -and -not $_.Seen })
    if (-not $running.Count -and -not $fresh.Count) { return $null }
    $bits = @()
    foreach ($t in $running) {
        $n = $t.LineCount
        $bits += if ($n) { "$($t.Label) ($n)" } else { $t.Label }
    }
    foreach ($t in $fresh) {
        $bits += if ($t.Cancelled) { "$($t.Label) cancelled" }
                 elseif ($t.Failed) { "$($t.Label) FAILED" }
                 else { "$($t.Label) done" }
    }
    [pscustomobject]@{
        RunningCount = $running.Count
        Text         = ($bits -join ' | ')
    }
}
