# psmm design system (v2)

Implemented 2026-07-20 (0.1.0-beta6); successor to the v1 design system.
Mockups in `mockups/`: `psmm - Next Level.dc.html` (2a-2g); baseline
recreation of the v1 UI: `psmm - Current UI.dc.html` (1a-1n).

**Scope decision:** implement direction A (2a-2e, 2g). The pane-layout
contender (2f) is REJECTED for now — not beginner friendly; do not build it.

Verdict on v1: the discipline is the asset — single palette source
(00-Theme.ps1), key registry with tests, install ≠ update, alt-screen restore,
too-small fallback, row x/n. v2 keeps every one of those rules and changes the
surfaces: hint rendering, navigation, column language, help, cursor, startup
report. All of it stays Spectre markup + explicit 256-color names; no new
dependency.

## 1. Palette (theme = "glacier", default)

Defined once in `src/UI/00-Theme.ps1` as today. Additions in bold.

| Token | Colour | Use |
|---|---|---|
| key | `salmon1` | key capsules (foreground) |
| mute | `grey66` | action labels, secondary text |
| accent | `deepskyblue1` | cursor bar, titles, breadcrumb current, active tab |
| ok | `green3` | loaded, success |
| warn | `orange1` | installed-not-loaded, updates, warnings |
| err | `indianred1` | missing, failed |
| info | `steelblue1` | background-activity spinner, neutral highlights |
| **dim** | **`grey42`** | de-emphasised cells (off, ro, file names), legends |
| **capsule** | **`grey19`** | key-capsule background (`[salmon1 on grey19] i [/]`) |
| **rowbg** | **`grey15`** | cursor-row background |
| **border** | **`grey27`** | ALL table/panel borders (today they render default fg — too loud) |
| **brand** | **`black on salmon1`** | the ` psmm ` block in the header bar |

**Decision: glacier is the default.** Themes are user-selectable via a
`$PSMM_Theme` profile knob (`'glacier'` | `'ember'` | `'moss'`, set before
`Import-Module psmm`, invalid values fall back to glacier with a status-line
note). Variants (mockup 2g) are token swaps in 00-Theme.ps1 only. Nothing
outside 00-Theme.ps1 may name a colour (unchanged rule).

## 2. Header bar (new, every screen)

One line, full width, `on grey11`-style background:
`[black on salmon1] psmm [/] breadcrumb · counts……………right: version · engine · ⇡ update flag`

- Breadcrumb: `home`, `home › Microsoft.Graph`, `home › help`. Current segment
  default fg, parents dim. Replaces the per-screen accent title line.
- Right side: `v0.1.0-beta4 · PSResourceGet` + `elevated` when true + orange
  `⇡ update` when the self-update cache says so (detail line stays available
  in help › about).

## 3. Keys: capsules, two tiers

- Render every key through `Get-PSMMHint` (unchanged contract) but as a
  capsule: `[salmon1 on grey19] i [/] [grey66]install[/]`, separator two
  spaces (drop the `·` between pairs; keep `·` only between groups).
- Two tiers on every screen:
  - **verb row(s)**: contextual actions, salmon capsules.
  - **persistent row**: `g goto… · / filter · ? help · ^q quit` in accent-on-
    grey11 capsules with dim labels, always last, always the same. `^ = ctrl`
    legend sits right-aligned on this row (only when a chord is visible —
    unchanged rule).
- Keys stay lowercase; `^` stays the ctrl notation; no shift bindings
  (unchanged).

## 4. Navigation: the g goto layer (replaces screen-switch letters)

`g` anywhere opens a small overlay panel (bottom-left, accent border):

| chord | goes to |
|---|---|
| g h | home (grid) |
| g g | gallery |
| g f | files |
| g p | paths |
| g t | tasks |
| g c | conflicts |
| g x | cleanup |
| g ? | help › keys |

