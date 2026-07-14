# psmm — PowerShell Session Module Manager

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/psmm?include_prereleases&label=PowerShell%20Gallery)](https://www.powershellgallery.com/packages/psmm)
[![Downloads](https://img.shields.io/powershellgallery/dt/psmm?label=downloads)](https://www.powershellgallery.com/packages/psmm)
[![CI](https://github.com/PBNZ/psmm/actions/workflows/ci.yml/badge.svg)](https://github.com/PBNZ/psmm/actions/workflows/ci.yml)

Fast, declarative module loading at shell start, plus a keyboard-driven
terminal UI to manage it all.

**On the [PowerShell Gallery](https://www.powershellgallery.com/packages/psmm):**
`Install-PSResource psmm -Prerelease`

You describe the modules you care about in small JSON files — *load this at
startup, just keep that installed, leave those alone* — and psmm makes your
profile do exactly that, fast, with the slow work pushed to a background job.
The `psmm` command then gives you a live terminal manager: load/unload,
install/update, version pinning and cleanup, gallery search, command
browsing with full help, connection status for `Connect-*` modules, config
file management — all without leaving your shell, and without wiping your
terminal scrollback.

> [!IMPORTANT]
> **Vibe-coded personal project.** psmm was designed and is reviewed by a
> human, but largely written by an AI coding agent. Right now it exists for
> personal use and for sharing with friends and colleagues. Anyone is
> welcome to use it — but for the first few days and weeks, **issues and
> feature requests are limited to contributors** while it settles. If that's
> not you yet, feel free to fork; broader participation opens up soon.

Requires **PowerShell 7.0+**. Windows-first (the engine is platform-neutral;
non-Windows UI support is on the roadmap).

## Install

psmm is currently in **prerelease** on the PowerShell Gallery — you have to
ask for it explicitly:

```powershell
Install-PSResource psmm -Prerelease            # PSResourceGet (PS 7.4+ built-in)
# or: Install-Module psmm -AllowPrerelease     # legacy PowerShellGet
```

Or run it straight from a clone:

```powershell
git clone https://github.com/PBNZ/psmm
Import-Module .\psmm\psmm.psd1
```

(Clone/copy the folder into `~\Documents\PowerShell\Modules\psmm` instead
and plain `Import-Module psmm` plus autoloading work as if installed.)

### Updating psmm

While psmm is in prerelease, beta-to-beta updates need a forced reinstall —
`Update-PSResource` cannot see a prerelease-label-only bump (`0.1.0-beta2` →
`0.1.0-beta3` share the same base version, verified against PSResourceGet
1.2.0):

```powershell
Install-PSResource psmm -Prerelease -Reinstall
```

Then restart pwsh (or `Import-Module psmm -Force` in the current session).
No `Remove-Module` needed first — the reinstall succeeds while psmm is
loaded; your session simply keeps running the old copy until the reload.
Once psmm is stable, a plain `Update-PSResource psmm` does the job.

psmm also checks for updates itself: a background check runs at most once a
day (never delaying your prompt — the result is cached and shown at the
*next* profile load and in the UI). When a newer version exists you get the
exact command above, or just press `u` on psmm's own row in the grid —
psmm's update path knows about the prerelease quirk. Set
`$PSMM_UpdateCheck = $false` before `Import-Module psmm` to disable the
check entirely.

## Quickstart

**1. Bootstrap your profile.** Add two lines to `$PROFILE`:

```powershell
Import-Module psmm
Invoke-PSMMStartup
```

**2. Get a config.** The first `psmm` run creates
`~/.psmm/psmm-config.json` for you if no config exists anywhere (seeded with
PwshSpectreConsole, psmm's own UI engine, as a managed entry). To start from
a scenario template instead, press `f` (files) then `n` (new). Or just write
the JSON yourself:

```json
{
  "Modules": [
    { "Name": "Terminal-Icons" },
    { "Name": "ImportExcel", "Mode": "InstallOnly" },
    { "Name": "Az.Accounts", "Mode": "Ignore" }
  ]
}
```

**3. Restart your shell.** Managed `Load` modules import (with per-module
timings so you always know what's slow); `InstallOnly` work runs in a
background job; the report tells you what happened.

**4. Manage interactively.** Run `psmm`:

- one grid row per module: loaded/installed/missing, source file, mode,
  install policy, scope (CurrentUser/AllUsers), version, update marker
- `space` select · `^l`/`^u` load/unload (`^` = ctrl) · `i` install · `u` update
  · `k` check for updates
- `/` search (everywhere) · `?` help (everywhere) · `g h` home (anywhere) ·
  `^q` quit (anywhere)
- `g` search the PowerShell Gallery and add modules to your config
- `x` clean up stacked old module versions
- `m` reveal installed-but-unmanaged modules and adopt them into a config
- `f` config file manager · `c` conflicts & validation · `t` background tasks
- `p` module locations: see `$env:PSModulePath`, get warned when your
  CurrentUser module folder lives inside OneDrive (PowerShell's default when
  OneDrive backs up Documents), download or pin cloud-only module files, and
  move the primary location via the documented `powershell.config.json`
  override

Long operations run as background tasks with an unobtrusive progress line —
the UI never blocks. Exiting restores your terminal exactly as it was.

## Public API

| Command | What it does |
|---|---|
| `Invoke-PSMMStartup` | Runs the startup loader (the `$PROFILE` line). `-Quiet` suppresses the report. |
| `Show-PSModuleManager` | Opens the interactive manager. Alias: **`psmm`**. |
| `Get-PSMMConfigPath` | Lists every config location psmm checks, in load order, with existence. |

Optional `$PROFILE` knobs (set **before** `Import-Module psmm`):
`$PSMM_StartupReport = $false`, `$PSMM_BackgroundStartup = $false`,
`$PSMM_UpdateCheck = $false`, `$PSMM_InlineJson = '<json>'`,
`$PSMM_JsonPath = @('C:\dir\*.json')`, `$PSMM_MainConfigPath`,
`$PSMM_ProfileConfigPath`.

## Config

Full reference: [docs/config-schema.md](docs/config-schema.md). The short
version: up to five sources (inline JSON, the main config at
`~/.psmm/psmm-config.json`, its `Includes`, a profile-directory config,
legacy globs); per-module `Install` policy (`CheckOnly` / `IfMissing` /
`Latest`) is independent of `Mode` (`Load` / `InstallOnly` / `Ignore`);
optional `Version` pins an exact version or NuGet range; `"Enabled": false`
parks a whole file without losing it; the main config wins name conflicts.

Ready-made scenario configs ship in [`Configs/`](Configs/) (Microsoft 365
admin, developer, essentials) and are offered by the in-UI file creator.

## Development

```powershell
Invoke-Pester -Path Tests                                   # full suite
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Layout: `src/Engine` (platform-neutral core, parsed at import),
`src/Public` (exported commands), `src/UI` (the interactive manager —
parsed only on first use, so `Import-Module psmm` stays fast). Significant
design decisions are recorded in [DECISIONS.md](DECISIONS.md).

## License

MIT — see [LICENSE](LICENSE).
