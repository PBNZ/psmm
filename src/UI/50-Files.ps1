# 50-Files.ps1 — config-file manager: list files, toggle Enabled, apply to
# session, create (from scenario templates, #29), move, Includes wiring.

function script:Build-PSMMFilesView {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Metas,
        [string]$StatusMarkup
    )
    if (Test-PSMMWinTooSmall) { return (Get-PSMMTooSmallView) }
    $n = $Metas.Count
    $win = Get-PSMMWinSize
    $vp = Get-PSMMViewport -State $State -Count $n -Rows ($win.Height - 12)
    $rows = [System.Collections.Generic.List[string[]]]::new()
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        $m = $Metas[$i]
        $leaf = if ($m.Kind -eq 'inline') { 'profile inline' } else { Split-Path $m.Path -Leaf }
        $nm = ConvertTo-PSMMSafe $leaf
        if ($i -eq $State.Cursor) { $nm = "[bold $script:PSMM_ColAccent]$nm[/]" }
        $on = if ($m.Enabled) { "[$script:PSMM_ColOk]on[/]" } else { "[$script:PSMM_ColErr]off[/]" }
        $rw = if ($m.Writable) { 'rw' } else { 'ro' }
        $fl = if ($m.IncludesIgnored) { "[$script:PSMM_ColWarn]![/]" } else { ' ' }
        $rows.Add([string[]]@($nm, $m.Kind, $on, $rw, "$($m.ModuleCount)", $fl))
    }
    $T = New-PSMMTable -Headers @('file', 'kind', 'on', 'rw', 'mods', '!') -Rows $rows -CursorRow ($State.Cursor - $vp.First)
    $pos = Get-PSMMPositionMarkup -State $State -Count $n -Viewport $vp
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHeaderBar -Breadcrumb @('home', 'files') -CountsMarkup "$pos [$script:PSMM_ColDim]- full path of current row below[/]")))
    $items.Add($T)
    if ($n) {
        $cur = $Metas[$State.Cursor]
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColMute]$(ConvertTo-PSMMSafe $cur.Path)[/]"))
        if ($cur.IncludesIgnored) { $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColWarn]! this file has an Includes section that is being ignored (main config only)[/]")) }
    }
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('space=enable/disable+save', 'a=apply to session', 'n=new config (templates)', 'm=move file'))))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('left=back') -NoLegend)))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", '?=help', 'esc=back', '^q=quit'))))
    foreach ($w in @(Get-PSMMWarning | Select-Object -First 4)) { $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColWarn]$(ConvertTo-PSMMSafe $w)[/]")) }
    if ($StatusMarkup) { $items.Add([Spectre.Console.Markup]::new($StatusMarkup)) }
    [Spectre.Console.Rows]::new($items)
}

# Config file manager loop.
function script:Show-PSMMFiles {
    $ui = $script:PSMM_UI
    $st = New-PSMMListState
    $st.Status = ''
    while ($true) {
        if ($ui.HardQuit -or $ui.Goto) { return }
        $cmd = @{ Name = $null }
        Clear-PSMMScreen
        Invoke-PSMMLive -Body {
            param($ctx)
            while ($true) {
                if ($script:PSMM_UI.HardQuit) { return }
                $metas = @((Get-PSMMFileMeta).Values)
                $ctx.UpdateTarget((Build-PSMMFilesView -State $st -Metas $metas -StatusMarkup $st.Status))
                $ctx.Refresh()
                $k = Read-PSMMKeyResize
                if ($null -eq $k) { continue }
                if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true; return }
                if ($k.KeyChar -eq 'g') {
                    $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMFilesView -State $st -Metas $metas -StatusMarkup $st.Status)
                    if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                    continue
                }
                if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
                $st.Status = ''
                if (Invoke-PSMMListNav -State $st -KeyInfo $k -Count $metas.Count) { continue }
                # left/right: same everywhere (gh#7). A config file has no
                # sub-screen, so right says so rather than doing nothing.
                $drill = Get-PSMMDrillKey -KeyInfo $k
                if ($drill -eq 'out') { return }
                if ($drill -eq 'in') { $st.Status = Get-PSMMNoDrillStatus; continue }
                switch ($k.Key) {
                    ([ConsoleKey]::Spacebar) {
                        $m = $metas[$st.Cursor]
                        if ($m.Kind -eq 'inline' -or -not $m.Writable) { $st.Status = "[$script:PSMM_ColErr]read-only - cannot toggle[/]" }
                        else {
                            $m.Enabled = -not $m.Enabled
                            Save-PSMMFile -Path $m.Path -Entries (Get-PSMMAllEntries)
                            $script:PSMM_UI.Dirty = $true
                            $st.Status = "[$script:PSMM_ColOk]saved ($(if ($m.Enabled) { 'enabled' } else { 'disabled' })) - 'a' applies load/unload changes[/]"
                        }
                        continue
                    }
                    ([ConsoleKey]::A) { $cmd.Name = 'apply'; return }
                    ([ConsoleKey]::N) { $cmd.Name = 'new'; return }
                    ([ConsoleKey]::M) { $cmd.Name = 'move'; return }
                    ([ConsoleKey]::Escape) { return }
                    default { if ($k.KeyChar -eq '?') { $cmd.Name = 'help'; return } }
                }
            }
        }
        if ($ui.HardQuit) { return }

        # full-screen follow-ups (prompts cannot run inside the live display)
        if ($ui.Dirty) { Sync-PSMMUIEntries -FullScan }
        switch ($cmd.Name) {
            'apply'     { Invoke-PSMMApply }
            'new'       { New-PSMMConfigFile }
            'move'      { $metas = @((Get-PSMMFileMeta).Values); if ($metas.Count) { Move-PSMMConfigFile -Meta $metas[$st.Cursor] } }
            'help'      { Show-PSMMHelpScreen -Topic 'files' }
            default     { return }
        }
        if ($ui.Dirty) { Sync-PSMMUIEntries -FullScan }
    }
}

