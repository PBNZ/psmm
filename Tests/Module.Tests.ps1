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

    It 'dot-sources every engine file - psmm.psm1 lists them explicitly' {
        # The list in psmm.psm1 is hand-maintained for deterministic load order
        # and to avoid a directory glob at import. A new src/Engine file left
        # out of it still WORKS from a clone (the UI dot-sources its own
        # directory, and tests import the manifest), but is simply absent when
        # installed from the gallery - a failure that only shows up on a user's
        # machine. Plan.ps1 was new in 0.1.0-rc02.
        $psm1 = Get-Content -Raw (Join-Path $script:ModuleRoot 'psmm.psm1')
        $missing = @(
            foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot 'src/Engine') -Filter *.ps1)) {
                if ($psm1 -notmatch [regex]::Escape("src/Engine/$($f.Name)")) { $f.Name }
            }
        )
        $missing | Should -BeNullOrEmpty -Because "psmm.psm1 must dot-source: $($missing -join ', ')"
    }

    It 'ships every file the module needs (FileList/packaging sanity)' {
        # src/UI is dot-sourced lazily by Show-PSModuleManager from the
        # directory, so it needs no list - but the directory must exist and be
        # non-empty, and both source trees must be inside the module root.
        foreach ($d in 'src/Engine', 'src/Public', 'src/UI') {
            $p = Join-Path $script:ModuleRoot $d
            Test-Path -LiteralPath $p | Should -BeTrue -Because "$d must ship"
            @(Get-ChildItem -LiteralPath $p -Filter *.ps1).Count | Should -BeGreaterThan 0
        }
    }

    It 'has every required key present and non-empty' {
        $m = Test-ModuleManifest -Path $script:ManifestPath
        $m.Version | Should -Not -BeNullOrEmpty
        $m.Guid | Should -Be 'ed4c75e5-4d5b-43b1-a0ed-3c46fe4bcdee'
        $m.Author | Should -Be 'PBNZ'
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
