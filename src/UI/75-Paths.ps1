# 75-Paths.ps1 — module locations screen: every PSModulePath entry with
# OneDrive/cloud-placeholder diagnostics, download (hydrate) and pin actions,
# adding a location, moving a location's contents elsewhere, and management of
# the primary (CurrentUser) module location via the documented
# powershell.config.json PSModulePath override.

function script:Build-PSMMPathsView {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Infos,
        [string]$StatusMarkup
    )
    if (Test-PSMMWinTooSmall) { return (Get-PSMMTooSmallView) }
    $n = $Infos.Count
    $win = Get-PSMMWinSize
    $vp = Get-PSMMViewport -State $State -Count $n -Rows ($win.Height - 16)
    $rows = [System.Collections.Generic.List[string[]]]::new()
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        $p = $Infos[$i]
        $nm = ConvertTo-PSMMSafe (Get-PSMMTrunc $p.Path ([Math]::Max(20, $win.Width - 52)))
        if ($i -eq $State.Cursor) { $nm = "[bold $script:PSMM_ColAccent]$nm[/]" }
        $notes = @()
        if ($p.First) { $notes += "[$script:PSMM_ColAccent]first[/]" }
        if ($p.UserDefault) { $notes += 'user default' }
        if ($p.OneDrive) { $notes += "[$script:PSMM_ColWarn]onedrive[/]" }
        if (-not $p.Exists) { $notes += "[$script:PSMM_ColErr]missing[/]" }
        elseif ($p.PSObject.Properties['Writable'] -and -not $p.Writable) { $notes += "[$script:PSMM_ColDim]ro[/]" }
        $mods = if ($p.PSObject.Properties['ModuleCount'] -and $null -ne $p.ModuleCount) { "$($p.ModuleCount)" } else { '-' }
        $rows.Add([string[]]@("$($p.Order + 1)", $nm, "[$script:PSMM_ColDim]$mods[/]", ($notes -join ' ')))
    }
    $T = New-PSMMTable -Headers @('#', 'path', 'modules', 'notes') -Rows $rows -CursorRow ($State.Cursor - $vp.First)
    $pos = Get-PSMMPositionMarkup -State $State -Count $n -Viewport $vp
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb @('home', 'paths') -CountsMarkup "[$script:PSMM_ColDim](`$env:PSModulePath, search order = list order)[/]$pos")))
    $items.Add($T)

    # OneDrive diagnosis: pwsh derives the FIRST (CurrentUser) entry from the
    # Documents known folder; OneDrive folder backup / KFM policy moves it.
    # Wrapped at a readable measure - this paragraph used to run the full
    # terminal width (gh#11).
    $first = if ($n) { $Infos[0] } else { $null }
    if ($first -and $first.OneDrive) {
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColWarn]your primary module location is inside OneDrive[/]"))
        $prose = "this is PowerShell's default when OneDrive backs up the Documents folder (a common org policy, " +
                 'not something you did). cloud-only files there can stall or fail module loading - d downloads ' +
                 'them, k keeps the folder on this device, s moves the primary location, m moves the modules ' +
                 'that are already there.'
        foreach ($l in (Get-PSMMProseMarkup -Text $prose)) { $items.Add([Spectre.Console.Markup]::new($l)) }
    }
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('d=download cloud-only files', 'k=keep on device (pin)', 'n=add a location'))))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('s=set primary location', 'r=remove primary override', 'm=move contents elsewhere'))))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('left/right=back / details') -NoLegend)))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", '?=help', 'esc=back', '^q=quit'))))
    if ($StatusMarkup) { $items.Add([Spectre.Console.Markup]::new($StatusMarkup)) }
    [Spectre.Console.Rows]::new($items)
}

# One PSModulePath entry, enriched for the screen: writability and how many
# module folders it holds. Done ONCE per screen refresh, never per frame - it
# is a directory listing per root, and one of those roots may be in OneDrive.
function script:Get-PSMMPathScreenInfo {
    @(foreach ($p in (Get-PSMMModulePathInfo)) {
            $count = $null
            $writable = $false
            if ($p.Exists) {
                try { $count = @(Get-ChildItem -LiteralPath $p.Path -Directory -Force -ErrorAction SilentlyContinue).Count } catch { }
                $writable = Test-PSMMDirectoryWritable -Path $p.Path
            }
            $p | Add-Member -NotePropertyName ModuleCount -NotePropertyValue $count -Force
            $p | Add-Member -NotePropertyName Writable -NotePropertyValue $writable -Force
            $p
        })
}

