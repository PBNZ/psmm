# Startup.ps1 — engine half of the startup loader: the deferred background
# job and startup-job state. The exported entry point is
# src/Public/Invoke-PSMMStartup.ps1.

function Get-PSMMStartupJob      { $script:PSMM_StartupJob }
function Get-PSMMStartupJobTotal { $script:PSMM_JobTotal }

# v2 startup report (design-system-v2 §8): the same design tokens as the TUI,
# rendered with raw 256-colour escapes because Spectre is NOT loaded at
# profile time. Rows: @{ Kind = 'ok'|'warn'|'skip'|'fail'|'defer'; Name; Ms;
# Note; Count (defer only) }. 'warn' is "you asked for this module and it is
# not in your session" - not an error, but not a silent skip either.
# Returns the finished lines; the caller prints them.
function Get-PSMMStartupReportLines {
    [CmdletBinding()]
    param(
        [array]$Rows = @(),
        [int]$TotalMs = 0
    )
    $reset = Get-PSMMAnsiReset
    $c = @{}
    foreach ($t in 'key', 'ok', 'warn', 'err', 'info', 'mute', 'dim') { $c[$t] = Get-PSMMAnsi -Token $t }
    $mid = [char]0x00B7
    $lines = [System.Collections.Generic.List[string]]::new()

    $loaded  = @($Rows | Where-Object Kind -EQ 'ok').Count
    $skipped = @($Rows | Where-Object Kind -EQ 'skip').Count
    $missing = @($Rows | Where-Object Kind -EQ 'warn').Count
    $failed  = @($Rows | Where-Object Kind -EQ 'fail').Count
    $bg = 0
    foreach ($r in @($Rows | Where-Object Kind -EQ 'defer')) { $bg += [Math]::Max(1, [int]$r.Count) }
    $parts = @()
    if ($loaded)  { $parts += "$loaded loaded" }
    if ($missing) { $parts += "$missing missing" }
    if ($skipped) { $parts += "$skipped skipped" }
    if ($failed)  { $parts += "$failed failed" }
    if ($bg)      { $parts += "$bg in background" }
    $parts += "$TotalMs ms"
    $brand = "$(Get-PSMMAnsi -Token 'brandfg')$(Get-PSMMAnsi -Token 'brandbg' -Background) psmm $reset"
    $lines.Add("$brand $($c.mute)$($parts -join " $mid ")$reset")

    if (-not $Rows.Count) { return $lines }
    $nameW = 4
    foreach ($r in $Rows) { $l = [Math]::Min(34, "$($r.Name)".Length); if ($l -gt $nameW) { $nameW = $l } }
    $maxMs = 1
    foreach ($r in $Rows) { if ([int]$r.Ms -gt $maxMs) { $maxMs = [int]$r.Ms } }
    $okRows = @($Rows | Where-Object { $_.Kind -eq 'ok' -and [int]$_.Ms -gt 0 })
    $slowest = if ($okRows.Count -gt 1) { ($okRows | Sort-Object { [int]$_.Ms } -Descending)[0] } else { $null }
    $anyFail = $false

    foreach ($r in $Rows) {
        $nameTxt = "$($r.Name)"
        if ($nameTxt.Length -gt 34) { $nameTxt = $nameTxt.Substring(0, 33) + [char]0x2026 }
        $name = $nameTxt.PadRight($nameW)
        switch ($r.Kind) {
            'ok' {
                $ms = ("{0} ms" -f [int]$r.Ms).PadLeft(8)
                # proportional bar in eighth-blocks, 10 cells max
                $units = [double]$r.Ms / $maxMs * 10
                $full = [Math]::Floor($units)
                $frac = [Math]::Round(($units - $full) * 8)
                $bar = ([string][char]0x2588) * $full
                if ($frac -gt 0) { $bar += [char][int](0x2590 - $frac) }
                if (-not $bar) { $bar = [char]0x258F }
                if ($slowest -and $r -eq $slowest) {
                    $note = "$($c.dim)slowest $([char]0x2014) InstallOnly would free your prompt$reset"
                    $lines.Add("$($c.ok)$([char]0x25CF)$reset $name $($c.mute)$ms$reset  $($c.warn)$bar$reset  $note")
                } else {
                    $extra = if ($r.Note) { "  $($c.dim)$($r.Note)$reset" } else { '' }
                    $lines.Add("$($c.ok)$([char]0x25CF)$reset $name $($c.mute)$ms$reset  $($c.dim)$bar$reset$extra")
                }
            }
            'skip' {
                $ms = "$([char]0x2014)".PadLeft(8)
                $lines.Add("$($c.dim)$([char]0x25CB)$reset $($c.dim)$name$reset $($c.dim)$ms$reset   $($c.dim)$($r.Note)$reset")
            }
            'warn' {
                $ms = "$([char]0x2014)".PadLeft(8)
                $lines.Add("$($c.warn)$([char]0x25CB)$reset $name $($c.dim)$ms$reset   $($c.warn)$($r.Note)$reset")
            }
            'fail' {
                $anyFail = $true
                $ms = "$([char]0x2014)".PadLeft(8)
                $lines.Add("$($c.err)$([char]0x2715)$reset $name $($c.dim)$ms$reset   $($c.err)$($r.Note)$reset")
            }
            'defer' {
                $ms = 'bg'.PadLeft(8)
                $lines.Add("$($c.info)$([char]0x22EF)$reset $($c.mute)$name$reset $($c.dim)$ms$reset   $($c.dim)$($r.Note)$reset")
            }
        }
    }
    if ($anyFail) {
        $lines.Add("  $($c.dim)$([char]0x2192) psmm, then $reset$($c.key)i$reset$($c.dim) on the row retries$reset")
    }
    $lines
}

