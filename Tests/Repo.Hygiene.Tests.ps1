# Repository hygiene: nothing personal, nothing machine-specific, in tracked
# files. This is a PUBLIC repo whose recorded convention is to identify the
# maintainer by handle only (see the 'Scrub personal traces for public release'
# and 'identify the maintainer by handle everywhere' commits).
#
# Why this exists: during 0.1.0-rc02 a diagnostic's raw output - including a
# real account name and drive layout - was pasted into a handoff document as
# evidence and pushed to the public remote. It was caught by review, not by a
# gate, and the ad-hoc grep that would have caught it had been run three
# commits earlier and never repeated. A check you have to remember is not a
# check. This one runs in the suite, so it runs on every commit and in CI.
#
# It deliberately hard-codes NO names. The account name it looks for is read
# from the environment at run time, so it protects whoever runs it and records
# nothing about them in the repo.
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent

    # Only files git actually tracks: .tools/, scratch and ignored output are
    # not shipped and not our business.
    $script:Tracked = @(
        & git -C $script:RepoRoot ls-files 2>$null
    ) | Where-Object { $_ }

    function Get-TrackedText {
        param([string[]]$ExcludeLike = @())
        foreach ($rel in $script:Tracked) {
            # NB: a flag, not `return` - `return` inside this nested foreach
            # would exit the whole FUNCTION at the first excluded file and
            # silently stop scanning everything after it. It did exactly that
            # until CI caught it, which is the failure mode this guard exists
            # to prevent, so it is worth the comment.
            $skip = $false
            foreach ($x in $ExcludeLike) { if ($rel -like $x) { $skip = $true; break } }
            if ($skip) { continue }
            $full = Join-Path $script:RepoRoot $rel
            # -Force everywhere: on Unix a leading dot makes a file HIDDEN to
            # the PowerShell provider, so .gitignore / .github are invisible
            # without it - and those are exactly the files worth scanning.
            $item = $null
            try { $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop } catch { continue }
            if ($item.PSIsContainer) { continue }
            if ($item.Length -gt 2MB) { continue }          # binaries / oversized
            $text = $null
            try { $text = Get-Content -LiteralPath $full -Raw -Force -ErrorAction Stop } catch { continue }
            if ($null -eq $text) { continue }
            [pscustomobject]@{ Path = $rel; Text = $text }
        }
    }

    # Segments that are obviously stand-ins, not somebody's account.
    $script:Placeholders = @(
        'user', 'users', 'username', 'youruser', 'someone', 'you', 'me',
        'test', 'testuser', 'example', 'name', 'account', 'public', 'default',
        'all', 'alluser', 'allusers', 'currentuser', 'runner', 'runneradmin',
        'administrator', 'root', 'home'
    )

    # The maintainer's PUBLIC handle is the sanctioned identifier - it is the
    # manifest Author and half the ProjectUri, and using it is the policy, not
    # a leak. Read from the manifest so this list maintains itself and no name
    # is written down here.
    try {
        $author = (Import-PowerShellDataFile (Join-Path $script:RepoRoot 'psmm.psd1')).Author
        if ($author) { $script:Placeholders += $author.ToLowerInvariant() }
    } catch { }

    # Documentation placeholder domains (Microsoft's reserved examples).
    $script:AllowedMailPattern = 'noreply|users\.noreply|@(example|contoso|fabrikam|adventure-works)\.'

    # Reduce a captured path segment to the account-looking part: strips HTML
    # entities ('pbnz&gt'), trailing punctuation and quoting.
    function Get-AccountSegment {
        param([string]$Segment)
        $head = ($Segment -split '[^A-Za-z0-9]')[0]
        $head.ToLowerInvariant()
    }
}

