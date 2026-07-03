# Tasks.ps1 — in-session background task registry (ThreadJob-based).
# Powers the UI's unobtrusive progress overlay (#25), the unmanaged-module
# scan (#26), background Update-Help (#35) and any user-initiated long work.
# No rendering here — the UI asks for summaries and draws them itself.

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
    $job = Start-ThreadJob -Name "psmm-task-$($script:PSMM_TaskSeq)" -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $task = [pscustomobject]@{
        Id        = $script:PSMM_TaskSeq
        Label     = $Label
        Kind      = $Kind
        Data      = $Data
        Job       = $job
        StartedAt = [datetime]::Now
        Output    = @()      # harvested lines (filled by Update-PSMMTask)
        Done      = $false
        Failed    = $false
        Seen      = $false   # UI sets this after showing the completion notice
    }
    $script:PSMM_Tasks.Add($task)
    $task
}

# Harvest state + new output from every task. Cheap; safe to call per poll.
function Update-PSMMTask {
    [CmdletBinding()] param()
    foreach ($t in (Get-PSMMTask)) {
        if ($t.Done) { continue }
        $state = "$($t.Job.State)"
        $t.Output = @(Receive-Job -Job $t.Job -Keep -ErrorAction SilentlyContinue)
        if ($state -notin 'NotStarted', 'Running') {
            $t.Done = $true
            $t.Failed = ($state -ne 'Completed')
        }
    }
}

function Get-PSMMTask {
    [CmdletBinding()] param()
    if ($script:PSMM_Tasks) { @($script:PSMM_Tasks) } else { @() }
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

# A cheap change-fingerprint: the UI's key loop polls this and re-renders
# when it changes (task started/finished/produced output).
function Get-PSMMTaskFingerprint {
    [CmdletBinding()] param()
    $parts = foreach ($t in (Get-PSMMTask)) { "$($t.Id):$($t.Job.State):$($t.Output.Count)" }
    $job = Get-PSMMStartupJob
    if ($job) {
        $c = 0; try { $c = @(Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue).Count } catch { }
        $parts = @($parts) + "startup:$($job.State):$c"
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
        $n = $t.Output.Count
        $bits += if ($n) { "$($t.Label) ($n)" } else { $t.Label }
    }
    foreach ($t in $fresh) {
        $bits += if ($t.Failed) { "$($t.Label) FAILED" } else { "$($t.Label) done" }
    }
    [pscustomobject]@{
        RunningCount = $running.Count
        Text         = ($bits -join ' | ')
    }
}