# Start the background job that does every entry's disk/gallery work.
#
# The job EXECUTES plans; it does not decide anything. It used to re-implement
# the Mode x Install matrix by hand — because module functions are invisible
# inside a ThreadJob — and that copy had drifted from the actuator: no
# -Prerelease, no -Scope, no installed-prerelease track (gh#25). The fix is to
# ship the real functions in as source text and dot-source them, so there is
# exactly one implementation of everything (gh#29).
function Start-PSMMDeferredJob {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = '$payload is a scriptblock param supplied via -ArgumentList; $p is its foreach variable. The rule cannot see param bindings.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plans)
    $list = @($Plans)
    $script:PSMM_JobTotal = $list.Count
    # one object, so -ArgumentList cannot unroll the plan array (gh#1)
    $payload = [pscustomobject]@{ Plans = $list; Prelude = (Get-PSMMJobPrelude) }
    $script:PSMM_StartupJob = Start-ThreadJob -Name 'PSMM-Startup' -ScriptBlock {
        param($payload)
        . ([scriptblock]::Create($payload.Prelude))
        foreach ($p in $payload.Plans) {
            # one output line per module so the UI can show progress + summary
            try { Invoke-PSMMPlanAction -Plan $p }
            catch { "FAILED $($p.Name): $($_.Exception.Message)" }
        }
    } -ArgumentList (, $payload)
    Register-PSMMJobDisposal
    $script:PSMM_StartupJob
}

# Incrementally harvested output of the startup job (gh#24). Receive-Job -Keep
# never drains the buffer, so the old code re-materialised the ENTIRE output
# on every 500 ms poll — in three separate places — purely to count lines.
# Harvest once, keep the lines and the count here.
function Update-PSMMStartupJobOutput {
    [CmdletBinding()] param()
    $job = $script:PSMM_StartupJob
    if (-not $job) { return }
    if (-not $script:PSMM_StartupOutput) { $script:PSMM_StartupOutput = [System.Collections.Generic.List[string]]::new() }
    try {
        foreach ($line in @(Receive-Job -Job $job -ErrorAction SilentlyContinue)) {
            $script:PSMM_StartupOutput.Add("$line")
        }
    } catch { }
}

function Get-PSMMStartupJobOutput {
    [CmdletBinding()] param()
    Update-PSMMStartupJobOutput
    if ($script:PSMM_StartupOutput) { @($script:PSMM_StartupOutput) } else { @() }
}
