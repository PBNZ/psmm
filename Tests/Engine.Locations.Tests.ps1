# Module LOCATIONS engine (gh#4, gh#12, gh#13) plus the parallel cloud-file
# hydration and its concurrency policy (gh#14).
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    function New-FakeModule {
        param([string]$Root, [string]$Name, [string[]]$Versions = @('1.0.0'), [int]$Bytes = 64)
        foreach ($v in $Versions) {
            $dir = Join-Path (Join-Path $Root $Name) $v
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir "$Name.psm1") -Value ('x' * $Bytes)
        }
        (Join-Path $Root $Name)
    }
}

Describe 'Module tree resolution' -Tag Engine {

    # paths are built with Join-Path, not '\' literals: the engine tests also
    # run on Linux in CI, where a backslash is an ordinary filename character

    It 'finds the <root>/<Name> tree for a versioned install' {
        $root = Join-Path $TestDrive 'Mods'
        $tree = Join-Path $root 'Foo'
        $base = Join-Path $tree '1.2.3'
        InModuleScope psmm -Parameters @{ b = $base; t = $tree; r = $root } {
            $res = Get-PSMMModuleTree -ModuleBase $b -Name 'Foo'
            $res.Tree | Should -Be $t
            $res.Root | Should -Be $r
        }
    }

    It 'finds it for an unversioned (side-loaded) install too' {
        $root = Join-Path $TestDrive 'Mods2'
        $tree = Join-Path $root 'Foo'
        InModuleScope psmm -Parameters @{ t = $tree; r = $root } {
            $res = Get-PSMMModuleTree -ModuleBase $t -Name 'Foo'
            $res.Tree | Should -Be $t
            $res.Root | Should -Be $r
        }
    }
}

Describe 'Location inventory' -Tag Engine {

    It 'lists module folders with version counts and sizes' {
        $root = Join-Path $TestDrive 'inv'
        $null = New-FakeModule -Root $root -Name 'Alpha' -Versions @('1.0.0', '2.0.0') -Bytes 100
        $null = New-FakeModule -Root $root -Name 'Beta' -Bytes 50
        $mods = InModuleScope psmm -Parameters @{ p = $root } { @(Get-PSMMLocationModule -Path $p) }
        @($mods).Count | Should -Be 2
        ($mods | Where-Object Name -EQ 'Alpha').Versions | Should -Be 2
        ($mods | Where-Object Name -EQ 'Beta').Bytes | Should -BeGreaterThan 0
    }

    It 'returns nothing for a missing folder instead of throwing' {
        InModuleScope psmm { @(Get-PSMMLocationModule -Path 'Z:\nope\nope').Count } | Should -Be 0
    }

    It 'Format-PSMMSize scales without trailing periods' {
        InModuleScope psmm {
            Format-PSMMSize -Bytes 512 | Should -Be '512 B'
            Format-PSMMSize -Bytes 2048 | Should -Be '2.0 KB'
            Format-PSMMSize -Bytes (5 * 1MB) | Should -Be '5.0 MB'
        }
    }
}

