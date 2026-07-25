# CHECKPOINT — resume pointer

**Last updated:** 2026-07-26 — **rc02 is written, gated and committed on
`fix/rc02-engine-correctness`. It needs PBNZ's live pass, then a PR and a
tag.**

## Now (2026-07-26, later)

All eleven issues [#19-#29](https://github.com/PBNZ/psmm/issues) are fixed on
branch **`fix/rc02-engine-correctness`** (4 commits, no PR opened — that was
deliberate). `docs/rust-ui-plan.md` §3 is the spec that was implemented; §4
is the matrix that shipped.

The keystone was **#29**: `Mode`x`Install` was implemented four times.
`src/Engine/Plan.ps1` is now the only place it is decided —
`Get-PSMMEntryPlan` returns a plan object, every caller executes it, and
`Get-PSMMJobPrelude` ships the real engine functions into ThreadJob bodies so
they stop re-deriving policy. A static guard test fails the build if any file
outside `Plan.ps1` starts branching on the config vocabulary again.

**Verified** (all against real command output):

- Pester **334/334** on Windows (was 283 — 51 new).
- Engine tests **204/204 on Linux**, in Docker (`mcr.microsoft.com/powershell`,
  pwsh 7.4.2) — the same filter CI's Linux job uses.
- PSScriptAnalyzer **0 errors / 0 warnings**.
- The **ConPTY keystroke harness passes end to end** — see below, it did not
  before.
- Startup timing A/B vs rc01 under identical conditions:
  `Invoke-PSMMStartup` 101 → **98 ms**, `Import-Module` 184 → **190 ms**.

**Two things a resumed session should know:**

1. `Tests/tools/drive-psmm-ui.py` had been **silently broken since beta8** —
   four separate rots, each making every later step unreachable, so there was
   effectively no real-terminal check at all. It is repaired and extended.
   Run it after any UI change: `python Tests/tools/drive-psmm-ui.py`.
2. The `118 ms + 48 ms` startup split in `NOTES.md` **does not reproduce** on
   current machines — rc01 itself measures 184/101 here. Compare A/B against
   the previous commit, both worktrees on the *same* filesystem, and discard
   the first run. `NOTES.md` now says so.

**Open questions for PBNZ** are in
[`docs/rc02-handoff.md`](docs/rc02-handoff.md) — read that before merging.
The live pass is `RELEASE-CHECKLIST.md` section A, rewritten for this
release; its A1 block is the rc02-specific list.

Everything below this section is history from the original build.

## Published (2026-07-06)

Repo created public (branch renamed master→main to match the manifest
URIs) and pushed. Maiden CI run failed on one Windows test — root cause:
Spectre.Console force-enables ANSI when GITHUB_ACTIONS=true, overriding
AnsiSupport.No (verified with a local probe); fixed by stripping ANSI in
ConvertTo-PSMMTextLines + the test helper, suite verified locally under
GITHUB_ACTIONS=true. **CI run 2: both jobs green.** Remaining for PBNZ:
PSGallery beta1 publish (checklist E) and the section-A eyeball pass.

## Public + prerelease prep (2026-07-06)

PBNZ confirmed the GitHub slug (PBNZ/psmm), full-history publish, and
keeping all dev docs. Exposure audit of working tree + full git history:
no secrets, no personal email (author is the GitHub noreply address);
benign traces documented in RELEASE-CHECKLIST section D. Manifest now
carries `Prerelease = 'beta1'`; packaging re-validated against a temp local
repository (`psmm.0.1.0-beta1.nupkg`, hidden without `-Prerelease`, found
with it, fresh-process import OK). README install section rewritten for
Gallery-prerelease + clone; checklist sections D/E/E2 now cover public
repo, beta publishing and stable promotion. PBNZ's remaining steps:
sections A (eyeball pass), D (create repo + push + CI), E (publish beta1).

## Post-build fix round 2 (2026-07-05, PBNZ's second live report)

1. **Screens never cleared (push-up bug):** `(console).Clear()` is a C#
   extension method PowerShell can't call; the empty catch made every clear a
   silent no-op, so sub-screens (new entry, apply, cleanup...) appended BELOW
   the grid and pushed it up. Fix: `Clear($true)` (interface method). Now all
   full-screen flows repaint a clean alt-buffer page.
2. **Add flows dead-ended without a config:** new `Get-PSMMAddTargets` offers
   to create the main config on the spot ('a' on grid / A on unmanaged row).
3. **First `psmm` run with zero configs now auto-creates the main config**,
   seeded with PwshSpectreConsole (Install=IfMissing, Mode=InstallOnly) so
   psmm's own UI dependency is managed. TUI only — profile startup never
   writes files.
4. **Table width jitter while scrolling:** grid column widths now computed
   from ALL rows (fixed Width + NoWrap per column), not the viewport, so
   scrolling never resizes the table.
5. **Short lists padded to ≥5 table rows** so a fresh one-entry grid doesn't
   look collapsed.

Verified: Pester **96/96**, PSSA gate clean (0 errors / 0 warnings), ConPTY
keystroke harness extended (auto-create + full 'a' add-entry wizard) — all
checks green.

## Post-build fix (2026-07-05)

PBNZ's first live run (zero-config machine) crashed the sync path and the
`m` key: empty-array-unrolls-to-null hit Mandatory `$Entries` params. Fixed
at the shared engine functions (commit `8b8656e`) and regression-tested.

The fix was then verified with **real keystrokes in a real ConPTY
pseudo-terminal** (`Tests/tools/drive-psmm-ui.py`): open on zero configs →
scan finds 81 unmanaged → `m` reveals rows + position indicator → `?` opens
help → PageDown scrolls → esc back → esc quits cleanly → alternate-screen
restore code emitted → process exits, zero error text in the stream. That
run flushed out one more real bug — the shared pager's Mandatory
`[string[]]` rejected blank lines (crashed `?` help) — fixed with
`[AllowEmptyString()]` + regression test. Suite now **91/91**, PSSA 0.
PBNZ's own eyeball pass (look & feel, remaining screens) is
RELEASE-CHECKLIST section A.

## State at the end of the original build (2026-07-06)

The build program was finished and verified; there was no in-progress work,
and the remaining steps were PBNZ's, in `RELEASE-CHECKLIST.md` (manual UI
verification in a real terminal → private testing → repo hosting → publish).
All of those have since happened — see **Now** at the top of this file for
the current state.

