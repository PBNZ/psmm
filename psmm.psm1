# psmm root module.
#
# Import stays cheap by design (fast startup is the whole point): only the
# engine and the public entry points are parsed here. The interactive UI
# (src/UI/*.ps1, the bulk of the code plus the PwshSpectreConsole dependency)
# is dot-sourced on the first Show-PSModuleManager call — see Initialize-PSMMUI.

$script:PSMMRoot = $PSScriptRoot
$script:PSMMUISourced = $false

# Explicit file lists: deterministic order, no directory-glob cost at import.
$psmmEngineFiles = @(
    'src/Engine/Settings.ps1'
    'src/Engine/Entry.ps1'
    'src/Engine/Discovery.ps1'
    'src/Engine/Save.ps1'
    'src/Engine/Install.ps1'
    'src/Engine/State.ps1'
    'src/Engine/Conflict.ps1'
    'src/Engine/Startup.ps1'
    'src/Engine/Tasks.ps1'
    'src/Engine/Auth.ps1'
    'src/Engine/Gallery.ps1'
)
$psmmPublicFiles = @(
    'src/Public/Invoke-PSMMStartup.ps1'
    'src/Public/Show-PSModuleManager.ps1'
    'src/Public/Get-PSMMConfigPath.ps1'
)

foreach ($f in $psmmEngineFiles + $psmmPublicFiles) {
    . (Join-Path $PSScriptRoot $f)
}

Set-Alias -Name psmm -Value Show-PSModuleManager

Export-ModuleMember `
    -Function 'Show-PSModuleManager', 'Invoke-PSMMStartup', 'Get-PSMMConfigPath' `
    -Alias 'psmm'
