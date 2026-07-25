# DECISIONS — psmm build

One entry per significant decision. Newest at the bottom. PRD references are to
`PRD.md` in the planning folder (not in this repo).

---

## D1 — Module name: `psmm`

**Decision:** the module publishes as `psmm`.
**Verified:** `Find-PSResource -Name psmm -Repository PSGallery` returned no
result (2026-07-04), so the name is free. `psmm` also remains the interactive
alias.

## D2 — License: MIT

Copyright (c) 2026 PBNZ. Permissive, the community norm for PowerShell
modules. *(Amended 2026-07-14: copyright holder changed from the legal name
to the PBNZ handle in LICENSE and the manifest, and the meaningless "All
rights reserved." boilerplate dropped - the Copyright manifest field is
free-form and optional per about_Module_Manifests, and pseudonymous
copyright is recognized.)*

## D3 — Author / identifiers

- Author: `PBNZ` *(amended 2026-07-14, was the legal name - the Gallery
  Author field is a free-form string, often a handle or org name)*
- Manifest GUID (generated once 2026-07-04, never change it):
  `ed4c75e5-4d5b-43b1-a0ed-3c46fe4bcdee`
- `ProjectUri`/`LicenseUri` are placeholders until the GitHub repo exists —
  flagged in `RELEASE-CHECKLIST.md`.

## D4 — Minimum PowerShell version: 7.0

Language features used: `??`, `?:`-free code, `[Console]::ReadKey`, ThreadJob,
`Start-ThreadJob` (ships in PS 7 box as Microsoft.PowerShell.ThreadJob),
`ForEach-Object -Parallel` not used. Nothing requires 7.2+. Manifest declares
`PowerShellVersion = '7.0'`, `CompatiblePSEditions = @('Core')`.

## D5 — No remote, no push, local git only

Hard boundary from the PRD. All repo hosting, remotes, pushes, CI runs, and
publishing are PBNZ's post-build steps (`RELEASE-CHECKLIST.md`).

## D6 — CI matrix

`ci.yml`: lint + full Pester on `windows-latest`; engine-only Pester on
`ubuntu-latest` (tags-based filter, UI excluded). Sets up the cross-platform
story without pretending the UI is tested off-Windows.

## D7 — Publish tooling (for PBNZ, later)

`Publish-PSResource` primary, `Publish-Module` fallback; exact commands in
`RELEASE-CHECKLIST.md`. In-build packaging validation uses a temporary local
filesystem repository only.

## D-TUI — TUI technology: keep Spectre.Console (via PwshSpectreConsole), lazily loaded

> **Superseded in part by `D-RUST-UI` (2026-07-26)**, which replaces the
> technology choice and reverses the mouse-related reasoning below. The
> alternate-screen decision in this entry still stands.

**Evaluated options**
1. **PwshSpectreConsole / Spectre.Console (current)** — the existing look and
   feel is built on it; the current code already bypasses the cmdlet wrappers
   in the per-keypress path (direct `Spectre.Console.Table` construction,
   ~1–2 ms/frame vs ~60 ms via cmdlets), which we keep. Actively maintained,
   cross-platform, installs from PSGallery on first UI use.
2. **Hand-rolled VT/ANSI renderer** — zero dependencies and full control, but
   re-implements tables, markup, wrapping, wide-char handling, prompts, and a
   live-display diff for no user-visible gain; high effort, high regression
   risk against the look PBNZ wants preserved.
3. **Terminal.Gui** — full widget toolkit with a very different (boxy,
   mouse-centric) feel; would not preserve the current aesthetic and is a
   heavier dependency.

**Decision:** option 1. The fidelity + proven perf + maintained dependency beat
zero-dependency purity here. The heavy dependency stays **lazy**: nothing UI
related is imported (or even parsed — see D-STRUCT) until the first
`Show-PSModuleManager` call.

**Scrollback preservation (#4)** is independent of this choice: the UI now runs
inside the terminal's alternate screen buffer (`ESC[?1049h` on entry,
`ESC[?1049l` on exit), which is exactly how `edit`/`vim`/`less` restore the
screen. Works in Windows Terminal, conhost ≥ Win10 1809, and all VT terminals.

