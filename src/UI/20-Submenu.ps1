# 20-Submenu.ps1 — per-module actions: details, load/unload/install, version
# pinning, duplicate cleanup, auth status/disconnect (#32), add-unmanaged
# (#27), edit/delete/move, command browsing.

# Build the details panel for one entry. $Auth may be $null (not yet queried).
function script:Build-PSMMModuleMenuView {
    param(
        [Parameter(Mandatory)] $Entry,
        $Auth,
        [string]$StatusMarkup
    )
    $isUnmanaged = [bool]$Entry.PSObject.Properties['Unmanaged']
    $issues = if ($Entry.Issues.Count) { ConvertTo-PSMMSafe ($Entry.Issues -join '; ') } else { 'none' }
    $srcLabel = if ($isUnmanaged) { 'not in any config file (unmanaged)' }
                else { "$(ConvertTo-PSMMSafe $Entry.Source)  ($(if ($Entry.Writable) { 'writable' } else { 'read-only' }))" }
    $installedTxt = if ($Entry.Installed) {
        $vers = @($Entry.InstalledVersions)
        $extra = if ($vers.Count -gt 1) { " [orange1]($($vers.Count) versions on disk - K cleans up)[/]" } else { '' }
        $upd = if ($Entry.UpdateAvailable) { " [orange1](update -> v$($Entry.LatestVersion))[/]" } else { '' }
        "yes  v$($Entry.InstalledVersion)  [grey66]$($Entry.InstallScope)[/]$upd$extra"
    } else { 'no' }
    $pinTxt = if ($Entry.Version) { "$($Entry.Version)$(if ($Entry.PinnedExact) { ' (exact)' } else { ' (range)' })" } else { '-' }
    $rows = @(
        , @('Name        ', (ConvertTo-PSMMSafe $Entry.Name))
        , @('Description ', $(if ([string]::IsNullOrWhiteSpace($Entry.Description)) { '-' } else { ConvertTo-PSMMSafe $Entry.Description }))
        , @('Source      ', $srcLabel)
        , @('Install/Mode', "$($Entry.Install) / $($Entry.Mode)")
        , @('Version pin ', $pinTxt)
        , @('Installed   ', $installedTxt)
        , @('Loaded      ', $(if ($Entry.Loaded) { "yes  v$($Entry.LoadedVersion)$(if ($null -ne $Entry.ImportMs) { "  [grey66]import took $($Entry.ImportMs) ms[/]" })" } else { 'no' }))
        , @('Issues      ', $issues)
    )
    if ($Auth) {
        $authTxt = if (-not $Auth.Supported) { '-' }
                   elseif ($Auth.Connected) { "[green3]connected[/]  $(ConvertTo-PSMMSafe $Auth.Account)$(if ($Auth.Detail) { "  [grey66]$(ConvertTo-PSMMSafe $Auth.Detail)[/]" })" }
                   else { '[grey66]not connected[/]' }
        $rows += , @('Connection  ', $authTxt)
    }
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $rule = [Spectre.Console.Rule]::new("[$script:PSMM_ColAccent]$(ConvertTo-PSMMSafe $Entry.FriendlyName)[/]")
    $rule.Style = [Spectre.Console.Style]::Parse($script:PSMM_ColAccent)
    $items.Add($rule)
    $panel = [Spectre.Console.Panel]::new((New-PSMMDetailGrid -Rows $rows))
    $panel.Header = [Spectre.Console.PanelHeader]::new('details')
    $panel.Border = [Spectre.Console.BoxBorder]::Rounded
    $panel.BorderStyle = [Spectre.Console.Style]::Parse($script:PSMM_ColMute)
    $items.Add($panel)

    # verb keys match the grid (design system): ^l/^u load/unload, i install,
    # u update - install and update are always separate keys.
    $pairs = @('^l=load', '^u=unload')
    if ($Entry.Installed) { $pairs += 'u=update' } else { $pairs += 'i=install' }
    $pairs += 'b=browse commands'
    if ($Entry.Installed -and @($Entry.InstalledVersions).Count -gt 1) { $pairs += 'x=clean old versions' }
    if ($isUnmanaged) { $pairs += 'a=add to config' }
    elseif ($Entry.Writable -and $Entry.Source -ne '<profile inline>') { $pairs += @('e=edit', 'v=pin version', 'd=delete', 'm=move to file') }
    if ($Auth -and $Auth.Supported) {
        $pairs += 's=re-check connection'
        if ($Auth.Connected) { $pairs += 'o=disconnect' }
    } elseif (Get-PSMMAuthProvider -ModuleName $Entry.Name) {
        $pairs += 's=check connection'
    }
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs $pairs)))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", '?=help', 'esc=back', '^q=quit'))))
    if ($StatusMarkup) { $items.Add([Spectre.Console.Markup]::new($StatusMarkup)) }
    [Spectre.Console.Rows]::new($items)
}

