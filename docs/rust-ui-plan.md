# psmm Rust UI — Phase 0 outcome and delivery plan

| Field | Value |
|---|---|
| Document | rust-ui-plan |
| Status | Ratified |
| Date | 2026-07-26 |
| Input | `docs/PRD-psmm-rust-ui.md` v0.2 |
| Related | `DECISIONS.md` (`D-RUST-UI`), `ROADMAP.md`, `docs/config-schema.md`, `docs/design-system.md` |

## Context

`docs/PRD-psmm-rust-ui.md` proposes replacing psmm's Spectre.Console UI with
a Rust binary (Ratatui 0.30.2 / Crossterm 0.29 / Tokio), keeping the engine,
config semantics and public API in PowerShell. It explicitly defers to a
planning session: **no production code until Phase 0 completes.**

This document is that Phase 0 outcome. It records what the source actually
does (the PRD's §8.7 V1–V8 and its §9.1 keymap, re-derived from `src/`),
where the PRD's assumptions were wrong, the decisions ratified on 2026-07-25
and 2026-07-26, and the delivery plan that follows from them.

The headline finding reframes the whole `Mode`×`Install` workstream: **the
matrix is not implemented once and drifting from spec — it is implemented
four times, and the four disagree.** So the first work is not Rust. It is
collapsing four implementations into one, fixing the defects that fall out,
and locking the result with the nine per-cell Pester tests the PRD asks for
(S8). Only then does a rewrite have a correct spec to build against.

**Deliverable IDs** (`C-n`, `FR-n`, `KB-n`, `MS-n`, `Q-n`, `V-n`, `S-n`,
`P-n`, `T-n`, `NFR-n`) refer to the PRD and are stable references for
commits, ADRs and issues.

---

## 1. Decisions ratified (2026-07-25)

| # | Decision | Supersedes |
|---|---|---|
| D-1 | The six engine defects are fixed **in PowerShell first**, before any Rust ships. Each is logged as a GitHub issue | PRD §15 Phase 0 ("reconcile") |
| D-2 | **Q-1 = 8.2a.** Gallery/network I/O is never foreground. Import is foreground; all disk/gallery work is background. No schema change | PRD §8.2, `docs/config-schema.md` |
| D-3 | **Q-6 = scheme (b).** `%APPDATA%\psmm` on Windows, `$XDG_CONFIG_HOME/psmm` (else `~/.config/psmm`) elsewhere. Opt-in copy migration | PRD FR-4.2 lean of (c) |
| D-4 | **Keyboard = flat verbs + the `g` goto layer + mode-scoped submaps.** No prefix key. Uppercase `L`/`U` for load/unload. Keymap user-remappable via the preferences file | PRD §9.3, KB-R5, design-system §10 |
| D-5 | **No strangler, no dual UI.** `rc02` is the PowerShell fixes; `rc03` is the Rust UI and **drops Spectre entirely**. No `$PSMM_UI` knob, ever | PRD §15 (six phases), Q-10, Q-11, R10 |
| D-6 | **`win-x64` ships in the Gallery package; `win-arm64`, `linux-x64`, `linux-arm64` are fetched on demand** against a module-pinned SHA-256 | PRD P1 |

**What D-5 costs, recorded so it is a decision and not an accident.** The
PRD's Phase 2 off-ramp — render read-only in Rust, look at it, and keep
Spectre as the default if it disappoints — is gone, and so is R10's
mitigation. The fallback is no longer a runtime knob but **the previous
Gallery release**: rc02 stays installable and `Install-PSResource psmm
-Version 0.1.0-rc02 -Reinstall` is the documented escape. What protects
rc03 is therefore the standing rule that nothing is tagged until it has been
driven in a real terminal — which for rc03 is load-bearing in a way it is
not for rc02. In exchange, D-5 deletes the two-keymap window, the
divergence documentation, the `$PSMM_UI` knob and its tests, and the whole
Phase 6.

**Q-10 and Q-11 are dissolved by D-5** — there is no second front end to
diverge from and no knob to select one. Carried at my recommendation unless
PBNZ says otherwise: **Q-2** a background install that lands after the prompt
is live is reported, never imported behind the user (`installed — available
next session`); **Q-4** `Mode` is a startup declaration only, the UI always
permits explicit action on any row and shows the deviation; **Q-7**
preferences persist, session state does not; **Q-12** ROADMAP #39 stays out
of scope until the protocol exists.

---

## 2. Phase 0 findings — where the PRD was wrong

### 2.1 `Mode` × `Install` (V1–V8)

**Four implementations.** `src/Public/Invoke-PSMMStartup.ps1:62-102`;
`src/Engine/Install.ps1:131-153` (`Invoke-PSMMEntryAction`);
`src/Engine/Startup.ps1:102-138` (ThreadJob body);
`src/UI/10-Grid.ps1:398-423` (ThreadJob body). Job bodies re-implement the
logic by hand because module functions are invisible inside a ThreadJob
(`Startup.ps1:91-92` says so). They have drifted.

**V1 — the nine cells as implemented** (defaults: `$PSMM_BackgroundStartup`
unset ⇒ `$true`, `Start-ThreadJob` present):

| Mode | Install | Installs | Imports | Network | Scheduling |
|---|---|---|---|---|---|
| Load | CheckOnly | never | if present | no | foreground |
| Load | IfMissing | only on `FileNotFoundException` | yes | only when missing | foreground |
| Load | Latest | **always** (unconditional install/update) | if not already loaded | **every start** | **foreground** |
| InstallOnly | CheckOnly | never | never | no | background |
| InstallOnly | IfMissing | if absent | never | only when missing | background |
| InstallOnly | Latest | always | never | always | background |
| Ignore | any | no | no | no | never touched |

**V3 — confirmed, and worse than the PRD states.** `Install` has **zero**
influence on scheduling: `Invoke-PSMMStartup.ps1:62-63` partitions on `Mode`
alone. `Load`+`Latest` is not a check that may update — it is an
unconditional `Install-PSMMModule -Update` (`Install.ps1:145`), every branch
of which is a repository call (`Install.ps1:86,93,95,97`), synchronous,
before the prompt.

**Q-3 — answered; half the PRD's premise is false.** An exact pin does *not*
neuter `Latest`. `Install.ps1:84-86` passes `-Reinstall:$Update`, so pin +
`Latest` force-reinstalls the version you already have, in the foreground,
every shell start. The pin *does* suppress the update flag
(`Gallery.ps1:437-438`). Range pins resolve newest-in-range only under
PSResourceGet (`Install.ps1:103-108` drops the range with a warning
otherwise) — and because `PinnedExact` is false for a range, the check
compares against unconstrained gallery-latest, so a range-pinned module is
flagged forever and **the flag can never clear**. It also renders no `pin`
marker (`10-Grid.ps1:76`).

**Q-5 / V6 — answered both ways.** `Ignore` is filtered at the partition,
the earliest possible point: inert at startup. But **no update check of any
kind runs at startup for any cell**, so §8.5's "background, report-only
check" for cells 1–3 is aspirational. In the TUI the check filters on
`Installed` only (`10-Grid.ps1:432`), so `Ignore` entries *are* queried.

**V4 — no hot-swap exists anywhere.** The failure mode is the mirror image
of the PRD's worry: `Load`+`Latest` on a loaded module replaces the files
and reports `latest + already loaded` (`Install.ps1:148-152`) — a silently
stale session.

**V7 — the gh#16 failure class is still live for user modules.**
`50-Files.ps1:118` builds `$managed` from `Get-PSMMAllEntries` (pre-filter,
disabled files included); `:139` unloads anything managed-but-not-active.
The gh#16 fix was a psmm-own allow-list (`:144`), not a fix to `$managed`.

**V8 — the `!` column does not exist.** Issues render as `⚠` after the
module name (`10-Grid.ps1:129-132`). Five single-field issue messages; **no
cross-field lint at all**, so §8.5's required "Install has no effect while
Mode is Ignore" and cell-4's "watch only" notice have nothing to build on.

### 2.2 Keybindings (§9.1 re-derived, §9.2 corrected)

| PRD | Source |
|---|---|
| KB-7 "No `Enter`" | **Wrong.** Bound on 9 handlers; unbound only on submenu and files |
| `^q` is the only quit | **`^x` is a second hard-quit** (`01-Input.ps1:6-7`) |
| 7 goto chords | **8** — `g ?` → help/keys is missing from the table |
| KB-1 `k` collides once | Twice: check-for-updates (grid) and keep-on-device (paths) |
| KB-5 `m` overloaded twice | **Four** meanings |

Uppercase bindings are **impossible in the Spectre UI** (`ConsoleKey` is
case-blind; `$k.KeyChar -eq 'g'` is case-insensitive) — moot under D-5, but
it confirms the new keymap could never have been backported:
the Spectre keymap freezes. Free for the new scheme: `1`–`9`, `[`, `]`,
`:`, `z`, `=`, `-`, `Tab`/`Shift+Tab`, `j`, `q`, `Q`, `y`.

Live drift proving KB-R2/R3 are needed: the submenu's `l` loads with no Ctrl
guard (`20-Submenu.ps1:308`) while every hint says `^l`, and the test asserts
only that the *string* `^l load` renders. There is no duplicate-binding test;
the only keymap-as-data is `Get-PSMMGotoTable` (8 entries). The submenu calls
`[Console]::ReadKey` directly, so it alone never repaints on resize.
`README.md`'s table and `RELEASE-CHECKLIST.md` section A are both stale.

### 2.3 Feature audits

- **FR-1** exists but is foreground, uncached, untimed, module-menu only;
  five hard-coded providers (`Auth.ps1:12-56`) — a table in shape, not
  pluggable in fact; the Teams provider (`Get-CsTenant`) is a network call.
  A hung provider hangs the TUI. FR-1.5 and FR-1.6 unmet. No accessor leaks
  a secret today, but they are free-form property readers with no allow-list.
- **FR-2**: `Receive-Job -Keep` re-materialises the entire output every
  500 ms — unbounded (FR-2.8 unmet). No cancel, no queued state. **No
  `PowerShell.Exiting` handler exists anywhere — C6 is not implemented.**
  The startup job is not in the task registry. FR-6.7 works by accident of
  module scope, and every re-entry queues another full scan.
- **FR-3**: no user/system classification exists. `Get-PSMMScopeForPath` is
  a `$HOME` prefix test — already platform-neutral, so FR-3.6 is half-done —
  but `$PSHOME`/System32 modules become `AllUsers` and are offered for
  adoption. Nothing reads `PSGetModuleInfo.xml`. The scan is written twice;
  the engine copy (`State.ps1:169-190`) is dead at runtime.
- **FR-5**: `Update-Help` **does** exist (`68-Tasks.ps1:65-77`, tasks screen
  `u`, background, `-Scope CurrentUser`). `-ErrorAction SilentlyContinue`
  means the job always reaches `Completed`, so total failure reports as
  "done". It runs; its reporting is broken. No tests.
- **NFR-8**: "guard tests for both" is half true. Colour has a static guard
  (`UI.Tests.ps1:1223-1235`, a closed allow-list of colour names in current
  use). The render-primitive rule has **no** static guard.

### 2.4 Environment and packaging

- Appendix A checks out: Ratatui **0.30.2**, Crossterm **0.29.0**,
  `ratatui-interact` **0.5.3** (~32k lifetime downloads — evaluate, but
  MS-R1 is small enough not to take the dependency).
- **§7.4's sharp edge is much duller than stated.** crossterm 0.29 reads
  input from the console device, not redirected stdio: Windows uses
  `Handle::current_in_handle()` (CONIN$ via `CreateFileW`, *not*
  `GetStdHandle`) for both the event source and raw mode; Unix `tty_fd()`
  falls back to `/dev/tty` when stdin is not a tty. Output is generic
  (`CrosstermBackend::new(writer: W)`). A child with stdio pipes still owns
  the terminal.
- **The edge the PRD misses:** raw mode is set on the *shared* console input
  buffer, so the child mutating it changes the parent's console. The shim
  must restore it if the child dies.
- **`Install-PSResource` has no per-RID filtering** — every user downloads
  every RID. Four RIDs at NFR-4's ≤10 MB ⇒ ~40 MB for a module that ships
  ~200 KB of text today.
- `release.yml:92` stages text files only and runs solely on
  `windows-latest`.
- Unix executable bit through `Publish-PSResource` → `Install-PSResource`:
  **unverified in either direction.** Phase 1 gate, not an assumption.
- Measured: native child spawn ≈ **46–48 ms** median here (S2's budget is
  150 ms). No Rust toolchain installed. `CHECKPOINT.md` is stale;
  `NOTES.md` has the real startup baseline (118 ms + 48 ms).
- Test posture: **283 `It` blocks**; 136 skip without PwshSpectreConsole.

---

## 3. Workstream 1 — engine correctness (PowerShell, ships first)

**Goal:** one implementation of the matrix, the six defects fixed, nine
per-cell tests. No Rust. Ends as a Gallery prerelease.

### 3.1 Issues (D-1) — filed 2026-07-26

| Issue | Title | Evidence |
|---|---|---|
| [#19](https://github.com/PBNZ/psmm/issues/19) | `Load`+`Latest` hits the gallery in the foreground on every shell start | `Invoke-PSMMStartup.ps1:62-63,83-85` → `Install.ps1:145` |
| [#20](https://github.com/PBNZ/psmm/issues/20) | Exact pin + `Install=Latest` force-reinstalls the pinned version every start | `Install.ps1:84-86` (`-Reinstall:$Update`) |
| [#21](https://github.com/PBNZ/psmm/issues/21) | `Load`+`IfMissing` drops `-Prerelease`, installing the newest stable | `Invoke-PSMMStartup.ps1:78` vs `Install.ps1:142` |
| [#22](https://github.com/PBNZ/psmm/issues/22) | `files > apply` unloads a loaded user module whose file is disabled | `50-Files.ps1:118,139,144` |
| [#23](https://github.com/PBNZ/psmm/issues/23) | A range-pinned module is flagged "update available" and can never clear it | `Gallery.ps1:433,437-441`; `10-Grid.ps1:76,443-447` |
| [#24](https://github.com/PBNZ/psmm/issues/24) | Task output is unbounded (`Receive-Job -Keep` re-reads the whole buffer every 500 ms), in four places; no cancellation | `Tasks.ps1:40,70`; `10-Grid.ps1:299,303` |
| [#25](https://github.com/PBNZ/psmm/issues/25) | Background job's `Update-PSResource` omits `-Prerelease`/`-Scope`; no installed-prerelease track | `Startup.ps1:131` vs `Install.ps1:87-95` |
| [#26](https://github.com/PBNZ/psmm/issues/26) | `Update-Help` failures report as success | `68-Tasks.ps1:65-77`; `Tasks.ps1:41-44` |
| [#27](https://github.com/PBNZ/psmm/issues/27) | The unmanaged scan is implemented twice; the engine copy is dead code | `State.ps1:169-190` vs `05-Init.ps1:145-167` |
| [#28](https://github.com/PBNZ/psmm/issues/28) | No `PowerShell.Exiting` handler — nothing disposes background work at session end (C6) | repo-wide: none |
| [#29](https://github.com/PBNZ/psmm/issues/29) | **Root cause / umbrella:** the matrix is implemented four times and the four disagree | `Invoke-PSMMStartup.ps1:62-102`; `Install.ps1:131-153`; `Startup.ps1:102-138`; `10-Grid.ps1:398-423` |

#19–#23 are correctness; #24–#28 are the ones the rewrite would otherwise
inherit. **#29 is the keystone** — fixing it is what makes most of the others
one-line consequences rather than separate patches, so it lands first.

### 3.2 The single policy function

Introduce `Get-PSMMEntryPlan -Entry <e> -Context <ctx>` in `src/Engine`,
returning a **structured decision object**, not a free-text string:

```
@{ Import = $true|$false; Install = 'none'|'ifmissing'|'latest'
   Check  = $true|$false; Schedule = 'foreground'|'background'
   Reason = '<plain words for the context sentence>'
   Notices = @('Install policy has no effect while Mode is Ignore') }
```

Every caller consumes the object: `Invoke-PSMMStartup` for scheduling, the
actuator for execution, the grid for the context sentence, the job payload
for background work. This removes the regex re-parsing at
`Invoke-PSMMStartup.ps1:87-96,121-127`.

**Job bodies get the plan, not the logic.** `Start-PSMMDeferredJob` and the
grid's task already receive a serialised payload; extend the payload to carry
the plan so the ThreadJob executes decisions rather than re-deciding them.
That is what kills implementations #3 and #4 without fighting ThreadJob scope.

### 3.3 D-2 (8.2a) applied

- Scheduling becomes derived, not declared: **import is foreground; every
  disk/gallery operation is background, in all nine cells.**
- `Load`+`Latest` imports what is on disk now and updates behind the prompt,
  reporting `updated to X — restart to use it` in the activity panel.
- `Load`+`IfMissing` when absent installs in the background and reports
  `installed — available next session` (Q-2). It does not import mid-session.
- Exact pin degrades `Latest` to `IfMissing` (fixes I-2). Range pin makes
  `Latest` mean newest-in-range, and the update check becomes range-aware so
  the flag can clear (fixes I-5).
- `Ignore` suppresses the check interactively as well as at startup, and
  gains the cross-field notice (§8.5 cells 7–9).
- Cell 4 (`InstallOnly`+`CheckOnly`) gains its plain-words context sentence:
  *"watch only — psmm will never install or load this."*
- **CHANGELOG must announce the behavioural change** (R5): anyone relying on
  `Latest` applying before the prompt now gets it after.

### 3.4 Tests (S8 / T5)

Nine `It` blocks, one per cell, each asserting install / import / check /
report **independently**, plus the cases nothing covers today: `Load`×
`Latest`×exact pin; range pin under `Latest`; range-pin flag clearing;
`Prerelease:true` through `Load`+`IfMissing`; `Ignore` reaching the
interactive check; `Invoke-PSMMApply` against a non-psmm disabled-file
module; the job's `Latest`+pin and `Latest`+prerelease branches. Add the
static guard that the matrix is decided in exactly one place (grep for
`$_.Mode -eq` outside the policy function).

### 3.5 Also in this workstream

- `Register-EngineEvent -SourceIdentifier PowerShell.Exiting` disposing jobs
  (I-10, C6) — needed regardless of the rewrite.
- Bound task output with a ring buffer and a stated cap (I-6, FR-2.8).
  `Update-PSMMTask` (`Tasks.ps1:40`) replaces the whole array every poll, and
  `Get-PSMMTaskFingerprint` (`:70`) re-reads the startup job's entire buffer
  **purely to count lines** — harvest incrementally and keep a count instead.
  Add cancellation while here: there is no `Stop-Job` anywhere, so a running
  task cannot be stopped (FR-2, and the protocol needs it as a first-class
  message).
- `Update-Help` reports failure (I-8, FR-5.3) — drop
  `-ErrorAction SilentlyContinue`, classify the known failure modes.
- Delete the dead `Get-PSMMUnmanagedModule` or make it the single
  implementation (I-9).
- Refresh `README.md`'s key table and `RELEASE-CHECKLIST.md` section A,
  which describe pre-`g`-layer keymaps.

---

## 4. Deliverable 3 — the ratified matrix (normative)

Under D-2, with scheduling derived. `Check` is background and report-only in
every cell where it runs.

| # | Mode | Install | Startup | Interactive |
|---|---|---|---|---|
| 1 | Load | CheckOnly | import if present (fg); never install; check (bg); absent ⇒ warn `missing — not loaded` | `i` available as explicit override |
| 2 | Load | IfMissing | import if present (fg); if absent install (bg) and report `installed — available next session`; check (bg) | standard |
| 3 | Load | Latest | import best on-disk (fg); check + update (bg); report `updated to X — restart to use it`; **exact pin degrades to cell 2**; range pin ⇒ newest-in-range | plus explicit `u` |
| 4 | InstallOnly | CheckOnly | nothing installed or imported; presence + update reported (bg) | context: *"watch only — psmm will never install or load this"* |
| 5 | InstallOnly | IfMissing | install if absent (bg); never import | standard |
| 6 | InstallOnly | Latest | keep newest eligible on disk (bg); never import | standard |
| 7–9 | Ignore | any | nothing, **and no gallery I/O of any kind** | visible, marked ignored; explicit actions still permitted; `Install` value preserved on save; `⚠` notice *"Install policy has no effect while Mode is Ignore"* |

Invariants: **Update never hot-swaps a loaded module** (V4 — keep today's
behaviour, but say so in the row rather than silently); **Check is suppressed
entirely for exact-pinned modules**; **invalid values degrade with a `⚠`
notice and are preserved on save**.

> **Amended by what rc02 actually shipped (PBNZ, 2026-07-26).** The `Check`
> column above is **not** performed at startup. `Get-PSMMEntryPlan` carries
> `Check` and the *interactive* check consumes it — which is what stops exact
> pins and `Mode: Ignore` entries being queried, as both were — but the
> deferred startup job runs no gallery check. At profile time there is no UI
> to show a result to and no cache to put one in, so it would be one gallery
> round trip per module per shell start bought for nothing visible, which is
> the opposite of what §3 is for. **Ruled: ship rc02 without it.** The field
> is already on the plan object, so reinstating it is small once there is a
> consumer — the natural shape is the self-update check's: background, at
> most daily, cached to disk, surfaced next time the TUI opens.
>
> Two further amendments from the same review, both in `CHANGELOG.md`:
> `files > apply` **never unloads** (a loaded module is not psmm's to remove;
> unloading is `^u`), and platform modules are **marked `system`**, not
> hidden, so their commands and help stay browsable.

---

## 5. Deliverable 4 — keyboard scheme (D-4)

Flat verbs, the `g` goto layer, mode-scoped submaps, no prefix.

**Motion — every list region**

| Key | Action |
|---|---|
| `j` `k` `↓` `↑` | row down / up |
| `ctrl+d` `ctrl+u` | half page — *freed precisely because load/unload left `^l`/`^u`* |
| `pgdn` `pgup` | full page |
| `G` `home` `end` | bottom / top / bottom |
| `tab` `shift+tab` | cycle regions (FR-0.9) |

**Frame (FR-0)**

| Key | Action |
|---|---|
| `1`–`9` | jump to tab *n* (Herdr) |
| `]` `[` | next / previous tab |
| `z` | zoom the focused region to the full frame, toggle (Herdr's verb) |
| `-` | collapse / expand the focused region |
| `=` | reset layout proportions |

**Row actions**

| Key | Action | Note |
|---|---|---|
| `enter` `l` `→` | open the module workspace (FR-10) | `enter` already bound today |
| `h` `←` `esc` | back | |
| `space` | select | unchanged |
| `L` `U` | load / unload | D-4; shift marks the session-mutating pair |
| `i` `u` | install / update | unchanged; `u` no longer shadowed |
| `r` `R` | refresh local (config+disk) / refresh **and** check the gallery | replaces `k`; Herdr's shift-widens-scope convention, and it leaves `c` free for copy |
| `p` | pin a version | reclaimed (KB-6) |
| `M` | move (folder / file / location contents) | destructive ⇒ shift |
| `m` | collapse / expand the unmanaged half | same key, new meaning (FR-3.1) |
| `x` `X` | clean this row / clean all | replaces `ctrl+a`/`shift+a` |
| `a` `b` `e` `d` `w` `s` `o` | adopt · browse commands · edit · delete · prereleases · status · disconnect | as today |

**Global**

| Key | Action |
|---|---|
| `/` | filter → enters the filter submap |
| `?` | context-aware help, generated from the keymap (FR-12) |
| `:` | command palette, generated from the keymap |
| `q` | back one level / close overlay |
| `^q` `^x` `Q` | quit — `^x` and `Q` are the flow-control-safe fallbacks (KB-4) |
| `ctrl+c` | quit (in raw mode it arrives as a key event, not a signal) |

**Submaps** — the mechanism that removes both collisions the PRD missed:

- *filter active*: `n` / `N` next / previous match, `esc` clear, `enter`
  apply. `n` keeps meaning "new file" / "add location" everywhere else.
- *text and pager surfaces*: `c` (and `y`) copy, `/` search, `n`/`N` repeat.
  `c` therefore never means check-for-updates anywhere — that is `R`.

**Goto layer** — 8 chords today (`Get-PSMMGotoTable`, `03-Goto.ps1:9-20`),
with one ratified change: gallery moves from `g g` to **`g s`** (search),
freeing `g g` for vim's top-of-list and making `gg`/`G` symmetric. The screen
already prompts "Search the PowerShell Gallery", so `s` is the better
mnemonic. Cost: one relearned chord, in a table, a welcome panel and a help
tab that are all generated from one source. The other seven —
`g h` `g f` `g p` `g t` `g c` `g x` `g ?` — are unchanged, and `g ,` is added
for settings (FR-11.1).

**Requirements.** KB-R1 one declarative keymap; KB-R2 a build-failing
duplicate-binding guard *per scope*; KB-R3 help and palette generated from
it, never hand-written; KB-R4 every action has a keyboard route;
**KB-R5 is reversed** — the keymap is user-remappable in the preferences
file, multiple bindings per action, invalid binding ⇒ safe default plus a
visible startup warning (Herdr's rule). Publish a safe-chord note and an
avoid-list; Herdr moved its own prefix off `ctrl+s` for exactly the reason
KB-4 names.

---

## 6. Deliverable 5 — mouse model

Adopt PRD §10 in full (MS-1…MS-7, §10.2's per-screen table), with three
changes:

- **MS-R1 restated:** the layout pass emits hit regions as data
  (`compute_view` → `render`), and *every hit region carries the keymap
  action id it invokes*.
- **MS-8 (new):** no mouse handler may perform an action directly; it
  resolves an action id and dispatches through the same table the keyboard
  uses. Parity then becomes a property of the data, not a promise.
- **MS-R2 restated (T8):** assert, over the keymap, that every action id has
  ≥1 key binding **and** ≥1 hit-region producer. That is a mechanical test,
  where the PRD's "checklist test" is a document that rots.

Herdr's bar is the one to hold: *usable without learning a single
keybinding*, with keyboard as an optional layer — while C10 keeps the
converse true.

---

## 7. Deliverables 6/6a/6b/6c — the frame and the new views

FR-0's three-region shell is **not a port of the current UI** — today's
architecture is a stack of full-screen loops, each with its own key handler
(`Invoke-PSMMManagerLoop` → `Show-PSMM*`). The frame must exist from the
first Rust frame drawn (PRD Phase 2 is right about this).

- **FR-1 loaded rail.** `Get-PSMMAuthProviderTable` (`Auth.ps1:9-58`) is a
  source literal that rebuilds five objects and ten scriptblocks on every
  lookup, and `Get-PSMMConnectionStatus` runs the provider synchronously
  with a bare `catch { }` (`:84`). Rebuild it as a real registry
  (registration function, built once), moved to a background, budgeted,
  cached check with a per-provider timeout — the gallery path is already
  time-bounded and auth is not. Replace the free-form `Account`/`Detail`
  scriptblocks (`:15-16` etc.) with a **declared field allow-list** per
  provider: anything a provider does not declare is dropped before render.
  That satisfies C12 by construction rather than by review.
- **FR-2 activity panel.** Needs the §3.5 engine work (ring buffer,
  `PowerShell.Exiting`, cancellation, the startup job joining the registry)
  before the panel can honestly claim FR-2.5–2.8.
- **FR-3 user/system split.** Engine-side (FR-3.7), built on
  `PSGetModuleInfo.xml` presence first, then path root, then signature —
  and it must explain itself per row (FR-3.3). Fold the duplicate scan
  (I-9) into one implementation while doing it. Overrides persist in the
  **preferences file**, not the module entry: UI saves write only known
  fields, so a module-entry override would be silently dropped on the next
  edit (`docs/config-schema.md` "Compatibility promise").
- **FR-10 module workspace**, **FR-11 settings**, **FR-12 help**: as the PRD
  specifies. FR-11's settings tab and FR-12's help are both *generated* —
  from the preferences schema and the keymap respectively — so neither can
  drift.
- **The palette does not move to Rust.** `src/Engine/Theme.ps1` already
  carries both a Spectre markup name **and** the xterm-256 index for each of
  its 14 tokens, specifically so the startup report can render the same
  tokens without Spectre loaded (`Get-PSMMAnsi`, `:66-77`). The startup
  report stays in PowerShell — it runs at profile time, where no Rust
  process exists — so the palette must stay there as the single source and
  be **handed to the UI over the protocol**. Duplicating it in Rust would
  reintroduce exactly the drift `D-RENDER` was written to prevent. NFR-7's
  three themes are token swaps (`:47-61`) and port as data.

---

## 8. Deliverable 7 — config location (D-3)

Scheme **(b)**, matching Herdr: `%APPDATA%\psmm\psmm-config.json` on
Windows, `$XDG_CONFIG_HOME/psmm/psmm-config.json` (else
`~/.config/psmm/…`) elsewhere.

`Get-PSMMMainConfigPath` (`Settings.ps1:27-32`) is the single seam — it is
already the only producer of the path, and `$PSMM_MainConfigPath` already
overrides it (C8 preserved). Migration is **opt-in, copy-not-move**,
reported file by file; resolution order is new-wins with a persistent banner
while the old path exists; `Get-PSMMConfigPath` lists both, marked old/new;
`Includes` targets, profile-directory configs and legacy globs are untouched
(FR-4.10); the deprecation horizon is stated in `CHANGELOG.md` (FR-4.9).

The same directory holds the new **preferences file** (FR-8/FR-11.4) —
human-readable, hand-editable, holding theme, mouse capture, layout
proportions, collapsed regions, column widths, sort, default tab, keymap
overrides (§5) and FR-3.4 classification overrides. Session state is never
persisted (Q-7).

---

## 9. Architecture, protocol, teardown, packaging, phasing

### 9.0 Where the ten §18 deliverables land

| §18 | Deliverable | Section |
|---|---|---|
| 1 | Target architecture / exact boundary | §9.1 |
| 2 | Front-end ↔ session communication, with trade-offs | §9.1–9.2 |
| 3 | `Mode`×`Install` matrix + discrepancies | §2.1, §4 |
| 4 | Streamlined keybindings, before/after | §2.2, §5 |
| 5 | Mouse model with keyboard parity | §6 |
| 6 | Activity panel, loaded rail, user/system split | §2.3, §7 |
| 6a | Screen layout — three regions, tabbed right pane | §7 |
| 6b | Module workspace | §7 |
| 6c | In-app settings, theming, help | §7, §8 |
| 7 | Config location + migration | §8 |
| 8 | Fast startup, background persistence, teardown, state | §3.3, §3.5, §9.3 |
| 9 | Delivery plan — two releases, not a strangler (D-5) | §3, §9.5 |
| 10 | Risks, packaging, CI, testing | §2.4, §9.4, §9.6, §10 |

### 9.1 Boundary — option B (stdio child), unamended

Scored against §7.3: **B 45, C 40, A 32, D 19, E 14.** Fact 1 (§2.4) is
decisive — the objection that could have sunk B is gone, because crossterm
never reads the child's stdin. B then wins on the two criteria that matter
most here: **EOF is a free, symmetric, cross-platform death signal** (C has
to *build* what B gets from the OS, and FR-7.4 makes a stale process a bug
with a test), and **testability** — a conformance run is
`Get-Content fixture.ndjson | psmm-ui --headless | diff - expected.ndjson`,
where a named pipe needs a harness. On a project where the human reviewer's
Rust budget is the scarce resource (R2), that difference compounds weekly.

Option D is rejected harder than the PRD implies: its only real advantage is
saving the 46–48 ms spawn, bought with a Rust panic killing the user's shell,
no elevation path at all, `Add-Type` on the launch path (which costs more
than the 48 ms it saves — N5), and crossterm contending with .NET's console
driver over the same handles.

- **Console ownership:** the child, exclusively, from `ESC[?1049h` to
  `ESC[?1049l`. It takes `CONIN$` implicitly via crossterm (events + raw
  mode) and `CONOUT$` / `/dev/tty` explicitly as a `File` handed to
  `CrosstermBackend::new`. Its stdout is protocol; its **stderr is
  free-form diagnostics only** — which is where a panic message lands, so
  NFR-9 gets a diagnosable message without touching the screen.
- **The shim** blocks in a strictly synchronous dispatch loop: read a line,
  execute, flush queued events, write the response. The session is quiescent
  and single-threaded, so mutation is safe and `-Global` behaves exactly as
  today (C1, and `Tests/Engine.Load.Tests.ps1` keeps guarding the same
  source). A property worth advertising: **the UI never freezes while the
  host is blocked** — a 90-second install leaves the grid scrollable and `q`
  responsive, which today's single-threaded Spectre loop cannot do.
- **C11 in three layers:** one wrapper (`Invoke-PSMMHostCall`) is the only
  engine call site and captures all six streams as `result.streams`; an AST
  guard in the shape of the existing `-Global` guard fails the build on
  `Write-Host`/`Write-Progress`/`Read-Host`/`$Host.UI.*`/`[Console]::*`/
  `Read-Spectre*` anywhere in the pump's call graph — **including reads**,
  because `Read-Host` at `05-Init.ps1:24` is a live re-entrancy deadlock
  under the pump; and a runtime flag catches scriptblocks built at runtime.
- **Elevation (#39) attaches later without a protocol break.** Windows
  forces the shape: `-Verb RunAs` requires `UseShellExecute = $true`, which
  forbids stdio redirection, so an elevated helper can never be a second
  stdio child — it must connect back over a per-session pipe/socket. The
  rule that makes it additive: *the UI has one peer, the shim; the shim may
  fan out to N actuators.* Reserve `actor` (default `"session"`) on request
  params and job records, and the `E_ELEVATION_REQUIRED` code. Two lines now.
- **Fallback is cheap.** Put the transport behind one seam on each side in
  Phase 1. B is overturned only by: a supported host where the child cannot
  open the console device with stdio redirected (VS Code's Integrated
  Console is the likeliest); idle CPU that cannot reach ≈0 on a blocking
  read; or stdin EOF failing to arrive on a force-kill. Each has a named
  test (§9.5).

### 9.2 psmm-proto v0

NDJSON, one object per line, UTF-8, no BOM, LF. Child→host on the child's
stdout, host→child on its stdin. Max frame 8 MiB (a runaway job becomes
`E_MALFORMED`, not an OOM). Unknown fields ignored; unknown `method` is
`E_UNKNOWN_METHOD`, never a disconnect. `$PSMM_ProtoLog` dumps both
directions — that is both the debugger and the source of the T3 golden
fixtures.

```
Request   { "id":"r17", "method":"grid.snapshot", "params":{…}, "timeout_ms":5000 }
Response  { "id":"r17", "result":{…} }
          { "id":"r17", "error":{ "code":"E_ENGINE", "message":"…", "hint":"…", "data":{…} } }
Event     { "event":"job.progress", "seq":412, "data":{…} }
```

Three deliberate deviations from Herdr, each earning its keep:

1. **`hello` is a mandatory first frame, not `ping`.** Herdr needs `ping` as
   a probe because clients attach at any time; psmm has one client for one
   lifetime, so the handshake can be rich enough to paint frame one without
   a second round trip — it returns proto, host/PS version, platform,
   elevation, install engine, theme name, caps, config paths, prefs and the
   session stash. Major mismatch ⇒ `E_PROTO_VERSION`, one plain sentence
   naming both versions and the fix, then close. `ping` survives as a
   zero-cost heartbeat.
2. **Events are flushed, not pushed.** True unsolicited push needs a second
   PowerShell thread writing to the child's stdin — reintroducing exactly
   the concurrency option B was chosen to avoid. So: `events.subscribe` is
   accepted and recorded, events queue host-side and flush as standalone
   frames immediately before each response, plus `jobs.poll { since_seq }`
   which the child sends **only while a job is live**. That is strictly
   better than today's unconditional 500 ms fingerprint poll
   (`01-Input.ps1:37`), so NFR-3 improves. The child's parser is identical
   either way, so real push later needs no version bump — and the
   conformance suite must include an event arriving at an arbitrary point.
3. **Cancellation has a mode, because a cancel that lies is worse than
   none.** `Stop-Job` mid-`Install-PSResource` can leave a half-written
   module folder. `{"mode":"detach"}` (default) stops reporting and always
   succeeds; `{"mode":"stop"}` returns
   `{stopped, partial_state_possible:true}` and the child must surface that
   flag.

**The rule that replaces "every long operation is a job":** imports and
unloads are foreground host calls — `Import-Module` cannot cross a job
boundary, which the engine already states at `Invoke-PSMMStartup.ps1:61-63`.
Everything touching disk-scan, gallery or network is a job. Nothing else may
block. So `timeout_ms` is advisory on `module.load`; a second mutating
request while one is in flight gets `E_BUSY`; and a full
`Get-Module -ListAvailable` sweep is a job — which is precisely how FR-6.4 is
met: frame one paints from config + in-session state, disk truth arrives as
an event.

Error codes are stable strings, not numbers: `E_PROTO_VERSION`,
`E_MALFORMED` (both fatal), `E_UNKNOWN_METHOD`, `E_BAD_PARAMS`,
`E_NOT_FOUND`, `E_BUSY`, `E_TIMEOUT`, `E_CANCELLED`, `E_ENGINE`, `E_POLICY`,
`E_ELEVATION_REQUIRED`, `E_UNSUPPORTED`. **The child never composes engine
prose** — it renders `message` and `hint` verbatim, so psmm's writing voice
does not bifurcate across two languages and every user-visible sentence stays
greppable in PowerShell, where the tests already are.

**Phase 1 methods (14):** `hello`, `ping`, `session.info`, `grid.snapshot`,
`grid.refresh` (job), `module.load` / `module.unload` (foreground),
`jobs.poll`, `jobs.output`, `job.cancel`, `events.subscribe`,
`session.stash`, `ui.log`, `shutdown`.
**Phase 2 adds:** `config.files`, `config.file.read`, `conflicts.list`,
`locations.list`, `cleanup.candidates`, `module.detail`, `module.commands`,
`selfupdate.status`, `prefs.get/set` — plus `gallery.search`,
`gallery.versions`, `help.get` and `auth.status` **as jobs**, the last
because FR-1.6 requires it.

**State ownership.** Host: config, entries and computed state (snapshot
tagged `rev`; a stale `rev` on a mutating request is `E_BAD_PARAMS`), policy
evaluation, job registry and ring buffers, paths and scope, gallery caches,
the preferences file (one writer to disk, so it stays listable by
`Get-PSMMConfigPath`), the theme *name* (`$PSMM_Theme` is public API).
Child: cursor, scroll, focus, filter, selection, expansion, active tab,
hover, in-use column widths — and the palette *definition*, with the golden
token table asserted from both sides (§7, N9). Between UI runs in one
session, that view state goes back to the host via `session.stash` and
returns in the next `hello` — never to disk. A crashed child simply loses
cursor position, exactly as §7.4 promises.

### 9.3 Teardown

**L0 — restore the *shared* console input mode.** The obligation the PRD does
not have. Unix: the shim captures `stty -g < /dev/tty` **before** spawn and
restores it in `finally` on every path (~5 ms, POSIX-exact). Windows,
abnormal paths only: spawn `psmm-ui --restore-tty`, a mode of the same
binary that opens `CONIN$`/`CONOUT$`, disables raw mode and mouse tracking,
leaves the alternate screen and shows the cursor (one ~47 ms spawn, on an
already-exceptional path). Not P/Invoke: `Add-Type` on the launch path costs
50–100 ms of first-use compilation, most of the S2 budget (N5).

**L1 graceful:** child sends `shutdown`, unwinds alt-screen → mouse → raw →
cursor in that order, closes stdout, exits 0; shim reaps with a bounded wait
and runs L0. **L2 child dies:** `ReadLine()` returns `$null` — the free
primitive stdio gives us; shim reaps, drains a 200-line stderr ring, runs
L0, prints one plain sentence. Child-side defence in depth: a `Drop` guard,
`panic::set_hook` that restores before printing, SIGTERM/SIGINT/SIGHUP
handlers.

**L3 orphan — this is what actually delivers C6.** Three independent, cheap
mechanisms: **stdin EOF** (pwsh's exit closes the pipe; the child's stdin
read returns 0 bytes — zero cost, it is a task already reading);
`prctl(PR_SET_PDEATHSIG, SIGHUP)` on Linux with an immediate `getppid()`
re-check to close the parent-died-first race; and a 2 s parent-PID watchdog
carrying **`--parent-start-time`** to close the PID-reuse hole.

> **Deviation from PRD §7.4, recorded in D-BOUNDARY: do not use Windows Job
> Objects in v0.** §7.4 calls them the layer that delivers C6. They are not,
> once fact 1 is in hand — EOF plus the watchdog cover the same failure with
> no P/Invoke, no `Add-Type` on the launch path, and no interaction with the
> job object Windows Terminal may already have assigned to pwsh. Revisit only
> if the orphan test fails on a real host.

**L4 window killed:** covered entirely by L3 on both platforms, at zero cost.
The ThreadJobs need nothing — they are in-process runspaces and die with
pwsh — so C6 is free for everything psmm starts today. That should become a
documented rule for future job bodies: nothing may spawn an external process.

**L5 graceful shell exit:** `Register-EngineEvent PowerShell.Exiting`,
registered **lazily** from `Start-PSMMTask` and the UI launch, never at
import, so a zero-config startup pays nothing (C5 intact). Its limitation —
it does not fire on window close or force-kill — is the reason L3 exists and
belongs in the code comment.

Plus: a **single-instance guard** per session, and a **nested-instance
refusal** via `PSMM_UI_ACTIVE=1` in the child's environment.

### 9.4 Packaging — `win-x64` in-package, three RIDs fetched (ratified)

Target RIDs `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64`. Only
**`win-x64` ships inside the Gallery package**; the other three are fetched
on demand from GitHub Releases.

The forcing fact is that `Install-PSResource` has no per-RID filtering
(§2.4), so every RID in the nupkg is downloaded by every user. Shipping all
four would tax a Windows user with two Linux binaries they can never run, on
a tool whose entire pitch is leanness. One binary keeps the package at
**1×B** and the primary Windows-first audience offline on first run.

Two properties of this choice are load-bearing:

- **It routes around the executable-bit question entirely.** That risk only
  exists for a binary arriving *through* the nupkg. No Unix binary ever
  does — they arrive as tarballs we extract and `chmod` ourselves. G2a is
  still worth running (you want the answer, and it decides whether an
  in-package Linux RID is ever viable) but Phase 1 is not hostage to it.
- **It is the pattern psmm already ships.** First `psmm` run today prompts
  to install PwshSpectreConsole from the Gallery (`05-Init.ps1:24`). A
  fetched binary is the same first-use contract, from a different source —
  and it *replaces* that prompt rather than adding one.

**Kill switch:** if the stripped `win-x64` binary exceeds 8 MB at the E1
gate, drop to fetching everything and keep the package at ~200 KB.

**Never execute the binary in place.** Even the in-package copy is copied to
a version-keyed cache — `%LOCALAPPDATA%\psmm\bin\<module-version>\<rid>\` /
`${XDG_CACHE_HOME:-~/.cache}/psmm/bin/<module-version>/<rid>/` — and run from
there. One rule kills four failure classes: `Update-PSResource psmm` cannot
fail on a file-in-use lock while the child runs; a read-only or `noexec`
module directory does not block launch; `chmod +x` never has to touch the
module folder; and resolution becomes uniform. Cost: one file copy per psmm
version, ~10–30 ms warm.

Resolution order in `Get-PSMMUIBinary`: `$PSMM_UIBinary` (explicit path — the
air-gap and distro-packager hatch, existence-checked only) → in-package
`bin/<rid>/` → the version-keyed cache → `psmm-ui` on `PATH` (accepted only
if `--proto-version` is compatible) → **offer to fetch**, with the same y/N
prompt users already accept from `Initialize-PSMMUI`; `$PSMM_NoFetch = $true`
skips straight to the P3 message for locked-down environments. RID detection
composes `[RuntimeInformation]::IsOSPlatform` + `OSArchitecture`, and
**detects musl explicitly**, refusing with a named remedy rather than
shipping a glibc binary that dies with a loader error.

**Fetch verification.** Each GitHub Release carries
`psmm-ui-<version>-<rid>.{zip,tar.gz}`. The **expected SHA-256 for every RID
is pinned inside the module**, in a generated
`src/Engine/UIBinary.Hashes.psd1` — no second network call, no trusting the
release page's own checksum file; the hash travels in the same artefact as
the module, and text is free. Mismatch ⇒ delete, refuse, print both hashes.
On Unix, `chmod 0755` explicitly after extract, never relying on the
archive's recorded mode. The committed hash file is a **fail-closed
placeholder** that refuses to fetch and points at `$PSMM_UIBinary`; the
release job regenerates it from the artefacts it just built, and a Pester
test asserts the placeholder shape so a hand-edited value can never ship.

**Verification before the binary is ever handed the terminal:**
`psmm-ui --proto-version` must print the expected proto and exit 0, cached by
`(path, mtime, size)`. That one ~47 ms probe catches glibc mismatch, missing
loader, `noexec`, SELinux denial, Mark-of-the-Web and AppLocker — which is
P3's "never a stack trace, never a hang", made structural. The failure
message names every path searched, the reason each failed, and the remedies —
retry, `$PSMM_UIBinary` for an offline copy, and (since D-5 leaves no
in-product fallback) `Install-PSResource psmm -Version 0.1.0-rc02 -Reinstall`
for the last Spectre release. It closes with the load-bearing sentence:
*nothing else in psmm needs this binary — `Invoke-PSMMStartup` and
`Get-PSMMConfigPath` work exactly as before.* That sentence is what keeps a
failed fetch an inconvenience rather than a dead install, and it is why the
binary must never be resolved on the profile path.

**`release.yml` changes:**

1. New `build-ui` job, matrix over the four RIDs on **native runners** —
   `windows-latest`, `windows-11-arm`, `ubuntu-latest`, `ubuntu-24.04-arm`.
   GitHub provides ARM runners for public repos, so **no cross-compilation is
   needed**. Steps: pinned toolchain (NFR-10), `cargo build --release
   --locked`, strip, `cargo deny check` + `cargo audit` (P5), `cargo test`,
   `clippy -D warnings`, `fmt --check`, upload artefact.
2. **Linux binaries never enter the nupkg**, which removes the
   cross-platform staging problem from the publish job entirely. `release`
   gains `needs: [build-ui]` and downloads **only** the `win-x64` artefact
   into `./bin/win-x64/` **in the working tree before PSSA and Pester**
   (P6 — tests exercise the shipped shape). `bin/` goes in `.gitignore`.
3. The stage list at `:92` gains `bin`.
4. New step **"pin the binary hashes"**, between Pester and Stage: SHA-256
   every artefact, write `src/Engine/UIBinary.Hashes.psd1` into the *staged*
   copy, and throw if the committed file is anything but the placeholder.
5. **Create the GitHub Release *before* `Publish-PSResource`.** The P3
   failure message points at a release URL; publishing first would ship a
   module whose fetch URL 404s for as long as the release step takes. This
   is a correctness requirement, not a preference.
6. New gate step **"binary must run"**: `& $stage/bin/win-x64/psmm-ui.exe
   --proto-version` must print the expected proto — catching a mis-staged or
   wrong-architecture artefact before publish.
7. `RELEASE-CHECKLIST.md` gains a binary-artefacts section and T17's manual
   round trip; `ci.yml` gains the same `build-ui` restricted to `win-x64` +
   `linux-x64`, plus the T3 conformance suite run from **both** sides.

### 9.5 Two releases (D-5)

Only two things reach the Gallery: **rc02**, the PowerShell correctness work,
and **rc03**, the Rust UI with Spectre deleted. Everything between them is an
internal milestone on a branch — gated, but unpublished.
`Tests/tools/try-psmm-branch.ps1` already runs the working tree against a
sandboxed copy of the real config, and is the harness for every milestone
pass.

#### rc02 — engine correctness (published)

Entry: the eleven issues in §3.1 filed (done, 2026-07-26). Work: §3, all of
it, in one release, starting with #29 because the rest fall out of it.
**Exit gate:** nine per-cell tests green (S8/V9); a test that fails if *any*
network call occurs on the startup path (instrument `Install-PSMMModule`);
startup timing unchanged against the `NOTES.md` baseline (118 ms + 48 ms);
PSSA clean; PBNZ's live-terminal pass; CHANGELOG announces the 8.2a
behaviour change (R5).
**STOP if** 8.2a breaks a real config in a way that cannot simply be
announced — reopen Q-1 rather than ship a silent behaviour change.

rc02 is also **the fallback for rc03**, so it has to be a version worth
falling back to: no known-bad state, and a CHANGELOG entry naming it as the
last Spectre release, with
`Install-PSResource psmm -Version 0.1.0-rc02 -Reinstall` written down.

#### rc03 — the Rust UI (published; `src/UI` deleted in the same release)

Entry: rc02 shipped and lived through a week or two of real use; Rust
toolchain installed (none today); ADRs written — **D-UI-RUST** (supersedes
`D-TUI`, including its mouse-centric objection to Terminal.Gui),
**D-BOUNDARY**, **D-PROTO**, **D-KEYMAP**, **D-CONFIG-PATH**, **D-STATE**,
**D-LAYOUT**.

**M1 — toolchain and shape.** *Gate E1, before any protocol work:* workspace
builds; `--proto-version` / `--restore-tty` / `--headless` exist;
`cargo deny`/`audit` clean; **stripped `win-x64` binary < 8 MB**; spawn +
`--proto-version` round trip < 60 ms.
> **STOP the programme here** if the binary exceeds 10 MB or spawn+handshake
> exceeds 60 ms. The 150 ms budget is then unreachable with a child process,
> and the boundary decision was wrong at the arithmetic level rather than the
> design level. This is the cheapest possible place to discover that.

**M2 — protocol spine.** The pump, the 14 Phase-1 methods, a read-only grid,
exactly one mutation (`module.load`). Gate: G1, G2a/b, G3, G4, G5, G6, G7,
G-HOSTS; T3 conformance from both sides in CI; the C11 AST guard green.
**STOP if** any of those fails and the fix needs abandoning stdio — fall back
to transport option C **once, timeboxed to a week**; if C also fails, stop,
and rc02 is simply where psmm stays.

**M3 — the frame, read-only.** Every screen rendering inside the FR-0
three-region tabbed shell, with the D-4 keymap. Gate: TestBackend layout at
five sizes including the stated minimum and one below (T14); focus model
(T15); keymap duplicate guard (T9); palette conformance from both sides.
**This is where PBNZ looks at it.** Under D-5 that is no longer a
ship-or-not decision but a continue-or-stop one — and stopping is cheap,
because rc02 has already shipped and psmm is none the worse.

**M4 — action parity, new views, mouse.** Every Spectre action gains a Rust
route; FR-1 (loaded rail + connection identity), FR-2 (activity panel),
FR-3 (Yours/System), FR-10 (module workspace); and the mouse layer (§6) —
which under D-5 is not a later phase but part of parity, because there is no
Spectre release left to carry users while it lands. Gate: T8 asserts every
action id has both a key binding and a hit-region producer; the nine-cell
matrix tests still pass unchanged; orphan and restoration tests on both
platforms.
**STOP if** mouse capture regresses copy/paste badly enough to stay off
(R7) — ship it default-off rather than delaying rc03.

**M5 — the rest, and the deletion.** FR-4 config path (D-3), FR-5
`Update-Help` verified, FR-11 settings, FR-12 help, FR-6/FR-7 hardening,
keymap remapping. Then **delete `src/UI`, drop the PwshSpectreConsole
dependency and unwind `D-OWN-MODULES`** (FR-9) — inside rc03, not after it.
Gate: T11 timing regression; T17 Gallery round trip; migration tested with
the old config path present, absent and both; **`Import-Module psmm`
measurably cheaper than the 118 ms baseline** (S1/FR-6.3), now a release
criterion rather than a Phase-6 aspiration; and PBNZ's live pass over every
screen — the full `RELEASE-CHECKLIST.md` section A, rewritten for the new
keymap.

**The one-way door.** rc03 removes the fallback in the act of shipping it,
so its live pass is not a formality — it is the only thing between a bad
frame and a broken tool. Do not tag it on a green suite alone.

### 9.6 Risks the PRD does not carry

| # | Risk | Mitigation |
|---|---|---|
| N1 | **The child mutates the *parent's* console.** Raw mode is on the shared input buffer, so a child dying unwinding-free leaves pwsh with echo and line input off. R4 treats this as child-side; it is parent-side | Teardown L0, unconditional on Unix and on every abnormal Windows path. Test G5 |
| N2 | **Ctrl+C no longer reaches pwsh while the UI is up** — raw mode disables `ISIG`/`ENABLE_PROCESSED_INPUT`, so a wedged child cannot be interrupted. A real regression against today's `ReadKey` behaviour | Input lives in its own Tokio task, separate from render, and owns restore, so it can always exit. Document Ctrl+Break (Windows) and `psmm-ui --restore-tty` from a second terminal (Unix). Named test: wedge the render task, assert Ctrl+C still exits and restores |
| N3 | **Nested psmm** — launching pwsh from inside the UI gives two children on one input buffer | `PSMM_UI_ACTIVE=1`; `Show-PSModuleManager` refuses. Plus the single-instance guard |
| N4 | **48 ms of the 150 ms budget is spent before psmm code runs** | Explicit budget — spawn 48 / handshake + snapshot ≤ 40 / first paint ≤ 30 / 30 slack, enforced by G7. The lever is already designed in: `grid.snapshot` skips the disk sweep |
| N5 | **`Add-Type` on the launch path would blow the budget alone** (50–100 ms first-use compile) | Hard rule: no `Add-Type` on the launch path — this is why L3 uses EOF not Job Objects and L0 uses `stty`/`--restore-tty` not P/Invoke. AST guard on the launch call graph |
| N6 | **The pump is a re-entrancy hazard** — any engine path that prompts deadlocks. One exists today (`05-Init.ps1:24`) | The C11 guard bans reads as well as writes; confirmation moves to the child; `E_POLICY` makes refusal data, not a prompt |
| N7 | **stdin EOF is not guaranteed if a pipe handle leaks** to another process | PID + start-time watchdog; PDEATHSIG on Linux; G6 in CI on both runners |
| N8 | **Two sources of palette truth** — `Get-PSMMAnsi` renders the startup report in PowerShell, Rust renders everything else | Golden token→colour fixture asserted from both sides, in the T3 suite. `D-RENDER` extended across the language boundary, not abandoned at it |
| N9 | **D-5 leaves no in-product fallback.** rc03 deletes Spectre in the act of shipping the Rust UI, so a bad frame cannot be worked around with a knob — it needs a downgrade | rc02 is built to be worth falling back to and its CHANGELOG names it as the last Spectre release, with the exact `-Version 0.1.0-rc02 -Reinstall` command; rc03's live pass over the full section-A list is a tagging precondition; M3 is an explicit continue-or-stop gate while abandoning is still cheap |
| N10 | **In-session psmm update vs a running binary** — a file-in-use failure on Windows. The existing skew guard (`Show-PSModuleManager.ps1:39-52`) covers `.ps1` only | "Never execute in place" (§9.4); extend the skew guard to the resolved binary's version |
| N11 | **Fetch-on-demand is a new supply-chain surface** the PRD does not have, because P1 assumed everything shipped in-package | SHA-256 pinned inside the module, so no second network call is trusted; fail closed on mismatch and on the placeholder; `$PSMM_UIBinary` escape hatch; `$PSMM_NoFetch` for locked-down environments; `cargo deny`/`audit` in CI (P5) |

PRD risks whose severity changes: **R1 down** — the Gallery package now
carries text plus one Windows binary, and the high-variance parts (Unix exec
bit, four RIDs, size) move to a tarball path we control end to end;
**R4 up** (N1 relocates the blast radius to the parent shell); **R6 changes
character** — with no per-RID filtering the cost was never build surface but
a download tax, which this packaging removes; **R2** unchanged, but its
off-ramp is now an explicit, blessed gate.

**Uncertainties and the experiment that resolves each:** U1 does
`disable_raw_mode()` restore from a *fresh* process on Unix (→ G5 variant;
if not, Unix relies solely on the shim's `stty -g`, which is already the
design); U2 does .NET's `ReadKey` reset the input mode itself, making part of
L0 unnecessary; U3 the exec bit (→ G2a/G2b, **run first**); U4 does stdin
hit EOF on `Stop-Process -Force` (→ G6); U5 is there a usable console device
in VS Code's Integrated Console (→ G-HOSTS); U6 are ARM runners available to
this repo (→ one `build-ui` run).

---

## 10. Verification

**Workstream 1 (must all pass before any Rust work starts):**

```powershell
Invoke-Pester -Path Tests                       # 283+ It blocks, all green
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

plus, specifically:

- the nine per-cell tests (§3.4) assert install / import / check / report
  independently;
- a static guard that `Mode`/`Install` is decided in exactly one function;
- `Tests/Engine.Load.Tests.ps1`'s `-Global` AST guard passes **unchanged**
  (C1, T2);
- a real-terminal pass by PBNZ before any tag — UI changes are never
  released on headless tests alone.

**Rust workstreams:** `TestBackend` frame tests at several terminal sizes
including the stated minimum and one below it (T14); focus-model test (T15);
keymap duplicate-binding guard (T9); keyboard/mouse parity over the action
table (§6, T8); protocol conformance fixtures run from both sides (T3).

**Named gates (§9.5).** `G2a`/`G2b` are cheap and answer the executable-bit
question for good; under the ratified packaging they are informational
(no Unix binary rides in the nupkg) rather than blocking, and they decide
whether an in-package Linux RID is ever viable. `E1` and `G7` are the two
that can stop the programme.

| Gate | Proves | Shape |
|---|---|---|
| G2a | the nupkg preserves the Unix exec bit | publish to a local repository, `unzip -Z -l` the nupkg, read the mode column for `bin/linux-x64/psmm-ui` |
| G2b | the same, end to end on Linux | `Install-PSResource` from that repository, `stat -c '%A'`, then `--proto-version` |
| G1 | Gallery round trip (P2 / Q-8) | clean machine: install prerelease, binary present, `--proto-version` exits 0, `psmm` renders a frame |
| G3 | `-Global` lands at the user's prompt (S5, C1) | drive the UI, load a module, then `Get-Module` / `Get-Command` at the prompt |
| G4 | scrollback byte-identical (S3) | capture before/after via the existing ConPTY harness, compare hashes |
| G5 | terminal restored after parent SIGKILL (S4) | `stty -g` before, `kill -9` the parent, diff after |
| G6 | zero orphans (S6, FR-7.4) | force-kill pwsh, poll for `psmm-ui` for 5 s, fail if it survives |
| G7 | first frame < 150 ms warm (S2) | 10 runs of `--bench-first-frame` against a fixture, take the median |
| G-HOSTS | option B holds on real hosts | G3 by hand in Windows Terminal, conhost, VS Code Integrated Console, Windows OpenSSH, tmux-over-SSH |

`Tests/tools/drive-psmm-ui.py` already drives the real TUI through a ConPTY
and is the natural harness for G3 and G4 — it was built for exactly this
class of check and should be extended rather than replaced.

---

## 11. Open items

1. The four carried defaults in §1 (Q-2, Q-4, Q-7, Q-12) stand unless
   overturned. Q-10 and Q-11 are dissolved by D-5; Q-3 and Q-5 were answered
   from source in §2.1; Q-8 belongs to the rc03 M2 gate; Q-9 is withdrawn by
   the PRD.
2. The seven implementation ADRs — **D-UI-RUST** (superseding `D-TUI`'s
   technology choice and its mouse-centric objection to Terminal.Gui),
   **D-BOUNDARY**, **D-PROTO**, **D-KEYMAP**, **D-CONFIG-PATH**, **D-STATE**,
   **D-LAYOUT** — are written at rc03 entry, not now. `D-RUST-UI` in
   `DECISIONS.md` records the programme-level ruling that authorises them.
3. Documentation debt this plan creates work for, tracked here rather than as
   its own issue: `RELEASE-CHECKLIST.md` section A describes the pre-`g`-layer
   keymap and must be rewritten against the D-4 scheme before rc03 ships;
   `README.md`'s key summary omits `^x`, `enter` and the `g ?` chord.
