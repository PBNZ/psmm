# Settings.ps1 — user-tunable knobs and config-file locations.
#
# All knobs are plain GLOBAL variables the user may set in $PROFILE *before*
# Import-Module psmm — the same contract the original profile block used:
#
#   $PSMM_InlineJson         inline JSON config (read-only in the UI)
#   $PSMM_JsonPath           extra legacy glob(s) for *.json config files
#   $PSMM_StartupReport      $true (default): print the per-module report
#   $PSMM_BackgroundStartup  $true (default): defer InstallOnly work to a job
#   $PSMM_MainConfigPath     override ~/.psmm/psmm-config.json
#   $PSMM_ProfileConfigPath  override <profile dir>/psmm-config.json

# Read a user knob from global scope, falling back to a default. $null and
# missing are both "not set"; an explicit $false is honoured.
function Get-PSMMSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        $Default
    )
    $v = Get-Variable -Name $Name -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $v) { $v } else { $Default }
}

function Get-PSMMConfigFileName { 'psmm-config.json' }

function Get-PSMMMainConfigPath {
    [CmdletBinding()] param()
    $override = Get-PSMMSetting -Name 'PSMM_MainConfigPath'
    if ($override) { return [string]$override }
    Join-Path (Join-Path $HOME '.psmm') (Get-PSMMConfigFileName)
}

function Get-PSMMProfileConfigPath {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reading $global:PROFILE is the point: config discovery is anchored to the user profile directory.')]
    [CmdletBinding()] param()
    $override = Get-PSMMSetting -Name 'PSMM_ProfileConfigPath'
    if ($override) { return [string]$override }
    # $PROFILE can be absent in hosted/headless runspaces
    $profilePath = $global:PROFILE
    if ([string]::IsNullOrWhiteSpace($profilePath)) { return $null }
    Join-Path (Split-Path -Parent $profilePath) (Get-PSMMConfigFileName)
}

function Get-PSMMLegacyGlobs {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reading $global:PROFILE is the point: the legacy glob default lives next to the user profile.')]
    [CmdletBinding()] param()
    $globs = Get-PSMMSetting -Name 'PSMM_JsonPath'
    if ($null -ne $globs) { return @($globs) }
    $profilePath = $global:PROFILE
    if ([string]::IsNullOrWhiteSpace($profilePath)) { return @() }
    @((Join-Path (Join-Path (Split-Path -Parent $profilePath) 'psmodules.d') '*.json'))
}

# Example config content used by "create config file" and shipped scenarios.
function Get-PSMMExampleConfigJson {
    [CmdletBinding()]
    param([bool]$IsMain)
    $o = [ordered]@{
        Enabled = $true
    }
    if ($IsMain) { $o.Includes = @() }
    $o._legend = [ordered]@{
        Enabled  = 'true/false - false deactivates every module in this file'
        Includes = 'main config only: absolute paths of further config files to load'
        Install  = 'CheckOnly | IfMissing (default) | Latest'
        Mode     = 'Load (default) | InstallOnly | Ignore'
        Version  = 'optional pin: exact "1.2.3" or NuGet range "[1.0,2.0)" - omit for latest'
    }
    $o.Modules = @(
        [ordered]@{
            Name        = 'ImportExcel'
            Description = 'example entry - set Mode to Load/InstallOnly to activate'
            Install     = 'IfMissing'
            Mode        = 'Ignore'
        }
    )
    ([pscustomobject]$o | ConvertTo-Json -Depth 10)
}
