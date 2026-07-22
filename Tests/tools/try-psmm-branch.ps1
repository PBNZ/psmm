# try-psmm-branch.ps1 - run the psmm WORKING TREE against a throwaway copy of
# your real config, so a build under test cannot scribble on the real one.
#
#   pwsh -NoProfile -File Tests\tools\try-psmm-branch.ps1
#   pwsh -NoProfile -File Tests\tools\try-psmm-branch.ps1 -Fresh
#   pwsh -NoProfile -File Tests\tools\try-psmm-branch.ps1 -AllowInstalls
#
# Default: your real config sources are COPIED into a sandbox and psmm is
# pointed at the copies. Same modules, same layout, same startup behaviour -
# but every config write lands in the sandbox.
#
# -Fresh          ignore your config; use a synthetic one over fake modules in
#                 fake locations. Everything, including the folder-moving
#                 actions, is then harmless.
# -AllowInstalls  keep the real Install policies. Without it every entry is
#                 rewritten to CheckOnly in the COPY, so startup imports what
#                 is already on disk and never downloads anything.
#
# WHAT IS NOT SANDBOXED (leave these alone unless you mean it):
#   module menu 'p'  moves REAL module folders  (safe under -Fresh)
#   paths       'm'  moves REAL module folders  (safe under -Fresh)
#   paths       'n'  "persist for new sessions?" writes your USER PSModulePath
#                    environment variable - answer no
#   paths     's'/'r'  writes your real powershell.config.json
#   module menu 'i'/'u'  real gallery traffic, real installs