# Apply config changes to the live session: import newly-active Load-mode
# modules; unload loaded modules that are managed but no longer active.
function script:Invoke-PSMMApply {
    $ui = $script:PSMM_UI
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Apply config changes[/]"
    $activeEntries = @(Get-PSMMEntry)
    $active = @{}; foreach ($e in $activeEntries) { if ($e.Name) { $active[$e.Name] = $e } }
    $managed = @{}; foreach ($e in (Get-PSMMAllEntries)) { if ($e.Name) { $managed[$e.Name] = $true } }
    # cloud-only check up front, one confirm for the whole batch (per-module
    # prompts would be noise): cancelling skips the apply entirely
    foreach ($e in $activeEntries) {
        if ($e.Mode -eq 'Load' -and -not (Get-Module -Name $e.Name)) {
            if (-not (Confirm-PSMMCloudHydration -ModuleName $e.Name)) {
                Write-PSMMLine "[$script:PSMM_ColMute]apply cancelled (cloud-only files not downloaded)[/]"
                $null = Wait-PSMMKey
                return
            }
        }
    }
    $did = 0
    foreach ($e in $activeEntries) {
        if ($e.Mode -eq 'Load' -and -not (Get-Module -Name $e.Name)) {
            Write-PSMMLine "[$script:PSMM_ColAccent]loading $(ConvertTo-PSMMSafe $e.Name)...[/]"
            try { Import-PSMMModuleTimed -Entry $e; $did++ }
            catch { Write-PSMMLine "[$script:PSMM_ColErr]  $(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
        }
    }
    foreach ($m in @(Get-Module)) {
        if (-not ($managed.ContainsKey($m.Name) -and -not $active.ContainsKey($m.Name))) { continue }
        # $managed includes entries from DISABLED files, so disabling the file
        # that holds psmm's seeded UI-dependency entry (or your own psmm entry)
        # used to make apply unload psmm's engine - or psmm itself - out from
        # under the running manager. Verified before fixing (gh#16).
        if (Test-PSMMOwnModule -Name $m.Name) {
            Write-PSMMLine "[$script:PSMM_ColMute]keeping $(ConvertTo-PSMMSafe $m.Name) - psmm's own, never unloaded[/]"
            continue
        }
        Write-PSMMLine "[$script:PSMM_ColAccent]unloading $(ConvertTo-PSMMSafe $m.Name) (no longer active)...[/]"
        try { Remove-Module -Name $m.Name -Force -ErrorAction Stop; $did++ }
        catch { Write-PSMMLine "[$script:PSMM_ColErr]  $(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
    }
    $ui.Dirty = $true
    Write-PSMMLine "[$script:PSMM_ColOk]$did change(s) applied.[/]"
    $null = Wait-PSMMKey
}

# Scenario templates shipped with the module (#29). Key = menu label.
function script:Get-PSMMConfigTemplate {
    [CmdletBinding()] param()
    $dir = Join-Path $script:PSMMRoot 'Configs'
    $templates = [ordered]@{ 'blank (example entry only)' = $null }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'scenario-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $label = ($f.BaseName -replace '^scenario-', '') -replace '-', ' '
        $templates[$label] = $f.FullName
    }
    $templates
}

function script:New-PSMMConfigFile {
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Create config file[/]"
    $main = Get-PSMMMainConfigPath
    $prof = Get-PSMMProfileConfigPath
    $opts = @()
    if (-not (Test-Path -LiteralPath $main)) { $opts += "main: $main" }
    if ($prof -and -not (Test-Path -LiteralPath $prof)) { $opts += "profile dir: $prof" }
    $opts += 'custom path...'
    $pick = Read-SpectreSelection -Message 'Where?' -Choices $opts -Color $script:PSMM_ColAccent
    $path = switch -Wildcard ($pick) {
        'main:*'        { $main }
        'profile dir:*' { $prof }
        default         { Read-PSMMText -Message 'Full path for the new .json' }
    }
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if (Test-Path -LiteralPath $path) { Write-PSMMLine "[$script:PSMM_ColErr]File already exists - not overwriting.[/]"; $null = Wait-PSMMKey; return }

    # scenario templates (#29)
    $templates = Get-PSMMConfigTemplate
    $tpl = Read-SpectreSelection -Message 'Start from' -Choices @($templates.Keys) -Color $script:PSMM_ColAccent
    $tplPath = $templates[$tpl]

    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $isMain = ($path -eq $main)
    if ($tplPath) {
        Copy-Item -LiteralPath $tplPath -Destination $path
        if ($isMain) {
            # main config carries an Includes array; add it if the template lacks one
            try {
                $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if (-not $obj.PSObject.Properties['Includes']) {
                    $obj | Add-Member -NotePropertyName Includes -NotePropertyValue @()
                    ($obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $path -Encoding utf8
                }
            } catch { }
        }
        Write-PSMMLine "[$script:PSMM_ColOk]Created $(ConvertTo-PSMMSafe $path) from the '$tpl' template.[/]"
        Write-PSMMLine "[$script:PSMM_ColMute]All template modules are set to Mode=Ignore - flip the ones you want to Load/InstallOnly.[/]"
    } else {
        Get-PSMMExampleConfigJson -IsMain $isMain | Set-Content -LiteralPath $path -Encoding utf8
        Write-PSMMLine "[$script:PSMM_ColOk]Created $(ConvertTo-PSMMSafe $path) (example content, sample module set to Ignore).[/]"
    }
    if (-not $isMain -and $path -ne $prof) {
        Write-PSMMLine "[$script:PSMM_ColWarn]Note: this path is not auto-discovered. Add it to the main config's Includes (or `$PSMM_JsonPath).[/]"
        $mainMeta = (Get-PSMMFileMeta)[$main]
        if ($mainMeta -and $mainMeta.Writable) {
            if (Read-SpectreConfirm -Message 'Add it to the main config Includes now?' -DefaultAnswer 'y') {
                $mainMeta.Includes = @($mainMeta.Includes) + $path
                Save-PSMMFile -Path $main -Entries (Get-PSMMAllEntries)
                Write-PSMMLine "[$script:PSMM_ColOk]Added to Includes.[/]"
            }
        }
    }
    $script:PSMM_UI.Dirty = $true
    $null = Wait-PSMMKey
}

function script:Move-PSMMConfigFile {
    param([Parameter(Mandatory)] $Meta)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Move $(ConvertTo-PSMMSafe (Split-Path $Meta.Path -Leaf))[/]"
    if ($Meta.Kind -eq 'inline') { Write-PSMMLine "[$script:PSMM_ColErr]The inline profile block cannot be moved.[/]"; $null = Wait-PSMMKey; return }
    $dir = Read-PSMMText -Message 'Target folder'
    if ([string]::IsNullOrWhiteSpace($dir)) { return }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-PSMMLine "[$script:PSMM_ColErr]Folder not found.[/]"; $null = Wait-PSMMKey; return }
    $new = Join-Path $dir (Split-Path $Meta.Path -Leaf)
    if (Test-Path -LiteralPath $new) { Write-PSMMLine "[$script:PSMM_ColErr]A file with that name already exists there.[/]"; $null = Wait-PSMMKey; return }
    try { Move-Item -LiteralPath $Meta.Path -Destination $new -ErrorAction Stop }
    catch { Write-PSMMLine "[$script:PSMM_ColErr]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]"; $null = Wait-PSMMKey; return }
    Write-PSMMLine "[$script:PSMM_ColOk]Moved to $(ConvertTo-PSMMSafe $new).[/]"
    # discovery follow-up: keep the file reachable
    $main = Get-PSMMMainConfigPath
    $mainMeta = (Get-PSMMFileMeta)[$main]
    $wasIncluded = $mainMeta -and (@($mainMeta.Includes) -contains $Meta.Path)
    if ($wasIncluded) {
        $mainMeta.Includes = @(@($mainMeta.Includes | Where-Object { $_ -ne $Meta.Path }) + $new)
        Save-PSMMFile -Path $main -Entries (Get-PSMMAllEntries)
        Write-PSMMLine "[$script:PSMM_ColOk]Main config Includes updated to the new path.[/]"
    } elseif ($Meta.Kind -in 'legacy', 'profile') {
        Write-PSMMLine "[$script:PSMM_ColWarn]The new location may not be auto-discovered.[/]"
        if ($mainMeta -and $mainMeta.Writable) {
            if (Read-SpectreConfirm -Message 'Add the new path to the main config Includes?' -DefaultAnswer 'y') {
                $mainMeta.Includes = @($mainMeta.Includes) + $new
                Save-PSMMFile -Path $main -Entries (Get-PSMMAllEntries)
                Write-PSMMLine "[$script:PSMM_ColOk]Added to Includes.[/]"
            }
        }
    }
    $script:PSMM_UI.Dirty = $true
    $null = Wait-PSMMKey
}
