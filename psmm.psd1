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
            Prerelease   = 'rc02'
            ProjectUri   = 'https://github.com/PBNZ/psmm'
            LicenseUri   = 'https://github.com/PBNZ/psmm/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0-rc02 - the correctness release. Mode x Install was implemented four times and the four disagreed; there is one decision function now. BEHAVIOUR CHANGE: the import is the only thing that happens in the foreground at shell start - every install, update and gallery lookup is deferred to a background job, so nothing waits on the network, and a module installed at startup is available next session. Also fixes: an exact pin no longer force-reinstalls itself every start; "Prerelease": true is honoured without a pin; a range-pinned module can clear its update flag; files > apply no longer unloads a module whose file is disabled; Update-Help failures are reported as failures; task output is bounded and cancellable; background jobs are disposed at session end. Last release built on Spectre.Console. See CHANGELOG.md.'
        }
    }
}
