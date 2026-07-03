# 01-Input.ps1 — key reading with resize + background-activity wake-ups.

# Is this key the universal hard-quit chord (Ctrl+Q / Ctrl+X)?
function script:Test-PSMMHardQuitKey {
    param([Parameter(Mandatory)] $KeyInfo)
    ((($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -and
     ($KeyInfo.Key -in [ConsoleKey]::Q, [ConsoleKey]::X))
}

# Key read that also notices terminal resizes and background-task activity:
# returns $null when the window size changed OR a background job/task changed
# state or produced output (caller should re-render, typically via continue).
# Falls back to a plain blocking read where KeyAvailable is unsupported.
function script:Read-PSMMKeyResize {
    $w0 = Get-PSMMWinSize
    $fp0 = Get-PSMMTaskFingerprint
    $tick = 0
    while ($true) {
        try { if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) } }
        catch { return [Console]::ReadKey($true) }
        Start-Sleep -Milliseconds 100
        $w = Get-PSMMWinSize
        if ($w.Width -ne $w0.Width -or $w.Height -ne $w0.Height) { return $null }
        # every 500 ms: wake when background activity changed, so the grid's
        # overlay and job lines update by themselves (#25)
        $tick++
        if ($tick % 5 -eq 0) {
            $fp = Get-PSMMTaskFingerprint
            if ($fp -ne $fp0) { return $null }
        }
    }
}

# Consistent "press a key" pause that honours Ctrl+Q / Ctrl+X (hard quit).
# Returns $false when hard-quitting so callers can bail out immediately.
function script:Wait-PSMMKey {
    param([string]$Message = 'press any key to continue')
    Write-PSMMLine (Get-PSMMHint -Pairs @("any key=$Message", 'Ctrl+Q=quit'))
    $k = [Console]::ReadKey($true)
    if (Test-PSMMHardQuitKey $k) {
        $script:PSMM_UI.HardQuit = $true
        return $false
    }
    return $true
}
