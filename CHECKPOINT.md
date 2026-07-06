# CHECKPOINT — resume pointer

**Last updated:** 2026-07-06 — **BUILD COMPLETE + public/prerelease-ready.**

## Public + prerelease prep (2026-07-06)

Peter confirmed the GitHub slug (PBNZ/psmm), full-history publish, and
keeping all dev docs. Exposure audit of working tree + full git history:
no secrets, no personal email (author is the GitHub noreply address);
benign traces documented in RELEASE-CHECKLIST section D. Manifest now
carries `Prerelease = 'beta1'`; packaging re-validated against a temp local
repository (`psmm.0.1.0-beta1.nupkg`, hidden without `-Prerelease`, found
with it, fresh-process import OK). README install section rewritten for
Gallery-prerelease + clone; checklist sections D/E/E2 now cover public
repo, beta publishing and stable promotion. Peter's remaining steps:
sections A (eyeball pass), D (create repo + push + CI), E (publish beta1).

## Post-build fix round 2 (2026-07-05, Peter's second live report)

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

Peter's first live run (zero-config machine) crashed the sync path and the
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
Peter's own eyeball pass (look & feel, remaining screens) is
RELEASE-CHECKLIST section A.

## State

The build program is finished and verified. If you are a resumed session
reading this: there is no in-progress work. The remaining steps are Peter's
and live in `RELEASE-CHECKLIST.md` (manual UI verification in a real
terminal → private testing → repo hosting → publish).

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
