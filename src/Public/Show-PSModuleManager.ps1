function Show-PSModuleManager {
    <#
    .SYNOPSIS
    Opens the interactive psmm terminal UI (alias: psmm).

    .DESCRIPTION
    A live, keyboard-driven manager for every module your psmm config files
    declare - plus the unmanaged ones psmm discovers on your machine:

      - scrollable, filterable module grid (loaded / installed / missing,
        source file, mode, install policy, scope, version, issues)
      - bulk load / unload / install / update, update checking
      - per-module actions: load, unload, install/update, pin, browse
        commands with full help, edit, delete, move to another file
      - duplicate-version cleanup, PowerShell Gallery search, background
        Update-Help, connection status for Connect-* style modules
      - config-file manager (enable/disable files, apply to session,
        create from examples, move, Includes wiring) and conflict views
      - press ? on any screen for context help

    The UI runs in the terminal's alternate screen buffer, so whatever was on
    your screen before launching is exactly there again when you leave (like
    'edit' or 'less'). The heavy rendering dependency (PwshSpectreConsole) is
    only loaded - and offered for install - on first use, never at profile
    import time.

    .EXAMPLE
    psmm

    Opens the manager (alias for Show-PSModuleManager).

    .LINK
    Invoke-PSMMStartup
    #>
    [CmdletBinding()]
    param()

    # Parse the UI implementation on first use only (import stays cheap).
    if (-not $script:PSMMUISourced) {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $script:PSMMRoot 'src/UI') -Filter '*.ps1' | Sort-Object Name) {
            . $f.FullName
        }
        $script:PSMMUISourced = $true
    }

    if (-not (Initialize-PSMMUI)) { return }
    Invoke-PSMMManagerLoop
}
