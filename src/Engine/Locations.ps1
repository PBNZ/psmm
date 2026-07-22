# Locations.ps1 — module LOCATIONS as a thing you can manage: add a folder to
# the search path, and move module folders between locations (gh#4, gh#12,
# gh#13).
#
# Layout assumption, straight out of about_PSModulePath: an installed module
# lives at <root>\<Name>\<version>\ (versioned install) or <root>\<Name>\
# (side-loaded). Get-Module -ListAvailable reports ModuleBase = the folder
# holding the manifest, so the folder to MOVE is the <root>\<Name> tree, never
# the version folder alone - moving one version out of a multi-version tree
# would leave a half-populated module behind.

# Can we create/delete inside this directory? Probe by writing a temp file:
# ACL maths is a losing game (inherited denies, network shares, OneDrive).
function Test-PSMMDirectoryWritable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
        $probe = Join-Path $Path (".psmm_w_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
        [System.IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        $true
    } catch { $false }
}

# The <root>\<Name> tree a ModuleBase belongs to, plus the search root above
# it. $Name disambiguates the two layouts without guessing at version syntax.
function Get-PSMMModuleTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModuleBase,
        [Parameter(Mandatory)][string]$Name
    )
    $base = $ModuleBase.TrimEnd('\', '/')
    $leaf = Split-Path -Leaf $base
    $tree = if ($leaf -eq $Name) { $base } else { Split-Path -Parent $base }
    [pscustomobject]@{
        Tree = $tree
        Root = (Split-Path -Parent $tree)
    }
}

# Total size of a folder tree in bytes (0 when unreadable) - used to tell the
# user what a move is about to shift before they commit to it.
function Get-PSMMFolderSize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($sum) { [long]$sum } else { 0L }
    } catch { 0L }
}

# Human-readable byte size, one decimal, no trailing period (design system).
function Format-PSMMSize {
    [CmdletBinding()]
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    "$Bytes B"
}

# The module folders directly under a search root, with size and version count.
function Get-PSMMLocationModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $versions = @(Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d+(\.\d+){0,3}$' })
            [pscustomobject]@{
                Name     = $_.Name
                Path     = $_.FullName
                Versions = $versions.Count
                Bytes    = (Get-PSMMFolderSize -Path $_.FullName)
            }
        })
}

# Move one folder tree to a new parent. Returns the new path; throws with a
# usable message on collision / permission / locked files.
function Move-PSMMFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$TargetRoot
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "not found: $Source" }
    $leaf = Split-Path -Leaf $Source.TrimEnd('\', '/')
    # GetFullPath, NOT Resolve-Path: the target root legitimately may not exist
    # yet (we create it below), and Resolve-Path throws on a missing path -
    # which would turn "move into a new folder" into a confusing failure.
    $srcFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    $destFull = [System.IO.Path]::GetFullPath((Join-Path $TargetRoot $leaf)).TrimEnd('\', '/')
    $cmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ([string]::Equals($srcFull, $destFull, $cmp)) { throw 'source and target are the same folder' }
    # moving a tree into itself (...\Foo -> ...\Foo\sub) would either fail
    # half-way or recurse - refuse it before anything is touched
    if ($destFull.StartsWith($srcFull + [System.IO.Path]::DirectorySeparatorChar, $cmp)) {
        throw 'the target folder is inside the folder being moved'
    }
    if (Test-Path -LiteralPath $destFull) { throw "'$leaf' already exists in the target location" }
    if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
    }
    try {
        Move-Item -LiteralPath $Source -Destination $destFull -ErrorAction Stop
    } catch {
        # Move-Item across volumes is copy-then-delete and is NOT atomic: a
        # locked or unreadable file part-way through leaves files in BOTH
        # places. psmm cannot roll that back safely (deleting the partial copy
        # could destroy the only copy of a file that did move), so say exactly
        # where things stand instead of pretending nothing happened.
        if (Test-Path -LiteralPath $destFull) {
            throw ("$($_.Exception.Message) - PARTIALLY MOVED: files exist in both " +
                "'$Source' and '$destFull'. Compare them before deleting either.")
        }
        throw
    }
    $destFull
}

