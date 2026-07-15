# Changelog

All notable changes to psmm. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [0.1.0-beta4] — 2026-07-15

### Added
- **Version display**: the running psmm version now shows next to the name
  in the profile-load report header, the main screen's title line, and the
  terminal window title.
- **Self update check**: a background gallery check runs at most once a day
  (fire-and-forget task; the result is cached next to the main config, so
  profile load never pays network cost). When a newer psmm exists, the
  profile report and a standing grid line show the exact update command;
  `$PSMM_UpdateCheck = $false` disables the check.
- **Prerelease-aware updates**: `u`/update on any module whose installed
  copy is a prerelease now uses `Install-PSResource -Prerelease -Reinstall`,
  because `Update-PSResource` cannot see a prerelease-label-only bump
  (beta2 → beta3 share the base version folder; verified against
  PSResourceGet 1.2.0). This makes `u` on psmm's own row a working
  user-driven self-update.
- README/help: an "Updating psmm" section with the verified commands
  (no `Remove-Module` needed; restart pwsh or `Import-Module psmm -Force`
  to pick up the new version).

### Changed
- **Set primary location (`s` on the paths screen)** now also puts the new
  path first in the CURRENT session's `$env:PSModulePath` (the
  `powershell.config.json` override alone only affects new sessions), so
  the new location shows up as `first` in the table immediately. The flow
  still suggests a folder in the user profile outside OneDrive
  (`$HOME\PowerShell\Modules`) and offers to create it.

### Fixed
- The startup report's retry hint still said `Ctrl+P`; it now names the
  current key (`i` on the row).
- **Crash on `s` (set primary location)**: the flow's three-line caveat text
  opened an `[orange1]` markup tag on the first `Write-PSMMLine` and closed
  it two calls later - each call is its own Spectre `Markup`, so the screen
  died with "Unbalanced markup stack" before the prompt ever appeared. Tags
  now balance per line, and a test validates every literal `Write-PSMMLine`
  markup string in `src` with Spectre's own parser.
- **"Get-PSMMModulePathInfo is not recognized" after an in-session update**:
  `Install-PSResource psmm -Prerelease -Reinstall` replaces the files on
  disk (prerelease labels share the base-version folder) while the session
  keeps running the engine it imported at startup; the first `psmm` call
  then dot-sourced the NEW UI files into the OLD engine and every run ended
  in "term not recognized" errors. `Show-PSModuleManager` now compares the
  on-disk manifest version with the running version before sourcing the UI
  and, on a mismatch, prints clear guidance (restart pwsh or
  `Import-Module psmm -Force`) instead of crashing.

## [0.1.0-beta3] — 2026-07-14

Metadata-only release; code identical to 0.1.0-beta2.

### Changed
- Module metadata: `Author` and the copyright holder are now the `PBNZ`
  handle (`(c) 2026 PBNZ` in the manifest and LICENSE); the
  "All rights reserved." boilerplate is gone since it read contradictory
  next to the MIT license.

## [0.1.0-beta2] — 2026-07-14

### Added
- **Module locations screen (`p`) with OneDrive diagnostics**: lists every
  `$env:PSModulePath` entry in search order and flags the first/CurrentUser
  entry when it lives inside OneDrive — which is PowerShell's *default*
  whenever OneDrive backs up the Documents folder (verified against
  about_PSModulePath, the PowerShell source, and the OneDrive Known Folder
  Move docs). From there: `d` downloads (hydrates) all cloud-only
  placeholder files with progress, `k` pins the folder "always keep on this
  device" (`attrib +p`), `s` sets a different primary (CurrentUser) module
  location via the documented `powershell.config.json` `PSModulePath`
  override (with backup and a corrupt-file guard), `r` removes it again.
- **Cloud-only pre-load checks**: before loading a module whose files are
  OneDrive Files On-Demand placeholders, psmm warns, asks, and downloads
  them with per-file progress (module menu and apply-to-session); grid bulk
  loads hydrate silently with a status line. Prevents the stalls/"Access to
  the cloud file is denied" failures that placeholder recalls cause
  mid-import.
- **Design system** (`docs/design-system.md`): palette, hint style, and a
  key registry so every screen binds the same verb to the same key.
- **Go home from anywhere**: `g` then `h` jumps straight back to the module
  grid from any sub-screen (the vim-style goto chord used by yazi/ranger/
  spotify_player; ctrl+h works too in Windows Terminal/conhost).
- **Copy help to the clipboard**: `c` in the tabbed command help copies the
  tab you are viewing; `c` in any text page (help, conflicts, task output)
  copies the whole page.
- **Clear too-small message**: when the terminal is too narrow/short for a
  screen's table, psmm now says so (current vs required size) instead of
  rendering a bare `...`. The grid computes the required width exactly and
  flexes the Name column before giving up.

