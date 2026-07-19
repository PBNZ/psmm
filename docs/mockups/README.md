# Handoff: psmm UI v2 (design system evolution)

## Overview
Evolution of the psmm terminal UI (github.com/PBNZ/psmm): capsule-style key
hints in two tiers, a `g` goto overlay replacing screen-switch letters,
plain-word `startup`/`gallery` columns with a context sentence, full-row
cursor highlight, a header bar with breadcrumb, tabbed help, and a restyled
startup report. Default theme **glacier** (today's salmon1 + deepskyblue1,
tuned), user-selectable via a `$PSMM_Theme` knob (`glacier`|`ember`|`moss`).

**The authoritative spec is `../design-system-v2.md`** — tokens, key registry,
symbols, rules that must keep passing tests, and a safe 8-step migration
order. Read it first; this README is orientation.

## About the design files
The files in this folder are **design references created in HTML** — static
pictures of intended terminal output, NOT code to ship. The target is the
existing PowerShell 7 + Spectre.Console (PwshSpectreConsole) codebase:
recreate the visuals with Spectre markup and explicit 256-color names inside
the existing architecture (`src/UI/00-Theme.ps1` owns all colours;
`Get-PSMMHint` owns all hint rendering; screens are `Build-*` functions
driving LiveDisplay). Open the `.dc.html` files in a browser to view them
(`support.js` must sit next to them).

## Fidelity
**High-fidelity.** Colors are exact and map to xterm-256 names (below).
Spacing in the mocks is CSS; in the terminal, match structure and colour,
not pixels. Box borders = Spectre `Rounded` border with `grey27` style.

## Scope decisions (already made — do not relitigate)
- Implement direction A: mock sections 2a (grid), 2b (goto overlay),
  2c (tabbed help), 2d (startup report), 2e (module menu), 2g (themes).
- Section 2f (lazygit-style panes) is **rejected** — not beginner friendly.
- Glacier is the default theme; `$PSMM_Theme` selects variants.
- JSON config schema is untouched: `startup`/`gallery` are display words for
  the existing `Mode`/`Install` enums.
- Follow the migration order in the spec (8 independently shippable steps);
  extend `Tests/UI.Tests.ps1` at each step.

## Screens (mock ids in `mockups/psmm - Next Level.dc.html`)
- **2a v2 grid**: header bar (` psmm ` brand block on salmon1 + breadcrumb +
  right-aligned version/engine/⇡), lowercase dim column headers
  `module state startup gallery version scope file`, state glyphs
  `● ◐ ○ ◌` + word, cursor = full-row grey15 bg + `▌` accent bar + bold
  accent name, selection `▪`, context sentence for the cursor row, verb
  capsules row + persistent dim row (`g goto… · / filter · ? help · ^q quit`,
  `^ = ctrl` right-aligned).
- **2b goto overlay**: pressing `g` re-renders the screen with a small
  accent-bordered panel (bottom-left): `h home · g gallery · f files ·
  p paths · t tasks · c conflicts · x cleanup · m unmanaged · ? keys`;
  esc cancels, other keys swallowed. Identical on every screen.
- **2c tabbed help**: tabs `this screen | keys | config | startup | about`,
  ←/→ switch, `/` filters, `c` copies tab. Keys tab = grouped two-column
  capsule layout (navigate / act on modules / go places / everywhere).
- **2d startup report**: brand block + summary line; per-module rows of
  glyph · name · right-aligned ms · proportional bar (slowest in orange1 with
  a note); `✕` failures with exception text and the retry hint; one `⋯` row
  for deferred work; `⇡` self-update line.
- **2e module menu**: breadcrumb `home › <module>`, condensed facts panel
  (what/entry/disk/session/connection), actions grouped by what they touch:
  `session | gallery | entry | connection`, then the persistent row.
- **2g themes**: glacier (default), ember, moss — token swaps only.

`mockups/psmm - Current UI.dc.html` (1a–1n) is the faithful recreation of
today's UI, for before/after comparison.

## Design tokens (glacier)
| token | xterm name | hex |
|---|---|---|
| key | salmon1 (209) | #ff875f |
| mute | grey66 (248) | #a8a8a8 |
| accent | deepskyblue1 (39) | #00afff |
| ok | green3 (34) | #00af00 |
| warn | orange1 (214) | #ffaf00 |
| err | indianred1 (203/204) | #ff5f87 |
| info | steelblue1 (75) | #5f87ff |
| dim | grey42 (242) | #6c6c6c |
| capsule bg | grey19 (236) | #303030 |
| row bg | grey15 (235) | #262626 |
| border | grey27 (238) | #444444 |
| brand | black on salmon1 | — |

Capsule markup shape: `[salmon1 on grey19] i [/] [grey66]install[/]`
(persistent row: `[deepskyblue1 on grey11]`-style, dim labels).
Symbols registry: `▌ ▪ ● ◐ ○ ◌ ⚠ ⇡ ↑ ↓ … ~ ^` — meanings in the spec §9.

## Files
- `../design-system-v2.md` — the spec (becomes `docs/design-system.md`
  once implemented).
- `psmm - Next Level.dc.html` — v2 mockups (sections 2a–2g).
- `psmm - Current UI.dc.html` — baseline recreation (1a–1n).
- `support.js` — runtime the mockup pages need to render; not part
  of the design.