# Move every installed copy of ONE module to another search root (gh#4).
# $InstalledVersions is the entry's list (Version / Path / Scope). Returns one
# result record per module tree: Moved + From/To, or Skipped + Reason.
function Move-PSMMModuleTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()] $InstalledVersions,
        [Parameter(Mandatory)][string]$TargetRoot
    )
    $trees = @($InstalledVersions | ForEach-Object { (Get-PSMMModuleTree -ModuleBase "$($_.Path)" -Name $Name).Tree } |
            Select-Object -Unique | Where-Object { $_ })
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $trees) {
        try {
            $dest = Move-PSMMFolder -Source $t -TargetRoot $TargetRoot
            $results.Add([pscustomobject]@{ Name = $Name; From = $t; To = $dest; Moved = $true; Reason = '' })
        } catch {
            $results.Add([pscustomobject]@{ Name = $Name; From = $t; To = ''; Moved = $false; Reason = $_.Exception.Message })
        }
    }
    @($results)
}

# Move every module folder from one search root to another (gh#13).
# Skips - never fails on - collisions and locked trees; $OnProgress is called
# as &$OnProgress $index $total $name before each move.
# $Skip maps a module name to the REASON it is being skipped, because the
# caller knows why (imported in this session / already in the target) and the
# user is owed the real reason, not a guess. Lookup is case-insensitive
# (PowerShell hashtable default), like every other module-name comparison here.
function Move-PSMMLocationContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [hashtable]$Skip = @{},
        [scriptblock]$OnProgress
    )
    $mods = @(Get-PSMMLocationModule -Path $Source)
    $results = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($m in $mods) {
        $i++
        if ($OnProgress) { & $OnProgress $i $mods.Count $m.Name }
        if ($Skip.ContainsKey($m.Name)) {
            $results.Add([pscustomobject]@{ Name = $m.Name; Moved = $false; Reason = "$($Skip[$m.Name])" })
            continue
        }
        try {
            $null = Move-PSMMFolder -Source $m.Path -TargetRoot $Target
            $results.Add([pscustomobject]@{ Name = $m.Name; Moved = $true; Reason = '' })
        } catch {
            $results.Add([pscustomobject]@{ Name = $m.Name; Moved = $false; Reason = $_.Exception.Message })
        }
    }
    @($results)
}

# --- adding a location to the module search path (gh#12) ------------------

# Is this path already on $env:PSModulePath? (trailing separators and case are
# noise on Windows; on Linux/macOS only the separator is)
function Test-PSMMModulePathContains {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $norm = $Path.TrimEnd('\', '/')
    $cmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    foreach ($p in ($env:PSModulePath -split [System.IO.Path]::PathSeparator)) {
        if ($p -and [string]::Equals($p.TrimEnd('\', '/'), $norm, $cmp)) { return $true }
    }
    $false
}

# Add a folder to the SESSION search path (first or last). Returns $false when
# it was already there.
function Add-PSMMModulePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$First
    )
    if (Test-PSMMModulePathContains -Path $Path) { return $false }
    $sep = [System.IO.Path]::PathSeparator
    $rest = @($env:PSModulePath -split $sep | Where-Object { $_ })
    $env:PSModulePath = if ($First) { (@($Path) + $rest) -join $sep } else { (@($rest) + @($Path)) -join $sep }
    $true
}

# Persist a folder in the USER-scope PSModulePath environment variable, which
# pwsh merges into $env:PSModulePath for every new session (about_PSModulePath).
# NOT powershell.config.json: its PSModulePath key REPLACES the CurrentUser
# location rather than adding one - that is what Set-PSMMUserModulePath does.
# Windows-only; returns the new user-scope value. $TargetSeam is a test seam.
function Add-PSMMPersistentModulePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Existing,
        [switch]$WhatIfOnly
    )
    if (-not $IsWindows -and -not $PSBoundParameters.ContainsKey('Existing')) {
        throw 'persisting a module location is a Windows feature - add it to your $PROFILE instead'
    }
    $cur = if ($PSBoundParameters.ContainsKey('Existing')) { "$Existing" }
           else { "$([Environment]::GetEnvironmentVariable('PSModulePath', 'User'))" }
    $sep = [System.IO.Path]::PathSeparator
    $parts = @($cur -split $sep | Where-Object { $_ })
    $cmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    foreach ($p in $parts) {
        if ([string]::Equals($p.TrimEnd('\', '/'), $Path.TrimEnd('\', '/'), $cmp)) { return $cur }
    }
    $new = (@($parts) + @($Path)) -join $sep
    if (-not $WhatIfOnly) { [Environment]::SetEnvironmentVariable('PSModulePath', $new, 'User') }
    $new
}