### Changed
- **Key hints are lowercase everywhere**, and `^` now denotes ctrl
  (`^q=quit`); any hint line using a chord starts with a `^=ctrl` legend.
- **Install and update are separate actions with fixed keys**: `i` installs
  (missing targets), `u` updates (installed targets) — on the grid
  (background) and in the module menu (foreground). The gallery update
  *check* moved from `u` to `k`; the old combined `Ctrl+P` install/update
  and the module menu's `P` are gone.
- Module menu rebinds for consistency: load/unload are `^l`/`^u` (matching
  the grid), version cleanup is `x` (matching the grid's cleanup screen,
  was `K`), connection check is `s` (was `I`).
- Cleanup screen: clean-all is `^a` (was `Shift+A`).
- The update-available marker in the Ver column and the list scroll
  indicators are now `↑`/`↓` (the `^` glyph is reserved for ctrl).

## [0.1.0-beta1] — Unreleased (first public prerelease)

First release as a proper module. Everything below is relative to the
original `$PROFILE` drop-in block.

### Added
- **Alternate screen buffer**: the UI no longer wipes your terminal — on
  exit, everything you had on screen is restored (like `edit`/`less`).
- **Background tasks with a live overlay**: installs/updates (`Ctrl+P`),
  update checks (`u`), the unmanaged-module scan, and `Update-Help` all run
  in the background while the grid stays fully usable; a `t` screen shows
  every task with its output.
- **Unmanaged-module discovery**: a background scan finds installed modules
  that are in no config file; `m` reveals them; one keypress adopts them
  into a config.
- **Install-scope awareness**: grid column showing CurrentUser/AllUsers/
  mixed; actions adapt to session elevation (AllUsers cleanup is skipped
  with a notice when not elevated).
- **Duplicate-version cleanup** (`x`): lists every module with stacked old
  versions and prunes to the newest — per module or all at once.
- **Version pinning**: optional `Version` config field (exact or NuGet
  range), honoured at install and import; pinned modules are never nagged
  about updates. Pin/unpin from the module menu (`V`).
- **PowerShell Gallery search** (`g`): find modules and add them straight
  into a config file.
- **Connection status for Connect-* modules**: Microsoft Graph, Az,
  Exchange Online, PnP, Teams — see the signed-in account and disconnect
  from the module menu.
- **Per-module import timing**: the startup report and module details show
  how long each import took, so slow modules can't hide.
- **Real help system**: `?` on any screen opens context help plus a global
  key reference and the full config guide.
- **Scenario config templates** (Microsoft 365 admin, developer,
  essentials), offered by the in-UI config creator and shipped in `Configs/`.
- **Drill-in navigation**: right-arrow moves into a module / its commands;
  left-arrow backs out.
- `Get-PSMMConfigPath` public helper listing all config locations.
- **First-run bootstrap**: opening `psmm` with no config anywhere
  auto-creates `~/.psmm/psmm-config.json`, seeded with PwshSpectreConsole
  (psmm's own UI engine) as a managed InstallOnly entry. Add flows (`a`,
  adopting an unmanaged module) offer to create the config on the spot if
  none is writable.

### Changed
- Packaged as the `psmm` module with an explicit public surface:
  `Show-PSModuleManager` (alias `psmm`), `Invoke-PSMMStartup`,
  `Get-PSMMConfigPath`. Engine/UI internals are private.
- Search is now `/` everywhere (the command browser's "just start typing"
  behaviour is gone); esc clears the filter first, then goes back.
- Command-help tabs render correctly on small terminal windows.
- Every action reports progress/status immediately; every scrollable list
  shows a `row X/n` position indicator.
- Update checks and bulk installs survive individual module failures and
  report a per-module summary.
- Grid column widths come from ALL rows (not the visible window), so
  scrolling never resizes the table; short lists are padded to five rows;
  sub-screens repaint a clean page instead of appending below the grid.
- Warmer, higher-contrast colour scheme: coral keys, brighter muted text,
  and explicit 256-colour status colours that render the same in every
  terminal. The blue accent is unchanged.
- The UI stack (Spectre.Console) now loads lazily on first `psmm` use only —
  profile import cost stays within a few tens of ms of the original block
  (measured; see NOTES.md).

### Compatibility
- Existing `psmm-config.json` files work unchanged (test-covered against
  the legacy shape). The `Version` field is the only schema addition and is
  optional.
- The `$PSMM_*` profile knobs keep their original meaning
  (`$PSMM_StartupReport`, `$PSMM_BackgroundStartup`, `$PSMM_InlineJson`,
  `$PSMM_JsonPath`).
