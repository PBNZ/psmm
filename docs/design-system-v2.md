# psmm design system v2 — spec

Drop-in successor to `docs/design-system.md`. Written to be handed to a coding
agent. Mockups: `psmm - Next Level.dc.html` (2a-2g); baseline recreation of
today's UI: `psmm - Current UI.dc.html` (1a-1n).

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
| g m | unmanaged toggle |
| g ? | help › keys |

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
| `▌` | cursor row (column one) |
| `▪` | selected row |
| `● ◐ ○ ◌` | loaded / installed / missing / unmanaged |
| `⚠` | entry has validation issues |
| `⇡` | update available (Ver column, header bar, startup report) |
| `↑ ↓` after `showing x-y` | more rows above/below (unchanged) |
| `…` | truncated (unchanged) |
| `~` | background activity spinner line (unchanged) |
| `^` | ctrl, and nothing else (unchanged) |

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
