# 40-Conflicts.ps1 — validation issues, duplicate names, command shadowing.
# Rendered to text and paged (the alt screen has no scrollback).

function script:Build-PSMMConflictLines {
    param([Parameter(Mandatory)] $Conflict)

    $lines = [System.Collections.Generic.List[string]]::new()
    $addTable = {
        param($Title, $Rows, $Columns)
        $lines.Add('')
        $lines.Add("== $Title ==")
        if (-not $Rows.Count) { $lines.Add('   none'); return }
        $T = [Spectre.Console.Table]::new()
        $T.Border = [Spectre.Console.TableBorder]::Rounded
        foreach ($c in $Columns) { [void][Spectre.Console.TableExtensions]::AddColumn($T, $c) }
        foreach ($r in $Rows) {
            [void][Spectre.Console.TableExtensions]::AddRow($T, [string[]]@($r | ForEach-Object { ConvertTo-PSMMSafe "$_" }))
        }
        foreach ($l in (ConvertTo-PSMMTextLines -Renderable $T)) { $lines.Add($l) }
    }

    & $addTable 'Validation issues' @(
        $Conflict.Validation | ForEach-Object {
            , @($_.Name, (Split-Path $_.Source -Leaf), $_.Issues, $(if ($_.Writable) { 'yes' } else { 'no' }))
        }
    ) @('Name', 'Source', 'Issues', 'RW')

    & $addTable 'Duplicate module names' @(
        $Conflict.Duplicates | ForEach-Object { , @($_.Name, $_.Count, $_.Sources) }
    ) @('Name', 'Count', 'Sources')

    & $addTable 'Command shadowing (loaded modules)' @(
        $Conflict.Shadowed | ForEach-Object { , @($_.Command, $_.Modules) }
    ) @('Command', 'Modules')

    $warnings = Get-PSMMWarning
    if ($warnings.Count) {
        $lines.Add('')
        $lines.Add('== Config warnings (this session) ==')
        foreach ($w in $warnings) { $lines.Add("   $w") }
    }
    $lines
}

function script:Show-PSMMConflicts {
    $c = Get-PSMMConflict -Entries (Get-PSMMAllEntries)
    $lines = Build-PSMMConflictLines -Conflict $c
    Show-PSMMPager -Lines $lines -TitleMarkup "[$script:PSMM_ColAccent]Conflicts & validation[/]"
}
