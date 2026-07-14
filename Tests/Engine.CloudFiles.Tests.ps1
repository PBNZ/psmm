# CloudFiles engine: OneDrive/Files On-Demand detection, hydration,
# PSModulePath info and the powershell.config.json PSModulePath override.
# Attribute values are the documented Win32/MS-FSCC constants.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force
}

Describe 'Cloud placeholder detection' -Tag Engine {

    It 'recognises the documented recall attributes as cloud-only' {
        InModuleScope psmm {
            Test-PSMMCloudOnlyAttribute -Attributes 0x400000 | Should -BeTrue   # RECALL_ON_DATA_ACCESS
            Test-PSMMCloudOnlyAttribute -Attributes 0x40000  | Should -BeTrue   # RECALL_ON_OPEN
            Test-PSMMCloudOnlyAttribute -Attributes (0x400000 -bor 0x20) | Should -BeTrue
            Test-PSMMCloudOnlyAttribute -Attributes 0x20     | Should -BeFalse  # plain Archive
            Test-PSMMCloudOnlyAttribute -Attributes 0x1000   | Should -BeFalse  # Offline alone is not a recall bit
        }
    }

    It 'Test-PSMMOneDrivePath matches paths under any OneDrive root env var' {
        $saved = $env:OneDrive
        try {
            $env:OneDrive = Join-Path $TestDrive 'FakeOneDrive'
            InModuleScope psmm {
                Test-PSMMOneDrivePath -Path (Join-Path $env:OneDrive 'Documents\PowerShell\Modules') | Should -BeTrue
                Test-PSMMOneDrivePath -Path 'C:\Definitely\Elsewhere' | Should -BeFalse
            }
        } finally { $env:OneDrive = $saved }
    }

    It 'a normal on-disk folder has no cloud-only files' {
        $dir = Join-Path $TestDrive 'mod'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'a.psm1') -Value 'x'
        InModuleScope psmm -Parameters @{ d = $dir } {
            @(Get-PSMMCloudOnlyFile -Path $d).Count | Should -Be 0
        }
    }
}

Describe 'File hydration' -Tag Engine {

    It 'reads every file, reports Ok, and calls the progress callback' {
        $dir = Join-Path $TestDrive 'hyd'
        New-Item -ItemType Directory -Path $dir | Out-Null
        1..3 | ForEach-Object { Set-Content -Path (Join-Path $dir "f$_.txt") -Value ('x' * 100) }
        InModuleScope psmm -Parameters @{ d = $dir } {
            $files = @(Get-ChildItem -LiteralPath $d -File)
            $seen = [System.Collections.Generic.List[string]]::new()
            $r = Invoke-PSMMFileHydration -Files $files -OnProgress { param($i, $n, $f) $seen.Add("$i/$n $($f.Name)") }
            $r.Ok | Should -Be 3
            $r.Failed | Should -Be 0
            $seen.Count | Should -Be 3
            $seen[0] | Should -Be '1/3 f1.txt'
        }
    }

    It 'survives an unreadable file and reports it as failed' {
        InModuleScope psmm {
            $ghost = [pscustomobject]@{ FullName = 'Z:\does\not\exist.bin'; Name = 'exist.bin'; Length = 1 }
            $r = Invoke-PSMMFileHydration -Files @($ghost)
            $r.Ok | Should -Be 0
            $r.Failed | Should -Be 1
            @($r.Errors).Count | Should -Be 1
        }
    }
}

Describe 'PSModulePath info' -Tag Engine {

    It 'annotates every entry, flags the first, and matches the env variable' {
        InModuleScope psmm {
            $infos = @(Get-PSMMModulePathInfo)
            $expected = @($env:PSModulePath -split [System.IO.Path]::PathSeparator | Where-Object { $_ })
            $infos.Count | Should -Be $expected.Count
            $infos[0].First | Should -BeTrue
            @($infos | Where-Object First).Count | Should -Be 1
            $infos[0].Path | Should -Be $expected[0]
        }
    }

    It 'derives the user default from the Documents known folder (Windows)' -Skip:(-not $IsWindows) {
        InModuleScope psmm {
            $expected = Join-Path (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell') 'Modules'
            Get-PSMMUserDefaultModulePath | Should -Be $expected
        }
    }
}

Describe 'CurrentUser PSModulePath override (powershell.config.json)' -Tag Engine {

    It 'creates the config with the PSModulePath key and preserves existing keys' {
        $cfg = Join-Path $TestDrive 'cfg\powershell.config.json'
        New-Item -ItemType Directory -Path (Split-Path $cfg) | Out-Null
        '{"Microsoft.PowerShell:ExecutionPolicy":"RemoteSigned"}' | Set-Content -LiteralPath $cfg
        InModuleScope psmm -Parameters @{ cfg = $cfg } {
            $null = Set-PSMMUserModulePath -Path 'D:\PSModules' -ConfigPath $cfg
            $obj = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
            $obj.PSModulePath | Should -Be 'D:\PSModules'
            $obj.'Microsoft.PowerShell:ExecutionPolicy' | Should -Be 'RemoteSigned'
            Test-Path -LiteralPath "$cfg.bak" | Should -BeTrue   # previous content backed up
        }
    }

    It '-Clear removes only the PSModulePath key' {
        $cfg = Join-Path $TestDrive 'cfg2\powershell.config.json'
        New-Item -ItemType Directory -Path (Split-Path $cfg) | Out-Null
        '{"PSModulePath":"D:\\X","ExperimentalFeatures":["F1"]}' | Set-Content -LiteralPath $cfg
        InModuleScope psmm -Parameters @{ cfg = $cfg } {
            $null = Set-PSMMUserModulePath -Clear -ConfigPath $cfg
            $obj = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
            $obj.PSObject.Properties['PSModulePath'] | Should -BeNullOrEmpty
            @($obj.ExperimentalFeatures) | Should -Be @('F1')
        }
    }

    It 'refuses to touch a config file that does not parse (a corrupt file stops pwsh)' {
        $cfg = Join-Path $TestDrive 'cfg3\powershell.config.json'
        New-Item -ItemType Directory -Path (Split-Path $cfg) | Out-Null
        '{ this is not json' | Set-Content -LiteralPath $cfg
        InModuleScope psmm -Parameters @{ cfg = $cfg } {
            { Set-PSMMUserModulePath -Path 'D:\X' -ConfigPath $cfg } | Should -Throw '*refusing*'
            Get-Content -LiteralPath $cfg -Raw | Should -Match 'this is not json'   # untouched
        }
    }

    It 'works when no config file exists yet' {
        $cfg = Join-Path $TestDrive 'cfg4\powershell.config.json'
        InModuleScope psmm -Parameters @{ cfg = $cfg } {
            $null = Set-PSMMUserModulePath -Path 'D:\Fresh' -ConfigPath $cfg
            (Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).PSModulePath | Should -Be 'D:\Fresh'
        }
    }
}
