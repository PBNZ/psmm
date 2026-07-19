# 05-Welcome.ps1 - the first-run welcome overlay: a new user has no reason
# to guess that 'g' hides the whole navigation layer, so the very first grid
# paint gets a small tips panel floating over it (same VT overlay as goto).
# Shown exactly once, ever - a marker file next to the main config remembers
# it (so $PSMM_MainConfigPath redirects it too, like the update-check cache).

function script:Get-PSMMWelcomePath {
    [CmdletBinding()] param()
    Join-Path (Split-Path -Parent (Get-PSMMMainConfigPath)) 'psmm-welcome.json'
}

function script:Test-PSMMWelcomeDue {
    [CmdletBinding()][OutputType([bool])] param()
    -not (Test-Path -LiteralPath (Get-PSMMWelcomePath) -ErrorAction Ignore)
}

function script:Set-PSMMWelcomeShown {
    [CmdletBinding()] param()
    $p = Get-PSMMWelcomePath
    try {
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir -ErrorAction Ignore)) {
            $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
        }
        @{ ShownAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json |
            Set-Content -LiteralPath $p -Encoding utf8 -ErrorAction Stop
    } catch { }   # an unwritable config dir must never break the TUI
}

# The panel: three tips, g first - that is the key nobody would guess.
function script:Build-PSMMWelcomePanel {
    $tips = @(
        @{ Key = 'g';     Label = 'goto';    Text = 'then a letter jumps to any screen, from anywhere' }
        @{ Key = '?';     Label = 'help';    Text = 'keys and tips for the screen you are on' }
        @{ Key = 'enter'; Label = 'actions'; Text = 'everything psmm can do with the highlighted module' }
    )
    $g = [Spectre.Console.Grid]::new()
    for ($c = 0; $c -lt 2; $c++) {
        $col = [Spectre.Console.GridColumn]::new()
        $col.Padding = [Spectre.Console.Padding]::new(0, 0, 2, 0)
        [void]$g.AddColumn($col)
    }
    foreach ($t in $tips) {
        [void][Spectre.Console.GridExtensions]::AddRow($g, [string[]]@(
            "[$script:PSMM_ColKey on $script:PSMM_ColCapsuleDim] $($t.Key) [/] [$script:PSMM_ColMute]$($t.Label)[/]",
            "[$script:PSMM_ColDim]$($t.Text)[/]"))
    }
    $items = [System.Collections.Generic.List[Spectre.Console.Rendering.IRenderable]]::new()
    $items.Add([Spectre.Console.Markup]::new(
        "[$script:PSMM_ColBrandFg on $script:PSMM_ColBrandBg] psmm [/] [default]welcome[/] [$script:PSMM_ColDim]$([char]0x2014) the three keys worth knowing[/]"))
    $items.Add($g)
    $items.Add([Spectre.Console.Markup]::new(
        "[$script:PSMM_ColDim]any key closes this $([char]0x00B7) it appears only once[/]"))
    $panel = [Spectre.Console.Panel]::new([Spectre.Console.Rows]::new($items))
    $panel.Border = [Spectre.Console.BoxBorder]::Rounded
    $panel.BorderStyle = [Spectre.Console.Style]::Parse($script:PSMM_ColAccent)
    $panel
}

# Float the panel over the current frame, wait for one key, restore. The
# marker is only written when the panel was actually seen; headless hosts
# skip everything (mirrors Write-PSMMOverlay's redirected-output no-op).
function script:Show-PSMMWelcomeOverlay {
    [CmdletBinding()] param($BaseRenderable)
    if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { return }
    $region = Write-PSMMOverlay -Renderable (Build-PSMMWelcomePanel) -Content $BaseRenderable
    $k = [Console]::ReadKey($true)
    Clear-PSMMOverlay -Region $region
    Set-PSMMWelcomeShown
    if (Test-PSMMHardQuitKey $k) { $script:PSMM_UI.HardQuit = $true }
}
