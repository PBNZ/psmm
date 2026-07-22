# 05-Init.ps1 — lazy UI bootstrap: dependency, console, UI state.

# Ensure PwshSpectreConsole (ships the Spectre.Console assembly) is loaded,
# offering to install it on first use. NEVER runs at profile import.
#
# Imported WITHOUT -Global on purpose (gh#16). This is psmm's own UI engine,
# not something the user asked for, and it has no business appearing in their
# `Get-Module`. A private import is enough for psmm's needs: the Spectre
# assembly loads process-wide so the types resolve either way, and the
# PwshSpectreConsole cmdlets psmm calls (Read-SpectreConfirm /
# Read-SpectreSelection) are visible in psmm's own session state - verified.
# Note the asymmetry with Import-PSMMModuleTimed, which MUST use -Global: the
# user's modules belong in the user's session, psmm's belong in psmm's.
function script:Initialize-PSMMUI {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'First-use install prompt is interactive host output by design (mirrors the original block).')]
    [CmdletBinding()] param()
    $dep = Get-PSMMUIDependencyName
    if (-not ('Spectre.Console.AnsiConsole' -as [type])) {
        if (Get-Module -ListAvailable -Name $dep) {
            Register-PSMMPrivateImport -Module (Import-Module $dep -PassThru -ErrorAction Stop)
        } else {
            Write-Host "$dep is required for the interactive manager." -ForegroundColor Yellow
            if ((Read-Host 'Install it now from the PowerShell Gallery? (y/N)') -notmatch '^(y|yes)$') { return $false }
            try {
                Install-PSMMModule -Name $dep
                Register-PSMMPrivateImport -Module (Import-Module $dep -PassThru -ErrorAction Stop)
            } catch {
                Write-Warning "Could not install ${dep}: $($_.Exception.Message)"
                return $false
            }
        }
    }
    # NB: when the type already resolves nothing is imported and nothing is
    # registered - the copy in play is the user's own (or an earlier psmm run's,
    # already registered), and either way the grid should report it as it finds
    # it.
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
        $script:PSMM_UI.Status = "[$script:PSMM_ColOk]created $(ConvertTo-PSMMSafe $main) - psmm's UI dependency is managed there[/]"
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
        Goto          = $null      # set by the g goto overlay: unwind to the
                                   # manager loop, which routes to the target
        Unmanaged     = $null      # results of the background scan (#26)
        ShowUnmanaged = $false     # 'm' toggles unmanaged rows in the grid
        Elevated      = Test-PSMMElevated
        Engine        = Get-PSMMInstallEngine
        Version       = Get-PSMMVersionString
        # OneDrive-backed primary module location? (cached: grid renders a
        # standing notice, and per-frame path checks would be too slow)
        OneDrivePrimary = [bool](@(Get-PSMMModulePathInfo) | Where-Object { $_.First -and $_.OneDrive })
        # newer psmm on the gallery, per the daily cached background check
        SelfUpdate    = Test-PSMMUpdateAvailable
    }
    $null = Start-PSMMSelfUpdateCheck   # throttled to once a day
    Initialize-PSMMMainConfig
    Sync-PSMMUIEntries -FullScan
    # unknown $PSMM_Theme: glacier took over silently at source time - say so
    # (last, so a first-run "created config" status cannot overwrite it)
    if (Test-PSMMThemeFallback) {
        $script:PSMM_UI.Status = "[$script:PSMM_ColWarn]unknown `$PSMM_Theme '$(ConvertTo-PSMMSafe (Get-PSMMSetting -Name 'PSMM_Theme'))' - using glacier (glacier|ember|moss)[/]"
    }
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
    # @() is mandatory: a single-entry result (fresh install: the one seeded
    # PwshSpectreConsole module) unrolls to a scalar PSObject on return, and
    # scalar + array below throws op_Addition (gh#1)
    $all = @(Get-PSMMAllEntries)
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
    # psmm's own modules are excluded like managed ones: they are infrastructure,
    # not something to adopt into a config (gh#16)
    $managed = @(@((Get-PSMMAllEntries).Name | Where-Object { $_ }) + @(Get-PSMMOwnModuleName))
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
