# rc02 handoff — what to look at before merging

Branch: **`fix/rc02-engine-correctness`**, open as
[PR #31](https://github.com/PBNZ/psmm/pull/31).

All eleven issues [#19–#29](https://github.com/PBNZ/psmm/issues) are fixed.
The full rationale is in `CHANGELOG.md` and `DECISIONS.md` `D-PLAN`; this
page is only the things **you** should rule on.

---

## 1. Judgement calls — all ruled on (2026-07-26)

Every call below is settled; nothing here is waiting on a decision. Kept as
the record of what was decided and why.

### 1.1 No update check at startup — RULED: ship without it *(settled 2026-07-26)*

`docs/rust-ui-plan.md` §4 says a background, report-only update check runs at
startup for cells 1–6. rc02 does not do that half, deliberately: at profile
time there is no UI to show a result to and no cache to put one in, so it
would be one gallery round trip *per module, per shell start*, bought for
nothing visible.

The half that IS done: the plan object carries `Check`, and the *interactive*
check consumes it — which is what stops exact pins and `Mode: Ignore` entries
being queried, as both were before.

**Ruled: ship rc02 without it.** Recorded as an amendment against §4 of the
plan so the next session does not read the matrix as unimplemented. If it is
ever wanted, the shape is the self-update check's — background, at most
daily, cached to disk, surfaced next time the TUI opens.

### 1.2 `files > apply` — RULED: it never unloads *(settled 2026-07-26)*

**Your ruling: "The module is already loaded. It should not be unloaded by
psmm."** Applied, and taken to its general form: apply only ever *adds*.
Editing config changes what happens at the next shell start; unloading is
`^u`, never a side effect of an edit. Apply now names anything still loaded
that the config no longer asks for, so the state is visible rather than
silently divergent.

The session-import tracking I had added for the previous criterion is deleted
along with it rather than left sitting there unused.

### 1.3 System modules — RULED: marked, not hidden *(settled 2026-07-26)*

**Your ruling: they must stay in the unmanaged view so psmm can browse their
commands and help.** Applied. They are listed again and render as `system` in
the scope column.

One thing worth knowing about how it is implemented, because it is not
obvious: the mark is a **separate property, not a third `Scope` value**. Both
version-cleanup paths guard with `-eq 'AllUsers'` / `-ne 'AllUsers'` string
tests, and an unrecognised third value falls **open** through them — an
unelevated session would have started trying to uninstall copies under
`$PSHOME`. Finding that also closed a hole that was already there:
`Get-PSMMDuplicateVersion` has no platform filter, so platform copies already
reached both cleanup screens labelled `AllUsers`, and an **elevated** session
could have uninstalled a module the shell itself depends on. Now refused at
any elevation.

### 1.3a Two defects your screenshots exposed — both root-caused and fixed

Neither was introduced by rc02; both were reproduced against `main` first.

**The module screen said "not installed" while describing the module in
full.** Pressing `m` (show/hide unmanaged) rebuilds the entry list, and a
rebuild mints fresh blank objects whose disk fields are only filled by the
full disk sweep — which a toggle skips, for speed. So after one `m` press
**every** module in the grid read "missing", not just PwshSpectreConsole. The
manifest block kept working because it reads memory, not disk, which is
exactly why the screen contradicted itself. Disk and gallery facts now
survive a rebuild. Before/after on your config: `m` → `Installed=False` /
`○ missing`, versus `2.6.3` / `◈ psmm's own`.

*"session: not imported" on that same screen is correct, not a bug* — psmm
imports its UI engine into its own module scope, never `-Global`, so your
prompt genuinely cannot see it (`D-OWN-MODULES`).

**The blinking cursor.** You remembered a past fix, and the archaeology is
worth a sentence: cursor hiding did arrive in 0.1.0-beta7, but it only ever
covered alt-screen entry and text input. Spectre's live display shows the
cursor again every time it exits, and the module menu has read keys outside a
live display since the very first UI commit — so that screen has blinked
since the beginning and nothing regressed. Fixed at the mechanism (re-assert
on live exit, on every repaint, and before every key psmm waits for) rather
than per-screen, plus a test that fails if a new key-wait forgets, and a
real-terminal check in the ConPTY harness that I verified fails without the
fix.

### 1.3b Your own modules were being filed as `AllUsers`

On the maintainer's machine `$HOME` is on `C:` while Documents — and so the
CurrentUser module folder — is on another drive entirely. The user-vs-machine
test was a bare `$HOME` prefix comparison, so **every module installed there**
was reported machine-wide: shown as read-only in the grid, and skipped by
version cleanup as "session is not elevated". Cleanup was effectively dead on
that machine. It now also tests the Documents-derived root, which psmm already
computed for its OneDrive diagnostics.

This is the "related, worth fixing at the same time" note on #27, and it is
probably the highest-impact fix in the round for you specifically.

### 1.4 CI pins Pester to 5.x — RULED: keep it, with an expiry *(settled 2026-07-26)*

Unpinned `Install-PSResource -Name Pester` now resolves to **6.0.1**, which
**fails to load on pwsh 7.4.x** — `Update-TypeData` rejects its type
converter. Reproduced in `mcr.microsoft.com/powershell:latest` (pwsh 7.4.2).
The suite is written against Pester 5 (`#Requires ModuleVersion 5.0`), so the
pin is correct on its own terms, not just as a workaround.

**Ruled: keep the pin, and track the migration decision** —
[#30](https://github.com/PBNZ/psmm/issues/30), so it has a review date rather
than quietly ossifying. Not blocking: the whole suite is green on both
runners under 5.x (numbers in §3).

### 1.5 Two small UI additions inside a keymap that is supposed to be frozen

- `x` on the tasks screen = cancel a running task. #24 asked for cancellation
  and there was no way to stop anything psmm started.
- A range pin renders `pin≈` in the version column (exact pins already
  rendered `pin`; ranges rendered nothing, so a range-pinned row showed an
  update arrow with no explanation — #23).

Both are additive. Say the word and either can go.

### 1.6 `RELEASE-CHECKLIST.md` section A is rewritten now, not at rc03

Plan §3.5 puts it in rc02's scope; §11.3 says rewrite it against the D-4
keymap before rc03. I read those as two passes and did the first: section A
now matches the **current** `g`-layer keymap, with a new **A1** block that is
just the rc02 behaviours. It will need the D-4 pass at rc03 as planned.

---

## 2. What I could not do, and you can

- **The live pass.** Headless tests and a ConPTY harness cannot tell you
  whether it *looks* right. `RELEASE-CHECKLIST.md` **section A1** is the
  rc02-specific list and should take ten minutes.
- **Merge, tag and publish.** The branch is pushed and PR #31 is open with CI
  green on both runners; merging and tagging are yours.
- **macOS.** Untested, as before.

---

## 3. Verification actually run (not claimed)

Numbers below are **CI's** on the branch tip, not a local claim — GitHub's own
runners, on the same commit the PR proposes to merge. Baselines in brackets
are `main`'s last CI run.

| Check | Result |
|---|---|
| Pester, Windows, full suite | **358 passed, 0 failed, 1 skipped** (main: 283 — 75 new tests) |
| Pester, **Linux**, `-Tag Engine` | **223 passed, 0 failed, 3 skipped** (main: 157 — 66 new tests) |
| PSScriptAnalyzer, repo source | **0 errors / 0 warnings** |
| ConPTY keystroke harness, real TUI | **all checks pass** |
| Startup A/B vs rc01, same filesystem, 15 runs | `Invoke-PSMMStartup` 101 → **98 ms**; `Import-Module` 184 → **190 ms** |
| Packaging | stages, publishes to a local repository, and a staged copy imports in a fresh process |

The nine per-cell matrix tests, the "no network on the startup path" gate and
the single-decision static guard are all in `Tests/Engine.Plan.Tests.ps1` and
`Tests/Engine.Startup.Tests.ps1`.

---

## 4. Two traps I hit, written down so you don't

**The `118 ms + 48 ms` startup figures in `NOTES.md` do not reproduce.**
rc01 itself measures **184 / 101** on this machine. I nearly reported a 2×
regression before A/B-ing against rc01. Two things made it worse: comparing a
worktree on local disk against a checkout inside **OneDrive** (a phantom
30 ms), and not discarding the first run, which is consistently a large
outlier. `NOTES.md` now records all of this.

**`Tests/tools/drive-psmm-ui.py` had been broken since beta8** — four
separate rots, each of which made every later step unreachable, so the repo
has had no working real-terminal check for several releases while appearing
to have one. Repaired and extended; run it after any UI change:

```powershell
python Tests/tools/drive-psmm-ui.py
```

---

## 5. What is left

1. `pwsh -NoProfile -File Tests\tools\try-psmm-branch.ps1` — the branch
   against a sandboxed copy of your real config.
2. `RELEASE-CHECKLIST.md` section **A1** (the rc02-specific list), then the
   rest of A if you want it.
3. Merge PR #31 — `Closes #19`–`#29` in the body retires all eleven issues on
   merge; #30 stays open by design, with a review date.
4. Tag `v0.1.0-rc02` and push the tag; the release workflow re-runs the gate
   before it publishes.

Nothing is blocked on a decision.