Describe 'Repository hygiene - nothing personal in tracked files' -Tag Engine, Hygiene {

    It 'contains no home-directory path with a real account name' {
        # C:\Users\<seg>  /home/<seg>  /Users/<seg>  - flagged unless <seg> is a
        # placeholder or a variable/token ($env:..., <user>, %USERNAME%, ~).
        $patterns = @(
            '[A-Za-z]:\\Users\\([^\\/\s"'')\],;:]+)'
            '/home/([^/\s"'')\],;:]+)'
            '/Users/([^/\s"'')\],;:]+)'
        )
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($f in (Get-TrackedText -ExcludeLike @('Tests/Repo.Hygiene.Tests.ps1'))) {
            $n = 0
            foreach ($line in ($f.Text -split "`r?`n")) {
                $n++
                foreach ($p in $patterns) {
                    foreach ($m in [regex]::Matches($line, $p)) {
                        $seg = $m.Groups[1].Value
                        if (-not $seg) { continue }
                        # variables and tokens are fine: $env:..., <user>, %USERNAME%, ~
                        if ($seg -match '^[<%$~\*\{]') { continue }
                        $acct = Get-AccountSegment -Segment $seg
                        if (-not $acct) { continue }
                        if ($acct.Length -le 2) { continue }             # 'x', 'p' - test fixtures
                        if ($acct -in $script:Placeholders) { continue }
                        $offenders.Add("$($f.Path):$n  $($m.Value)")
                    }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "these look like a real account's paths:`n$($offenders -join "`n")"
    }

    It 'does not contain the account name of whoever is running this' {
        # Reads the name at run time and never writes it down. Protects every
        # contributor, including the one who introduced the original leak.
        $me = @($env:USERNAME, $env:USER) | Where-Object { $_ -and $_.Length -ge 4 } | Select-Object -First 1
        if (-not $me) { Set-ItResult -Skipped -Because 'no account name in the environment to check against'; return }
        if (($me -replace '[^A-Za-z]', '').ToLowerInvariant() -in $script:Placeholders) {
            Set-ItResult -Skipped -Because "the account name '$me' is itself a generic word - it would false-positive"
            return
        }
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($f in (Get-TrackedText -ExcludeLike @('Tests/Repo.Hygiene.Tests.ps1'))) {
            $n = 0
            foreach ($line in ($f.Text -split "`r?`n")) {
                $n++
                if ($line -match [regex]::Escape($me)) { $offenders.Add("$($f.Path):$n") }
            }
        }
        # the account name itself is NOT quoted into the failure message
        $offenders | Should -BeNullOrEmpty -Because "your account name appears in tracked files at:`n$($offenders -join "`n")"
    }

    It 'contains no personal email address' {
        # the manifest's author address is a GitHub noreply, which is the point
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($f in (Get-TrackedText -ExcludeLike @('Tests/Repo.Hygiene.Tests.ps1'))) {
            $n = 0
            foreach ($line in ($f.Text -split "`r?`n")) {
                $n++
                foreach ($m in [regex]::Matches($line, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')) {
                    if ($m.Value -match $script:AllowedMailPattern) { continue }
                    $offenders.Add("$($f.Path):$n  $($m.Value)")
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "tracked files must carry no personal address:`n$($offenders -join "`n")"
    }

    It 'the guard covers the whole tracked tree, not a stale subset' {
        # if git ls-files ever comes back empty the checks above pass vacuously
        @($script:Tracked).Count | Should -BeGreaterThan 20
        $script:Tracked | Should -Contain 'psmm.psd1'
        $script:Tracked | Should -Contain 'docs/rc02-handoff.md'
    }

    It 'actually reads every tracked file, including hidden ones and those after an exclusion' {
        # Two ways this guard can go quietly blind, both of which it did:
        #  1. `return` in the exclusion loop stopped the scan at the first
        #     excluded file, so everything sorting after it went unchecked.
        #  2. Without -Force, dot-files are HIDDEN to the provider on Unix, so
        #     .gitignore and .github/** were unreadable and threw.
        $seen = @(Get-TrackedText -ExcludeLike @('Tests/Repo.Hygiene.Tests.ps1')).Path
        $seen | Should -Not -Contain 'Tests/Repo.Hygiene.Tests.ps1' -Because 'the exclusion must work'
        $seen | Should -Contain '.gitignore' -Because 'dot-files are hidden on Unix without -Force'
        $seen | Should -Contain '.github/workflows/ci.yml'
        # sorts AFTER the excluded file in git ls-files byte order, so a
        # truncating scan would miss it
        $seen | Should -Contain 'psmm.psd1' -Because 'the scan must not stop at the first exclusion'
        @($seen).Count | Should -BeGreaterThan (@($script:Tracked).Count * 0.7) -Because 'most tracked files should be readable text'
    }
}
