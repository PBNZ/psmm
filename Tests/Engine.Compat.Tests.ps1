# Backward compatibility: Peter's existing psmm-config.json files must keep
# working, byte-for-byte, without migration.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'psmm.psd1') -Force

    # A faithful copy of the real-world example config shape (abridged from
    # the reference psmm-config.example.json: same fields, same style).
    $script:LegacyJson = @'
{
  "Enabled": true,
  "Includes": [],
  "_legend": {
    "Enabled": "true/false - false deactivates every module in this file",
    "Includes": "main config only: absolute paths of further config files to load",
    "Install": "CheckOnly | IfMissing (default) | Latest",
    "Mode": "Load (default) | InstallOnly | Ignore"
  },
  "Modules": [
    {
      "Name": "Wsl",
      "FriendlyName": "WSL Management for PowerShell",
      "Description": "Manage WSL distros from PowerShell",
      "Install": "IfMissing",
      "Mode": "Load"
    },
    {
      "Name": "ImportExcel",
      "Description": "Read/write .xlsx without Excel installed",
      "Install": "IfMissing",
      "Mode": "InstallOnly"
    },
    {
      "Name": "Microsoft.Online.SharePoint.PowerShell",
      "FriendlyName": "SharePoint Online",
      "Install": "CheckOnly",
      "Mode": "InstallOnly"
    },
    {
      "Name": "Pester",
      "Description": "Unit/integration testing framework",
      "Install": "IfMissing",
      "Mode": "Ignore"
    }
  ]
}
'@
}

Describe 'Legacy config compatibility' -Tag Engine {

    AfterEach {
        Remove-Variable -Name PSMM_MainConfigPath, PSMM_ProfileConfigPath, PSMM_JsonPath, PSMM_InlineJson -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'main')
        $global:PSMM_MainConfigPath    = Join-Path $root 'main\psmm-config.json'
        $global:PSMM_ProfileConfigPath = Join-Path $root 'profile\psmm-config.json'
        $global:PSMM_JsonPath          = @(Join-Path $root 'legacy\*.json')
        Set-Content -LiteralPath $global:PSMM_MainConfigPath -Value $script:LegacyJson -Encoding utf8
    }

    It 'loads a legacy-shaped config unchanged with zero warnings' {
        $active = InModuleScope psmm { Get-PSMMEntry }
        @($active).Count | Should -Be 4
        (InModuleScope psmm { Get-PSMMWarning }) | Should -BeNullOrEmpty
    }

    It 'reproduces the exact Mode/Install matrix of the legacy entries' {
        $active = InModuleScope psmm { Get-PSMMEntry }
        ($active | Where-Object Name -eq 'Wsl').Mode | Should -Be 'Load'
        ($active | Where-Object Name -eq 'Wsl').Install | Should -Be 'IfMissing'
        ($active | Where-Object Name -eq 'ImportExcel').Mode | Should -Be 'InstallOnly'
        ($active | Where-Object Name -eq 'Microsoft.Online.SharePoint.PowerShell').Install | Should -Be 'CheckOnly'
        ($active | Where-Object Name -eq 'Pester').Mode | Should -Be 'Ignore'
    }

    It 'entries without new-in-0.1 fields (Version) resolve with no pin and no issues' {
        $active = InModuleScope psmm { Get-PSMMEntry }
        foreach ($e in $active) {
            $e.Version | Should -BeNullOrEmpty
            $e.Issues | Should -BeNullOrEmpty
        }
    }

    It 'a legacy file survives a save round-trip with its legend intact' {
        $null = InModuleScope psmm { Get-PSMMEntry }
        InModuleScope psmm { Save-PSMMFile -Path (Get-PSMMMainConfigPath) -Entries (Get-PSMMAllEntries) }
        $reloaded = Get-Content -LiteralPath $global:PSMM_MainConfigPath -Raw | ConvertFrom-Json
        @($reloaded.Modules).Count | Should -Be 4
        $reloaded._legend.Mode | Should -Match 'InstallOnly'
        # and it still parses as an active config afterwards
        $active = InModuleScope psmm { Get-PSMMEntry }
        @($active).Count | Should -Be 4
    }
}
