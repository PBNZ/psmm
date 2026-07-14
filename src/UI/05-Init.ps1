# 05-Init.ps1 — lazy UI bootstrap: dependency, console, UI state.

# Ensure PwshSpectreConsole (ships the Spectre.Console assembly) is loaded,
# offering to install it on first use. NEVER runs at profile import.
function script:Initialize-PSMMUI {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'First-use install prompt is interactive host output by design (mirrors the original block).')]
    [CmdletBinding()] param()
    if (-not ('Spectre.Console.AnsiConsole' -as [type])) {
        if (Get-Module -ListAvailable -Name PwshSpectreConsole) {
            Import-Module PwshSpectreConsole -ErrorAction Stop -Global
        } else {
            Write-Host 'PwshSpectreConsole is required for the interactive manager.' -ForegroundColor Yellow
            if ((Read-Host 'Install it now from the PowerShell Gallery? (y/N)') -notmatch '^(y|yes)$') { return $false }
            try {
                Install-PSMMModule -Name PwshSpectreConsole
                Import-Module PwshSpectreConsole -ErrorAction Stop -Global
            } catch {
                Write-Warning "Could not install PwshSpectreConsole: $($_.Exception.Message)"
                return $false
            }
        }
    }
    $null = Get-PSMMConsole
    $true
}

# First manager run with no config file anywhere: create the main config,
# seeded with psmm's own UI dependency as a managed entry (2026-07-05
# feedback). Mode InstallOnly keeps profile startup import-free - psmm loads
# Spectre lazily itself. Only the TUI does this, never Invoke-PSMMStartup:
# profile import must not write files.
function script:Initialize-PSMMMainConfig {
    [CmdletBinding()] param()
    $null = Get-PSMMEntry   # (re)build file metadata before inspecting it
    if (@((Get-PSMMFileMeta).Values | Where-Object { $_.Kind -ne 'inline' }).Count) { return }
    $main = Get-PSMMMainConfigPath
    if (Test-Path -LiteralPath $main) { return }
    try {
        $dir = Split-Path -Parent $main
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        ([ordered]@{
            Includes = @()
            Modules  = @([ordered]@{
                Name        = 'PwshSpectreConsole'
                Description = 'TUI engine used by psmm itself'
                Install     = 'IfMissing'
                Mode        = 'InstallOnly'
            })
        } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $main -Encoding utf8
        $script:PSMM_UI.Status = "[green3]created $(ConvertTo-PSMMSafe $main) - psmm's UI dependency is managed there[/]"
    } catch { }   # best-effort: the add flows still offer creation
}

# Fresh UI state for a manager session.
function script:Initialize-PSMMUIState {
    [CmdletBinding()] param()
    $script:PSMM_UI = @{
        Entries       = [System.Collections.Generic.List[object]]::new()
        Cursor        = 0
        Top           = 0
        Sel           = [System.Collections.Generic.HashSet[int]]::new()
        Filter        = ''
        FilterMode    = $false
        View          = @()
        Status        = ''
        Dirty         = $false
        HardQuit      = $false
        GoHome        = $false     # set by the 'g h' chord: unwind to the grid
        Unmanaged     = $null      # results of the background scan (#26)
        ShowUnmanaged = $false     # 'm' toggles unmanaged rows in the grid
        Elevated      = Test-PSMMElevated
        Engine        = Get-PSMMInstallEngine
    }
    Initialize-PSMMMainConfig
    Sync-PSMMUIEntries -FullScan
}

# (Re)build the entry list from config + disk. -FullScan does the one
# expensive Get-Module -ListAvailable sweep (open + explicit reload only).
function script:Sync-PSMMUIEntries {
    [CmdletBinding()] param([switch]$FullScan)
    $active = Get-PSMMEntry
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $active) { $list.Add($e) }
    # unmanaged rows appended when the toggle is on and the scan has results
    if ($script:PSMM_UI.ShowUnmanaged -and $script:PSMM_UI.Unmanaged) {
        $known = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($active.Name), [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($u in $script:PSMM_UI.Unmanaged) {
            if ($known.Contains($u.Name)) { continue }
            $x = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = $u.Name; Description = $u.Description }) -Source '<unmanaged>' -Writable $false
            $x | Add-Member -NotePropertyName FromMain -NotePropertyValue $false -Force
            $x | Add-Member -NotePropertyName FileEnabled -NotePropertyValue $true -Force
            $x | Add-Member -NotePropertyName Unmanaged -NotePropertyValue $true -Force
            $x.Installed = $true
            $x.InstalledVersion = $u.Version
            $x.InstallScope = $u.Scope
            $x.Mode = '-'
            $x.Install = '-'
            $list.Add($x)
        }
    }
    $script:PSMM_UI.Entries = $list
    $all = Get-PSMMAllEntries
    if ($FullScan) { Update-PSMMAvailable -Entries ($all + @($list | Where-Object { $_.PSObject.Properties['Unmanaged'] })) }
    Update-PSMMLoaded -Entries $list
    Update-PSMMLoaded -Entries $all
    $script:PSMM_UI.Sel.Clear()
    $script:PSMM_UI.Dirty = $false
}

# Kick off the background unmanaged-module scan (#26). Results surface as an
# unobtrusive overlay line; 'm' shows them in the grid.
function script:Start-PSMMUnmanagedScan {
    [CmdletBinding()] param()
    $managed = @((Get-PSMMAllEntries).Name | Where-Object { $_ })
    $null = Start-PSMMTask -Label 'scan: unmanaged modules' -Kind 'unmanagedscan' -ArgumentList (, $managed) -ScriptBlock {
        param($managedNames)
        $managedSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$managedNames, [System.StringComparer]::OrdinalIgnoreCase)
        Get-Module -ListAvailable -ErrorAction SilentlyContinue |
            Group-Object Name |
            Where-Object { -not $managedSet.Contains($_.Name) } |
            ForEach-Object {
                $newest = @($_.Group | Sort-Object Version -Descending)[0]
                [pscustomobject]@{
                    Name        = $_.Name
                    Version     = $newest.Version
                    Scope       = if ($newest.ModuleBase.StartsWith($HOME, [System.StringComparison]::OrdinalIgnoreCase)) { 'CurrentUser' } else { 'AllUsers' }
                    Description = $newest.Description
                }
            }
    }
}
