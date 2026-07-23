@{
    RootModule           = 'psmm.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'ed4c75e5-4d5b-43b1-a0ed-3c46fe4bcdee'
    Author               = 'PBNZ'
    Copyright            = '(c) 2026 PBNZ'
    Description          = 'PowerShell Session Module Manager: fast, declarative module loading at shell start (JSON config), plus a keyboard-driven terminal UI to manage modules, browse commands, resolve config conflicts, check updates, and manage config files.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')

    FunctionsToExport    = @(
        'Show-PSModuleManager'
        'Invoke-PSMMStartup'
        'Get-PSMMConfigPath'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('psmm')

    PrivateData          = @{
        PSData = @{
            Tags         = @('module-management', 'modules', 'profile', 'startup', 'TUI', 'terminal', 'PSEdition_Core', 'Windows')
            # rc.N, not betaN: a prerelease label containing letters is compared
            # LEXICALLY, so '0.1.0-beta10' sorts BELOW '0.1.0-beta9' - the
            # gallery would keep serving beta9 as latest and Update-PSResource
            # would refuse to move anyone. 'rc' > 'beta' and the trailing number
            # is its own numeric identifier, so rc.9 -> rc.10 rolls over
            # correctly. 0.1.0 stays reserved for stable.
            Prerelease   = 'rc.1'
            ProjectUri   = 'https://github.com/PBNZ/psmm'
            LicenseUri   = 'https://github.com/PBNZ/psmm/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0-rc.1 - gallery search now works like the gallery website: a word matches names, descriptions and tags in relevance order ("excel" finds ImportExcel first), a pattern matches names across every registered repository, and a search that finds nothing says why. Broad queries went from 216 seconds to under one. New downloads column. See CHANGELOG.md.'
        }
    }
}
