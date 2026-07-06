# NOTES — psmm build log

## Provenance of the reference source

- The planning folder was expected to contain `existing-source/`, but it did
  not exist at build start (2026-07-04). The reference code was re-extracted
  read-only from the original design note (last edited 2026-07-03): the
  `powershell` code block (1,454 lines, parses clean) and the `json` example
  config (valid JSON). Both were saved back to the planning folder's
  `existing-source/` for future sessions.
- **Seed vs. live `$PROFILE`:** the build machine's `$PROFILE` contains
  **no psmm block** — the block lives on a different machine. No diff was
  possible; the note export (edited the day before the build) is treated as
  authoritative. If the other machine's copy is newer, reconcile manually
  later.
- The build machine has no `~/.psmm/` and no real psmm configs — nothing
  real was touched; all tests use scratch paths.

## Startup baseline (PRD §7 / §13, measured 2026-07-04)

Method: fresh `pwsh -NoProfile -NonInteractive` child processes,
`Measure-Command`, 5 runs, median; `USERPROFILE`/`HOME`/`$PROFILE` redirected
to an empty sandbox so zero configs are discovered and startup performs no
module work (pure parse + function-definition + empty-startup cost — the same
conditions will be applied to the finished module).

| Scenario | Runs (ms) | Median |
|---|---|---|
| bare `pwsh -NoProfile` (control) | 229, 205, 187, 183, 177 | **187 ms** |
| + dot-source original profile block (incl. `Invoke-PSMMStartup`) | 635, 420, 420, 419, 422 | **420 ms** |
| **original block cost** | | **≈ 233 ms** |

Acceptance target: `Import-Module psmm` + `Invoke-PSMMStartup` in the same
sandbox shows no meaningful regression vs. 233 ms.

### Final measurement (finished module, 10 interleaved runs, same sandbox)

| Scenario | Median | Cost over bare |
|---|---|---|
| bare `pwsh -NoProfile` | 176 ms | — |
| original block | 436 ms | **260 ms** |
| `Import-Module psmm; Invoke-PSMMStartup` | 468 ms | **292 ms** |

In-process split: `Import-Module` 118 ms + `Invoke-PSMMStartup` (zero
configs) 48 ms. **Verdict: +32 ms over the block (≈12%, imperceptible at
shell start) — accepted as within the PRD's "small margin".** The delta is
Import-Module manifest/session machinery + 11 source files vs. one; merging
files would need a build step (complexity) for ~tens of ms — declined. The
UI (14 more files + Spectre.Console) is parsed/loaded only on first `psmm`
call and costs profile import nothing.

## Environment

PS 7.6.3 · Pester 5.7.1 · PSResourceGet 1.2.0 · ThreadJob 2.2.0 · git 2.54 ·
Windows 11. PSScriptAnalyzer + PwshSpectreConsole saved to `.tools/`
(gitignored) via `Save-PSResource` so the real installed-module set stays
untouched.

## Lessons / gotchas (running)

- `jq` is not on this machine's Git Bash — use PowerShell `ConvertFrom-Json`.
- The note export's XHTML codeblocks: per-line `<div>`s; parse as XML after
  stripping the DOCTYPE and mapping `&nbsp;`.
- **Dot-sourcing inside a function defines functions in the function's
  transient scope** — they vanish on return. The lazy UI loader therefore
  declares every UI function as `function script:Name`, which lands them in
  the module's script scope regardless of where the dot-source runs.
- **`$t` and `$T` are the same PowerShell variable** (case-insensitive):
  a `$T` table + `foreach ($t in ...)` in one function silently clobber
  each other. Caught by the headless render tests.
- Accessors that return a `List[T]` via the comma trick (`, $list`) pipe the
  whole list as ONE object — return `@($list)` for pipe-safety instead.
- **`[Parameter(Mandatory)][string[]]` rejects empty-string ELEMENTS** —
  any text document with blank lines crashes the binding. Declare
  `[AllowEmptyString()]` (found by the ConPTY keystroke test, which the
  headless render tests could not catch — see `Tests/tools/`).
- **C# extension methods are invisible to PowerShell method syntax**:
  `$console.Clear()` (Spectre's zero-arg extension) throws MethodException;
  only the interface's `Clear($true)` works. Wrapped in `try { } catch { }`,
  this made every screen clear a silent no-op — sub-screens appended below
  the grid instead of replacing it. Beware of empty catch + extension method.
- `#24 "move into module"` interpreted as drill-in/out arrow navigation:
  right-arrow enters (grid → module menu → commands → help detail),
  left-arrow backs out. Recorded here because the request was one line.
