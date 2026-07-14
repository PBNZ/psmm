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

Copyright (c) 2026 Peter Braun. Permissive, the community norm for PowerShell
modules.

## D3 — Author / identifiers

- Author: `Peter Braun`
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
publishing are Peter's post-build steps (`RELEASE-CHECKLIST.md`).

## D6 — CI matrix

`ci.yml`: lint + full Pester on `windows-latest`; engine-only Pester on
`ubuntu-latest` (tags-based filter, UI excluded). Sets up the cross-platform
story without pretending the UI is tested off-Windows.

## D7 — Publish tooling (for Peter, later)

`Publish-PSResource` primary, `Publish-Module` fallback; exact commands in
`RELEASE-CHECKLIST.md`. In-build packaging validation uses a temporary local
filesystem repository only.

## D-TUI — TUI technology: keep Spectre.Console (via PwshSpectreConsole), lazily loaded

**Evaluated options**
1. **PwshSpectreConsole / Spectre.Console (current)** — the existing look and
   feel is built on it; the current code already bypasses the cmdlet wrappers
   in the per-keypress path (direct `Spectre.Console.Table` construction,
   ~1–2 ms/frame vs ~60 ms via cmdlets), which we keep. Actively maintained,
   cross-platform, installs from PSGallery on first UI use.
2. **Hand-rolled VT/ANSI renderer** — zero dependencies and full control, but
   re-implements tables, markup, wrapping, wide-char handling, prompts, and a
   live-display diff for no user-visible gain; high effort, high regression
   risk against the look Peter wants preserved.
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