## D-STRUCT — Source layout: Engine/Public dot-sourced at import; UI parsed lazily

```
psmm.psd1, psmm.psm1
src/Engine/*.ps1     # platform-neutral, no UI deps — parsed at import
src/Public/*.ps1     # exported functions — parsed at import
src/UI/*.ps1         # everything interactive — dot-sourced on FIRST psmm call
```

One function per file for testability. The twist vs. the conventional
Public/Private split: the UI is by far the largest body of code, and parsing it
at import time would tax every shell start; deferring the *dot-sourcing itself*
keeps `Import-Module psmm` lean (startup is sacred, PRD §7). Tests can force
UI parsing via the internal loader to reach UI functions.

## D-UI-ARCH — Drive Spectre.Console LiveDisplay directly; no globals, no GetNewClosure

The original profile block ran its render loops through PwshSpectreConsole's
`Invoke-SpectreLive`, which executes the loop scriptblock in *that* module's
context — forcing all shared UI state into `$global:PSMM_*` variables and
`GetNewClosure()` local-capture workarounds (the code carried warning comments
about both).

**Verified empirically (2026-07-04):** a scriptblock authored inside a psmm
module function converts cleanly to `Action[LiveDisplayContext]`, runs
synchronously on the same thread via
`[Spectre.Console.LiveDisplay]::new($console, $renderable).Start($delegate)`,
and resolves **unexported module functions** and module script-scope state
just fine. It also renders against a custom `IAnsiConsole` backed by a
`StringWriter` (`Interactive = No`).

**Decision:** psmm's UI drives Spectre.Console types directly for all live
loops and hot render paths (the reference already did this for tables, for
perf); UI state lives in module script scope; the render console is a module
variable (`$script:PSMM_Console`) so tests can inject a StringWriter console
and assert on rendered frames headlessly. PwshSpectreConsole cmdlets are still
used where they're outside live loops and convenient (prompts, spinners,
rules). Bonus: automated smoke tests of actual rendered UI frames, which the
original architecture could not do.

## D-CONFIG — No schema changes in this build

Existing `psmm-config.json` files work byte-for-byte unchanged. New features
(auth status, scope display, unmanaged modules) derive everything at runtime;
no new config fields were needed, so none were added. If a future feature needs
one, extend with optional fields + defaults (never a silent break).

## D-DOCS — RepoKit doc-style adopted; living-docs add-on evaluated and not adopted (2026-07-14)

RepoKit 0.3.0 (2026-07-13) added two documentation standards. Applied to psmm
as follows:

**doc-style (adopted).** The deterministic formatting rules — one table style
(`|---|` separators, no alignment padding), ISO `YYYY-MM-DD` dates, fixed
status vocabulary, sentence-case headings, structure changes as their own
commit — now govern all psmm docs. An audit found the existing docs already
compliant, so adoption cost nothing; the rules bind future edits. Reference:
RepoKit `repo-standard/standard/doc-style.md`.

**living-docs (not adopted).** The add-on (docs/STATE.json + state blocks +
check-docs.ps1 in CI) targets repos whose docs track live operational state
and whose volatile facts would otherwise be stated in several places. psmm's
volatile facts already have exactly one canonical source each: version and
prerelease flag in `psmm.psd1`, history in `CHANGELOG.md`, release state in
`RELEASE-CHECKLIST.md`. Introducing STATE.json would create a *second* source
of truth for those facts, which contradicts the pattern's own core rule
("every volatile fact lives in exactly one place"). Revisit only if psmm docs
ever start duplicating status across files.

## D-IMPORT-SCOPE — every module import passes `-Global` (2026-07-22)

**Decision:** every `Import-Module` psmm performs on a managed module passes
`-Global`. A static AST guard test (`Tests/Engine.Load.Tests.ps1`) fails the
build if one appears without it.

