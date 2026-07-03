# Changelog

All notable changes to psmm. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [0.1.0] — Unreleased (private-testing candidate)

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
