# Discovery.ps1 — build the module-entry lists from every config source.
#
# Sources, in load order (precedence rules below):
#   1. inline JSON in $PSMM_InlineJson            (read-only)
#   2. MAIN config   ~/.psmm/psmm-config.json     (only file whose Includes count)
#   3. main's Includes (one level deep, no nesting -> no circular references)
#   4. profile-dir   <profile dir>/psmm-config.json
#   5. legacy globs in $PSMM_JsonPath (default: psmodules.d/*.json next to $PROFILE)
#
# Conflict rules (same module name in several files):
#   - main config wins over anything else (warning)
#   - among non-main files, first-loaded wins (error-style warning)
#   - a disabled file's entries are parsed but never actioned, and are
#     preserved on save (never silently dropped)
#
# Engine state lives in script scope; UI and tests reach it via the accessor
# functions at the bottom, never the variables directly.

function Get-PSMMEntry {
    [CmdletBinding()] param()
    $script:PSMM_Legends  = @{}
    $script:PSMM_FileMeta = [ordered]@{}
    $script:PSMM_Warnings = [System.Collections.Generic.List[string]]::new()
    $all  = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $loadFile = {
        param([string]$Path, [string]$Kind, [bool]$AllowIncludes)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
        if (-not $seen.Add(([IO.Path]::GetFullPath($Path)))) { return @() }
        try { $parsed = ConvertFrom-PSMMJson -Json (Get-Content -LiteralPath $Path -Raw) }
        catch { $script:PSMM_Warnings.Add("failed to parse '$Path': $($_.Exception.Message)"); return @() }
        $writable = Test-PSMMWritable -Path $Path
        $script:PSMM_Legends[$Path] = $parsed.Legend
        $ignored = (-not $AllowIncludes) -and $parsed.Includes.Count -gt 0
        if ($ignored) {
            $script:PSMM_Warnings.Add("Includes in '$(Split-Path $Path -Leaf)' ignored - only the main config ($(Get-PSMMMainConfigPath)) may include files")
        }
        $script:PSMM_FileMeta[$Path] = [pscustomobject]@{
            Path = $Path; Kind = $Kind; Enabled = $parsed.Enabled; HasEnabled = $parsed.HasEnabled
            Includes = @($parsed.Includes); IncludesIgnored = $ignored
            Writable = $writable; ModuleCount = @($parsed.Modules).Count
            RawModules = @($parsed.Modules)
        }
        foreach ($m in $parsed.Modules) {
            $e = Resolve-PSMMEntry -Raw $m -Source $Path -Writable $writable
            $e | Add-Member -NotePropertyName FromMain -NotePropertyValue ($Kind -eq 'main') -Force
            $e | Add-Member -NotePropertyName FileEnabled -NotePropertyValue $parsed.Enabled -Force
            $all.Add($e)
        }
        if ($AllowIncludes) { return @($parsed.Includes) } else { return @() }
    }

    # 1. inline (optional — empty/whitespace means "config lives in files")
    $inlineJson = Get-PSMMSetting -Name 'PSMM_InlineJson'
    if (-not [string]::IsNullOrWhiteSpace($inlineJson)) {
        try {
            $inline = ConvertFrom-PSMMJson -Json $inlineJson
            $script:PSMM_Legends['<profile inline>'] = $inline.Legend
            if ($inline.Includes.Count) {
                $script:PSMM_Warnings.Add('Includes in the inline profile JSON are ignored - only the main config may include files')
            }
            $script:PSMM_FileMeta['<profile inline>'] = [pscustomobject]@{
                Path = '<profile inline>'; Kind = 'inline'; Enabled = $inline.Enabled; HasEnabled = $inline.HasEnabled
                Includes = @(); IncludesIgnored = ($inline.Includes.Count -gt 0)
                Writable = $false; ModuleCount = @($inline.Modules).Count; RawModules = @($inline.Modules)
            }
            if ($inline.Enabled) {
                foreach ($m in $inline.Modules) {
                    $e = Resolve-PSMMEntry -Raw $m -Source '<profile inline>' -Writable $false
                    $e | Add-Member -NotePropertyName FromMain -NotePropertyValue $false -Force
                    $e | Add-Member -NotePropertyName FileEnabled -NotePropertyValue $true -Force
                    $all.Add($e)
                }
            }
        } catch { Write-Warning "psmm: inline JSON parse failed: $($_.Exception.Message)" }
    }

    # 2 + 3. main config and its (one-level) includes
    $includes = & $loadFile (Get-PSMMMainConfigPath) 'main' $true
    foreach ($inc in $includes) {
        $p = $inc
        try { $p = [System.Environment]::ExpandEnvironmentVariables($inc) } catch { }
        if ($p -match '^~') { $p = Join-Path $HOME ($p -replace '^~[\\/]?', '') }
        if (Test-Path -LiteralPath $p -PathType Leaf) { $null = & $loadFile $p 'include' $false }
        else { $script:PSMM_Warnings.Add("included config not found: '$inc'") }
    }

    # 4. profile-dir config
    $profileCfg = Get-PSMMProfileConfigPath
    if ($profileCfg) { $null = & $loadFile $profileCfg 'profile' $false }

    # 5. legacy globs
    foreach ($glob in (Get-PSMMLegacyGlobs)) {
        $files = @(); try { $files = @(Get-ChildItem -Path $glob -File -ErrorAction SilentlyContinue) } catch { }
        foreach ($f in $files) { $null = & $loadFile $f.FullName 'legacy' $false }
    }

    $script:PSMM_AllEntries = $all

    # ---- dedupe with precedence: main wins; otherwise first wins ----
    $final  = [System.Collections.Generic.List[object]]::new()
    $byName = @{}
    foreach ($e in $all) {
        if (-not $e.FileEnabled) { continue }                       # disabled file: not active
        if ([string]::IsNullOrWhiteSpace($e.Name)) { $final.Add($e); continue }
        $leafE = if ($e.Source -eq '<profile inline>') { 'profile inline' } else { Split-Path $e.Source -Leaf }
        if (-not $byName.ContainsKey($e.Name)) { $byName[$e.Name] = $e; $final.Add($e); continue }
        $cur = $byName[$e.Name]
        $leafC = if ($cur.Source -eq '<profile inline>') { 'profile inline' } else { Split-Path $cur.Source -Leaf }
        if ($e.FromMain -and -not $cur.FromMain) {
            $idx = $final.IndexOf($cur); $final[$idx] = $e; $byName[$e.Name] = $e
            $script:PSMM_Warnings.Add("conflict: '$($e.Name)' also defined in $leafC - main config wins")
        } elseif ($cur.FromMain) {
            $script:PSMM_Warnings.Add("conflict: '$($e.Name)' in $leafE overridden by main config")
        } else {
            $script:PSMM_Warnings.Add("ERROR conflict: '$($e.Name)' defined in $leafC and $leafE - using $leafC, fix your configs")
        }
    }
    return $final
}

# ---- engine-state accessors (UI + tests use these, never the vars) ----
# Get-PSMMAllEntries returns a plain array (safe to pipe); mutation goes
# through Add-PSMMAllEntry / Set-PSMMAllEntries so the backing list stays
# consistent. NB: pipeline unrolling strips the @() on return - callers that
# need a real array (indexing, +) must wrap the call in @() themselves (gh#1).

function Get-PSMMAllEntries  { if ($script:PSMM_AllEntries) { @($script:PSMM_AllEntries) } else { @() } }
function Get-PSMMFileMeta    { $script:PSMM_FileMeta }
function Get-PSMMLegend      { param([string]$Path) $script:PSMM_Legends[$Path] }
function Get-PSMMWarning     { if ($script:PSMM_Warnings) { @($script:PSMM_Warnings) } else { @() } }
function Add-PSMMAllEntry    { param([Parameter(Mandatory)] $Entry) $script:PSMM_AllEntries.Add($Entry) }
function Set-PSMMAllEntries  {
    param([Parameter(Mandatory)] $Entries)
    $l = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Entries) { $l.Add($e) }
    $script:PSMM_AllEntries = $l
}
