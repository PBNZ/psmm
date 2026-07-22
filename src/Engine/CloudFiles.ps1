# CloudFiles.ps1 — OneDrive / Files On-Demand awareness + PSModulePath info.
#
# Why this exists: on Windows, pwsh derives its FIRST PSModulePath entry (the
# CurrentUser location) from the Documents known folder
# (about_PSModulePath; ModuleIntrinsics.cs GetPersonalModulePath). OneDrive
# Known Folder Move — including the admin policy "Silently move Windows known
# folders to OneDrive", i.e. zero user action — redirects Documents into
# OneDrive (learn.microsoft.com/sharepoint/redirect-known-folders). With
# Files On-Demand, module files can then be cloud-only placeholders whose
# every read is a remote fetch; when the fetch stalls or is denied, module
# discovery and Import-Module fail in confusing ways (e.g. PSResourceGet #300
# "Access to the cloud file is denied").
#
# Attribute values verified against the Win32 File Attribute Constants doc
# and [MS-FSCC] 2.6:
#   FILE_ATTRIBUTE_OFFLINE               0x00001000
#   FILE_ATTRIBUTE_RECALL_ON_OPEN        0x00040000  (item is virtual)
#   FILE_ATTRIBUTE_UNPINNED              0x00100000  (may be dehydrated)
#   FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS 0x00400000  (content not fully local;
#                                        reading fetches it from the cloud)
# Reading a placeholder hydrates it — that is the documented design of
# RECALL_ON_DATA_ACCESS — so hydration here is simply a full sequential read.

$script:PSMM_AttrRecallOnDataAccess = 0x00400000
$script:PSMM_AttrRecallOnOpen       = 0x00040000

# Content is NOT fully on disk when either recall attribute is set.
function Test-PSMMCloudOnlyAttribute {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Attributes)
    (($Attributes -band $script:PSMM_AttrRecallOnDataAccess) -ne 0) -or
    (($Attributes -band $script:PSMM_AttrRecallOnOpen) -ne 0)
}

# Is the path under a OneDrive root? (personal or business - the sync client
# publishes its roots as environment variables)
function Test-PSMMOneDrivePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    foreach ($v in 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') {
        $root = [Environment]::GetEnvironmentVariable($v)
        if ($root -and $Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# All cloud-only placeholder files under a path (empty on non-Windows and for
# missing paths).
function Get-PSMMCloudOnlyFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { return @() }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Ignore)) { return @() }
    @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-PSMMCloudOnlyAttribute -Attributes ([int]$_.Attributes) })
}

# Cloud-only files across every installed base of one module. Only OneDrive
# bases are scanned - everything else can't be a placeholder, and this runs
# in load paths where speed matters.
function Get-PSMMModuleCloudOnlyFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not $IsWindows) { return @() }
    $bases = @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ModuleBase -Unique |
        Where-Object { Test-PSMMOneDrivePath -Path $_ })
    @(foreach ($b in $bases) { Get-PSMMCloudOnlyFile -Path $b })
}

# How many placeholders psmm will recall at once (gh#14).
#
# Hydration is one blocking read per file, each waiting on a OneDrive round
# trip, so the work is latency-bound and overlapping it is a big win. The cap
# is the machine's LOGICAL PROCESSOR COUNT: every reader costs a runspace and a
# thread, and past one per core the extra threads only queue behind the ones
# already waiting - the sync client, not psmm, becomes the limit. Floored at 2
# so a single-core box still overlaps two requests; ceiling 16 keeps a 64-core
# workstation from spawning 64 runspaces for a folder of 20 files.
function Get-PSMMHydrationMax {
    [CmdletBinding()] param()
    [Math]::Max(2, [Math]::Min(16, [Environment]::ProcessorCount))
}

function Get-PSMMHydrationDefault {
    [CmdletBinding()] param()
    [Math]::Max(1, [Math]::Min(4, (Get-PSMMHydrationMax)))
}

# Why the max is the max, in one sentence for the UI to show. A bare number
# tells the user nothing, and the reason differs depending on which of the two
# bounds actually bit.
function Get-PSMMHydrationMaxReason {
    [CmdletBinding()] param()
    $max = Get-PSMMHydrationMax
    $cores = [Environment]::ProcessorCount
    $why = 'each download holds a thread waiting on OneDrive, so extra readers just queue up behind the ones already waiting'
    if ($max -lt $cores) {
        return "max $max - this machine has $cores logical processors, but psmm stops at 16: $why"
    }
    "max $max = this machine's logical processor count: $why"
}