Show/hide unmanaged is NOT a goto destination - it is the grid verb `m`
(live-run feedback 2026-07-20: it changes what home shows, it doesn't go
anywhere).

- esc cancels; any other second key is swallowed (today's behaviour).
- Grid letters `f p c t x m g` are freed; single letters on a screen are
  VERBS only. `a add`, `r reload`, `i u k`, `^l ^u` keep their registry slots.
- Implementation: re-render the current view with the panel appended — same
  pattern as the filter-mode hint swap; no new machinery.
- ctrl+h stays as home alias where the terminal reports it (unchanged).

## 5. Grid columns: plain words + context line

- Rename headers, lowercase + dim: `module state startup gallery version
  scope file`.
- `Mode` → **startup**: `load` / `install` / `off` (Load / InstallOnly /
  Ignore). `Install` → **gallery**: `if-missing` / `check-only` / `latest`.
  JSON schema is untouched — this is display language only.
- **state** gets glyphs: `● loaded` (ok) · `◐ installed` (warn) · `○ missing`
  (err) · `◌ unmanaged` (info). Glyph + word, never glyph alone.
- `!` column dies; issues render as `⚠` (err) after the module name.
- Update marker becomes `⇡` and shows the target on the cursor row:
  `7.8.10 ⇡ 7.9.0`. (`↑` was fine; `⇡` reads better next to digits — either
  is acceptable, pick one and register it.)
- **Context line** (new, under the selection/pos line): one muted sentence
  explaining the cursor row in full words:
  `ImportExcel — background-installs at shell start when missing · not
  imported this session · v7.8.10 on disk, v7.9.0 available (u updates)`.
  This is where Mode/Install/pin/scope subtleties get to be verbose so the
  columns don't have to.

## 6. Cursor & selection

- Cursor: full-row `on grey15` background + `▌` accent bar in column one +
  bold accent module name. The bare `>` is retired.
- Selection: `▪` (ok) in column one + `▪ N selected` in the status area.
  Checkbox `[ ]/[x]` column is retired (the marks carry it).

## 7. Help: tabs (reuse the command-detail pattern)

`?` opens help for the current screen as **tabs**, not one pager:
`this screen | keys | config | startup | about` — left/right switches,
`/` filters within help, `c` copies the visible tab, esc back.
The keys tab is a grouped two-column layout (navigate / act on modules /
go places / everywhere), keys as capsules — see mockup 2c. Content source
stays Get-PSMMHelpSection, split per tab instead of concatenated.

## 8. Startup report: same design system as the TUI

Format (mockup 2d):

- Line 1: ` psmm ` brand block + summary: `4 loaded · 1 skipped · 1 failed ·
  3 in background · 407 ms`.
- One aligned row per module: state glyph · name · right-aligned ms ·
  proportional bar (dim; warn-coloured for the slowest, annotated
  `slowest — InstallOnly would free your prompt`).
- Failures: `✕ name` + the exception message + `→ psmm, then i on the row
  retries`.
- Deferred: one `⋯` row: `ImportExcel +2 more — installing in the background`.
- Self-update: `⇡ psmm vX is out — <command>` (command in cyan, as today).
- Drop the `> Name <` wrappers and raw ConsoleColor semantics; use $PSStyle
  RGB/256 escapes so report and TUI share tokens.

## 9. Symbols registry (v2)

| symbol | meaning |
|---|---|
| `▌` | cursor row (far-left mark slot, left of the selection dot) |
| `▪` | selected row |
| `● ◐ ○ ◌` | loaded / installed / missing / unmanaged |
| `⚠` | entry has validation issues |
| `⇡` | update available (Ver column, header bar, startup report) |
| `↑ ↓` after `showing x-y` | more rows above/below (unchanged) |
| `→` | "next step" pointer in prose only — **never** a key |
| `…` | truncated (unchanged) |
| `~` | background activity spinner line (unchanged) |
| `^` | ctrl, and nothing else (unchanged) |

**Arrow keys are never drawn as glyphs.** A key is always spelled out and
capsuled: `left/right`, `up/dn`, `pgup/pgdn`, `home/end`. `←`/`→` as key
names are banned outright — they collide with the `↑ ↓` scroll indicator and
the `→` prose pointer, and they made one pair of keys read three different
ways across the UI. A guard test checks every key-rendering call site.

## 10. Unchanged rules (restated so tests keep passing)

- One palette source; no colours outside 00-Theme.ps1.
- Same verb, same key, on every screen; install and update never share a key.
- Keys lowercase; `^`=ctrl with visible legend; no shift bindings.
- esc backs out one level (clears filter first); `^q`/`^x` hard-quit anywhere.
- `/` filter everywhere with identical editing semantics.
- Every scrollable list: `row x/n` + `showing a-b` when clipped.
- Every action reports in the status line; no-op keypresses say so.
- Alt-screen buffer in/out; scrollback never touched.
- Too-small terminal → explicit one-line message with current/required size.
- Status/labels lowercase, no trailing periods; errors show exception text;
  durations in ms; versions `v`-prefixed.

## 11. Rendering primitives (added 2026-07-22)

Four things every screen shows — code, links, prose, versions — used to be
hand-formatted at each call site, which is why they drifted: the config JSON
was flat text, one update command was hand-coloured cyan, URLs were dead text
and a paragraph ran a 200-column terminal edge to edge. **A screen never
formats one of these itself.** All four live in `src/UI/04-Render.ps1`, take
theme tokens only, and return balanced markup *per line* (every
`Markup`/`Write-PSMMLine` is parsed on its own).

| you are showing | go through | rule |
|---|---|---|
| code or a command | `Format-PSMMCode -Text <lines> [-Language powershell\|json]` | PowerShell is tokenised with `[PSParser]::Tokenize` (command / parameter / string / variable / number / comment / keyword). Unparseable input degrades to escaped plain text — never throws. JSON is regex-highlighted because the samples carry `//` comments and are deliberately not valid JSON. |
| one inline command | `Get-PSMMCommandMarkup -Command <string>` | same tokens, single line |
| a URL | `Get-PSMMLinkMarkup -Url <url> [-Text <label>]` | emits Spectre `[link=…]`, i.e. a real OSC 8 hyperlink — ctrl+clickable in Windows Terminal. Degrades to styled plain text when the URL cannot be expressed as a tag. `Markup::Remove` still yields the label, so `c` copy and the tests are unaffected. |
| a paragraph | `Get-PSMMProseMarkup` / `Write-PSMMProse` (measure: `Get-PSMMProseWidth`) | wraps at `min(window − 4, 84)` columns. Tables, panels and hint rows are all measured; prose has to be too. |
| a version | `Get-PSMMVersionMarkup` / `Get-PSMMVersionText` | the prerelease label is part of the version and is always shown, tinted `info`: `0.1.0-beta8` must never render as `0.1.0` |
| a key | `Get-PSMMKeyCap` (used by `Get-PSMMHint`) | one capsule definition for the whole UI; keys lowercase and spelled out (§9) |

Two more rules that fall out of this:

- **Help is markup, not escaped text.** Every help tab — including
  `this screen` — renders through the same primitives as the screen it
  documents: real key capsules, real state glyphs in their real colours,
  highlighted code. Help that describes a coloured UI in flat monospace does
  not look like the thing it describes. `Get-PSMMHelpText` flattens it back to
  plain text for `c` copy and the tests.
- **Destructive, hard-to-undo actions are gated by a typed phrase**
  (`Read-PSMMConfirmPhrase`), not by `y`/`enter` — those are one keystroke
  away from navigation. Moving a whole module location's contents is the
  first user of this.

## Migration order (safe increments)

1. Borders → grey27, headers lowercase+dim, cursor row bg (00-Theme + grid).
2. Capsule hint rendering inside Get-PSMMHint (one function, every screen).
3. startup/gallery column words + context line.
4. g goto overlay; remove screen letters from the grid's third hint row.
5. Header bar with breadcrumb (replaces title lines screen by screen).
6. Tabbed help.
7. Startup report restyle.
8. Theme variants ($PSMM_Theme).

Each step is independently shippable and testable (extend UI.Tests.ps1:
capsule markup shape, goto table completeness, startup/gallery word mapping,
context-line presence).

## Implementation notes (2026-07-20)

All 8 steps shipped in 0.1.0-beta6; a live-run feedback round shipped in
0.1.0-beta7. Deliberate deviations from the letter of this spec:

- **Border = `grey35` (240), not grey27**: #444 had too little contrast on a
  black terminal background.
- **The goto overlay really overlays**: the panel is drawn on top of the
  current frame with raw VT cursor positioning (DECSC/DECRC around
  absolute moves) - appending it to the renderable pushed a full-height
  frame off screen. It floats dead centre of the frame's CONTENT box
  (measured from the renderable, excluding the padded full-width header
  bar), like a modal over the content - picked in live-run feedback after
  bottom-left, middle-left and window-centre all read as detached. On
  dismissal only the panel rectangle is blanked and the caller's repaint
  restores what was underneath.
- **Tables are borderless inside** (mockup 2a, live-run feedback 2026-07-20
  round 4): outer rounded frame only — no column separators, no header
  rule. One shared builder renders every list table; the grid builds inline
  (hot path) with the identical technique.
- **The `▌` cursor bar lives in its own far-left mark slot**, immediately
  LEFT of the selection dot — the earlier complaints were the bar *sharing*
  the selection slot and covering the `▪` dot (and, with column borders,
  reading as a broken checkbox). Cursor = bar + full-row `rowbg` background
  + bold accent name, identical on the grid and every sub-screen list; the
  design-consistency test renders every list screen and holds them to it.
- **A blank line separates the verb rows from the persistent goto row**
  (mockup 2a); it ships inside `Get-PSMMPersistentHint`, so every screen
  gets it for free.
- **`m` (show/hide unmanaged) is a grid verb**, not a goto chord.
- **The console cursor is hidden** while the TUI runs (it blinked over the
  frames); text prompts show it for the duration.
- **Esc cancels text prompts**: `Read-PSMMText` is a minimal line editor
  (enter accepts, esc returns `$null` = abort); edit/add flows collect all
  answers before assigning anything, so an abort never half-saves.
- **`by` (author)**: a column in the gallery results and a facts row in the
  module menu (resolved once from the manifest, never in the render path).
- **First-run welcome overlay** (live-run feedback 2026-07-20): nothing on
  screen tells a new user that `g` hides the whole navigation layer, so the
  very first grid paint floats a small tips panel (same VT overlay + accent
  border as goto) with the three keys worth knowing: `g` goto, `?` help,
  `enter` actions. Any key closes it; a marker file next to the main config
  (`psmm-welcome.json`) makes it once-ever. Headless hosts skip it without
  burning the marker.

- The persistent row's pairs adapt to the screen type: the grid shows
  `g goto… · / filter · ? help · ^q quit`; sub-screens swap `/ filter` for
  `esc back` when they have no filter (the row is otherwise identical).
- **rowbg = `grey23` (237), not grey15**: once the cursor bar left the grid,
  the #262626 background all but vanished on a black terminal; #3a3a3a reads
  as a highlight and stays below the grey35 border. Sub-screen tables get
  the same edge-to-edge background via `New-PSMMTable` (widths computed from
  all rows, padding inside the cells — the grid technique, shared).
- The token table lives in `src/Engine/Theme.ps1` (markup name + xterm-256
  index per token) so the startup report can render the same tokens without
  Spectre; `src/UI/00-Theme.ps1` reads its palette from there. The guard
  test allows colour names only in those two files.
- `err` maps to Spectre `indianred1` (#ff5f5f, 203) - the spec allowed
  203/204.
