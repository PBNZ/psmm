# Startup.ps1 — engine half of the startup loader: the deferred background
# job and startup-job state. The exported entry point is
# src/Public/Invoke-PSMMStartup.ps1.

function Get-PSMMStartupJob      { $script:PSMM_StartupJob }
function Get-PSMMStartupJobTotal { $script:PSMM_JobTotal }

# v2 startup report (design-system-v2 §8): the same design tokens as the TUI,
# rendered with raw 256-colour escapes because Spectre is NOT loaded at
# profile time. Rows: @{ Kind = 'ok'|'skip'|'fail'|'defer'; Name; Ms; Note;
# Count (defer only) }. Returns the finished lines; the caller prints them.
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
    $failed  = @($Rows | Where-Object Kind -EQ 'fail').Count
    $bg = 0
    foreach ($r in @($Rows | Where-Object Kind -EQ 'defer')) { $bg += [Math]::Max(1, [int]$r.Count) }
    $parts = @()
    if ($loaded)  { $parts += "$loaded loaded" }
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

# Start the background job that handles Mode=InstallOnly entries.
# The job re-implements the minimal install logic because module functions
# are not visible inside a ThreadJob's session.
function Start-PSMMDeferredJob {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = '$mods is a scriptblock param supplied via -ArgumentList; $m is its foreach variable. The rule cannot see param bindings.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entries)
    $payload = @($Entries | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Install = $_.Install; Version = $_.Version; Prerelease = [bool]$_.AllowPrerelease }
    })
    $script:PSMM_JobTotal = $payload.Count
    $script:PSMM_StartupJob = Start-ThreadJob -Name 'PSMM-Startup' -ScriptBlock {
        param($mods)
        foreach ($m in $mods) {
            # one output line per module so the UI can show progress + summary
            try {
                $have = Get-Module -ListAvailable -Name $m.Name
                $psrg = [bool](Get-Command Install-PSResource -ErrorAction SilentlyContinue)
                $pre = [bool]$m.Prerelease
                $installLatest = {
                    if ($psrg) {
                        if ($m.Version) { Install-PSResource -Name $m.Name -Version $m.Version -Scope CurrentUser -Prerelease:$pre -TrustRepository -ErrorAction Stop }
                        else { Install-PSResource -Name $m.Name -Scope CurrentUser -Prerelease:$pre -TrustRepository -ErrorAction Stop }
                    } else {
                        Install-Module -Name $m.Name -Scope CurrentUser -Force -AllowClobber -AllowPrerelease:$pre -ErrorAction Stop
                    }
                }
                switch ($m.Install) {
                    'CheckOnly' {
                        if (-not $have) { "FAILED $($m.Name): not installed (check-only)" } else { "ok $($m.Name)" }
                    }
                    'IfMissing' {
                        if (-not $have) { & $installLatest; "installed $($m.Name)" } else { "ok $($m.Name)" }
                    }
                    'Latest' {
                        if ($m.Version) { & $installLatest }
                        # $psrg, not just $have: Install-PSResource does not
                        # exist on a PowerShellGet-only machine, and this is
                        # the one branch that names it directly
                        elseif ($have -and $pre -and $psrg) { Install-PSResource -Name $m.Name -Prerelease -Reinstall -Scope CurrentUser -TrustRepository -ErrorAction Stop }
                        elseif ($have -and $psrg -and (Get-Command Update-PSResource -ErrorAction SilentlyContinue)) { Update-PSResource -Name $m.Name -ErrorAction Stop }
                        else { & $installLatest }
                        "updated $($m.Name)"
                    }
                }
            } catch { "FAILED $($m.Name): $($_.Exception.Message)" }
        }
    } -ArgumentList (, $payload)
    $script:PSMM_StartupJob
}