function script:Show-PSMMPaths {
    $ui = $script:PSMM_UI
    $st = New-PSMMListState
    $st.Status = ''
    while ($true) {
        if ($ui.HardQuit -or $ui.Goto) { return }
        $infos = @(Get-PSMMPathScreenInfo)
        $cmd = @{ Name = $null }
        Clear-PSMMScreen
        Invoke-PSMMLive -Body {
            param($ctx)
            while ($true) {
                if ($script:PSMM_UI.HardQuit) { return }
                $ctx.UpdateTarget((Build-PSMMPathsView -State $st -Infos $infos -StatusMarkup $st.Status))
                $ctx.Refresh()
                $k = Read-PSMMKeyResize
                if ($null -eq $k) { continue }
                if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; return }
                if ($k.KeyChar -eq 'g') {
                    $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMPathsView -State $st -Infos $infos -StatusMarkup $st.Status)
                    if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                    continue
                }
                if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
                $st.Status = ''
                if (Invoke-PSMMListNav -State $st -KeyInfo $k -Count $infos.Count) { continue }
                # left/right work here exactly as everywhere else (gh#7)
                $drill = Get-PSMMDrillKey -KeyInfo $k
                if ($drill -eq 'out') { return }
                if ($drill -eq 'in') { $cmd.Name = 'details'; return }
                # verbs are plain letters: a ctrl chord must never trigger one
                # (ctrl+m in particular is Enter on many terminals, and 'm'
                # moves module folders)
                $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
                switch ($k.Key) {
                    ([ConsoleKey]::Enter)  { $cmd.Name = 'details'; return }
                    ([ConsoleKey]::D)      { if (-not $ctrl) { $cmd.Name = 'download'; return }; continue }
                    ([ConsoleKey]::K)      { if (-not $ctrl) { $cmd.Name = 'pin'; return }; continue }
                    ([ConsoleKey]::S)      { if (-not $ctrl) { $cmd.Name = 'setprimary'; return }; continue }
                    ([ConsoleKey]::R)      { if (-not $ctrl) { $cmd.Name = 'clearprimary'; return }; continue }
                    ([ConsoleKey]::N)      { if (-not $ctrl) { $cmd.Name = 'newlocation'; return }; continue }
                    ([ConsoleKey]::M)      { if (-not $ctrl) { $cmd.Name = 'movecontent'; return }; continue }
                    ([ConsoleKey]::Escape) { return }
                    default { if ($k.KeyChar -eq '?') { $cmd.Name = 'help'; return } }
                }
            }
        }
        if ($ui.HardQuit -or $ui.Goto) { return }
        $cur = if ($infos.Count) { $infos[[Math]::Min($st.Cursor, $infos.Count - 1)] } else { $null }
        switch ($cmd.Name) {
            'help' { Show-PSMMHelpScreen -Topic 'paths' }
            'details' { if ($cur) { Show-PSMMPathDetails -Info $cur } }
            'download' {
                if ($cur) { $st.Status = Invoke-PSMMPathDownload -Info $cur }
            }
            'pin' {
                if ($cur) { $st.Status = Invoke-PSMMPathPin -Info $cur }
            }
            'newlocation' { $st.Status = Add-PSMMLocationUI }
            'movecontent' { if ($cur) { $st.Status = Move-PSMMLocationUI -Info $cur -All $infos } }
            'setprimary' { $st.Status = Set-PSMMPrimaryLocationUI }
            'clearprimary' {
                Clear-PSMMScreen
                Write-PSMMLine "[$script:PSMM_ColAccent]Remove the primary-location override[/]"
                $cfg = Get-PSMMUserConfigJsonPath
                Write-PSMMLine "[$script:PSMM_ColMute]removes the PSModulePath key from $(ConvertTo-PSMMSafe "$cfg") - pwsh falls back to the Documents default[/]"
                if (Read-SpectreConfirm -Message 'Remove the override?' -DefaultAnswer 'n') {
                    try {
                        $null = Set-PSMMUserModulePath -Clear
                        $st.Status = "[$script:PSMM_ColOk]override removed - takes effect in NEW pwsh sessions[/]"
                    } catch { $st.Status = "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                } else { $st.Status = "[$script:PSMM_ColMute]cancelled[/]" }
            }
            default { return }
        }
    }
}

