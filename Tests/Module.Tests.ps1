# Manifest, exports and import hygiene (PRD §13 "Module & manifest").
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:ManifestPath = Join-Path $script:ModuleRoot 'psmm.psd1'
}

Describe 'Module manifest' -Tag Module, Engine {

    It 'passes Test-ModuleManifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'has every required key present and non-empty' {
        $m = Test-ModuleManifest -Path $script:ManifestPath
        $m.Version | Should -Not -BeNullOrEmpty
        $m.Guid | Should -Be 'ed4c75e5-4d5b-43b1-a0ed-3c46fe4bcdee'
        $m.Author | Should -Be 'Peter Braun'
        $m.Description | Should -Not -BeNullOrEmpty
        $m.PowerShellVersion | Should -Be ([version]'7.0')
        $m.CompatiblePSEditions | Should -Contain 'Core'
        $m.RootModule | Should -Be 'psmm.psm1'
        $m.PrivateData.PSData.Tags | Should -Not -BeNullOrEmpty
        $m.PrivateData.PSData.ProjectUri | Should -Not -BeNullOrEmpty
        $m.PrivateData.PSData.LicenseUri | Should -Not -BeNullOrEmpty
        $m.PrivateData.PSData.ReleaseNotes | Should -Not -BeNullOrEmpty
    }

    It 'declares no wildcard exports in the raw psd1' {
        $raw = Import-PowerShellDataFile -Path $script:ManifestPath
        $raw.FunctionsToExport | Should -Not -Contain '*'
        $raw.CmdletsToExport | Should -Not -Contain '*'
        $raw.VariablesToExport | Should -Not -Contain '*'
        $raw.AliasesToExport | Should -Not -Contain '*'
    }
}

Describe 'Module import and public surface' -Tag Module, Engine {

    BeforeAll {
        Import-Module $script:ManifestPath -Force
    }

    It 'imports without errors' {
        (Get-Module psmm) | Should -Not -BeNullOrEmpty
    }

    It 'exports exactly the intended function set - nothing leaked' {
        $exported = (Get-Module psmm).ExportedFunctions.Keys | Sort-Object
        $exported | Should -Be @('Get-PSMMConfigPath', 'Invoke-PSMMStartup', 'Show-PSModuleManager')
    }

    It 'exports exactly the psmm alias' {
        $aliases = (Get-Module psmm).ExportedAliases.Keys
        $aliases | Should -Be @('psmm')
        (Get-Alias psmm).Definition | Should -Be 'Show-PSModuleManager'
    }

    It 'keeps engine internals private' {
        foreach ($name in 'Get-PSMMEntry', 'Save-PSMMFile', 'Install-PSMMModule', 'Resolve-PSMMEntry') {
            Get-Command $name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'has comment-based help with synopsis and examples on every export' {
        foreach ($fn in (Get-Module psmm).ExportedFunctions.Keys) {
            $h = Get-Help $fn -Full
            $h.Synopsis | Should -Not -BeNullOrEmpty -Because "$fn needs a synopsis"
            @($h.description).Count | Should -BeGreaterThan 0 -Because "$fn needs a description"
            @($h.examples.example).Count | Should -BeGreaterThan 0 -Because "$fn needs examples"
        }
    }
}
