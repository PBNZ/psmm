# RELEASE CHECKLIST — human-only steps (PBNZ)

Everything here was deliberately **not** done by the build session (hard
boundary: no remotes, no publishing, nothing public, no real UI eyeballing).
Work top to bottom.

## A. Manual verification in a real terminal (before sharing with testers)

The agent verified the engine, data model, exports, packaging and headless
frame rendering with tests — but nobody has *watched* the UI run. In a real
Windows Terminal:

```powershell
$repo = '<path to your psmm clone>'
Import-Module $repo\psmm.psd1
Invoke-PSMMStartup    # against your real configs — check the report + timings
psmm
```

- [ ] **Re-check after the 2026-07-05 fixes** (use a FRESH shell — the
      previously-imported broken module lingers in old sessions): on a
      machine with no configs `psmm` now **auto-creates**
      `~/.psmm/psmm-config.json` managing PwshSpectreConsole (InstallOnly),
      the unmanaged notice shows once, `m` reveals the unmanaged modules,
      esc quits clean. *(Machine-verified with real keystrokes via
      `Tests/tools/drive-psmm-ui.py` — this line is your confirmation pass.)*
- [ ] Sub-screens (`a` add, apply, cleanup, version pin...) repaint a CLEAN
      page — nothing appends below the grid / pushes content up (2026-07-05
      Clear() fix).
- [ ] Scrolling a long list (e.g. `m` with many unmanaged rows) never
      changes the table width (2026-07-05 width-jitter fix); a one-entry
      grid still shows ≥5 table rows.
- [ ] `a` with no writable config offers to create one instead of the old
      dead-end message.
- [ ] Startup report prints per-module lines with import times; background
      task line appears for InstallOnly modules; warnings legible.