# What one location holds, as a pager (the drill-in target for right/enter).
function script:Show-PSMMPathDetails {
    param([Parameter(Mandatory)] $Info)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]reading $(ConvertTo-PSMMSafe $Info.Path)...[/]"
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("path            $($Info.Path)")
    $lines.Add("search order    $($Info.Order + 1)$(if ($Info.First) { ' (first - this is where PowerShell looks first)' })")
    $lines.Add("exists          $(if ($Info.Exists) { 'yes' } else { 'no' })")
    $lines.Add("writable        $(if ($Info.PSObject.Properties['Writable'] -and $Info.Writable) { 'yes' } else { 'no' })")
    $lines.Add("user default    $(if ($Info.UserDefault) { 'yes - derived from your Documents folder' } else { 'no' })")
    $lines.Add("onedrive        $(if ($Info.OneDrive) { 'yes - files here can be cloud-only placeholders' } else { 'no' })")
    $lines.Add('')
    $mods = @(Get-PSMMLocationModule -Path $Info.Path)
    $total = 0L
    foreach ($m in $mods) { $total += $m.Bytes }
    $lines.Add("$($mods.Count) module folder(s), $(Format-PSMMSize $total)")
    $lines.Add('')
    foreach ($m in ($mods | Sort-Object -Property @{ Expression = 'Bytes'; Descending = $true })) {
        $lines.Add(("  {0,-44} {1,4} version(s)  {2,10}" -f (Get-PSMMTrunc $m.Name 44), $m.Versions, (Format-PSMMSize $m.Bytes)))
    }
    Show-PSMMPager -Lines $lines -TitleMarkup "[$script:PSMM_ColAccent]Location details[/]" -Breadcrumb @('home', 'paths', 'details')
}

