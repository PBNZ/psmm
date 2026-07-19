# 75-Paths.ps1 — module locations screen: every PSModulePath entry with
# OneDrive/cloud-placeholder diagnostics, download (hydrate) and pin actions,
# and management of the primary (CurrentUser) module location via the
# documented powershell.config.json PSModulePath override.

function script:Build-PSMMPathsView {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Infos,
        [string]$StatusMarkup
    )
    if (Test-PSMMWinTooSmall) { return (Get-PSMMTooSmallView) }
    $n = $Infos.Count
    $win = Get-PSMMWinSize
    $vp = Get-PSMMViewport -State $State -Count $n -Rows ($win.Height - 14)
    $T = [Spectre.Console.Table]::new()
    $T.Border = [Spectre.Console.TableBorder]::Rounded
    foreach ($h in ' ', '#', 'Path', 'Notes') { [void][Spectre.Console.TableExtensions]::AddColumn($T, $h) }
    for ($i = $vp.First; $i -le $vp.Last; $i++) {
        $p = $Infos[$i]
        $nm = ConvertTo-PSMMSafe (Get-PSMMTrunc $p.Path ([Math]::Max(20, $win.Width - 45)))
        if ($i -eq $State.Cursor) { $nm = "[$script:PSMM_ColAccent]$nm[/]" }
        $notes = @()
        if ($p.First) { $notes += '[deepskyblue1]first[/]' }
        if ($p.UserDefault) { $notes += 'user default' }
        if ($p.OneDrive) { $notes += '[orange1]onedrive[/]' }
        if (-not $p.Exists) { $notes += '[indianred1]missing[/]' }
        [void][Spectre.Console.TableExtensions]::AddRow($T, [string[]]@(
                $(if ($i -eq $State.Cursor) { "[$script:PSMM_ColAccent]>[/]" } else { ' ' }),
                "$($p.Order + 1)", $nm, ($notes -join ' ')))
    }
    $pos = Get-PSMMPositionMarkup -State $State -Count $n -Viewport $vp
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColAccent]Module locations[/] [$script:PSMM_ColMute](`$env:PSModulePath, search order = list order)[/]$pos"))
    $items.Add($T)

    # OneDrive diagnosis: pwsh derives the FIRST (CurrentUser) entry from the
    # Documents known folder; OneDrive folder backup / KFM policy moves it.
    $first = if ($n) { $Infos[0] } else { $null }
    if ($first -and $first.OneDrive) {
        $items.Add([Spectre.Console.Markup]::new('[orange1]your primary module location is inside OneDrive[/]'))
        $items.Add([Spectre.Console.Markup]::new("[$script:PSMM_ColMute]this is PowerShell's default when OneDrive backs up the Documents folder (a common org policy," +
            ' not something you did). cloud-only files there can stall or fail module loading -' +
            ' d downloads them, k keeps the folder on this device, s moves the primary location.[/]'))
    }
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('d=download cloud-only files', 'k=keep on device (pin)'))))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMHint -Pairs @('s=set primary location', 'r=remove primary override'))))
    $items.Add([Spectre.Console.Markup]::new((Get-PSMMPersistentHint -Pairs @("g=goto$([char]0x2026)", '?=help', 'esc=back', '^q=quit'))))
    if ($StatusMarkup) { $items.Add([Spectre.Console.Markup]::new($StatusMarkup)) }
    [Spectre.Console.Rows]::new($items)
}

function script:Show-PSMMPaths {
    $ui = $script:PSMM_UI
    $st = New-PSMMListState
    $st.Status = ''
    while ($true) {
        if ($ui.HardQuit -or $ui.Goto) { return }
        $infos = @(Get-PSMMModulePathInfo)
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
                    $dest = Read-PSMMGotoKey -BaseRenderable (Build-PSMMPathsView -State $st -Infos $infos -StatusMarkup $st.Status) -Context $ctx
                    if ($dest) { $script:PSMM_UI.Goto = $dest; return }
                    continue
                }
                if (Test-PSMMHomeKey $k) { $script:PSMM_UI.Goto = 'home'; return }
                $st.Status = ''
                if (Invoke-PSMMListNav -State $st -KeyInfo $k -Count $infos.Count) { continue }
                switch ($k.Key) {
                    ([ConsoleKey]::D)      { $cmd.Name = 'download'; return }
                    ([ConsoleKey]::K)      { $cmd.Name = 'pin'; return }
                    ([ConsoleKey]::S)      { $cmd.Name = 'setprimary'; return }
                    ([ConsoleKey]::R)      { $cmd.Name = 'clearprimary'; return }
                    ([ConsoleKey]::Escape) { return }
                    default { if ($k.KeyChar -eq '?') { $cmd.Name = 'help'; return } }
                }
            }
        }
        if ($ui.HardQuit -or $ui.Goto) { return }
        $cur = if ($infos.Count) { $infos[[Math]::Min($st.Cursor, $infos.Count - 1)] } else { $null }
        switch ($cmd.Name) {
            'help' { Show-PSMMHelpScreen -Topic 'paths' }
            'download' {
                if ($cur) { $st.Status = Invoke-PSMMPathDownload -Info $cur }
            }
            'pin' {
                if ($cur) { $st.Status = Invoke-PSMMPathPin -Info $cur }
            }
            'setprimary' { $st.Status = Set-PSMMPrimaryLocationUI }
            'clearprimary' {
                Clear-PSMMScreen
                Write-PSMMLine "[$script:PSMM_ColAccent]Remove the primary-location override[/]"
                $cfg = Get-PSMMUserConfigJsonPath
                Write-PSMMLine "[grey66]removes the PSModulePath key from $(ConvertTo-PSMMSafe "$cfg") - pwsh falls back to the Documents default[/]"
                if (Read-SpectreConfirm -Message 'Remove the override?' -DefaultAnswer 'n') {
                    try {
                        $null = Set-PSMMUserModulePath -Clear
                        $st.Status = '[green3]override removed - takes effect in NEW pwsh sessions[/]'
                    } catch { $st.Status = "[indianred1]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
                } else { $st.Status = '[grey66]cancelled[/]' }
            }
            default { return }
        }
    }
}

# Scan one PSModulePath entry for cloud-only files and hydrate them, with a
# confirm first (downloads can take a while) and per-file progress.
function script:Invoke-PSMMPathDownload {
    param([Parameter(Mandatory)] $Info)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Download cloud-only files[/]"
    Write-PSMMLine "[grey66]$(ConvertTo-PSMMSafe $Info.Path)[/]"
    if (-not $Info.Exists) { $null = Wait-PSMMKey; return '[orange1]path does not exist[/]' }
    Write-PSMMLine 'scanning for cloud-only placeholder files...'
    $files = @(Get-PSMMCloudOnlyFile -Path $Info.Path)
    if (-not $files.Count) { $null = Wait-PSMMKey; return '[green3]no cloud-only files - everything is already on disk[/]' }
    $mb = [Math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
    Write-PSMMLine "[orange1]$($files.Count) cloud-only file(s), $mb MB to download - this can take a while on a slow connection[/]"
    if (-not (Read-SpectreConfirm -Message "Download $($files.Count) file(s) now?" -DefaultAnswer 'y')) { return '[grey66]download cancelled[/]' }
    $r = Invoke-PSMMFileHydration -Files $files -OnProgress {
        param($i, $total, $f)
        Write-PSMMLine "[$script:PSMM_ColMute]  ($i/$total) $(ConvertTo-PSMMSafe $f.Name)[/]"
    }
    foreach ($e in $r.Errors | Select-Object -First 5) { Write-PSMMLine "[indianred1]  $(ConvertTo-PSMMSafe $e)[/]" }
    $null = Wait-PSMMKey
    if ($r.Failed) { "[orange1]downloaded $($r.Ok), $($r.Failed) failed[/]" } else { "[green3]downloaded $($r.Ok) file(s)[/]" }
}

# Pin one PSModulePath entry so OneDrive keeps it permanently on this device.
function script:Invoke-PSMMPathPin {
    param([Parameter(Mandatory)] $Info)
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Keep on this device (pin)[/]"
    Write-PSMMLine "[grey66]$(ConvertTo-PSMMSafe $Info.Path)[/]"
    if (-not $Info.OneDrive) { $null = Wait-PSMMKey; return '[orange1]not a OneDrive path - nothing to pin[/]' }
    if (-not $Info.Exists) { $null = Wait-PSMMKey; return '[orange1]path does not exist[/]' }
    Write-PSMMLine 'marks every file "always keep on this device"; OneDrive downloads them in the background.'
    if (-not (Read-SpectreConfirm -Message 'Pin the whole folder?' -DefaultAnswer 'y')) { return '[grey66]pin cancelled[/]' }
    try {
        Invoke-PSMMPinPath -Path $Info.Path
        '[green3]pinned - OneDrive is downloading the files in the background[/]'
    } catch { "[indianred1]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
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
    Write-PSMMLine "[orange1]$($files.Count) file(s) of $(ConvertTo-PSMMSafe $ModuleName) are OneDrive cloud-only ($mb MB)[/]"
    Write-PSMMLine '[grey66]they must be downloaded before loading; this can take a while on a slow connection[/]'
    if (-not (Read-SpectreConfirm -Message 'Download now and continue?' -DefaultAnswer 'y')) { return $false }
    $r = Invoke-PSMMFileHydration -Files $files -OnProgress {
        param($i, $total, $f)
        Write-PSMMLine "[$script:PSMM_ColMute]  downloading ($i/$total) $(ConvertTo-PSMMSafe $f.Name)[/]"
    }
    if ($r.Failed) { Write-PSMMLine "[orange1]$($r.Failed) file(s) failed to download - the load may still fail[/]" }
    $true
}

# Prompt for and write the CurrentUser module-path override.
function script:Set-PSMMPrimaryLocationUI {
    Clear-PSMMScreen
    Write-PSMMLine "[$script:PSMM_ColAccent]Set the primary (CurrentUser) module location[/]"
    $cfg = Get-PSMMUserConfigJsonPath
    Write-PSMMLine "[grey66]writes the documented PSModulePath override to $(ConvertTo-PSMMSafe "$cfg")[/]"
    Write-PSMMLine '[grey66]new pwsh sessions will LOOK for CurrentUser modules there.[/]'
    # each Write-PSMMLine is its own Markup: tags must balance PER LINE
    Write-PSMMLine '[orange1]caveat (documented): Install-Module / Install-PSResource still INSTALL to the[/]'
    Write-PSMMLine '[orange1]default Documents-derived location - move existing module folders yourself, or[/]'
    Write-PSMMLine '[orange1]keep using d (download) / k (pin) to make the OneDrive copies reliable.[/]'
    $suggestion = if ($IsWindows) { Join-Path $HOME 'PowerShell\Modules' } else { '' }
    $path = Read-SpectreText -Message 'New primary module path (empty cancels)' -DefaultAnswer $suggestion -AllowEmpty
    if ([string]::IsNullOrWhiteSpace($path)) { return '[grey66]cancelled[/]' }
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            if (Read-SpectreConfirm -Message "Create $path now?" -DefaultAnswer 'y') {
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
        "[green3]primary location set - first in this session now, and in every NEW pwsh session ($(ConvertTo-PSMMSafe $path))[/]"
    } catch { "[indianred1]$(ConvertTo-PSMMSafe $_.Exception.Message)[/]" }
}
