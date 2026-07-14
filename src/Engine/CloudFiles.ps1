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

# Hydrate placeholders by reading them end-to-end (the documented
# RECALL_ON_DATA_ACCESS behaviour: a read fetches the content from the cloud).
# $OnProgress, when given, is called as &$OnProgress $index $total $file
# before each file so callers can render progress - downloads can be slow.
function Invoke-PSMMFileHydration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()] $Files,
        [scriptblock]$OnProgress
    )
    $ok = 0; $failed = 0; $errors = [System.Collections.Generic.List[string]]::new()
    $i = 0
    foreach ($f in @($Files)) {
        $i++
        if ($OnProgress) { & $OnProgress $i @($Files).Count $f }
        try {
            $fs = [System.IO.File]::OpenRead($f.FullName)
            try { $fs.CopyTo([System.IO.Stream]::Null) } finally { $fs.Dispose() }
            $ok++
        } catch {
            $failed++
            $errors.Add("$($f.Name): $($_.Exception.Message)")
        }
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