# Hydrate placeholders by reading them end-to-end (the documented
# RECALL_ON_DATA_ACCESS behaviour: a read fetches the content from the cloud).
# $OnProgress, when given, is called as &$OnProgress $index $total $file so
# callers can render progress - downloads can be slow.
# -ThrottleLimit 1 (default) keeps the sequential path: progress is reported
# BEFORE each read, in file order. Above 1 the reads run concurrently and
# progress is reported as each file COMPLETES, so the order is completion
# order, not file order.
function Invoke-PSMMFileHydration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()] $Files,
        [scriptblock]$OnProgress,
        [int]$ThrottleLimit = 1
    )
    $all = @($Files)
    $total = $all.Count
    $ok = 0; $failed = 0; $errors = [System.Collections.Generic.List[string]]::new()
    $i = 0
    if ($ThrottleLimit -le 1 -or $total -le 1) {
        foreach ($f in $all) {
            $i++
            if ($OnProgress) { & $OnProgress $i $total $f }
            try {
                $fs = [System.IO.File]::OpenRead($f.FullName)
                try { $fs.CopyTo([System.IO.Stream]::Null) } finally { $fs.Dispose() }
                $ok++
            } catch {
                $failed++
                $errors.Add("$($f.Name): $($_.Exception.Message)")
            }
        }
        return [pscustomobject]@{ Ok = $ok; Failed = $failed; Errors = $errors }
    }
    # Parallel: ForEach-Object -Parallel streams each result as it lands, so the
    # progress callback still runs on THIS thread (calling a caller-supplied
    # scriptblock from a worker runspace would not be safe).
    $limit = [Math]::Min($ThrottleLimit, (Get-PSMMHydrationMax))
    $all | ForEach-Object -ThrottleLimit $limit -Parallel {
        $f = $_
        try {
            $fs = [System.IO.File]::OpenRead($f.FullName)
            try { $fs.CopyTo([System.IO.Stream]::Null) } finally { $fs.Dispose() }
            [pscustomobject]@{ File = $f; Ok = $true; Error = $null }
        } catch {
            [pscustomobject]@{ File = $f; Ok = $false; Error = $_.Exception.Message }
        }
    } | ForEach-Object {
        $i++
        if ($OnProgress) { & $OnProgress $i $total $_.File }
        if ($_.Ok) { $ok++ } else { $failed++; $errors.Add("$($_.File.Name): $($_.Error)") }
    }
    [pscustomobject]@{ Ok = $ok; Failed = $failed; Errors = $errors }
}

# The default CurrentUser module location pwsh derives from the Documents
# known folder (the value OneDrive KFM moves).
function Get-PSMMUserDefaultModulePath {
    [CmdletBinding()] param()
    if (-not $IsWindows) { return $null }
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($docs)) { return $null }
    Join-Path (Join-Path $docs 'PowerShell') 'Modules'
}

# One record per $env:PSModulePath entry, annotated for the paths screen.
function Get-PSMMModulePathInfo {
    [CmdletBinding()] param()
    $userDefault = Get-PSMMUserDefaultModulePath
    $sep = [System.IO.Path]::PathSeparator
    $i = 0
    @(foreach ($p in ($env:PSModulePath -split $sep | Where-Object { $_ })) {
        [pscustomobject]@{
            Order       = $i
            Path        = $p
            First       = ($i -eq 0)
            # -ErrorAction Ignore: an entry we cannot even stat (e.g. under
            # /root on CI) must count as not-ours, not crash the listing
            Exists      = (Test-Path -LiteralPath $p -ErrorAction Ignore)
            OneDrive    = (Test-PSMMOneDrivePath -Path $p)
            UserDefault = ($userDefault -and ($p.TrimEnd('\', '/') -eq $userDefault.TrimEnd('\', '/')))
        }
        $i++
    })
}

# Path of the CurrentUser powershell.config.json (about_PowerShell_Config:
# "The user configuration directory can be found across platforms with the
# command Split-Path $PROFILE.CurrentUserCurrentHost").
function Get-PSMMUserConfigJsonPath {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reading $global:PROFILE is the point: the user config dir is defined by it.')]
    [CmdletBinding()] param()
    $profilePath = $global:PROFILE
    if ($profilePath -and $profilePath.PSObject.Properties['CurrentUserCurrentHost']) {
        $profilePath = $profilePath.CurrentUserCurrentHost
    }
    if ([string]::IsNullOrWhiteSpace("$profilePath")) { return $null }
    Join-Path (Split-Path -Parent "$profilePath") 'powershell.config.json'
}

# Set (or with -Clear remove) the CurrentUser module path override in
# powershell.config.json ("PSModulePath" key, about_PowerShell_Config).
# Preserves every other key. A corrupt config file stops pwsh from starting
# interactive sessions, so: refuse to touch a file we cannot parse, and write
# a .bak of the previous content first. Throws on failure.
# NOTE (documented caveat): this changes where pwsh LOOKS for CurrentUser
# modules; Install-Module/Install-PSResource keep installing to the DEFAULT
# Documents-derived location.
function Set-PSMMUserModulePath {
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$Clear,
        [string]$ConfigPath   # test seam; defaults to the real user config
    )
    if (-not $Clear -and [string]::IsNullOrWhiteSpace($Path)) { throw 'a path is required (or -Clear)' }
    $cfgPath = if ($ConfigPath) { $ConfigPath } else { Get-PSMMUserConfigJsonPath }
    if (-not $cfgPath) { throw 'cannot locate the user powershell.config.json (no $PROFILE in this host)' }
    $obj = [ordered]@{}
    if (Test-Path -LiteralPath $cfgPath) {
        $raw = Get-Content -LiteralPath $cfgPath -Raw
        try { $parsed = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { throw "refusing to modify $cfgPath - it does not parse as JSON ($($_.Exception.Message))" }
        foreach ($k in $parsed.Keys) { $obj[$k] = $parsed[$k] }
        Set-Content -LiteralPath "$cfgPath.bak" -Value $raw -Encoding utf8
    }
    if ($Clear) { $obj.Remove('PSModulePath') }
    else { $obj['PSModulePath'] = $Path }
    $dir = Split-Path -Parent $cfgPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ([pscustomobject]$obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $cfgPath -Encoding utf8
    $cfgPath
}

# Tell the OneDrive sync client to keep a folder tree permanently local
# ("always available"): attrib +p, the Microsoft-documented pin
# (learn.microsoft.com/sharepoint/files-on-demand-windows - "Pinning an
# online-only file makes the sync app download the file contents"). The
# download itself happens in the background via the sync client.
function Invoke-PSMMPinPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { throw 'pinning is a Windows / OneDrive feature' }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Ignore)) { throw "path not found: $Path" }
    & "$env:SystemRoot\System32\attrib.exe" +p -u "$Path\*" /s /d
    if ($LASTEXITCODE -ne 0) { throw "attrib.exe failed with exit code $LASTEXITCODE" }
}
