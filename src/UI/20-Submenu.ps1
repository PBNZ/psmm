# 20-Submenu.ps1 — per-module actions: details, load/unload/install, version
# pinning, duplicate cleanup, auth status/disconnect (#32), add-unmanaged
# (#27), edit/delete/move, command browsing.

# Build the module menu (mock 2e): breadcrumb header, condensed facts panel
# (what/entry/disk/session/connection), actions grouped by what they touch.
# $Auth may be $null (not yet queried).
function script:Build-PSMMModuleMenuView {
    param(
        [Parameter(Mandatory)] $Entry,
        $Auth,
        [string]$StatusMarkup
    )
    $isUnmanaged = [bool]$Entry.PSObject.Properties['Unmanaged']
    $mid = [char]0x00B7

    # --- condensed facts -------------------------------------------------
    $what = if (-not [string]::IsNullOrWhiteSpace($Entry.Description)) { ConvertTo-PSMMSafe $Entry.Description }
            elseif ($Entry.FriendlyName -and $Entry.FriendlyName -ne $Entry.Name) { ConvertTo-PSMMSafe $Entry.FriendlyName }
            else { '-' }
    $entryTxt = if ($isUnmanaged) { 'not in any config file (unmanaged)' }
                else {
                    # escape: range pins like '[1.0,2.0)' are invalid Spectre tags
                    $pinTxt = if ($Entry.Version) { "pin $(ConvertTo-PSMMSafe $Entry.Version)$(if ($Entry.PinnedExact) { ' (exact)' } else { ' (range)' })" } else { 'no pin' }
                    $srcLeaf = if ($Entry.Source -eq '<profile inline>') { 'profile inline' } else { Split-Path $Entry.Source -Leaf }
                    $rwTxt = if ($Entry.Writable -and $Entry.Source -ne '<profile inline>') { 'rw' } else { 'ro' }
                    "$(Get-PSMMStartupWord $Entry.Mode) at startup $mid gallery: $(Get-PSMMGalleryWord $Entry.Install) $mid $pinTxt [$script:PSMM_ColDim]$mid $(ConvertTo-PSMMSafe $srcLeaf) ($rwTxt)[/]"
                }
    $disk = if ($Entry.Installed) {
        $vers = @($Entry.InstalledVersions)
        $t = "v$($Entry.InstalledVersion) [$script:PSMM_ColDim]$($Entry.InstallScope)[/]"
        if ($Entry.UpdateAvailable -and $Entry.LatestVersion) { $t += " [$script:PSMM_ColWarn]$([char]0x21E1) v$($Entry.LatestVersion) available[/]" }
        if ($vers.Count -gt 1) { $t += " [$script:PSMM_ColWarn]$mid $($vers.Count) versions on disk[/]" }
        $t
    } else { 'not installed' }
    $session = if ($Entry.Loaded) {
        "imported $mid v$($Entry.LoadedVersion)$(if ($null -ne $Entry.ImportMs) { " [$script:PSMM_ColDim]$mid import took $($Entry.ImportMs) ms[/]" })"
    } else { 'not imported' }
    $facts = [System.Collections.Generic.List[string[]]]::new()
    $facts.Add(@('what', $what))
    $facts.Add(@('entry', $entryTxt))
    $facts.Add(@('disk', $disk))
    $facts.Add(@('session', $session))
    if ($Auth -and $Auth.Supported) {
        $authTxt = if ($Auth.Connected) { "[$script:PSMM_ColOk]connected[/] $(ConvertTo-PSMMSafe $Auth.Account)$(if ($Auth.Detail) { " [$script:PSMM_ColDim]$mid $(ConvertTo-PSMMSafe $Auth.Detail)[/]" })" }
                  else { "[$script:PSMM_ColDim]not connected[/]" }
        $facts.Add(@('connection', $authTxt))
    }
    if ($Entry.Issues.Count) {
        $facts.Add(@('issues', "[$script:PSMM_ColErr]$([char]0x26A0) $(ConvertTo-PSMMSafe ($Entry.Issues -join '; '))[/]"))
    }
    $fg = [Spectre.Console.Grid]::new()
    $lcol = [Spectre.Console.GridColumn]::new()
    $lcol.Padding = [Spectre.Console.Padding]::new(0, 0, 3, 0)
    [void]$fg.AddColumn($lcol)
    [void]$fg.AddColumn([Spectre.Console.GridColumn]::new())
    foreach ($f in $facts) {
        [void][Spectre.Console.GridExtensions]::AddRow($fg, [string[]]@("[$script:PSMM_ColDim]$($f[0])[/]", $f[1]))
    }
    $panel = [Spectre.Console.Panel]::new($fg)
    $panel.Border = [Spectre.Console.BoxBorder]::Rounded
    $panel.BorderStyle = Get-PSMMBorderStyle

    # --- actions grouped by what they touch (§2e); same verbs, same keys --
    $galleryPairs = @()
    if ($Entry.Installed) {
        $galleryPairs += if ($Entry.UpdateAvailable -and $Entry.LatestVersion) { "u=update to $($Entry.LatestVersion)" } else { 'u=update' }
        if (@($Entry.InstalledVersions).Count -gt 1) { $galleryPairs += "x=clean $(@($Entry.InstalledVersions).Count - 1) old version(s)" }
    } else { $galleryPairs += 'i=install' }
    $entryPairs = if ($isUnmanaged) { @('a=add to config') }
                  elseif ($Entry.Writable -and $Entry.Source -ne '<profile inline>') { @('e=edit', 'v=pin version', 'd=delete', 'm=move to file') }
                  else { @() }
    $connPairs = @()
    if ($Auth -and $Auth.Supported) {
        $connPairs += 's=re-check'
        if ($Auth.Connected) { $connPairs += 'o=disconnect' }
    } elseif (Get-PSMMAuthProvider -ModuleName $Entry.Name) {
        $connPairs += 's=check connection'
    }
    $groups = @(
        , @('session', @('^l=load', '^u=unload', 'b=browse commands'))
        , @('gallery', $galleryPairs)
        , @('entry', $entryPairs)
        , @('connection', $connPairs)
    )
    $ag = [Spectre.Console.Grid]::new()
    $gcol = [Spectre.Console.GridColumn]::new()
    $gcol.Padding = [Spectre.Console.Padding]::new(0, 0, 3, 0)
    [void]$ag.AddColumn($gcol)
    [void]$ag.AddColumn([Spectre.Console.GridColumn]::new())
    foreach ($g in $groups) {
        if (-not @($g[1]).Count) { continue }
        [void][Spectre.Console.GridExtensions]::AddRow($ag, [string[]]@(
                "[$script:PSMM_ColDim]$($g[0])[/]", (Get-PSMMHint -Pairs @($g[1]) -NoLegend)))
    }

    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb @('home', "$($Entry.Name)") -RightMarkup (Get-PSMMStateMarkup -Entry $Entry))))
    $items.Add($panel)
    $items.Add($ag)
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
                    $status = "[$script:PSMM_ColMute]load cancelled (cloud-only files not downloaded)[/]"
                } else {
                    try {
                        Import-PSMMModuleTimed -Entry $Entry
                        $status = "[$script:PSMM_ColOk]loaded ($($Entry.ImportMs) ms)[/]"
                    } catch { $status = "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                    Update-PSMMLoaded -Entries $ui.Entries
                }
            }
            ([ConsoleKey]::U) {
                if ($ctrl) {
                    Write-PSMMLine "[$script:PSMM_ColAccent]unloading $(ConvertTo-PSMMSafe $Entry.Name)...[/]"
                    try { Remove-Module -Name $Entry.Name -Force -ErrorAction Stop; $status = "[$script:PSMM_ColOk]unloaded[/]" }
                    catch { $status = "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                    Update-PSMMLoaded -Entries $ui.Entries
                } elseif (-not $Entry.Installed) {
                    $status = "[$script:PSMM_ColWarn]not installed - i installs it first[/]"
                } else {
                    Clear-PSMMScreen
                    Write-PSMMLine "[$script:PSMM_ColAccent]updating $(ConvertTo-PSMMSafe $Entry.Name)... (this can take a while)[/]"
                    try {
                        Install-PSMMModule -Name $Entry.Name -Update -Version $Entry.Version
                        $status = "[$script:PSMM_ColOk]update done[/]"
                    } catch { $status = "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                    Update-PSMMAvailable -Entries $ui.Entries -Name $Entry.Name
                }
            }
            ([ConsoleKey]::I) {
                if ($ctrl) { continue }
                if ($Entry.Installed) {
                    $status = "[$script:PSMM_ColWarn]already installed - u updates it[/]"
                } else {
                    Clear-PSMMScreen
                    Write-PSMMLine "[$script:PSMM_ColAccent]installing $(ConvertTo-PSMMSafe $Entry.Name)... (this can take a while)[/]"
                    try {
                        Install-PSMMModule -Name $Entry.Name -Version $Entry.Version
                        $status = "[$script:PSMM_ColOk]install done[/]"
                    } catch { $status = "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
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
                        $status = "[$script:PSMM_ColOk]disconnected[/]"
                        $auth = Get-PSMMConnectionStatus -ModuleName $Entry.Name
                    } catch { $status = "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
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
    if (-not $obsolete.Count) { return "[$script:PSMM_ColMute]nothing to clean[/]" }
    $blocked = @($obsolete | Where-Object { $_.Scope -eq 'AllUsers' -and -not $ui.Elevated })
    $doable  = @($obsolete | Where-Object { $_.Scope -ne 'AllUsers' -or $ui.Elevated })
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Clean up old versions of $(ConvertTo-PSMMSafe $Entry.Name)[/]"
    Write-PSMMLine "keeping [$script:PSMM_ColOk]v$($Entry.InstalledVersion)[/], removing: $(($doable | ForEach-Object { "v$($_.Version)" }) -join ', ')"
    if ($blocked.Count) { Write-PSMMLine "[$script:PSMM_ColWarn]skipping $(@($blocked).Count) AllUsers version(s) - session is not elevated[/]" }
    if (-not $doable.Count) { $null = Wait-PSMMKey; return "[$script:PSMM_ColWarn]nothing removable without elevation[/]" }
    if (-not (Read-SpectreConfirm -Message "Remove $($doable.Count) old version(s)?" -DefaultAnswer 'n')) { return "[$script:PSMM_ColMute]cleanup cancelled[/]" }
    $ok = 0; $failed = 0
    foreach ($v in $doable) {
        Write-PSMMLine "[$script:PSMM_ColAccent]removing v$($v.Version)...[/]"
        try { Uninstall-PSMMModuleVersion -Name $Entry.Name -Version "$($v.Version)"; $ok++ }
        catch { $failed++; Write-PSMMLine "[$script:PSMM_ColErr]  v$($v.Version): $(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
    }
    if ($failed) { "[$script:PSMM_ColWarn]removed $ok, $failed failed[/]" } else { "[$script:PSMM_ColOk]removed $ok old version(s)[/]" }
}

# Pin (or unpin) an entry's version and save (#research: version pinning).
# Returns $true when the config changed (caller reloads).
function script:Set-PSMMEntryPin {
    param([Parameter(Mandatory)] $Entry)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Pin $(ConvertTo-PSMMSafe $Entry.Name) to a version[/]"
    Write-PSMMLine "[$script:PSMM_ColMute]exact '1.2.3' or NuGet range '[[1.0,2.0)'; empty removes the pin[/]"
    $v = Read-SpectreText -Message 'Version' -DefaultAnswer ($Entry.Version ?? '') -AllowEmpty
    $v = "$v".Trim()
    if ($v -eq "$($Entry.Version)") { return $false }
    $probe = Resolve-PSMMEntry -Raw ([pscustomobject]@{ Name = $Entry.Name; Version = $v }) -Source $Entry.Source -Writable $true
    if ($v -and -not $probe.Version) {
        Write-PSMMLine "[$script:PSMM_ColErr]'$(ConvertTo-PSMMSafe $v)' is not a valid version or range - nothing saved[/]"
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
    Write-PSMMLine "[$script:PSMM_ColWarn]No writable config file yet.[/]"
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
    Write-PSMMLine "[$script:PSMM_ColOk]added to $(ConvertTo-PSMMSafe (Split-Path $target -Leaf)) - it is now managed[/]"
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
    if (-not $targets.Count) { $script:PSMM_UI.Status = "[$script:PSMM_ColMute]add cancelled - no config file[/]"; return }
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
        Write-PSMMLine "[$script:PSMM_ColWarn]No other writable config file to move to (create one via f -> n).[/]"
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
    Write-PSMMLine "[$script:PSMM_ColOk]Moved to $(ConvertTo-PSMMSafe (Split-Path $target -Leaf)).[/]"
    $script:PSMM_UI.Dirty = $true
    $null = Wait-PSMMKey
    return $true
}