**Why:** `Import-Module` called from inside a module imports into *that
module's* session state, not the global one (about_Modules; `Import-Module
-Scope`, whose default is `Local` when called from a module). psmm is a
module, so without `-Global` every module it loads lands in psmm's private
state: `Get-Module` at the prompt does not list it and its commands are "not
recognized" — while psmm's own `Get-Module`, which sees global *plus* its own
private imports, keeps reporting `● loaded` for the rest of the session. It
looked like a stale cache; it was two different session states.

**Why nobody noticed for eight betas:** PowerShell command auto-loading. For a
module whose manifest lists its exports, typing one of its commands
auto-loads it into the global state on demand, so the private import is
invisible. A module that exports `*` (verified with
`Microsoft.Online.SharePoint.PowerShell` 16.0.27313.12000) cannot be
auto-loaded by command name, and the failure becomes total.

**Consequence for state:** `Update-PSMMLoaded` deliberately keeps using plain
`Get-Module`. That is only honest *because* nothing is imported privately any
more — the two sets are identical. There is no supported way to enumerate the
global module table from inside a module, so the invariant is enforced by the
guard test rather than by a smarter query.

## D-PARALLEL — `ForEach-Object -Parallel` for cloud-file hydration (2026-07-22)

**Decision:** `Invoke-PSMMFileHydration -ThrottleLimit n` (n > 1) uses
`ForEach-Object -Parallel`. `n = 1` keeps the original sequential loop.

**Why:** hydrating a OneDrive placeholder is one blocking read per file, each
waiting on a network round trip — latency-bound work that overlaps almost
perfectly. `ForEach-Object -Parallel` streams each result as it lands, so the
caller's progress callback still runs on the calling thread (invoking a
caller-supplied scriptblock from a worker runspace would not be safe) and
per-file error handling is unchanged. It is PowerShell 7.0+, which matches the
module's floor (D4) — that entry's note that it is "not used" is now
superseded for this one code path.

**Bound:** concurrency is capped at the machine's logical processor count
(floor 2, ceiling 16). Each reader holds a runspace and a thread; past one per
core the extra threads queue behind the ones already waiting, and the sync
client — not psmm — becomes the limit. The UI shows both the cap and that
reason, because a bare "max 16" tells the user nothing.

## D-RENDER — cross-cutting rendering primitives (2026-07-22)

**Decision:** code/commands, links, prose and versions are rendered only via
the primitives in `src/UI/04-Render.ps1` (design-system §11). No screen
hand-formats them.

**Why:** each of those four had drifted into per-call-site formatting — flat
uncoloured JSON in help, one hand-cyaned update command, dead URLs, and
paragraphs running the full width of a 200-column terminal. The palette rule
("no colour literal outside the theme sources") already proved that a single
source plus a guard test is what actually holds a UI together over time; this
extends the same discipline from colour to the four other things every screen
shows.

## D-OWN-MODULES — psmm's own modules are infrastructure, not the user's session (2026-07-22)

**Decision:** psmm imports its UI dependency into its OWN session state (no
`-Global`), tracks what it imported by instance, and treats psmm + that
dependency as infrastructure everywhere in the UI: rendered as `◈ psmm's own`,
excluded from the "N loaded" count and the unmanaged scan, never unloaded.
They remain visible, installable and updatable.

**Why:** psmm manages the modules the user asked for. Before this, psmm wrote
its own dependency into the user's config, imported it `-Global` into the
user's session, counted itself in "N loaded", and offered both under `m` as
modules to adopt. None of that is the user's business.

**Why not hide them entirely:** a broken UI dependency would become unfixable
from inside the tool that needs it to render the repair screen. Visible but
marked is the honest middle.

**The coupling that makes this subtle:** `Get-Module` inside psmm returns the
global module table PLUS psmm's private state, so the moment psmm imports
anything privately, `Update-PSMMLoaded` must subtract it or it reports
"loaded" for a module the user's prompt cannot see - the D-IMPORT-SCOPE bug
again, smaller. The two rules are one mechanism and a single guard test
enforces both halves: an import registered via `Register-PSMMPrivateImport`
must NOT be `-Global`; every other import must be.

