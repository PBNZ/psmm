# Save.ps1 — write config files back to disk without losing anything.

# Can we write to this path (or create it in its directory)?
function Test-PSMMWritable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None'); $fs.Dispose(); return $true
        }
        $dir = Split-Path -Parent $Path
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            $probe = Join-Path $dir (".psmm_w_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
            [System.IO.File]::WriteAllText($probe, ''); Remove-Item -LiteralPath $probe -Force; return $true
        }
        return $false
    } catch { return $false }
}

# Persist one config file from the in-memory entry list.
# Always pass the ALL-entries list (not the active list) so conflict losers
# and entries of disabled files are never silently dropped on save.
function Save-PSMMFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)] $Entries
    )
    $meta    = $script:PSMM_FileMeta[$Path]
    $forFile = @($Entries | Where-Object Source -eq $Path)
    $modules = if (-not $forFile.Count -and $meta -and -not $meta.Enabled) {
        @($meta.RawModules)   # disabled file: its entries are not in memory — keep them
    } else {
        @(foreach ($e in $forFile) {
            $o = [ordered]@{ Name = $e.Name }
            if ($e.FriendlyName -and $e.FriendlyName -ne $e.Name) { $o.FriendlyName = $e.FriendlyName }
            if ($e.Description) { $o.Description = $e.Description }
            $o.Install = $e.Install
            $o.Mode    = $e.Mode
            if ($e.Version) { $o.Version = $e.Version }
            [pscustomobject]$o
        })
    }
    $root = [ordered]@{}
    if ($meta -and ($meta.HasEnabled -or -not $meta.Enabled)) { $root['Enabled'] = [bool]$meta.Enabled }
    if ($meta -and $meta.Kind -eq 'main') { $root['Includes'] = @($meta.Includes) }
    $legend = $script:PSMM_Legends[$Path]
    if ($legend) { $root['_legend'] = $legend }
    $root['Modules'] = @($modules)
    ([pscustomobject]$root | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $Path -Encoding utf8
    if ($meta) { $meta.RawModules = @($modules); $meta.ModuleCount = @($modules).Count }
}
