# Startup.ps1 — engine half of the startup loader: the deferred background
# job and startup-job state. The exported entry point is
# src/Public/Invoke-PSMMStartup.ps1.

function Get-PSMMStartupJob      { $script:PSMM_StartupJob }
function Get-PSMMStartupJobTotal { $script:PSMM_JobTotal }

# Start the background job that handles Mode=InstallOnly entries.
# The job re-implements the minimal install logic because module functions
# are not visible inside a ThreadJob's session.
function Start-PSMMDeferredJob {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = '$mods is a scriptblock param supplied via -ArgumentList; $m is its foreach variable. The rule cannot see param bindings.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entries)
    $payload = @($Entries | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Install = $_.Install; Version = $_.Version }
    })
    $script:PSMM_JobTotal = $payload.Count
    $script:PSMM_StartupJob = Start-ThreadJob -Name 'PSMM-Startup' -ScriptBlock {
        param($mods)
        foreach ($m in $mods) {
            # one output line per module so the UI can show progress + summary
            try {
                $have = Get-Module -ListAvailable -Name $m.Name
                $psrg = [bool](Get-Command Install-PSResource -ErrorAction SilentlyContinue)
                $installLatest = {
                    if ($psrg) {
                        if ($m.Version) { Install-PSResource -Name $m.Name -Version $m.Version -Scope CurrentUser -TrustRepository -ErrorAction Stop }
                        else { Install-PSResource -Name $m.Name -Scope CurrentUser -TrustRepository -ErrorAction Stop }
                    } else {
                        Install-Module -Name $m.Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
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
                        elseif ($have -and (Get-Command Update-PSResource -ErrorAction SilentlyContinue)) { Update-PSResource -Name $m.Name -ErrorAction Stop }
                        else { & $installLatest }
                        "updated $($m.Name)"
                    }
                }
            } catch { "FAILED $($m.Name): $($_.Exception.Message)" }
        }
    } -ArgumentList (, $payload)
    $script:PSMM_StartupJob
}