**Subtraction is by INSTANCE, not by name.** Verified: when the user imports
the same module globally themselves, `Get-Module` inside psmm returns THEIR
instance, so a by-name exclusion would hide a module they really do have
loaded. Reference equality gets both cases right.

**Also fixed by this:** `files > apply` unloads anything "managed but not
active", and `$managed` includes entries from disabled files - so disabling
the file holding the seeded dependency entry made psmm target its own engine,
and itself, for `Remove-Module` mid-session. Reproduced before fixing.

> **Note (2026-07-26):** the fix was a psmm-own allow-list, not a fix to
> `$managed`, so the same failure class is still reachable for any *user*
> module. See issue #22. `D-RUST-UI` schedules unwinding this whole entry.

## D-RUST-UI — replace the Spectre UI with a Rust binary; two releases, not a strangler (2026-07-26)

**Decision:** psmm's interactive manager is rebuilt as a Rust binary
(Ratatui / Crossterm / Tokio) driven over a line protocol by a PowerShell
pump. The engine, the config semantics and the public API stay PowerShell.
Full reasoning, the re-derived `Mode`x`Install` matrix, the keyboard and
mouse models, the protocol sketch and the delivery plan are in
[`docs/rust-ui-plan.md`](docs/rust-ui-plan.md); the requirements it answers
are in [`docs/PRD-psmm-rust-ui.md`](docs/PRD-psmm-rust-ui.md).

Six rulings, all ratified 2026-07-25/26:

| # | Ruling |
|---|---|
| D-1 | The engine defects found during Phase 0 are fixed in PowerShell **first**, before any Rust ships. Filed as issues #19-#29 |
| D-2 | Gallery/network I/O is **never** foreground. Import is foreground; all disk/gallery work is background, in all nine `Mode`x`Install` cells. No schema change, so `D-CONFIG` holds |
| D-3 | The main config moves to a platform-native path - `%APPDATA%\psmm` on Windows, `$XDG_CONFIG_HOME/psmm` (else `~/.config/psmm`) elsewhere. Migration is opt-in and copies, never moves |
| D-4 | The keyboard model is flat single-letter verbs plus the existing `g` goto layer plus mode-scoped submaps. **No prefix key.** Uppercase `L`/`U` for load/unload. The keymap is user-remappable via the preferences file, reversing the PRD's KB-R5 |
| D-5 | **No strangler and no dual UI.** `rc02` is the PowerShell correctness work; `rc03` is the Rust UI and deletes `src/UI` in the same release. There is no `$PSMM_UI` selector, ever |
| D-6 | `win-x64` ships inside the Gallery package; `win-arm64`, `linux-x64` and `linux-arm64` are fetched on demand against a SHA-256 pinned inside the module |

**Why now.** The UI is the largest and least testable body of code in the
repo (`D-STRUCT`); Ratatui's `TestBackend` gives frame assertions natively
where `D-UI-ARCH` needed a bespoke `IAnsiConsole`; `ROADMAP.md` #34 is
blocked on key handling and alternate-screen behaviour that Crossterm carries
as a maintained cross-platform dependency; mouse support is wanted, reversing
`D-TUI`'s objection to Terminal.Gui on that ground; and the UI dependency is
the entire reason `D-OWN-MODULES` exists, so a Rust UI makes most of that
machinery deletable.

**Why the engine work comes first (D-1).** Phase 0 found the `Mode`x`Install`
matrix implemented **four times**, in four places that disagree - the two
ThreadJob bodies re-derive policy because module functions are invisible
inside a job. Porting four disagreeing implementations would bake the
disagreement into a protocol. One policy function returning a plan object
comes first; the job bodies then execute decisions instead of re-deciding
them.

**Why no strangler (D-5).** Carrying both front ends means two keymaps, two
help surfaces, divergence documentation and a selector knob with its own
tests - ongoing drag on a solo project. The cost is real and recorded: rc03
deletes the fallback in the act of shipping it, so the fallback is the
**previous release** (`Install-PSResource psmm -Version 0.1.0-rc02
-Reinstall`), and rc03's real-terminal pass is a tagging precondition rather
than a formality.