[CmdletBinding()]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'A developer tool that talks to a human at a console: the banner IS host output, exactly like the startup report it sits above.')]
param(
    [string]$RepoPath = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [switch]$Fresh,
    [switch]$AllowInstalls,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

# --- UTF-8, or the box drawing and state glyphs render as garbage ----------
# Same incantation PwshSpectreConsole nags about; psmm's tables, glyphs and
# capsules all depend on it.
$OutputEncoding = [console]::InputEncoding = [console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$sandbox = Join-Path $env:TEMP ('psmm-sandbox-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$cfgDir = Join-Path $sandbox 'config'
New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null

# Rewrite a config copy so a test run cannot install half the gallery, and so
# any Includes point at the copies rather than back at the originals.
function Edit-SandboxConfig {
    param([string]$Path, [hashtable]$IncludeMap, [bool]$KeepInstallPolicy)
    try { $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return }
    if ($obj.PSObject.Properties['Includes']) {
        $obj.Includes = @(foreach ($i in @($obj.Includes)) {
                if ($IncludeMap.ContainsKey("$i")) { $IncludeMap["$i"] } else { $i }
            })
    }
    if (-not $KeepInstallPolicy -and $obj.PSObject.Properties['Modules']) {
        foreach ($m in @($obj.Modules)) {
            if ($m.PSObject.Properties['Install']) { $m.Install = 'CheckOnly' }
            else { $m | Add-Member -NotePropertyName Install -NotePropertyValue 'CheckOnly' -Force }
        }
    }
    ($obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-FakeModule {
    param([string]$Root, [string]$Name, [string[]]$Versions = @('1.0.0'), [string]$Prerelease = '')
    foreach ($v in $Versions) {
        $dir = Join-Path (Join-Path $Root $Name) $v
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $fn = 'Get-' + ($Name -replace '\W')
        Set-Content -LiteralPath (Join-Path $dir "$Name.psm1") -Value "function $fn { '$Name $v' }"
        $mf = @{
            Path = (Join-Path $dir "$Name.psd1"); RootModule = "$Name.psm1"
            ModuleVersion = $v; FunctionsToExport = $fn
            Author = 'Sandbox'; Description = 'fake module for psmm testing'
        }
        if ($Prerelease -and $v -eq $Versions[-1]) { $mf.Prerelease = $Prerelease }
        New-ModuleManifest @mf
    }
}

# fake module locations, first on the search path. Under -Fresh they are the
# only thing psmm manages; otherwise they just give the paths screen a couple
# of harmless targets to practise on.
$modsA = Join-Path $sandbox 'ModulesA'
$modsB = Join-Path $sandbox 'ModulesB'
New-Item -ItemType Directory -Path $modsA, $modsB -Force | Out-Null
New-FakeModule -Root $modsA -Name 'SandboxAlpha' -Versions @('1.0.0', '2.0.0')
New-FakeModule -Root $modsA -Name 'SandboxBeta' -Versions @('0.1.0') -Prerelease 'beta3'
New-FakeModule -Root $modsB -Name 'SandboxOther'
$env:PSModulePath = ($modsA, $modsB, $env:PSModulePath) -join [System.IO.Path]::PathSeparator

$global:PSMM_UpdateCheck = $false
$copied = @()

if ($Fresh) {
    $global:PSMM_MainConfigPath = Join-Path $cfgDir 'psmm-config.json'
    @{
        Modules = @(
            @{ Name = 'SandboxAlpha'; Description = 'two versions on disk'; Install = 'CheckOnly'; Mode = 'Load' }
            @{ Name = 'SandboxBeta'; Description = 'has a prerelease'; Install = 'CheckOnly'; Mode = 'InstallOnly'; Prerelease = $true }
            @{ Name = 'SandboxOther'; Description = 'lives in the second location'; Install = 'CheckOnly'; Mode = 'Ignore' }
            @{ Name = 'PwshSpectreConsole'; Description = "psmm's own UI engine"; Install = 'CheckOnly'; Mode = 'InstallOnly' }
        )
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $global:PSMM_MainConfigPath -Encoding utf8
} else {
    # Ask the INSTALLED psmm where your real config lives, then copy it.
    Get-Module psmm | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module psmm -ErrorAction Stop
    $sources = @(Get-PSMMConfigPath | Where-Object { $_.Exists -and $_.Path -ne '<profile inline>' })
    Get-Module psmm | Remove-Module -Force

    $includeMap = @{}
    foreach ($s in $sources) {
        if ($s.Source -like 'legacy glob*') {
            foreach ($f in @(Get-ChildItem -Path $s.Path -File -ErrorAction SilentlyContinue)) {
                $dest = Join-Path (New-Item -ItemType Directory -Force -Path (Join-Path $cfgDir 'legacy')).FullName $f.Name
                Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                $copied += $dest
            }
            continue
        }
        $dest = Join-Path $cfgDir ((Split-Path $s.Path -Leaf) -replace '\.json$', '')
        $dest = "$dest-$([guid]::NewGuid().ToString('N').Substring(0,4)).json"
        Copy-Item -LiteralPath $s.Path -Destination $dest -Force
        $copied += $dest
        switch -Wildcard ($s.Source) {
            'main config'         { $global:PSMM_MainConfigPath = $dest }
            'include*'            { $includeMap[$s.Path] = $dest }
            'profile-dir config'  { $global:PSMM_ProfileConfigPath = $dest }
        }
    }
    if (-not $global:PSMM_MainConfigPath) { $global:PSMM_MainConfigPath = Join-Path $cfgDir 'psmm-config.json' }
    $global:PSMM_JsonPath = @((Join-Path $cfgDir 'legacy\*.json'))
    if (-not $global:PSMM_ProfileConfigPath) { $global:PSMM_ProfileConfigPath = Join-Path $cfgDir 'no-profile-config.json' }
    foreach ($c in $copied) { Edit-SandboxConfig -Path $c -IncludeMap $includeMap -KeepInstallPolicy:$AllowInstalls }
}

# --- load the WORKING TREE, not the installed copy -------------------------
# Remove-Module first: -Force does NOT replace a same-named module, it loads a
# SECOND one and command resolution between them is anyone's guess.
Get-Module psmm | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $RepoPath 'psmm.psd1') -Force

$isBranch = [bool](& (Get-Module psmm) { Get-Command Test-PSMMOwnModule -ErrorAction SilentlyContinue })
Write-Host ''
Write-Host '  build     ' -NoNewline -ForegroundColor DarkGray; Write-Host (Get-Module psmm).Path
Write-Host '  version   ' -NoNewline -ForegroundColor DarkGray; Write-Host (& (Get-Module psmm) { Get-PSMMVersionString })
Write-Host '  working   ' -NoNewline -ForegroundColor DarkGray
Write-Host $(if ($isBranch) { 'yes - this is the repo working tree' } else { 'NO - this is the installed build!' }) -ForegroundColor $(if ($isBranch) { 'Green' } else { 'Red' })
Write-Host '  config    ' -NoNewline -ForegroundColor DarkGray
Write-Host $(if ($Fresh) { "synthetic (-Fresh)  $($global:PSMM_MainConfigPath)" } else { "copy of your real config  $($global:PSMM_MainConfigPath)" })
Write-Host '  installs  ' -NoNewline -ForegroundColor DarkGray
Write-Host $(if ($Fresh -or $AllowInstalls) { 'real policies' } else { 'forced to CheckOnly - nothing will be downloaded (-AllowInstalls keeps them)' })
Write-Host ''

# --- startup, exactly as your $PROFILE runs it -----------------------------
# This is what proves gh#2: Mode=Load entries must end up in THIS session, so
# Get-Module lists them and their commands work at the prompt after you quit.
Invoke-PSMMStartup

Write-Host ''
Write-Host '  loaded into this session by startup:' -ForegroundColor DarkGray
$loaded = @(Get-Module | Where-Object { $_.Name -notin 'psmm', 'Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management', 'PSReadLine' })
if ($loaded.Count) { $loaded | ForEach-Object { Write-Host "    $($_.Name) $($_.Version)" } }
else { Write-Host '    (none - no Mode=Load entry was importable)' }
Write-Host ''
Write-Host "  when done:  Remove-Item -LiteralPath '$sandbox' -Recurse -Force" -ForegroundColor DarkGray
Write-Host '              then close this session; nothing outside the sandbox changed.' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoLaunch) { Show-PSModuleManager }
