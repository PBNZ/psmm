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
            Prerelease   = 'beta2'
            ProjectUri   = 'https://github.com/PBNZ/psmm'
            LicenseUri   = 'https://github.com/PBNZ/psmm/blob/main/LICENSE'
            ReleaseNotes = 'v0.1.0-beta2 - design-system key scheme (i/u install/update, ^=ctrl, g h home), OneDrive module-location diagnostics with cloud-only download/pin, too-small-window message, copy help to clipboard. See CHANGELOG.md.'
        }
    }
}