**Verified while deciding, because each would have changed the answer:**
Crossterm 0.29 reads input from the console device, not from redirected
stdio - Windows via `Handle::current_in_handle()` (`CONIN$` through
`CreateFileW`, not `GetStdHandle`), Unix via `tty_fd()` falling back to
`/dev/tty` - so a child with stdio pipes still owns the terminal, which is
what makes the boundary viable. `CrosstermBackend::new` is generic over any
`Write`, so rendering can target `CONOUT$` / `/dev/tty` explicitly.
`Install-PSResource` has **no** per-RID filtering, so every RID in a package
is downloaded by every user - which is what forces D-6.

**Not decided here.** The seven implementation ADRs - **D-BOUNDARY**,
**D-PROTO**, **D-KEYMAP**, **D-CONFIG-PATH**, **D-STATE**, **D-LAYOUT**, and
the formal **D-UI-RUST** superseding note on `D-TUI` - are written at rc03
entry, against working code rather than a plan.

## D-PLAN — one policy function; scheduling is derived, not declared (2026-07-26)

**Decision:** `Get-PSMMEntryPlan` (`src/Engine/Plan.ps1`) is the only place
the `Mode` × `Install` matrix is decided. It returns a plan object — import /
install / check / schedule / reason / notices — and every caller *executes*
that plan: the startup loader for scheduling, `Invoke-PSMMPlanAction` for the
disk/gallery half, the grid for its context sentence, and the job payload so
ThreadJob bodies stop re-deriving policy.

Scheduling follows from the pair rather than being chosen by either: **the
import is the only foreground action; every disk or gallery operation is
background, in all nine cells.**

**Why:** the matrix was written out four times — `Invoke-PSMMStartup`, the
actuator, the deferred job body and the grid's install task — and the four
disagreed. Six of the eight rc02 defects were consequences of that single
fact, not independent bugs: the foreground gallery round trip (gh#19), the
pinned force-reinstall (gh#20), the dropped `-Prerelease` (gh#21), the job's
missing `-Prerelease`/`-Scope` (gh#25). Fixing them one at a time would have
left the fifth copy free to drift next.

**Why the duplicates existed, and why they no longer have to.** Module
functions are invisible inside a `Start-ThreadJob` runspace, which is a real
constraint — both job bodies said so in comments. Re-deriving policy to
satisfy it was the mistake. `Get-PSMMJobPrelude` emits the real functions as
source text for the job to dot-source, so the constraint is met without a
second implementation. A static guard test (`Engine.Plan.Tests.ps1`) fails
the build if any file outside `Plan.ps1` compares `Mode`/`Install` against
the config vocabulary again. The guard is **case-sensitive on purpose**:
config words are PascalCase (`'Latest'`), plan verbs are lowercase
(`'latest'`), and that casing is exactly the line between deciding and
executing.

**The behavioural cost, accepted and announced (R5).** A module that has to
be installed at shell start is now installed in the background and reported
as available *next* session, rather than being imported behind a prompt the
user is already typing into (Q-2). Anyone relying on `Latest` applying before
the prompt gets it after. The alternative — keeping the foreground install —
is what made a cold `Az` or `Microsoft.Graph` install a multi-minute
unresponsive shell.

**Where the shipped code deviates from the plan's §4, deliberately.** §4 says
a report-only update check runs in the background at startup for cells 1-6.
The plan object carries `Check`, and the *interactive* check consumes it — so
exact pins and `Ignore` entries are no longer queried, which they both were.
But the startup job performs no gallery check: at profile time there is no UI
to show a result to and no cache to put one in, so it would be N gallery
round trips per shell start bought for nothing. Reinstate it when there is a
consumer; the field is already there.

**Verified while deciding:** a `Register-EngineEvent -Action` scriptblock
cannot see its defining module's `$script:` variables — they read as `$null`,
and `-MessageData` did not survive either — so the session-exit disposal
handler reaches module scope through `& (Get-Module psmm) { … }` instead.
Written the obvious way, it would have disposed nothing while looking
correct.
