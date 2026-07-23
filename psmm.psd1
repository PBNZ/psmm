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
            # 'rc01', and every character of it is load-bearing:
            #   rc..  not beta.. - a prerelease label is compared LEXICALLY, so
            #         '0.1.0-beta10' sorts BELOW '0.1.0-beta9'; the gallery
            #         would go on serving beta9 as latest and Update-PSResource
            #         would refuse to move anyone. 'rc' > 'beta', so the line
            #         steps up cleanly from beta9.
            #   ..01  zero-padded, because the same lexical rule makes 'rc10'
            #         sort below 'rc9'. Fixed-width digits sort like numbers.
            #   no dot - the gallery rejects a prerelease containing anything
            #         but a-zA-Z0-9 (server-side, AFTER the quality gate has
            #         run), so the SemVer-idiomatic 'rc.1' is not publishable.
            # All three verified against NuGet.Versioning and the live gallery,
            # 2026-07-23. 0.1.0 stays reserved for stable.
            Prerelease   = 'rc01'
            ProjectUri   = 'https://github.com/PBNZ/psmm'
            LicenseUri   = 'https://github.com/PBNZ/psmm/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0-rc01 - gallery search now works like the gallery website: a word matches names, descriptions and tags in relevance order ("excel" finds ImportExcel first), a pattern matches names across every registered repository, and a search that finds nothing says why. Broad queries went from 216 seconds to under one. New downloads column. See CHANGELOG.md.'
        }
    }
}
