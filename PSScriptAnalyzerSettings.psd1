@{
    # Lint gate for the module source (psm1/psd1 + src/). Tests are linted
    # with the same file but exercise user-facing globals deliberately.
    #
    # Every exclusion below is a considered decision, not a shortcut:
    #
    # PSAvoidUsingEmptyCatchBlock
    #   psmm probes optional state everywhere (console size, job state,
    #   provider status, writability). The empty catch IS the documented
    #   degrade path: probe fails -> feature reports "unknown"/default,
    #   never an exception into the render loop.
    #
    # PSUseShouldProcessForStateChangingFunctions
    #   Flagged functions (Set-PSMMAllEntries, Update-PSMMLoaded,
    #   Start-PSMMTask, ...) mutate in-memory module state or start
    #   ThreadJobs inside an interactive TUI. -WhatIf/-Confirm semantics on
    #   per-keypress internals would be noise; the destructive operations a
    #   user cares about (delete entry, uninstall version) prompt in the UI.
    #
    # PSUseSingularNouns
    #   Get-PSMMAllEntries et al. return collections by contract; renaming
    #   to singular would hurt readability for no behavioural gain.
    #
    # PSAvoidGlobalVars
    #   The $PSMM_* user knobs are read (never written) from global scope -
    #   that is the documented back-compat contract with the original
    #   profile block. Tests also assign these globals to drive scenarios.
    ExcludeRules = @(
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
        'PSAvoidGlobalVars'
    )
}