Describe 'Moving module folders' -Tag Engine {

    It 'moves a whole module tree - every version together, never one version out of it' {
        $src = Join-Path $TestDrive 'mv-src'
        $dst = Join-Path $TestDrive 'mv-dst'
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        $null = New-FakeModule -Root $src -Name 'Multi' -Versions @('1.0.0', '2.0.0')
        $versions = @(
            [pscustomobject]@{ Version = '2.0.0'; Path = (Join-Path $src 'Multi\2.0.0') }
            [pscustomobject]@{ Version = '1.0.0'; Path = (Join-Path $src 'Multi\1.0.0') }
        )
        $r = InModuleScope psmm -Parameters @{ v = $versions; d = $dst } {
            @(Move-PSMMModuleTree -Name 'Multi' -InstalledVersions $v -TargetRoot $d)
        }
        @($r).Count | Should -Be 1                       # one tree, not two versions
        $r[0].Moved | Should -BeTrue
        Test-Path (Join-Path $dst 'Multi\1.0.0') | Should -BeTrue
        Test-Path (Join-Path $dst 'Multi\2.0.0') | Should -BeTrue
        Test-Path (Join-Path $src 'Multi') | Should -BeFalse
    }

    It 'creates a target root that does not exist yet instead of failing on it' {
        $src = Join-Path $TestDrive 'new-src'
        $dst = Join-Path $TestDrive 'brand\new\root'      # deliberately absent
        $null = New-FakeModule -Root $src -Name 'Fresh'
        $moved = InModuleScope psmm -Parameters @{ s = (Join-Path $src 'Fresh'); d = $dst } {
            Move-PSMMFolder -Source $s -TargetRoot $d
        }
        Test-Path -LiteralPath $moved | Should -BeTrue
        Test-Path (Join-Path $dst 'Fresh\1.0.0') | Should -BeTrue
    }

    It 'refuses to move a folder into itself' {
        $p = Join-Path $TestDrive 'selfmove'
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        InModuleScope psmm -Parameters @{ path = $p } {
            { Move-PSMMFolder -Source $path -TargetRoot $path } | Should -Throw '*inside the folder being moved*'
            { Move-PSMMFolder -Source $path -TargetRoot (Split-Path $path -Parent) } | Should -Throw '*same folder*'
        }
        Test-Path -LiteralPath $p | Should -BeTrue
    }

    It 'refuses a collision instead of merging or overwriting' {
        $src = Join-Path $TestDrive 'col-src'
        $dst = Join-Path $TestDrive 'col-dst'
        $null = New-FakeModule -Root $src -Name 'Same'
        $null = New-FakeModule -Root $dst -Name 'Same'
        InModuleScope psmm -Parameters @{ s = (Join-Path $src 'Same'); d = $dst } {
            { Move-PSMMFolder -Source $s -TargetRoot $d } | Should -Throw '*already exists*'
        }
        Test-Path (Join-Path $src 'Same') | Should -BeTrue   # untouched
    }

    It 'moves a location''s contents, skipping with the REASON the caller gave' {
        $src = Join-Path $TestDrive 'loc-src'
        $dst = Join-Path $TestDrive 'loc-dst'
        $null = New-FakeModule -Root $src -Name 'Movable'
        $null = New-FakeModule -Root $src -Name 'Loaded'
        $null = New-FakeModule -Root $src -Name 'Clashes'
        $null = New-FakeModule -Root $dst -Name 'Clashes'
        $seen = [System.Collections.Generic.List[string]]::new()
        $r = InModuleScope psmm -Parameters @{ s = $src; d = $dst; seen = $seen } {
            $skip = @{ 'Loaded' = 'imported in this session - unload it first' }
            @(Move-PSMMLocationContent -Source $s -Target $d -Skip $skip -OnProgress {
                    param($i, $n, $name) $seen.Add("$i/$n $name")
                })
        }
        @($r).Count | Should -Be 3
        ($r | Where-Object Name -EQ 'Movable').Moved | Should -BeTrue
        ($r | Where-Object Name -EQ 'Loaded').Moved | Should -BeFalse
        ($r | Where-Object Name -EQ 'Loaded').Reason | Should -Match 'unload'
        # not in the skip list: it fails on its own merits, with its own reason
        ($r | Where-Object Name -EQ 'Clashes').Moved | Should -BeFalse
        ($r | Where-Object Name -EQ 'Clashes').Reason | Should -Match 'already exists'
        $seen.Count | Should -Be 3
        Test-Path (Join-Path $src 'Loaded') | Should -BeTrue    # skipped, still there
        Test-Path (Join-Path $src 'Clashes') | Should -BeTrue
        Test-Path (Join-Path $dst 'Movable') | Should -BeTrue
    }

    It 'skip lookup is case-insensitive, like every other module-name comparison' {
        $src = Join-Path $TestDrive 'case-src'
        $dst = Join-Path $TestDrive 'case-dst'
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        $null = New-FakeModule -Root $src -Name 'MixedCase'
        $r = InModuleScope psmm -Parameters @{ s = $src; d = $dst } {
            @(Move-PSMMLocationContent -Source $s -Target $d -Skip @{ 'mixedcase' = 'nope' })
        }
        $r[0].Moved | Should -BeFalse
        $r[0].Reason | Should -Be 'nope'
        Test-Path (Join-Path $src 'MixedCase') | Should -BeTrue
    }
}