## Verified facts (final, all against real command output)

- Pester: **85/85 passing** (engine, discovery/precedence, save round-trip,
  legacy compat incl. a full-size 17-module config fixture, startup
  semantics, module/manifest/exports/help, headless UI frame rendering,
  tasks, auth, pinning).
- PSScriptAnalyzer: **0 errors / 0 warnings** with
  `PSScriptAnalyzerSettings.psd1` (4 justified exclusions, documented).
- Packaging: `psmm.0.1.0.nupkg` produced against a temporary local
  filesystem PSRepository; staged copy imports and runs startup. No gallery,
  no API key, repo unregistered.
- Startup perf: block 260 ms vs module 292 ms over bare pwsh (10-run
  medians); +32 ms accepted, split documented in NOTES.md.
- Fresh-context verifier subagent: 12/12 items PASS (one PARTIAL that is
  inherently manual — live-terminal UI checks). Its one actionable finding
  (compat fixture was abridged) was fixed: a full-size legacy config now
  lives at `Tests/fixtures/legacy-real-config.json` with its own test.
- Git: no remote, clean tree, logical commits M0→M8.

## Milestones

M0 scaffold+baseline ✓ · M1 engine ✓ · M2 startup loader ✓ · M3 UI
framework/grid ✓ · M4 screens ✓ · M5 tasks/intelligence/auth ✓ ·
M6 research→ROADMAP ✓ · M7 quality gates ✓ · M8 docs+verification ✓
