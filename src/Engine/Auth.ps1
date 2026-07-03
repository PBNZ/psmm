# Auth.ps1 — connection status + disconnect for Connect-* style modules (#32).
# Everything here is on-demand and read-only except Disconnect-PSMMModule,
# which only ever runs on an explicit user keypress. Unknown modules and any
# provider error degrade to "unknown" — never an exception into the UI.

# Known providers. StatusCmd is invoked only if it exists in the session
# (i.e. the module is loaded); Slow marks providers whose status check does
# network round-trips, so the UI can label the wait.
function Get-PSMMAuthProviderTable {
    [CmdletBinding()] param()
    @(
        [pscustomobject]@{
            Module = 'ExchangeOnlineManagement'
            StatusCmd = 'Get-ConnectionInformation'
            Account = { param($s) @($s)[0].UserPrincipalName }
            Detail  = { param($s) @($s)[0].ConnectionUri }
            DisconnectCmd = 'Disconnect-ExchangeOnline'
            DisconnectArgs = @{ Confirm = $false }
            Slow = $false
        }
        [pscustomobject]@{
            Module = 'Microsoft.Graph.Authentication'
            StatusCmd = 'Get-MgContext'
            Account = { param($s) $s.Account }
            Detail  = { param($s) "tenant $($s.TenantId)" }
            DisconnectCmd = 'Disconnect-MgGraph'
            DisconnectArgs = @{}
            Slow = $false
        }
        [pscustomobject]@{
            Module = 'Az.Accounts'
            StatusCmd = 'Get-AzContext'
            Account = { param($s) $s.Account.Id }
            Detail  = { param($s) "subscription $($s.Subscription.Name)" }
            DisconnectCmd = 'Disconnect-AzAccount'
            DisconnectArgs = @{}
            Slow = $false
        }
        [pscustomobject]@{
            Module = 'PnP.PowerShell'
            StatusCmd = 'Get-PnPConnection'
            Account = { param($s) $s.Url }
            Detail  = { param($s) $s.ConnectionType }
            DisconnectCmd = 'Disconnect-PnPOnline'
            DisconnectArgs = @{}
            Slow = $false
        }
        [pscustomobject]@{
            Module = 'MicrosoftTeams'
            StatusCmd = 'Get-CsTenant'
            Account = { param($s) $s.DisplayName }
            Detail  = { param($s) "tenant $($s.TenantId)" }
            DisconnectCmd = 'Disconnect-MicrosoftTeams'
            DisconnectArgs = @{}
            Slow = $true
        }
    )
}

function Get-PSMMAuthProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleName)
    Get-PSMMAuthProviderTable | Where-Object Module -eq $ModuleName | Select-Object -First 1
}

# Connection status for one module:
#   Supported=$false                  -> not a Connect-* module we know
#   Supported, Connected=$false       -> known module, no active session
#   Supported, Connected, Account,... -> signed in
function Get-PSMMConnectionStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleName)
    $p = Get-PSMMAuthProvider -ModuleName $ModuleName
    if (-not $p) { return [pscustomobject]@{ Supported = $false; Connected = $false; Account = $null; Detail = $null; Slow = $false } }
    $result = [pscustomobject]@{ Supported = $true; Connected = $false; Account = $null; Detail = $null; Slow = $p.Slow }
    if (-not (Get-Command $p.StatusCmd -ErrorAction SilentlyContinue)) { return $result }  # module not loaded
    try {
        $status = & $p.StatusCmd -ErrorAction Stop
        if ($status) {
            $result.Connected = $true
            try { $result.Account = & $p.Account $status } catch { }
            try { $result.Detail = & $p.Detail $status } catch { }
        }
    } catch { }   # treat any provider hiccup as "not connected"
    $result
}

# Disconnect one module's session. Only ever called on explicit user action.
function Disconnect-PSMMModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleName)
    $p = Get-PSMMAuthProvider -ModuleName $ModuleName
    if (-not $p) { throw "psmm: no disconnect support for '$ModuleName'" }
    if (-not (Get-Command $p.DisconnectCmd -ErrorAction SilentlyContinue)) { throw "psmm: $($p.DisconnectCmd) not available (module not loaded?)" }
    $splat = $p.DisconnectArgs
    & $p.DisconnectCmd @splat -ErrorAction Stop
}