function script:Show-PSMMModuleMenu {
    param([Parameter(Mandatory)] $Entry)
    $ui = $script:PSMM_UI
    $isUnmanaged = [bool]$Entry.PSObject.Properties['Unmanaged']
    $auth = $null
    # cheap providers get an automatic status check when the module is loaded;
    # slow ones (network round-trip) only on the explicit I key
    $provider = Get-PSMMAuthProvider -ModuleName $Entry.Name
    if ($provider -and -not $provider.Slow) { $auth = Get-PSMMConnectionStatus -ModuleName $Entry.Name }

    $status = ''
    while ($true) {
        if ($ui.HardQuit -or $ui.Goto) { return }
        Clear-PSMMScreen
        Write-PSMMRenderable (Build-PSMMModuleMenuView -Entry $Entry -Auth $auth -StatusMarkup $status)
        $status = ''

        $k = [Console]::ReadKey($true)
        if (Test-PSMMHardQuitKey $k) { $ui.HardQuit = $true; return }
        if ($k.KeyChar -eq 'g') {
            $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMModuleMenuView -Entry $Entry -Auth $auth)
            if ($dest) { $ui.Goto = $dest; return }
            continue
        }
        if (Test-PSMMHomeKey $k) { $ui.Goto = 'home'; return }
        $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        switch ($k.Key) {
            ([ConsoleKey]::L) {
                Write-PSMMLine "[$script:PSMM_ColAccent]loading $(ConvertTo-PSMMSafe $Entry.Name)...[/]"
                if (-not (Confirm-PSMMCloudHydration -ModuleName $Entry.Name)) {
                    $status = '[grey66]load cancelled (cloud-only files not downloaded)[/]'
                } else {
                    try {
                        Import-PSMMModuleTimed -Entry $Entry
                        $status = "[green3]loaded ($($Entry.ImportMs) ms)[/]"
                    } catch { $status = "[indianred1]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                    Update-PSMMLoaded -Entries $ui.Entries
                }
            }
            ([ConsoleKey]::U) {
                if ($ctrl) {
                    Write-PSMMLine "[$script:PSMM_ColAccent]unloading $(ConvertTo-PSMMSafe $Entry.Name)...[/]"
                    try { Remove-Module -Name $Entry.Name -Force -ErrorAction Stop; $status = '[green3]unloaded[/]' }
                    catch { $status = "[indianred1]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                    Update-PSMMLoaded -Entries $ui.Entries
                } elseif (-not $Entry.Installed) {
                    $status = '[orange1]not installed - i installs it first[/]'
                } else {
                    Clear-PSMMScreen
                    Write-PSMMLine "[$script:PSMM_ColAccent]updating $(ConvertTo-PSMMSafe $Entry.Name)... (this can take a while)[/]"
                    try {
                        Install-PSMMModule -Name $Entry.Name -Update -Version $Entry.Version
                        $status = '[green3]update done[/]'
                    } catch { $status = "[indianred1]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                    Update-PSMMAvailable -Entries $ui.Entries -Name $Entry.Name
                }
            }
            ([ConsoleKey]::I) {
                if ($ctrl) { continue }
                if ($Entry.Installed) {
                    $status = '[orange1]already installed - u updates it[/]'
                } else {
                    Clear-PSMMScreen
                    Write-PSMMLine "[$script:PSMM_ColAccent]installing $(ConvertTo-PSMMSafe $Entry.Name)... (this can take a while)[/]"
                    try {
                        Install-PSMMModule -Name $Entry.Name -Version $Entry.Version
                        $status = '[green3]install done[/]'
                    } catch { $status = "[indianred1]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                    Update-PSMMAvailable -Entries $ui.Entries -Name $Entry.Name
                }
            }
            ([ConsoleKey]::B) { Show-PSMMCommands -Entry $Entry }
            ([ConsoleKey]::X) {
                if ($Entry.Installed -and @($Entry.InstalledVersions).Count -gt 1) {
                    $status = Invoke-PSMMVersionCleanup -Entry $Entry
                    Update-PSMMAvailable -Entries $ui.Entries -Name $Entry.Name
                }
            }
            ([ConsoleKey]::S) {
                if ($provider) {
                    Write-PSMMLine "[$script:PSMM_ColAccent]checking connection status$(if ($provider.Slow) { ' (network - may take a moment)' })...[/]"
                    $auth = Get-PSMMConnectionStatus -ModuleName $Entry.Name
                }
            }
            ([ConsoleKey]::O) {
                if ($auth -and $auth.Connected) {
                    Write-PSMMLine "[$script:PSMM_ColAccent]disconnecting $(ConvertTo-PSMMSafe $Entry.Name)...[/]"
                    try {
                        Disconnect-PSMMModule -ModuleName $Entry.Name
                        $status = '[green3]disconnected[/]'
                        $auth = Get-PSMMConnectionStatus -ModuleName $Entry.Name
                    } catch { $status = "[indianred1]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                }
            }
            ([ConsoleKey]::A) {
                if ($isUnmanaged) { if (Add-PSMMUnmanagedEntry -Entry $Entry) { return } }
            }
            ([ConsoleKey]::E) { if (-not $isUnmanaged -and $Entry.Writable) { Edit-PSMMEntry -Entry $Entry; return } }
            ([ConsoleKey]::V) { if (-not $isUnmanaged -and $Entry.Writable) { if (Set-PSMMEntryPin -Entry $Entry) { return } } }
            ([ConsoleKey]::D) { if (-not $isUnmanaged -and $Entry.Writable) { if (Remove-PSMMEntryUI -Entry $Entry) { return } } }
            ([ConsoleKey]::M) { if (-not $isUnmanaged -and $Entry.Writable -and $Entry.Source -ne '<profile inline>') { if (Move-PSMMEntryUI -Entry $Entry) { return } } }
            ([ConsoleKey]::Escape) { return }
            ([ConsoleKey]::LeftArrow) { return }   # "move out" (#24)
            ([ConsoleKey]::RightArrow) { Show-PSMMCommands -Entry $Entry }   # "move into" commands (#24)
            default { if ($k.KeyChar -eq '?') { Show-PSMMHelpScreen -Topic 'module' } }
        }
    }
}

# Prune all but the newest installed version of a module (#30-lite, research
# "Clean Up"). Respects scope: AllUsers copies need elevation.
function script:Invoke-PSMMVersionCleanup {
    param([Parameter(Mandatory)] $Entry)
    $ui = $script:PSMM_UI
    $obsolete = @($Entry.InstalledVersions | Sort-Object { [version]"$($_.Version)" } -Descending | Select-Object -Skip 1)
    if (-not $obsolete.Count) { return '[grey66]nothing to clean[/]' }
    $blocked = @($obsolete | Where-Object { $_.Scope -eq 'AllUsers' -and -not $ui.Elevated })
    $doable  = @($obsolete | Where-Object { $_.Scope -ne 'AllUsers' -or $ui.Elevated })
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Clean up old versions of $(ConvertTo-PSMMSafe $Entry.Name)[/]"
    Write-PSMMLine "keeping [green3]v$($Entry.InstalledVersion)[/], removing: $(($doable | ForEach-Object { "v$($_.Version)" }) -join ', ')"
    if ($blocked.Count) { Write-PSMMLine "[orange1]skipping $(@($blocked).Count) AllUsers version(s) - session is not elevated[/]" }
    if (-not $doable.Count) { $null = Wait-PSMMKey; return '[orange1]nothing removable without elevation[/]' }
    if (-not (Read-SpectreConfirm -Message "Remove $($doable.Count) old version(s)?" -DefaultAnswer 'n')) { return '[grey66]cleanup cancelled[/]' }
    $ok = 0; $failed = 0
    foreach ($v in $doable) {
        Write-PSMMLine "[$script:PSMM_ColAccent]removing v$($v.Version)...[/]"
        try { Uninstall-PSMMModuleVersion -Name $Entry.Name -Version "$($v.Version)"; $ok++ }
        catch { $failed++; Write-PSMMLine "[indianred1]  v$($v.Version): $(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
    }
    if ($failed) { "[orange1]removed $ok, $failed failed[/]" } else { "[green3]removed $ok old version(s)[/]" }
}

# Pin (or unpin) an entry's version and save (#research: version pinning).
# Returns $true when the config changed (caller reloads).
function script:Set-PSMMEntryPin {
    param([Parameter(Mandatory)] $Entry)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Pin $(ConvertTo-PSMMSafe $Entry.Name) to a version[/]"
    Write-PSMMLine "[grey66]exact '1.2.3' or NuGet range '[[1.0,2.0)'; empty removes the pin[/]"
    $v = Read-SpectreText -Message 'Version' -DefaultAnswer ($Entry.Version ?? '') -AllowEmpty
    $v = "$v".Trim()
    if ($v -eq "$($Entry.Version)") { return $false }
    $probe = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = $Entry.Name; Version = $v }) -Source $Entry.Source -Writable $true
    if ($v -and -not $probe.Version) {
        Write-PSMMLine "[indianred1]'$(ConvertTo-PSMMSafe $v)' is not a valid version or range - nothing saved[/]"
        $null = Wait-PSMMKey
        return $false
    }
    $Entry.Version = $probe.Version
    $Entry.PinnedExact = $probe.PinnedExact
    Save-PSMMFile -Path $Entry.Source -Entries (Get-PSMMAllEntries)
    $script:PSMM_UI.Dirty = $true
    $true
}

# Writable targets for adding an entry; when none exist, offer to create the
# main config on the spot (2026-07-05 live-run feedback) instead of a dead
# end. Save-PSMMFile creates the file itself - only the directory must exist.
function script:Get-PSMMAddTargets {
    $meta = Get-PSMMFileMeta
    $targets = @($meta.Values | Where-Object { $_.Writable -and $_.Kind -ne 'inline' } | Select-Object -ExpandProperty Path)
    if ($targets.Count) { return $targets }
    $main = Get-PSMMMainConfigPath
    Write-PSMMLine '[orange1]No writable config file yet.[/]'
    if (-not (Read-SpectreConfirm -Message "Create $(ConvertTo-PSMMSafe $main) now?" -DefaultAnswer 'y')) { return @() }
    $dir = Split-Path -Parent $main
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    @($main)
}

# Add an unmanaged module to a writable config file (#27).
function script:Add-PSMMUnmanagedEntry {
    param([Parameter(Mandatory)] $Entry)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Add $(ConvertTo-PSMMSafe $Entry.Name) to a config file[/]"
    $targets = @(Get-PSMMAddTargets)
    if (-not $targets.Count) { return $false }
    $target = if ($targets.Count -eq 1) { $targets[0] } else { Read-SpectreSelection -Message 'Add to which file?' -Choices $targets -Color $script:PSMM_ColAccent }
    if (-not $target) { return $false }
    $install = Read-SpectreSelection -Message 'Install policy' -Choices 'IfMissing', 'CheckOnly', 'Latest' -Color $script:PSMM_ColAccent
    $mode    = Read-SpectreSelection -Message 'Mode' -Choices 'Load', 'InstallOnly', 'Ignore' -Color $script:PSMM_ColAccent
    $new = Resolve-PSMMEntry -Raw ([pscustomobject]@{
        Name = $Entry.Name; Description = $Entry.Description; Install = $install; Mode = $mode
    }) -Source $target -Writable $true
    $new | Add-Member -NotePropertyName FromMain -NotePropertyValue ($target -eq (Get-PSMMMainConfigPath)) -Force
    $new | Add-Member -NotePropertyName FileEnabled -NotePropertyValue $true -Force
    Add-PSMMAllEntry -Entry $new
    Save-PSMMFile -Path $target -Entries (Get-PSMMAllEntries)
    Write-PSMMLine "[green3]added to $(ConvertTo-PSMMSafe (Split-Path $target -Leaf)) - it is now managed[/]"
    $script:PSMM_UI.Dirty = $true
    $null = Wait-PSMMKey
    $true
}

# Edit an entry's fields and save.
function script:Edit-PSMMEntry {
    param([Parameter(Mandatory)] $Entry)
    if (-not $Entry.Writable) { return }
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Edit $(ConvertTo-PSMMSafe $Entry.Name)[/]"
    $Entry.Name         = Read-SpectreText -Message 'Name' -DefaultAnswer $Entry.Name
    $Entry.FriendlyName = Read-SpectreText -Message 'Friendly name' -DefaultAnswer ($Entry.FriendlyName ?? '') -AllowEmpty
    $Entry.Description  = Read-SpectreText -Message 'Description' -DefaultAnswer ($Entry.Description ?? '') -AllowEmpty
    $Entry.Install      = Read-SpectreSelection -Message 'Install policy' -Choices (@($Entry.Install) + (@('IfMissing', 'CheckOnly', 'Latest') | Where-Object { $_ -ne $Entry.Install })) -Color $script:PSMM_ColAccent
    $Entry.Mode         = Read-SpectreSelection -Message 'Mode'           -Choices (@($Entry.Mode) + (@('Load', 'InstallOnly', 'Ignore') | Where-Object { $_ -ne $Entry.Mode })) -Color $script:PSMM_ColAccent
    Save-PSMMFile -Path $Entry.Source -Entries (Get-PSMMAllEntries)
    $script:PSMM_UI.Dirty = $true
}

# Create a brand-new entry (grid key 'a').
function script:New-PSMMEntry {
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]New entry[/]"
    $targets = @(Get-PSMMAddTargets)
    if (-not $targets.Count) { $script:PSMM_UI.Status = '[grey66]add cancelled - no config file[/]'; return }
    $target = if ($targets.Count -eq 1) { $targets[0] } else { Read-SpectreSelection -Message 'Add to which file?' -Choices $targets -Color $script:PSMM_ColAccent }
    $name = Read-SpectreText -Message 'Module name'
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $friendly = Read-SpectreText -Message 'Friendly name' -AllowEmpty
    $desc     = Read-SpectreText -Message 'Description' -AllowEmpty
    $install  = Read-SpectreSelection -Message 'Install policy' -Choices 'IfMissing', 'CheckOnly', 'Latest' -Color $script:PSMM_ColAccent
    $mode     = Read-SpectreSelection -Message 'Mode' -Choices 'Load', 'InstallOnly', 'Ignore' -Color $script:PSMM_ColAccent
    $new = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = $name; FriendlyName = $friendly; Description = $desc; Install = $install; Mode = $mode }) -Source $target -Writable $true
    $new | Add-Member -NotePropertyName FromMain -NotePropertyValue ($target -eq (Get-PSMMMainConfigPath)) -Force
    $new | Add-Member -NotePropertyName FileEnabled -NotePropertyValue $true -Force
    Add-PSMMAllEntry -Entry $new
    Save-PSMMFile -Path $target -Entries (Get-PSMMAllEntries)
    $script:PSMM_UI.Dirty = $true
}

# Delete an entry (with confirm). Returns $true when deleted.
function script:Remove-PSMMEntryUI {
    param([Parameter(Mandatory)] $Entry)
    if (-not $Entry.Writable) { return $false }
    if (-not (Read-SpectreConfirm -Message "Delete '$($Entry.Name)' from $(Split-Path $Entry.Source -Leaf)?" -DefaultAnswer 'n')) { return $false }
    Set-PSMMAllEntries -Entries @(Get-PSMMAllEntries | Where-Object { -not ($_.Source -eq $Entry.Source -and $_.Name -eq $Entry.Name) })
    Save-PSMMFile -Path $Entry.Source -Entries (Get-PSMMAllEntries)
    $script:PSMM_UI.Dirty = $true
    return $true
}

# Move one entry to another writable config file.
function script:Move-PSMMEntryUI {
    param([Parameter(Mandatory)] $Entry)
    if (-not $Entry.Writable -or $Entry.Source -eq '<profile inline>') { return $false }
    $meta = Get-PSMMFileMeta
    $targets = @($meta.Values | Where-Object { $_.Writable -and $_.Kind -ne 'inline' -and $_.Path -ne $Entry.Source } | Select-Object -ExpandProperty Path)
    if (-not $targets.Count) {
        Write-PSMMLine '[orange1]No other writable config file to move to (create one via f -> n).[/]'
        $null = Wait-PSMMKey
        return $false
    }
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Move $(ConvertTo-PSMMSafe $Entry.Name)[/]"
    $target = if ($targets.Count -eq 1) { $targets[0] } else { Read-SpectreSelection -Message 'Move to which file?' -Choices $targets -Color $script:PSMM_ColAccent }
    if (-not $target) { return $false }
    $oldSource = $Entry.Source
    $Entry.Source = $target
    Save-PSMMFile -Path $oldSource -Entries (Get-PSMMAllEntries)   # removes it there
    Save-PSMMFile -Path $target -Entries (Get-PSMMAllEntries)      # adds it here
    Write-PSMMLine "[green3]Moved to $(ConvertTo-PSMMSafe (Split-Path $target -Leaf)).[/]"
    $script:PSMM_UI.Dirty = $true
    $null = Wait-PSMMKey
    return $true
}