# Scan one PSModulePath entry for cloud-only files and hydrate them, with a
# concurrency prompt first (gh#14) and per-file progress.
function script:Invoke-PSMMPathDownload {
    param([Parameter(Mandatory)] $Info)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Download cloud-only files[/]"
    Write-PSMMLine "[$script:PSMM_ColMute]$(ConvertTo-PSMMSafe $Info.Path)[/]"
    if (-not $Info.Exists) { $null = Wait-PSMMKey; return "[$script:PSMM_ColWarn]path does not exist[/]" }
    Write-PSMMLine 'scanning for cloud-only placeholder files...'
    $files = @(Get-PSMMCloudOnlyFile -Path $Info.Path)
    if (-not $files.Count) { $null = Wait-PSMMKey; return "[$script:PSMM_ColOk]no cloud-only files - everything is already on disk[/]" }
    $mb = [Math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
    Write-PSMMLine "[$script:PSMM_ColWarn]$($files.Count) cloud-only file(s), $mb MB to download[/]"
    $parallel = Read-PSMMNumber -Title 'Download cloud-only files' `
        -Message "$($files.Count) file(s), $mb MB. Each download waits on OneDrive, so several at once finish much sooner than one after the other." `
        -Default (Get-PSMMHydrationDefault) -Min 1 -Max (Get-PSMMHydrationMax) `
        -MaxReason (Get-PSMMHydrationMaxReason) -Unit 'at a time'
    if ($null -eq $parallel) { return "[$script:PSMM_ColMute]download cancelled[/]" }
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]downloading $($files.Count) file(s), $parallel at a time[/]"
    $r = Invoke-PSMMFileHydration -Files $files -ThrottleLimit $parallel -OnProgress {
        param($i, $total, $f)
        Write-PSMMLine "[$script:PSMM_ColMute]  ($i/$total) $(ConvertTo-PSMMSafe $f.Name)[/]"
    }
    foreach ($e in $r.Errors | Select-Object -First 5) { Write-PSMMLine "[$script:PSMM_ColErr]  $(ConvertTo-PSMMSafe $e)[/]" }
    $null = Wait-PSMMKey
    if ($r.Failed) { "[$script:PSMM_ColWarn]downloaded $($r.Ok), $($r.Failed) failed[/]" } else { "[$script:PSMM_ColOk]downloaded $($r.Ok) file(s)[/]" }
}

# Pin one PSModulePath entry so OneDrive keeps it permanently on this device.
function script:Invoke-PSMMPathPin {
    param([Parameter(Mandatory)] $Info)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Keep on this device (pin)[/]"
    Write-PSMMLine "[$script:PSMM_ColMute]$(ConvertTo-PSMMSafe $Info.Path)[/]"
    if (-not $Info.OneDrive) { $null = Wait-PSMMKey; return "[$script:PSMM_ColWarn]not a OneDrive path - nothing to pin[/]" }
    if (-not $Info.Exists) { $null = Wait-PSMMKey; return "[$script:PSMM_ColWarn]path does not exist[/]" }
    Write-PSMMProse -Text 'marks every file "always keep on this device"; OneDrive downloads them in the background.'
    if (-not (Read-SpectreConfirm -Message 'Pin the whole folder?' -DefaultAnswer 'y')) { return "[$script:PSMM_ColMute]pin cancelled[/]" }
    try {
        Invoke-PSMMPinPath -Path $Info.Path
        "[$script:PSMM_ColOk]pinned - OneDrive is downloading the files in the background[/]"
    } catch { "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
}

# Foreground pre-load check: when a module's files are OneDrive cloud-only
# placeholders, warn, ask, and download them with per-file progress before
# the import touches them (a failed/stalled recall mid-import is much worse).
# Returns $false when the user cancelled.
function script:Confirm-PSMMCloudHydration {
    param([Parameter(Mandatory)][string]$ModuleName)
    $files = @(Get-PSMMModuleCloudOnlyFile -Name $ModuleName)
    if (-not $files.Count) { return $true }
    $mb = [Math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
    Write-PSMMLine "[$script:PSMM_ColWarn]$($files.Count) file(s) of $(ConvertTo-PSMMSafe $ModuleName) are OneDrive cloud-only ($mb MB)[/]"
    Write-PSMMProse -Text 'they must be downloaded before loading; this can take a while on a slow connection'
    if (-not (Read-SpectreConfirm -Message 'Download now and continue?' -DefaultAnswer 'y')) { return $false }
    $par = Get-PSMMHydrationDefault
    $r = Invoke-PSMMFileHydration -Files $files -ThrottleLimit $par -OnProgress {
        param($i, $total, $f)
        Write-PSMMLine "[$script:PSMM_ColMute]  downloading ($i/$total) $(ConvertTo-PSMMSafe $f.Name)[/]"
    }
    if ($r.Failed) { Write-PSMMLine "[$script:PSMM_ColWarn]$($r.Failed) file(s) failed to download - the load may still fail[/]" }
    $true
}

# Add a folder to the module search path, creating it when it does not exist
# yet (gh#12).
function script:Add-PSMMLocationUI {
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Add a module location[/]"
    Write-PSMMProse -Text ('PowerShell looks for modules in every folder on $env:PSModulePath, in order. ' +
        'Adding one here takes effect in this session immediately; persisting it makes new sessions see it too.')
    $suggestion = if ($IsWindows) { Join-Path $HOME 'PowerShell\Modules' } else { Join-Path $HOME '.local/share/powershell/Modules' }
    $path = Read-PSMMText -Message 'Folder (empty cancels)' -DefaultAnswer $suggestion -AllowEmpty
    if ([string]::IsNullOrWhiteSpace($path)) { return "[$script:PSMM_ColMute]cancelled[/]" }
    $path = "$path".Trim()
    if (Test-PSMMModulePathContains -Path $path) { $null = Wait-PSMMKey; return "[$script:PSMM_ColWarn]already on the module search path[/]" }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        if (-not (Read-SpectreConfirm -Message "$(ConvertTo-PSMMSafe $path) does not exist - create it?" -DefaultAnswer 'y')) { return "[$script:PSMM_ColMute]cancelled[/]" }
        try { New-Item -ItemType Directory -Force -Path $path | Out-Null }
        catch { $null = Wait-PSMMKey; return "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
    }
    if (-not (Test-PSMMDirectoryWritable -Path $path)) {
        $null = Wait-PSMMKey
        return "[$script:PSMM_ColErr]that folder is not writable - modules could be read from it, but never installed there[/]"
    }
    $where = Read-SpectreSelection -Message 'Search order' -Choices 'after the existing locations', 'first (searched before everything else)' -Color $script:PSMM_ColAccent
    $first = ($where -like 'first*')
    $null = Add-PSMMModulePath -Path $path -First:$first
    $note = "added to this session's module search path"
    if ($IsWindows) {
        Write-PSMMProse -Text ('psmm can persist this in your user PSModulePath environment variable, which PowerShell ' +
            'merges into every new session. It does not change where Install-PSResource installs to.')
        if ($first) {
            # be honest: PowerShell composes the final search path itself, and
            # a user-scope entry cannot be forced ahead of the CurrentUser
            # default - only s (set primary location) moves what comes first
            Write-PSMMProse -Text ('"first" applies to this session only. PowerShell builds the search order for a new ' +
                'session itself, so a persisted entry lands after the built-in locations - use s to change which ' +
                'location comes first for good.') -Colour $script:PSMM_ColWarn
        }
        if (Read-SpectreConfirm -Message 'Persist it for new sessions?' -DefaultAnswer 'y') {
            try {
                $null = Add-PSMMPersistentModulePath -Path $path
                $note = 'added to this session and persisted in your user PSModulePath'
            } catch { Write-PSMMLine "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
        }
    } else {
        Write-PSMMProse -Text 'to keep it for new sessions, add it to $env:PSModulePath in your $PROFILE.'
    }
    $null = Wait-PSMMKey
    "[$script:PSMM_ColOk]$note ($(ConvertTo-PSMMSafe $path))[/]"
}

# Move every module folder from one location to another (gh#13).
# Gated behind a typed phrase: this is destructive and sits two keystrokes
# away from plain navigation, so y/n is not enough.
function script:Move-PSMMLocationUI {
    param(
        [Parameter(Mandatory)] $Info,
        [Parameter(Mandatory)] $All
    )
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Move the contents of a module location[/]"
    Write-PSMMLine "[$script:PSMM_ColMute]from[/] [$script:PSMM_ColDim]$(ConvertTo-PSMMSafe $Info.Path)[/]"
    if (-not $Info.Exists) { $null = Wait-PSMMKey; return "[$script:PSMM_ColWarn]path does not exist[/]" }
    Write-PSMMLine 'reading the folder...'
    $mods = @(Get-PSMMLocationModule -Path $Info.Path)
    if (-not $mods.Count) { $null = Wait-PSMMKey; return "[$script:PSMM_ColOk]no module folders here - nothing to move[/]" }

    $targets = @($All | Where-Object {
            $_.Path.TrimEnd('\', '/') -ne $Info.Path.TrimEnd('\', '/') -and $_.Exists -and
            (Test-PSMMDirectoryWritable -Path $_.Path)
        } | Select-Object -ExpandProperty Path)
    if (-not $targets.Count) {
        Write-PSMMProse -Text 'No other writable location on the module search path. Add one first with n.' -Colour $script:PSMM_ColWarn
        $null = Wait-PSMMKey
        return "[$script:PSMM_ColWarn]no writable target location[/]"
    }
    $target = if ($targets.Count -eq 1) { $targets[0] } else { Read-SpectreSelection -Message 'Move everything to' -Choices $targets -Color $script:PSMM_ColAccent }
    if (-not $target) { return "[$script:PSMM_ColMute]move cancelled[/]" }

    # what will be skipped, decided BEFORE anything moves
    $loaded = @(Get-Module | Select-Object -ExpandProperty Name)
    $loadedHere = @($mods | Where-Object { $loaded -contains $_.Name } | Select-Object -ExpandProperty Name)
    $existing = @(Get-PSMMLocationModule -Path $target | Select-Object -ExpandProperty Name)
    $collide = @($mods | Where-Object { $existing -contains $_.Name } | Select-Object -ExpandProperty Name)
    $movable = @($mods | Where-Object { $loadedHere -notcontains $_.Name -and $collide -notcontains $_.Name })
    # size of what will ACTUALLY move, not of everything in the folder -
    # quoting the total next to the movable count overstates the operation
    $total = 0L
    foreach ($m in $movable) { $total += $m.Bytes }

    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Move module folders[/]"
    Write-PSMMLine "[$script:PSMM_ColMute]from[/] [$script:PSMM_ColDim]$(ConvertTo-PSMMSafe $Info.Path)[/]"
    Write-PSMMLine "[$script:PSMM_ColMute]to[/]   [$script:PSMM_ColDim]$(ConvertTo-PSMMSafe $target)[/]"
    Write-PSMMLine "[$script:PSMM_ColOk]$($movable.Count) of $($mods.Count) folder(s) will move[/] [$script:PSMM_ColMute]($(Format-PSMMSize $total))[/]"
    if ($loadedHere.Count) {
        Write-PSMMProse -Text "skipped, imported in this session (their files are in use): $($loadedHere -join ', ')" -Colour $script:PSMM_ColWarn
    }
    if ($collide.Count) {
        Write-PSMMProse -Text "skipped, already present in the target: $($collide -join ', ')" -Colour $script:PSMM_ColWarn
    }
    if (-not $movable.Count) { $null = Wait-PSMMKey; return "[$script:PSMM_ColWarn]nothing movable - everything is loaded or already there[/]" }
    if (-not (Read-PSMMConfirmPhrase -Phrase 'really move' -Warning 'Module folders are moved on disk. Anything that references the old path (shortcuts, scripts pinning a full path) will stop working.')) {
        return "[$script:PSMM_ColMute]move cancelled - nothing was touched[/]"
    }
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]moving $($movable.Count) folder(s)...[/]"
    # each skip carries the reason it was skipped, so the report is truthful
    $skip = @{}
    foreach ($n in $loadedHere) { $skip[$n] = 'imported in this session - unload it first' }
    foreach ($n in $collide) { $skip[$n] = 'a module of that name is already in the target' }
    $results = @(Move-PSMMLocationContent -Source $Info.Path -Target $target -Skip $skip -OnProgress {
            param($i, $n, $name)
            Write-PSMMLine "[$script:PSMM_ColMute]  ($i/$n) $(ConvertTo-PSMMSafe $name)[/]"
        })
    $moved = @($results | Where-Object Moved).Count
    foreach ($r in @($results | Where-Object { -not $_.Moved } | Select-Object -First 8)) {
        Write-PSMMLine "[$script:PSMM_ColWarn]  skipped $(ConvertTo-PSMMSafe $r.Name): $(ConvertTo-PSMMSafe $r.Reason)[/]"
    }
    $script:PSMM_UI.Dirty = $true
    $null = Wait-PSMMKey
    if ($moved -eq $results.Count) { "[$script:PSMM_ColOk]moved $moved module folder(s) to $(ConvertTo-PSMMSafe $target)[/]" }
    else { "[$script:PSMM_ColWarn]moved $moved of $($results.Count) - the rest were skipped[/]" }
}

# Prompt for and write the CurrentUser module-path override.
function script:Set-PSMMPrimaryLocationUI {
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Set the primary (CurrentUser) module location[/]"
    $cfg = Get-PSMMUserConfigJsonPath
    Write-PSMMLine "[$script:PSMM_ColMute]writes the documented PSModulePath override to $(ConvertTo-PSMMSafe "$cfg")[/]"
    Write-PSMMLine "[$script:PSMM_ColMute]new pwsh sessions will LOOK for CurrentUser modules there.[/]"
    Write-PSMMProse -Colour $script:PSMM_ColWarn -Text ('caveat (documented): Install-Module / Install-PSResource still INSTALL to the ' +
        'default Documents-derived location - move existing module folders yourself (m on this screen, or p in a ' +
        'module menu), or keep using d (download) / k (pin) to make the OneDrive copies reliable.')
    $suggestion = if ($IsWindows) { Join-Path $HOME 'PowerShell\Modules' } else { '' }
    $path = Read-PSMMText -Message 'New primary module path (empty cancels)' -DefaultAnswer $suggestion -AllowEmpty
    if ([string]::IsNullOrWhiteSpace($path)) { return "[$script:PSMM_ColMute]cancelled[/]" }
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            if (Read-SpectreConfirm -Message "Create $(ConvertTo-PSMMSafe $path) now?" -DefaultAnswer 'y') {
                New-Item -ItemType Directory -Force -Path $path | Out-Null
            }
        }
        $null = Set-PSMMUserModulePath -Path $path
        # The config override only applies to NEW sessions; prepend to the
        # live search path too so the new location is first - and visible in
        # the locations table - right away.
        $sep = [System.IO.Path]::PathSeparator
        $norm = $path.TrimEnd('\', '/')
        $rest = @($env:PSModulePath -split $sep |
            Where-Object { $_ -and ($_.TrimEnd('\', '/') -ne $norm) })
        $env:PSModulePath = (@($path) + $rest) -join $sep
        "[$script:PSMM_ColOk]primary location set - first in this session now, and in every NEW pwsh session ($(ConvertTo-PSMMSafe $path))[/]"
    } catch { "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
}
