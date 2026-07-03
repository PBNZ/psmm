function Get-PSMMConfigPath {
    <#
    .SYNOPSIS
    Shows every location psmm looks for config files, in load order, and
    whether each one currently exists.

    .DESCRIPTION
    psmm reads its declarative JSON config from up to five sources, in this
    order (earlier sources win conflicts only where documented - the MAIN
    config always wins, otherwise first-loaded wins):

      1. inline JSON in $PSMM_InlineJson         (set in $PROFILE; read-only)
      2. main config    ~/.psmm/psmm-config.json (only file whose Includes count)
      3. the main config's Includes              (one level deep, no nesting)
      4. profile-dir    <profile dir>/psmm-config.json
      5. legacy globs   $PSMM_JsonPath (default: psmodules.d/*.json next to $PROFILE)

    .EXAMPLE
    Get-PSMMConfigPath

    Lists each source, its resolved path and whether it exists.

    .LINK
    Invoke-PSMMStartup
    #>
    [CmdletBinding()]
    param()

    $inline = Get-PSMMSetting -Name 'PSMM_InlineJson'
    [pscustomobject]@{
        Source = 'inline ($PSMM_InlineJson)'
        Path   = '<profile inline>'
        Exists = -not [string]::IsNullOrWhiteSpace($inline)
    }
    $main = Get-PSMMMainConfigPath
    [pscustomobject]@{
        Source = 'main config'
        Path   = $main
        Exists = Test-Path -LiteralPath $main -PathType Leaf
    }
    if (Test-Path -LiteralPath $main -PathType Leaf) {
        try {
            $parsed = ConvertFrom-PSMMJson -Json (Get-Content -LiteralPath $main -Raw)
            foreach ($inc in $parsed.Includes) {
                $p = $inc
                try { $p = [System.Environment]::ExpandEnvironmentVariables($inc) } catch { }
                if ($p -match '^~') { $p = Join-Path $HOME ($p -replace '^~[\\/]?', '') }
                [pscustomobject]@{
                    Source = 'include (from main config)'
                    Path   = $p
                    Exists = Test-Path -LiteralPath $p -PathType Leaf
                }
            }
        } catch { Write-Warning "psmm: cannot parse main config: $($_.Exception.Message)" }
    }
    $profileCfg = Get-PSMMProfileConfigPath
    if ($profileCfg) {
        [pscustomobject]@{
            Source = 'profile-dir config'
            Path   = $profileCfg
            Exists = Test-Path -LiteralPath $profileCfg -PathType Leaf
        }
    }
    foreach ($glob in (Get-PSMMLegacyGlobs)) {
        [pscustomobject]@{
            Source = 'legacy glob ($PSMM_JsonPath)'
            Path   = $glob
            Exists = [bool]@(Get-ChildItem -Path $glob -File -ErrorAction SilentlyContinue)
        }
    }
}
