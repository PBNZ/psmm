# Changelog

All notable changes to psmm. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [Unreleased]

### Fixed
- **Gallery search asks the gallery the question you meant** (gh#17). Every
  bare term was wrapped as `*term*` and handed to `Find-PSResource -Name`,
  which matches the module **name** only. Measured against the live gallery
  (2026-07-23, PSResourceGet 1.2.0):
  - `excel` returned `Search-ExcelFileWithUI` first and buried `ImportExcel`
    (22.9M downloads) in sixth place — the website puts it first.
  - `sharepoint` could not reach `PnP.PowerShell` at all, and `excel` could
    not reach `GetSQL` or `PSWriteOffice`: the word is in the description,
    never the name.
  - `a` pulled **8828 records over the wire in 216 seconds** and then cut
    them to an arbitrary 40, because `-First` cannot be pushed down into a
    glob. The same search now takes **0.5 s**.
  - `psmm` found nothing, because a module that has only ever published
    prereleases is invisible to the default query.

  A bare term now goes to the OData `Search()` endpoint the gallery website
  itself calls — name + description + tags, the site's own relevance order,
  limited server-side. An explicit wildcard still goes to the provider, which
  is the only thing that can honour one, and a pattern that matches nothing
  retries its words as a full-text search. A leading wildcard has also been
  seen to return 0 results *and* 0 errors — the original report — and psmm no
  longer builds one anywhere.
- **An empty gallery screen says why it is empty.** "No results." covered
  both "the gallery has nothing" and "the search service never answered";
  those are different answers and now read differently. If the endpoint
  fails, the search falls back to a name-prefix lookup and says so.

### Added
- The gallery table has a **downloads** column (`22.9M`), with the exact
  count on the context line — the one signal that says which of forty
  similar-looking modules people actually use. Results carry their
  repository, named on the context line when it is not the public gallery.
- Repositories other than the public gallery stay searchable: the endpoint
  only knows `powershellgallery.com`, so anything else registered is asked
  through the provider and merged in, bounded so a large internal feed cannot
  bury the gallery's ranking.
- A gallery result renders its prerelease label (design system §11) — it used
  to drop it, so `0.1.0-beta9` read as `0.1.0`.

## [0.1.0-beta9] — 2026-07-22

Live-run feedback round four, and one serious bug it uncovered.

### Fixed
- **Modules are imported into YOUR session again** (gh#2). `Import-Module`
  called from inside a module imports into *that module's* session state
  unless `-Global` is passed — and psmm is a module. Every module psmm
  loaded (at startup, from the grid, from the module menu, via files ›
  apply) therefore landed in psmm's private state: invisible to
  `Get-Module`, its commands "not recognized" at the prompt — while psmm's
  own state check, which sees its private imports too, reported `● loaded`
  for the rest of the session. Command auto-loading hid this for modules
  that export explicit names; a module whose manifest exports `*` (e.g.
  `Microsoft.Online.SharePoint.PowerShell`) cannot auto-load and broke
  outright. Every import now passes `-Global`, with an AST-based guard test
  so it cannot come back.
- **Long prose no longer runs the full terminal width** (gh#11): every
  explanation wraps at `min(window − 4, 84)` columns, like the tables and
  hint rows already did.
- **A filter containing `[` no longer takes the screen down.** `-like "*[*"`
  throws *"the specified wildcard character pattern is not valid"*; filters
  are free text, so they now use a plain case-insensitive substring test.
- **A path containing `[` or `]` no longer crashes a confirmation prompt** —
  those are legal in Windows filenames and Spectre parses a prompt message as
  markup. Every prompt that interpolates text now escapes it, with a guard
  test.
- **A prerelease version can actually be pinned.** The pin accepts
  `1.2.3-beta4`, installs with `-Prerelease`, and imports by its base version
  (`-RequiredVersion` is typed `[version]` and throws on a label).
- **The grid's bulk `ctrl+l` honours an exact version pin** — it used to load
  whichever version PowerShell found first, unlike every other load path.
- On a PowerShellGet-only machine, the deferred startup job no longer calls
  `Install-PSResource` for a prerelease update; it falls back like its
  siblings.
- **psmm no longer reports its own modules as if they were yours** (gh#16).
  Its UI engine is imported into psmm's own session state instead of yours, so
  it stops appearing in your `Get-Module`; psmm and that engine render as
  `◈ psmm's own`, are left out of the `N loaded` count and the unmanaged scan,
  and are never unloaded by psmm. They stay visible and updatable — a broken UI
  dependency has to be repairable from inside the tool that needs it.
  **`files › apply` could unload psmm itself**: it unloads anything "managed
  but not active", and `$managed` includes entries from *disabled* files, so
  disabling the file holding psmm's seeded dependency entry made it target its
  own engine — and psmm — for `Remove-Module` mid-session.

### Added
- **Prerelease versions, per module** (gh#6): new optional `"Prerelease":
  true` config field (`w` in the module menu toggles it) makes install,
  update, the update check and the pin picker consider prereleases. Every
  version psmm shows now carries its label — `0.1.0-beta8` no longer renders
  as `0.1.0` — and the gallery column flags the opt-in with `+pre`.
- **The module details screen answers "which copy, and from where?"**
  (gh#3): install path, the `$env:PSModulePath` root above it with its
  search order and OneDrive status, every installed version with its scope,
  module type, exported-command count, cloud-only file count, and the
  project URL as a clickable link.
- **Move a module's files to another location** (gh#4): `p` in the module
  menu moves the whole `<root>\<Name>` tree (all versions together) to
  another writable module location, refusing collisions and telling you to
  unload a module whose files are in use.
- **The paths screen can add a location** (gh#12): `n` creates the folder if
  needed, adds it to the session search path first or last, and offers to
  persist it in the user `PSModulePath` environment variable.
- **…and move a location's contents elsewhere** (gh#13): `m` shows what will
  move and what will be skipped (loaded modules, name collisions), then
  requires you to type `really move` — `y`/`enter` are one keystroke away
  from navigation and this is not undoable from psmm.
- **Cloud-only downloads run in parallel** (gh#14): `d` now asks how many
  files to fetch at once, defaulted sensibly and capped at the machine's
  logical processor count *with the reason shown*. Pre-load hydration uses
  the default concurrency without prompting.
- **The version pin picker** (gh#5): `v` lists the versions that actually
  exist — on disk and in the gallery — with the current pin preselected,
  plus "type it myself" for NuGet ranges and an explicit "remove the pin".
- **Syntax highlighting for code and commands** (gh#9) and **real
  ctrl+clickable hyperlinks** (gh#10), both through shared primitives in
  `src/UI/04-Render.ps1` and written down as design-system §11 so new
  screens inherit them.

### Changed
- **The `gallery` column is now `upkeep`.** It named the source rather than
  the behaviour — its values answer *how does psmm keep this module on disk*,
  not *what is the gallery*. `upkeep` reads correctly with all three
  (`if-missing` / `check-only` / `latest`); `install` would have been the most
  literal name but collides with the `startup` column's own `install` value.
  The module menu's action group is renamed to match. JSON schema untouched.
- **The module details path is shown whole**, wrapped at folder boundaries
  rather than truncated — the tail of a path (which module, which version) is
  the half worth reading. Also added there: size on disk, when the folder was
  written, what the module requires of the host (`PowerShell x+`, edition),
  and a warning when the manifest declares its exports as `*` — the reason a
  module's commands cannot auto-load, and the mechanism that hid gh#2.
- **`left`/`right` work on every screen and are documented** (gh#7): `left`
  backs out one level everywhere, `right` opens the cursor row where there
  is something to open (and says so where there is not). They appear in the
  on-screen legend, and the three different notations for them — `→`, `←`,
  and prose — collapse into one: `left/right`, spelled out. Arrow glyphs are
  now banned as key names, with a guard test.
- **Help looks like the screens it documents** (gh#8): the `this screen` tab
  renders real key capsules and real state glyphs in their live colours
  instead of flat monospace, and the config/startup/about tabs highlight
  their code. `c` copy still yields plain text.
- The paths screen gained a `modules` count column and a details drill-in
  (`right`/`enter`) listing what a location holds, by size.

## [0.1.0-beta8] — 2026-07-20

Live-run feedback rounds two and three on the v2 UI.

### Added
- **First-run welcome overlay**: nothing on screen told a new user that `g`
  hides the whole navigation layer, so the very first grid paint floats a
  small tips panel (same overlay style as goto) with the three keys worth
  knowing — `g` goto, `?` help, `enter` actions. Any key closes it; a
  `psmm-welcome.json` marker next to the main config makes it once-ever.
- **Design-consistency test**: every list screen (grid, files, tasks,
  gallery, paths, commands, cleanup) is rendered and held to the identical
  cursor treatment — any future screen that deviates fails the suite.

### Changed
- **The goto panel floats dead centre of the frame's content box** (not the
  window, not the bottom): after four placements read as detached, it now
  behaves like a modal over the content and only its rectangle is redrawn
  on dismissal.
- **One cursor design on every screen**: the `▌` bar is retired everywhere;
  sub-screen tables paint the same edge-to-edge cursor-row background as
  the grid (one shared table builder), with the bold accent name on top.
- **Cursor-row background lifted `grey15` → `grey23`**: once the bar left
  the grid, #262626 all but vanished on a black terminal; #3a3a3a reads as
  a highlight and stays below the grey35 border.

## [0.1.0-beta7] — 2026-07-20

Live-run feedback round on the v2 UI (thanks, first real session).

### Changed
- **The goto overlay actually overlays**: the panel is drawn on top of the
  current frame (bottom-left, raw VT cursor positioning) instead of being
  appended below it, which pushed a full-height screen out of the window.
- **Table borders lifted to `grey35`**: grey27 (#444) had too little
  contrast on a black terminal background.
- **Grid column one is selection-only**: the `▌` cursor bar next to the `▪`
  selection marks read as a broken checkbox; the cursor is now carried by
  the full-row background and bold accent name alone.
- **`m` (show/hide unmanaged) is a grid verb again**, not a goto chord —
  it changes what home shows, it doesn't go anywhere.
- **`by` (author)**: new column in the gallery results and a new facts row
  in the module menu.
- **The console cursor is hidden** while the TUI runs (it sat blinking over
  the frames); text prompts show it for typing.
- **Esc aborts the edit/add/pin/search prompts**: text input now runs
  through a minimal line editor with a real cancel path, and the edit
  dialog assigns nothing until every answer is in — an abort never
  half-saves.

## [0.1.0-beta6] — 2026-07-20

### Changed — UI design system v2 ([docs/design-system.md](docs/design-system.md))
- **The `g` goto layer replaces screen-switch letters**: `g` anywhere opens
  a small overlay — `g h` home, `g g` gallery, `g f` files, `g p` paths,
  `g t` tasks, `g c` conflicts, `g x` cleanup, `g m` unmanaged, `g ?` key
  reference. Single letters on a screen are verbs only; esc cancels the
  overlay and any other second key is swallowed.
- **Header bar on every screen**: the ` psmm ` brand block plus a
  breadcrumb (`home › Microsoft.Graph`), dim counts, and version · engine ·
  elevated · `⇡` update flag right-aligned — replacing the per-screen title
  lines.
- **Plain-word grid columns**: `Mode` renders as **startup**
  (load / install / off) and `Install` as **gallery** (if-missing /
  check-only / latest) — display language only, the JSON schema is
  untouched. The state column pairs a glyph with its word (`●` loaded,
  `◐` installed, `○` missing, `◌` unmanaged), entry issues show as `⚠`
  after the module name, the update marker is `⇡` (naming the target
  version on the cursor row), and a muted context sentence explains the
  cursor row in full words.
- **Cursor & selection**: full-row background with a `▌` accent bar and
  bold accent name (the bare `>` is retired everywhere); selection is `▪`
  in column one (the `[ ]`/`[x]` checkbox column is retired).
- **Capsule key hints in two tiers**: contextual verb capsules plus a
  persistent strip (`g goto… · / filter · ? help · ^q quit`) on every
  screen; the `^ = ctrl` legend sits at the end of the row.
- **Tabbed help**: `?` opens `this screen | keys | config | startup |
  about` — ←/→ switches, `/` filters within a tab, `c` copies the visible
  tab; the keys tab is a grouped two-column capsule reference; the about
  tab carries the exact self-update command (the grid's standing update
  line is retired in favour of the header-bar flag).
- **Startup report** now shares the TUI design tokens: brand block +
  summary line, aligned per-module rows with state glyphs, right-aligned
  timings and proportional bars (slowest Load module called out with
  "InstallOnly would free your prompt"), `✕` failures with the exception
  text and a retry hint, one `⋯` row for deferred background work — all in
  raw 256-colour escapes (Spectre stays unloaded at profile time).
- **Themes**: `$PSMM_Theme = 'glacier'` (default) `| 'ember' | 'moss'` in
  `$PROFILE` before `Import-Module psmm`; unknown values fall back to
  glacier with a status note. All colours come from one token table
  (`src/Engine/Theme.ps1`); borders are grey27, headers lowercase + dim.

### Fixed
- A NuGet **range pin** like `[1.0,2.0)` crashed the module menu (invalid
  Spectre markup — the pin is now escaped; regression test added).
- The tasks screen never showed its cursor marker: the `$state` cell
  variable shadowed the `$State` parameter (case-insensitive), latent
  since v1.

## [0.1.0-beta5] — 2026-07-19

### Fixed
- **Fresh-install crash revealed on exit**
  ([#1](https://github.com/PBNZ/psmm/issues/1)): with exactly one managed
  entry — what every fresh install has after the main config is seeded with
  PwshSpectreConsole — the first `Sync-PSMMUIEntries -FullScan` threw
  `op_Addition`: PowerShell's pipeline unrolling turns a single-element
  `Get-PSMMAllEntries` result into a scalar `PSObject`, and scalar `+` array
  is not defined. The error fired at startup *before* the alternate screen
  opened, stayed hidden behind the TUI, and appeared when the original
  buffer was restored on exit; the initial availability refresh also never
  ran in that state. The call site now wraps the result in `@()`, with a
  regression test covering the one-entry full scan.

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
