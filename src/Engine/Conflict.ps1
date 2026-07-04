# Conflict.ps1 — validation issues, duplicate names, command shadowing.

function Get-PSMMConflict {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()] $Entries)   # empty set = normal (zero configs)
    $Entries = @($Entries)

    $validation = foreach ($e in $Entries) {
        if ($e.Issues.Count) {
            [pscustomobject]@{ Name = $e.Name; Source = $e.Source; Issues = ($e.Issues -join '; '); Writable = $e.Writable }
        }
    }

    $dupes = $Entries | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object {
        [pscustomobject]@{
            Name    = $_.Name
            Count   = $_.Count
            Sources = (($_.Group.Source | ForEach-Object {
                if ($_ -eq '<profile inline>') { 'profile inline' } else { Split-Path $_ -Leaf }
            } | Select-Object -Unique) -join ', ')
        }
    }

    $loadedNames = (Get-Module).Name
    $shadow = @()
    if ($loadedNames) {
        $shadow = Get-Command -Module $loadedNames -CommandType Cmdlet, Function, Alias -ErrorAction SilentlyContinue |
            Group-Object Name | Where-Object { @($_.Group.Source | Select-Object -Unique).Count -gt 1 } |
            ForEach-Object {
                [pscustomobject]@{ Command = $_.Name; Modules = (@($_.Group.Source | Select-Object -Unique) -join ', ') }
            }
    }

    [pscustomobject]@{ Validation = @($validation); Duplicates = @($dupes); Shadowed = @($shadow) }
}
