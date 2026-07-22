# 20-Submenu.ps1 — per-module actions: details, load/unload/install, version
# pinning, duplicate cleanup, auth status/disconnect (#32), add-unmanaged
# (#27), edit/delete/move, command browsing.

# Where this module actually lives (gh#3). "Which copy is being used, and from
# where?" is the first question when a module misbehaves, and until now the
# screen could not answer it. Pure formatting: the paths and the search-root
# verdict were resolved once by Resolve-PSMMModuleFacts - the render path
# touches neither disk nor $env:PSModulePath.
function script:Get-PSMMModuleLocationFacts {
    param(
        [Parameter(Mandatory)] $Entry,
        $Manifest
    )
    $rows = [System.Collections.Generic.List[string[]]]::new()
    $vers = @($Entry.InstalledVersions)
    if (-not $vers.Count) { return @($rows) }
    $mid = [char]0x00B7
    $cap = [Math]::Max(30, (Get-PSMMWinSize).Width - 20)
    $rows.Add(@('path', "[$script:PSMM_ColDim]$(ConvertTo-PSMMSafe (Get-PSMMTrunc "$($vers[0].Path)" $cap))[/]"))
    if ($Manifest -and $Manifest.Root) {
        $notes = @()
        if ($null -ne $Manifest.RootOrder) {
            $notes += "search order $($Manifest.RootOrder + 1)"
            if ($Manifest.RootOneDrive) { $notes += "[$script:PSMM_ColWarn]onedrive[/]" }
        } else {
            $notes += "[$script:PSMM_ColWarn]not on the module search path[/]"
        }
        $rows.Add(@('location', "[$script:PSMM_ColDim]$(ConvertTo-PSMMSafe (Get-PSMMTrunc "$($Manifest.Root)" $cap))[/] $mid $($notes -join " $mid ")"))
    }
    if ($vers.Count -gt 1) {
        $shown = @($vers | Select-Object -First 4 | ForEach-Object {
                "v$(Get-PSMMVersionMarkup -Version $_.Version -Prerelease $_.Prerelease) [$script:PSMM_ColDim]$($_.Scope)[/]"
            })
        if ($vers.Count -gt 4) { $shown += "[$script:PSMM_ColDim]+$($vers.Count - 4) more[/]" }
        $rows.Add(@('versions', ($shown -join " $mid ")))
    }
    @($rows)
}

# Everything the module menu needs that costs I/O: manifest facts (author,
# project URL, type, command count), which search root the module sits under,
# and how many of its files are still cloud-only placeholders. Resolved ONCE
# when the screen opens - the render path must stay free of disk and network
# access (same rule the grid follows).
function script:Resolve-PSMMModuleFacts {
    param([Parameter(Mandatory)] $Entry)
    $facts = [pscustomobject]@{
        Author = ''; ProjectUri = ''; ModuleType = ''; CommandCount = 0; CloudOnly = 0
        Root = ''; RootOrder = $null; RootOneDrive = $false
    }
    try {
        $m = Get-Module -Name $Entry.Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $m -and $Entry.Installed) {
            $m = Get-Module -ListAvailable -Name $Entry.Name -ErrorAction SilentlyContinue |
                Sort-Object Version -Descending | Select-Object -First 1
        }
        if ($m) {
            $facts.Author = "$($m.Author)"
            $facts.ModuleType = "$($m.ModuleType)"
            $n = 0
            try { $n = @($m.ExportedCommands.Keys).Count } catch { }
            $facts.CommandCount = $n
            try {
                $uri = $m.PrivateData.PSData.ProjectUri
                if ($uri -and (Test-PSMMUrl -Text "$uri")) { $facts.ProjectUri = "$uri" }
            } catch { }
        }
    } catch { }
    $vers = @($Entry.InstalledVersions)
    if ($vers.Count) {
        try {
            $tree = Get-PSMMModuleTree -ModuleBase "$($vers[0].Path)" -Name $Entry.Name
            $facts.Root = $tree.Root
            $match = @(Get-PSMMModulePathInfo | Where-Object {
                    $_.Path.TrimEnd('\', '/') -eq "$($tree.Root)".TrimEnd('\', '/')
                }) | Select-Object -First 1
            if ($match) { $facts.RootOrder = $match.Order; $facts.RootOneDrive = [bool]$match.OneDrive }
        } catch { }
    }
    # only ever scans OneDrive module bases (see Get-PSMMModuleCloudOnlyFile)
    try { $facts.CloudOnly = @(Get-PSMMModuleCloudOnlyFile -Name $Entry.Name).Count } catch { }
    $facts
}