- [ ] `psmm` opens in the **alternate screen**; on quit (esc / Ctrl+Q) your
      previous terminal content is exactly restored (#4).
- [ ] Grid: arrows/PgUp/PgDn/Home/End, space select, `/` filter (type, enter
      keeps, esc clears), position indicator, resize redraws (#11/#12).
- [ ] Right-arrow drills into a module; left-arrow backs out (#24).
- [ ] Ctrl+L / Ctrl+U load/unload with visible per-module progress (#5);
      Ctrl+P starts a background install and the grid stays usable (#25).
- [ ] `u` update check runs in background; `^` markers appear; a pinned
      module never shows `^`.
- [ ] `m` reveals unmanaged modules once the scan lands; Enter → A adds one
      to a config (#26/#27).
- [ ] Module menu: B command browser (`/` works, esc resets filter — #19–21),
      Enter on a command → tabs render, including on a small window (#10).
- [ ] `I`/`O` connection status + disconnect on a Connect-* module you use
      (Graph or EXO is the easiest test) (#32).
- [ ] `x` version cleanup lists duplicates; non-elevated session skips
      AllUsers copies with a notice (#28).
- [ ] `g` gallery search finds and adds a module (#38); `t` tasks screen;
      `u` there starts background Update-Help (#35).
- [ ] `f` files: space toggles Enabled + saves, `a` applies to session,
      `n` creates from a scenario template (#29), `m` moves a file and fixes
      Includes.
- [ ] `?` shows real, per-screen help everywhere (#13).
- [ ] Ctrl+Q hard-quits from every screen.

## B. Profile bootstrap (your machines)

Replace the old drop-in block in `$PROFILE` with:

```powershell
Import-Module psmm    # or the full path while unpublished
Invoke-PSMMStartup
```

Your existing `~/.psmm/psmm-config.json` + includes keep working unchanged.
Knobs (`$PSMM_StartupReport`, `$PSMM_BackgroundStartup`, `$PSMM_InlineJson`,
`$PSMM_JsonPath`) must be set **before** the Import-Module line.

## C. Share with private testers (no gallery needed)

Either send the repo folder, or build a nupkg and share it:

```powershell
# stage the shippable content (mirror of what the packaging test did)
$stage = "$env:TEMP\psmm-stage\psmm"
New-Item -ItemType Directory -Force $stage | Out-Null
'psmm.psd1','psmm.psm1','src','Configs','LICENSE','README.md','CHANGELOG.md' |
    ForEach-Object { Copy-Item "$repo\$_" $stage -Recurse }
Register-PSResourceRepository -Name psmmShare -Uri "$env:TEMP\psmm-share" -Trusted
Publish-PSResource -Path $stage -Repository psmmShare
# -> share the .nupkg from $env:TEMP\psmm-share; testers install with:
#    Register-PSResourceRepository -Name psmmLocal -Uri <folder-with-nupkg> -Trusted
#    Install-PSResource psmm -Repository psmmLocal
Unregister-PSResourceRepository -Name psmmShare
```

## D. Repo hosting at github.com/PBNZ/psmm

Exposure audit + cleanup done 2026-07-06: no secrets anywhere, no personal
email (author is `PBNZ@users.noreply.github.com`), personal traces scrubbed
from the current files AND from history (docs/fixture/harness were removed
from past commits and re-added clean; commit trailers stripped). Cleared
for full-history publish.

1. Create the repo public and push:
   `gh repo create PBNZ/psmm --public --source . --push`
   (or start `--private` and flip to public after the CI run).
2. Confirm the first CI run passes (`.github/workflows/ci.yml` — lint + full
   Pester on Windows, engine tests on Linux). It has never actually run.
3. Optional, to enforce the README's "issues limited to contributors for
   now": repo Settings → Moderation options → Interaction limits →
   *Limit to prior contributors* (max 6 months, renewable), and/or
   Settings → Features → untick Issues until you're ready.

## E. Publish to the PowerShell Gallery

**0.1.0-beta1 was published manually on 2026-07-06.** Every release after
it goes through the tag-triggered pipeline
(`.github/workflows/release.yml`), which refuses to publish unless the tag
matches the manifest version and the full quality gate (PSSA + the whole
Pester suite) passes first.

One-time setup:
- [x] Repo Settings → Secrets and variables → Actions → new repository
      secret **`PSGALLERY_API_KEY`** (the same key used for beta1, scoped
      to `psmm`). *Added 2026-07-06.*

Per release (beta2, beta3, ... and eventually stable):
1. Bump `Prerelease` (and/or `ModuleVersion`) in `psmm.psd1`, update
   CHANGELOG, commit and push.
2. `git tag v<version>[-<prerelease>]` (e.g. `v0.1.0-beta2`), then
   `git push --tags`.
3. Watch the *Release to PowerShell Gallery* workflow; its final step
   polls the Gallery until the new version is findable.

Iterate by bumping only the label — burned prerelease numbers are painless
and `0.1.0` stays reserved for stable.

Two rules govern the label, and they pull against each other. Both were
learned the hard way on 2026-07-23 and are now enforced by the release
workflow before it publishes.

**1. It is compared LEXICALLY, never numerically.** `0.1.0-beta10` sorts
BELOW `0.1.0-beta9`: the Gallery would keep serving beta9 as latest,
`Update-PSResource` would refuse to move anyone, and psmm's own update
notice would stay silent. That wall is why the line went `beta9` →
**`rc01`** (`rc` > `beta`), and why the digits are **zero-padded** — fixed
width makes lexical order match numeric order, so `rc10` > `rc09` holds.

**2. Dots are illegal, however idiomatic.** The Gallery accepts only
`a-zA-Z0-9` in a prerelease (plus a leading hyphen) and rejects anything
else *server-side, after the entire quality gate has run* —
`Test-ModuleManifest` passes it locally, so nothing catches it earlier. The
SemVer-correct fix for rule 1 would be `rc.1`, with the number as its own
numeric identifier; it is not publishable. `v0.1.0-rc.1` died here.

So: keep the same prefix and the same digit width for the whole line
(`rc01`, `rc02`, … `rc10`, … `rc99`), and only change the prefix when you
need to step up (`beta` → `rc` → stable).

## E2. Later: promote to stable 0.1.0

1. Remove the `Prerelease` line from `psmm.psd1`, update `ReleaseNotes` +
   CHANGELOG heading, commit, push.
2. `git tag v0.1.0` and `git push --tags` — same pipeline. Testers on
   `-Prerelease` update to stable automatically (0.1.0 > 0.1.0-betaN).

## F. Optional: auto-resume scheduled task for future long builds

See STARTER-PROMPT.md appendix in the planning folder — a Task Scheduler job
running `claude --continue` in this repo. Set up and test on a small run first.