Describe 'Adding a module location' -Tag Engine {

    It 'adds to the session path, first or last, and refuses duplicates' {
        $prev = $env:PSModulePath
        try {
            $p = Join-Path $TestDrive 'newloc'
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            InModuleScope psmm -Parameters @{ path = $p } {
                Test-PSMMModulePathContains -Path $path | Should -BeFalse
                Add-PSMMModulePath -Path $path -First | Should -BeTrue
                Test-PSMMModulePathContains -Path $path | Should -BeTrue
                Add-PSMMModulePath -Path $path | Should -BeFalse   # already there
            }
            @($env:PSModulePath -split [System.IO.Path]::PathSeparator)[0] | Should -Be $p
        } finally { $env:PSModulePath = $prev }
    }

    It 'ignores a trailing separator when deciding "already there"' {
        $prev = $env:PSModulePath
        try {
            $p = Join-Path $TestDrive 'trail'
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            $env:PSModulePath = "$p\" + [System.IO.Path]::PathSeparator + $env:PSModulePath
            InModuleScope psmm -Parameters @{ path = $p } {
                Test-PSMMModulePathContains -Path $path | Should -BeTrue
            }
        } finally { $env:PSModulePath = $prev }
    }

    It 'appends to the persistent user PSModulePath value without duplicating' {
        $a = Join-Path $TestDrive 'A'
        $b = Join-Path $TestDrive 'B'
        $c = Join-Path $TestDrive 'C'
        InModuleScope psmm -Parameters @{ a = $a; b = $b; c = $c } {
            $sep = [System.IO.Path]::PathSeparator
            $existing = "$a$sep$b"
            Add-PSMMPersistentModulePath -Path $c -Existing $existing -WhatIfOnly | Should -Be "$existing$sep$c"
            # already present (modulo trailing separator): unchanged
            Add-PSMMPersistentModulePath -Path ($b + [System.IO.Path]::DirectorySeparatorChar) -Existing $existing -WhatIfOnly |
                Should -Be $existing
        }
    }

    It 'Test-PSMMDirectoryWritable says yes for a real folder and no for a missing one' {
        $p = Join-Path $TestDrive 'wr'
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        InModuleScope psmm -Parameters @{ path = $p } {
            Test-PSMMDirectoryWritable -Path $path | Should -BeTrue
            Test-PSMMDirectoryWritable -Path (Join-Path $path 'nope') | Should -BeFalse
        }
    }
}

Describe 'Hydration concurrency' -Tag Engine {

    It 'caps the parallelism at the logical processor count (and says why)' {
        InModuleScope psmm {
            $max = Get-PSMMHydrationMax
            $max | Should -BeGreaterOrEqual 2
            $max | Should -BeLessOrEqual 16
            $max | Should -BeLessOrEqual ([Math]::Max(2, [Environment]::ProcessorCount))
            (Get-PSMMHydrationDefault) | Should -BeLessOrEqual $max
            (Get-PSMMHydrationDefault) | Should -BeGreaterOrEqual 1
            # the reason is shown to the user verbatim - a bare number tells
            # them nothing (gh#14)
            Get-PSMMHydrationMaxReason | Should -Match "$max"
            Get-PSMMHydrationMaxReason | Should -Match 'processor'
        }
    }

    It 'hydrates every file in parallel, reports each one, and survives failures' {
        $dir = Join-Path $TestDrive 'par'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        1..6 | ForEach-Object { Set-Content -Path (Join-Path $dir "p$_.txt") -Value ('x' * 200) }
        $r = InModuleScope psmm -Parameters @{ d = $dir } {
            $files = @(Get-ChildItem -LiteralPath $d -File)
            $seen = [System.Collections.Generic.List[string]]::new()
            $res = Invoke-PSMMFileHydration -Files $files -ThrottleLimit 4 -OnProgress {
                param($i, $n, $f) $seen.Add("$i/$n $($f.Name)")
            }
            [pscustomobject]@{ Result = $res; Progress = @($seen) }
        }
        $r.Result.Ok | Should -Be 6
        $r.Result.Failed | Should -Be 0
        @($r.Progress).Count | Should -Be 6
        $r.Progress[-1] | Should -Match '^6/6 p\d\.txt$'
    }

    It 'a file that cannot be read fails alone, not the batch' {
        $dir = Join-Path $TestDrive 'par2'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        1..3 | ForEach-Object { Set-Content -Path (Join-Path $dir "q$_.txt") -Value 'y' }
        $r = InModuleScope psmm -Parameters @{ d = $dir } {
            $files = @(Get-ChildItem -LiteralPath $d -File) +
                     @([pscustomobject]@{ FullName = 'Z:\gone\missing.bin'; Name = 'missing.bin'; Length = 1 })
            Invoke-PSMMFileHydration -Files $files -ThrottleLimit 3
        }
        $r.Ok | Should -Be 3
        $r.Failed | Should -Be 1
        @($r.Errors)[0] | Should -Match 'missing\.bin'
    }
}