# Build the module menu (mock 2e): breadcrumb header, condensed facts panel
# (what/entry/disk/session/connection), actions grouped by what they touch.
# $Auth may be $null (not yet queried).
function script:Build-PSMMModuleMenuView {
    param(
        [Parameter(Mandatory)] $Entry,
        $Auth,
        [string]$StatusMarkup,
        # manifest facts resolved once by the caller - manifest lookups do not
        # belong in the render path (@{ Author; ProjectUri; ModuleType;
        # CommandCount; Manifest })
        $Manifest
    )
    $isUnmanaged = [bool]$Entry.PSObject.Properties['Unmanaged']
    $mid = [char]0x00B7
    $Author = if ($Manifest) { "$($Manifest.Author)" } else { '' }

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
                    $preTxt = if ($Entry.AllowPrerelease) { " $mid [$script:PSMM_ColInfo]prereleases allowed[/]" } else { '' }
                    "$(Get-PSMMStartupWord $Entry.Mode) at startup $mid gallery: $(Get-PSMMGalleryWord $Entry.Install) $mid $pinTxt$preTxt [$script:PSMM_ColDim]$mid $(ConvertTo-PSMMSafe $srcLeaf) ($rwTxt)[/]"
                }
    $disk = if ($Entry.Installed) {
        $vers = @($Entry.InstalledVersions)
        $t = "v$(Get-PSMMVersionMarkup -Version $Entry.InstalledVersion -Prerelease $Entry.InstalledPrerelease) [$script:PSMM_ColDim]$($Entry.InstallScope)[/]"
        if ($Entry.UpdateAvailable -and $Entry.LatestVersion) {
            $t += " [$script:PSMM_ColWarn]$([char]0x21E1) v$(ConvertTo-PSMMSafe (Get-PSMMVersionText -Version $Entry.LatestVersion -Prerelease $Entry.LatestPrerelease)) available[/]"
        }
        if ($vers.Count -gt 1) { $t += " [$script:PSMM_ColWarn]$mid $($vers.Count) versions on disk[/]" }
        $t
    } else { 'not installed' }
    $session = if ($Entry.Loaded) {
        "imported $mid v$(Get-PSMMVersionMarkup -Version $Entry.LoadedVersion -Prerelease $Entry.LoadedPrerelease)$(if ($null -ne $Entry.ImportMs) { " [$script:PSMM_ColDim]$mid import took $($Entry.ImportMs) ms[/]" })"
    } else { 'not imported' }
    $facts = [System.Collections.Generic.List[string[]]]::new()
    $facts.Add(@('what', $what))
    if (-not [string]::IsNullOrWhiteSpace($Author)) {
        $facts.Add(@('by', (ConvertTo-PSMMSafe $Author)))
    }
    $facts.Add(@('entry', $entryTxt))
    $facts.Add(@('disk', $disk))
    $facts.Add(@('session', $session))
    # where it actually lives (gh#3): the first question when a module
    # misbehaves is "which copy is being used, and from where?"
    foreach ($row in (Get-PSMMModuleLocationFacts -Entry $Entry -Manifest $Manifest)) { $facts.Add($row) }
    if ($Manifest) {
        $bits = @()
        if ($Manifest.ModuleType) { $bits += "[$script:PSMM_ColDim]$(ConvertTo-PSMMSafe "$($Manifest.ModuleType)") module[/]" }
        if ($Manifest.CommandCount) { $bits += "[$script:PSMM_ColDim]$($Manifest.CommandCount) command(s) (b browses them)[/]" }
        if ($bits.Count) { $facts.Add(@('kind', ($bits -join " $mid "))) }
        if ($Manifest.ProjectUri) {
            $facts.Add(@('project', (Get-PSMMLinkMarkup -Url "$($Manifest.ProjectUri)")))
        }
    }
    if ($Auth -and $Auth.Supported) {
        $authTxt = if ($Auth.Connected) { "[$script:PSMM_ColOk]connected[/] $(ConvertTo-PSMMSafe $Auth.Account)$(if ($Auth.Detail) { " [$script:PSMM_ColDim]$mid $(ConvertTo-PSMMSafe $Auth.Detail)[/]" })" }
                  else { "[$script:PSMM_ColDim]not connected[/]" }
        $facts.Add(@('connection', $authTxt))
    }
    if ($Manifest -and $Manifest.CloudOnly) {
        $facts.Add(@('cloud', "[$script:PSMM_ColWarn]$($Manifest.CloudOnly) file(s) are OneDrive cloud-only[/] [$script:PSMM_ColDim]$mid downloaded before the next load[/]"))
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
        # the target version keeps its prerelease label here too, or the hint
        # would offer "update to 0.1.0" when it means 0.1.0-beta9 (gh#6)
        $galleryPairs += if ($Entry.UpdateAvailable -and $Entry.LatestVersion) {
            "u=update to $(Get-PSMMVersionText -Version $Entry.LatestVersion -Prerelease $Entry.LatestPrerelease)"
        } else { 'u=update' }
        if (@($Entry.InstalledVersions).Count -gt 1) { $galleryPairs += "x=clean $(@($Entry.InstalledVersions).Count - 1) old version(s)" }
    } else { $galleryPairs += 'i=install' }
    $entryPairs = if ($isUnmanaged) { @('a=add to config') }
                  elseif ($Entry.Writable -and $Entry.Source -ne '<profile inline>') {
                      @('e=edit', 'v=pin version',
                        $(if ($Entry.AllowPrerelease) { 'w=stable only' } else { 'w=allow prereleases' }),
                        'd=delete', 'm=move to file')
                  } else { @() }
    $connPairs = @()
    if ($Auth -and $Auth.Supported) {
        $connPairs += 's=re-check'
        if ($Auth.Connected) { $connPairs += 'o=disconnect' }
    } elseif (Get-PSMMAuthProvider -ModuleName $Entry.Name) {
        $connPairs += 's=check connection'
    }
    # files on disk, as opposed to the config-file entry (gh#4)
    $diskPairs = if ($Entry.Installed) { @('p=move to another location') } else { @() }
    $groups = @(
        , @('session', @('^l=load', '^u=unload', 'b=browse commands'))
        , @('gallery', $galleryPairs)
        , @('entry', $entryPairs)
        , @('files', $diskPairs)
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
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('left/right=back / commands') -NoLegend)))
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

    # manifest facts (author, project URL, type, command count, cloud-only
    # placeholders), resolved once - never in the render path. The cloud-only
    # scan walks the module folder, so say what is happening rather than
    # pausing silently on a big module in OneDrive.
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColMute]reading $(ConvertTo-PSMMSafe $Entry.Name) details...[/]"
    $manifest = Resolve-PSMMModuleFacts -Entry $Entry

    $status = ''
    while ($true) {
        if ($ui.HardQuit -or $ui.Goto) { return }
        Clear-PSMMScreen
        Write-PSMMRenderable (Build-PSMMModuleMenuView -Entry $Entry -Auth $auth -StatusMarkup $status -Manifest $manifest)
        $status = ''

        $k = [Console]::ReadKey($true)
        if (Test-PSMMHardQuitKey $k) { $ui.HardQuit = $true; return }
        if ($k.KeyChar -eq 'g') {
            $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMModuleMenuView -Entry $Entry -Auth $auth -Manifest $manifest)
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
                        Install-PSMMModule -Name $Entry.Name -Update -Version $Entry.Version -Prerelease:([bool]$Entry.AllowPrerelease)
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
                        Install-PSMMModule -Name $Entry.Name -Version $Entry.Version -Prerelease:([bool]$Entry.AllowPrerelease)
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
            ([ConsoleKey]::E) { if (-not $isUnmanaged -and $Entry.Writable) { if (Edit-PSMMEntry -Entry $Entry) { return }; $status = $script:PSMM_UI.Status } }
            ([ConsoleKey]::V) { if (-not $isUnmanaged -and $Entry.Writable) { if (Set-PSMMEntryPin -Entry $Entry) { return } ; $status = $script:PSMM_UI.Status } }
            ([ConsoleKey]::W) { if (-not $ctrl -and -not $isUnmanaged -and $Entry.Writable) { if (Set-PSMMEntryPrerelease -Entry $Entry) { return } } }
            ([ConsoleKey]::D) { if (-not $isUnmanaged -and $Entry.Writable) { if (Remove-PSMMEntryUI -Entry $Entry) { return } } }
            ([ConsoleKey]::M) { if (-not $isUnmanaged -and $Entry.Writable -and $Entry.Source -ne '<profile inline>') { if (Move-PSMMEntryUI -Entry $Entry) { return } } }
            ([ConsoleKey]::P) {
                # a stray ctrl+p must never open a filesystem-move dialog
                if (-not $ctrl -and $Entry.Installed) {
                    $status = Move-PSMMModuleLocationUI -Entry $Entry
                    Update-PSMMAvailable -Entries $ui.Entries -Name $Entry.Name
                    $manifest = Resolve-PSMMModuleFacts -Entry $Entry
                }
            }
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
#
# gh#5: the old prompt was a bare text box - you had to know a version and type
# it. psmm knows which versions exist (on disk, instantly; in the gallery, over
# the network), so it offers them, with the CURRENT pin preselected. Free text
# stays available because a NuGet range can never come from a list.
function script:Set-PSMMEntryPin {
    param([Parameter(Mandatory)] $Entry)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Pin $(ConvertTo-PSMMSafe $Entry.Name) to a version[/]"
    $current = "$($Entry.Version)"
    if ($current) { Write-PSMMLine "[$script:PSMM_ColMute]currently pinned to[/] [$script:PSMM_ColAccent]$(ConvertTo-PSMMSafe $current)[/]" }
    else { Write-PSMMLine "[$script:PSMM_ColMute]not pinned - psmm installs whatever the gallery calls latest[/]" }
    Write-PSMMLine "[$script:PSMM_ColMute]looking up available versions (gallery - may take a moment)...[/]"
    $available = @(Get-PSMMAvailableVersion -Name $Entry.Name -Prerelease:([bool]$Entry.AllowPrerelease))

    $typeLabel = 'type an exact version or a NuGet range...'
    $clearLabel = 'remove the pin (always install latest)'
    $choices = [System.Collections.Generic.List[string]]::new()
    $byLabel = @{}
    foreach ($v in $available) {
        $where = @()
        if ($v.OnDisk) { $where += 'on disk' }
        if ($v.InGallery) { $where += 'gallery' }
        $label = "$($v.Display)  ($($where -join ', '))"
        if ($byLabel.ContainsKey($label)) { continue }
        $byLabel[$label] = $v.Display
        $choices.Add($label)
    }
    $choices.Add($typeLabel)
    if ($current) { $choices.Add($clearLabel) }
    # preselect what the user most likely wants: the existing pin, else the
    # installed version - Read-SpectreSelection has no "default" parameter, so
    # the preselected item is moved to the top of the list
    $preferred = if ($current) { $current } else { Get-PSMMVersionText -Version $Entry.InstalledVersion -Prerelease $Entry.InstalledPrerelease }
    $ordered = @($choices)
    if ($preferred) {
        $hit = @($choices | Where-Object { $byLabel[$_] -eq $preferred }) | Select-Object -First 1
        if ($hit) { $ordered = @($hit) + @($choices | Where-Object { $_ -ne $hit }) }
    }

    $picked = Read-SpectreSelection -Message 'Pin to' -Choices $ordered -Color $script:PSMM_ColAccent
    if (-not $picked) { $script:PSMM_UI.Status = "[$script:PSMM_ColMute]pin cancelled - nothing saved[/]"; return $false }
    $v = switch ($picked) {
        $clearLabel { '' }
        $typeLabel {
            Write-PSMMLine "[$script:PSMM_ColMute]exact '1.2.3' or NuGet range '[[1.0,2.0)'; empty removes the pin[/]"
            $typed = Read-PSMMText -Message 'Version' -DefaultAnswer $current -AllowEmpty
            if ($null -eq $typed) { $script:PSMM_UI.Status = "[$script:PSMM_ColMute]pin cancelled - nothing saved[/]"; return $false }
            "$typed".Trim()
        }
        default { "$($byLabel[$picked])" }
    }
    if ($v -eq $current) { $script:PSMM_UI.Status = "[$script:PSMM_ColMute]pin unchanged[/]"; return $false }
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

# Toggle the entry's prerelease policy and save (gh#6).
function script:Set-PSMMEntryPrerelease {
    param([Parameter(Mandatory)] $Entry)
    if (-not $Entry.Writable) { return $false }
    $Entry.AllowPrerelease = -not $Entry.AllowPrerelease
    Save-PSMMFile -Path $Entry.Source -Entries (Get-PSMMAllEntries)
    $script:PSMM_UI.Status = if ($Entry.AllowPrerelease) {
        "[$script:PSMM_ColOk]prereleases allowed for $(ConvertTo-PSMMSafe $Entry.Name) - install, update and pin now see them[/]"
    } else {
        "[$script:PSMM_ColOk]$(ConvertTo-PSMMSafe $Entry.Name) tracks stable releases only[/]"
    }
    $script:PSMM_UI.Dirty = $true
    $true
}

# Move a module's files to another module location (gh#4). Returns a status
# markup line. Every version of the module moves together: the folder that
# moves is <root>\<Name>, never one version out of a multi-version tree.
function script:Move-PSMMModuleLocationUI {
    param([Parameter(Mandatory)] $Entry)
    $vers = @($Entry.InstalledVersions)
    if (-not $vers.Count) { return "[$script:PSMM_ColWarn]not installed - nothing to move[/]" }
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Move $(ConvertTo-PSMMSafe $Entry.Name) to another module location[/]"
    $tree = Get-PSMMModuleTree -ModuleBase "$($vers[0].Path)" -Name $Entry.Name
    Write-PSMMLine "[$script:PSMM_ColMute]from[/] [$script:PSMM_ColDim]$(ConvertTo-PSMMSafe $tree.Tree)[/]"
    Write-PSMMLine "[$script:PSMM_ColMute]$(@($vers).Count) version(s), $(Format-PSMMSize (Get-PSMMFolderSize -Path $tree.Tree))[/]"

    # a loaded module holds its files open - binary modules in particular
    if ($Entry.Loaded) {
        Write-PSMMProse -Text "$($Entry.Name) is imported in this session, so its files are in use and the move will fail. Unload it first (ctrl+u), then try again." -Colour $script:PSMM_ColWarn
        $null = Wait-PSMMKey
        return "[$script:PSMM_ColWarn]move cancelled - unload the module first[/]"
    }

    $targets = @(Get-PSMMModulePathInfo |
            Where-Object { $_.Exists -and (Test-PSMMDirectoryWritable -Path $_.Path) -and
                           $_.Path.TrimEnd('\', '/') -ne "$($tree.Root)".TrimEnd('\', '/') } |
            Select-Object -ExpandProperty Path)
    $other = 'somewhere else (type a path)...'
    if (-not $targets.Count) {
        Write-PSMMProse -Text 'No other writable folder on the module search path. Add one first (g p, then n), or type a path below.' -Colour $script:PSMM_ColWarn
    }
    $pick = Read-SpectreSelection -Message 'Move to' -Choices (@($targets) + @($other)) -Color $script:PSMM_ColAccent
    if (-not $pick) { return "[$script:PSMM_ColMute]move cancelled[/]" }
    $target = if ($pick -eq $other) { Read-PSMMText -Message 'Target folder' } else { $pick }
    if ([string]::IsNullOrWhiteSpace($target)) { return "[$script:PSMM_ColMute]move cancelled[/]" }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        if (-not (Read-SpectreConfirm -Message "Create $(ConvertTo-PSMMSafe $target) now?" -DefaultAnswer 'y')) { return "[$script:PSMM_ColMute]move cancelled[/]" }
        try { New-Item -ItemType Directory -Force -Path $target | Out-Null }
        catch { return "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
    }
    if (-not (Test-PSMMDirectoryWritable -Path $target)) { $null = Wait-PSMMKey; return "[$script:PSMM_ColErr]target folder is not writable[/]" }
    if (-not (Read-SpectreConfirm -Message "Move $(ConvertTo-PSMMSafe $Entry.Name) to $(ConvertTo-PSMMSafe $target)?" -DefaultAnswer 'n')) { return "[$script:PSMM_ColMute]move cancelled[/]" }

    $results = @(Move-PSMMModuleTree -Name $Entry.Name -InstalledVersions $vers -TargetRoot $target)
    foreach ($r in $results) {
        if ($r.Moved) { Write-PSMMLine "[$script:PSMM_ColOk]moved[/] [$script:PSMM_ColDim]$(ConvertTo-PSMMSafe $r.To)[/]" }
        else { Write-PSMMLine "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $r.From): $(ConvertTo-PSMMSafe $r.Reason)[/]" }
    }
    $moved = @($results | Where-Object Moved).Count
    if ($moved -and -not (Test-PSMMModulePathContains -Path $target)) {
        Write-PSMMProse -Text "$target is not on the module search path, so PowerShell will not find the module there. Add it on the paths screen (g p, then n)." -Colour $script:PSMM_ColWarn
    }
    $script:PSMM_UI.Dirty = $true
    $null = Wait-PSMMKey
    if ($moved -eq @($results).Count) { "[$script:PSMM_ColOk]moved $(ConvertTo-PSMMSafe $Entry.Name) to $(ConvertTo-PSMMSafe $target)[/]" }
    elseif ($moved) { "[$script:PSMM_ColWarn]moved $moved of $(@($results).Count) folder(s)[/]" }
    else { "[$script:PSMM_ColErr]nothing moved[/]" }
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

# Edit an entry's fields and save. Esc on any text prompt aborts WITHOUT
# touching the entry (live-run feedback); nothing is assigned until every
# answer is in. Returns $true when the entry was saved.
function script:Edit-PSMMEntry {
    param([Parameter(Mandatory)] $Entry)
    if (-not $Entry.Writable) { return $false }
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Edit $(ConvertTo-PSMMSafe $Entry.Name)[/]"
    $cancelled = "[$script:PSMM_ColMute]edit cancelled - nothing saved[/]"
    $name = Read-PSMMText -Message 'Name' -DefaultAnswer $Entry.Name
    if ($null -eq $name) { $script:PSMM_UI.Status = $cancelled; return $false }
    $friendly = Read-PSMMText -Message 'Friendly name' -DefaultAnswer ($Entry.FriendlyName ?? '') -AllowEmpty
    if ($null -eq $friendly) { $script:PSMM_UI.Status = $cancelled; return $false }
    $desc = Read-PSMMText -Message 'Description' -DefaultAnswer ($Entry.Description ?? '') -AllowEmpty
    if ($null -eq $desc) { $script:PSMM_UI.Status = $cancelled; return $false }
    $install = Read-SpectreSelection -Message 'Install policy' -Choices (@($Entry.Install) + (@('IfMissing', 'CheckOnly', 'Latest') | Where-Object { $_ -ne $Entry.Install })) -Color $script:PSMM_ColAccent
    $mode    = Read-SpectreSelection -Message 'Mode'           -Choices (@($Entry.Mode) + (@('Load', 'InstallOnly', 'Ignore') | Where-Object { $_ -ne $Entry.Mode })) -Color $script:PSMM_ColAccent
    $preOpts = if ($Entry.AllowPrerelease) { @('allow prereleases', 'stable only') } else { @('stable only', 'allow prereleases') }
    $pre     = Read-SpectreSelection -Message 'Versions' -Choices $preOpts -Color $script:PSMM_ColAccent
    $Entry.Name            = $name
    $Entry.FriendlyName    = $friendly
    $Entry.Description     = $desc
    $Entry.Install         = $install
    $Entry.Mode            = $mode
    $Entry.AllowPrerelease = ($pre -eq 'allow prereleases')
    Save-PSMMFile -Path $Entry.Source -Entries (Get-PSMMAllEntries)
    $script:PSMM_UI.Dirty = $true
    $true
}

# Create a brand-new entry (grid key 'a').
function script:New-PSMMEntry {
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]New entry[/]"
    $targets = @(Get-PSMMAddTargets)
    if (-not $targets.Count) { $script:PSMM_UI.Status = "[$script:PSMM_ColMute]add cancelled - no config file[/]"; return }
    $target = if ($targets.Count -eq 1) { $targets[0] } else { Read-SpectreSelection -Message 'Add to which file?' -Choices $targets -Color $script:PSMM_ColAccent }
    $cancelled = "[$script:PSMM_ColMute]add cancelled - nothing saved[/]"
    $name = Read-PSMMText -Message 'Module name'
    if ($null -eq $name -or [string]::IsNullOrWhiteSpace($name)) { $script:PSMM_UI.Status = $cancelled; return }
    $friendly = Read-PSMMText -Message 'Friendly name' -AllowEmpty
    if ($null -eq $friendly) { $script:PSMM_UI.Status = $cancelled; return }
    $desc = Read-PSMMText -Message 'Description' -AllowEmpty
    if ($null -eq $desc) { $script:PSMM_UI.Status = $cancelled; return }
    $install  = Read-SpectreSelection -Message 'Install policy' -Choices 'IfMissing', 'CheckOnly', 'Latest' -Color $script:PSMM_ColAccent
    $mode     = Read-SpectreSelection -Message 'Mode' -Choices 'Load', 'InstallOnly', 'Ignore' -Color $script:PSMM_ColAccent
    $pre      = Read-SpectreSelection -Message 'Versions' -Choices 'stable only', 'allow prereleases' -Color $script:PSMM_ColAccent
    $new = Resolve-PSMMEntry -Raw ([pscustomobject]@{
        Name = $name; FriendlyName = $friendly; Description = $desc; Install = $install; Mode = $mode
        Prerelease = ($pre -eq 'allow prereleases')
    }) -Source $target -Writable $true
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
    if (-not (Read-SpectreConfirm -Message "Delete '$(ConvertTo-PSMMSafe $Entry.Name)' from $(ConvertTo-PSMMSafe (Split-Path $Entry.Source -Leaf))?" -DefaultAnswer 'n')) { return $false }
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
