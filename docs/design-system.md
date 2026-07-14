# psmm design system

The rules every psmm screen follows. Any new screen or key binding must comply; deviations are
bugs. Tests in `Tests/UI.Tests.ps1` assert the testable rules.

## Palette

Defined once in `src/UI/00-Theme.ps1`; never hard-code colours elsewhere.

| Token | Colour | Use |
|---|---|---|
| key | `salmon1` | keyboard shortcuts in hint lines |
| mute | `grey66` | action labels, separators, secondary text |
| accent | `deepskyblue1` | cursor row, titles, screen headings |
| ok | `green3` | success status |
| warn | `orange1` | warnings, degraded states |
| err | `indianred1` | errors, missing |
| info | `steelblue1` | neutral informational highlights |

Status colours are explicit 256-colour names so they render identically in every terminal.

## Key hints

- Hints are rendered only through `Get-PSMMHint` — one style everywhere.
- **Keys are always shown lowercase**: `i=install`, never `I=install`. This includes letters,
  `esc`, `enter`, `space`, `home`.
- **`^` is the ctrl modifier**: `^q=quit` means ctrl+q. Any hint line containing a `^` chord
  starts with the muted legend `^=ctrl` so the notation is always explained on screen.
- No shift-modified bindings. If a screen needs a second binding for a verb, use a ctrl chord.
- Hint pairs are `key=action` with a muted `·` separator. Keep actions to one or two words.
- Long hint sets are split across multiple short rows (a single long markup row collapses to
  `...` on narrow terminals). Row order: navigation first, module verbs second, screen
  switching last.

## Key registry — same verb, same key, on every screen

| Key | Verb | Notes |
|---|---|---|
| `i` | install | grid: background install of missing targets; module menu: install this module |
| `u` | update | grid: background update of installed targets; module menu: update this module. Install and update are always separate actions with separate keys |
| `k` | check updates | grid: background gallery check, marks rows with `↑` |
| `^l` | load | grid: bulk load targets; module menu: load this module |
| `^u` | unload | grid: bulk unload targets; module menu: unload this module |
| `x` | clean up versions | grid: cleanup screen; module menu: clean this module's old versions |
| `^a` | (cleanup screen) clean all | ctrl chord because it acts on everything at once |
| `s` | connection status | module menu: check the Connect-* session |
| `o` | disconnect | module menu |
| `b` | browse commands | module menu |
| `e` / `v` / `d` / `m` | edit / pin version / delete / move entry | module menu |
| `a` | add | grid: new entry; module menu (unmanaged): add to config; files: apply is `a` too (screen-local) |
| `c` | copy | help/pager screens: copy the visible content to the clipboard |
| `r` | reload / rescan | re-read from disk |

Screen-local keys (`g=gallery`, `f=files`, `p=paths`, `t=tasks`, `m=unmanaged`,
`n=new config`, `d=download`/`k=keep on device` on the paths screen, ...) may reuse letters
across screens as long as the *verb* differs per screen and no global verb is shadowed.

## Keys that work everywhere

| Key | Action |
|---|---|
| `up`/`dn`, `pgup`/`pgdn`, `home`/`end` | move / scroll (physical home = top of list, the common TUI meaning) |
| `/` | filter (search) mode |
| `?` | help for the current screen |
| `esc` | back one level (clears an active filter first); repeated esc reaches the home screen |
| `g h` | go straight to the home screen (the module grid) from any sub-screen. This is the vim-style goto chord used by yazi, ranger and spotify_player — there is no cross-TUI "home" standard, and ctrl+h is unreliable (it is ASCII backspace on VT paths). ctrl+h works as an alias where the terminal reports it distinctly (Windows Terminal, conhost) |
| `^q` / `^x` | quit psmm immediately |

## Symbols

- `^` before a key means ctrl (see legend rule above). Because `^` is reserved for ctrl,
  it is never used as a status marker.
- `↑` in the Ver column = update available; `↑`/`↓` after `showing x-y` = more rows above/below.
- `…` = truncated text.
- `>` = cursor row.

## Screens

- Every screen: title line in accent, content, hint row(s), then transient status line.
- Every scrollable list shows `row x/n` and, when clipped, `showing a-b`.
- Every action reports its outcome in the status line; a keypress that does nothing valid says so.
- Full-screen flows repaint a clean alternate-screen page; the user's scrollback is never touched.
- **Too-small terminal**: when the window is too small to render a screen's table, render a
  clear one-line message naming the current and required size instead of letting the table
  collapse to `...`.

## Writing style in the UI

- Status/labels are lowercase sentences without trailing periods: `loaded (123 ms)`.
- Errors show the exception message, never a bare failure.
- Durations in ms, versions prefixed `v`.
