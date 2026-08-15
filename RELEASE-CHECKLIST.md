# RELEASE CHECKLIST — human-only steps (PBNZ)

Everything here was deliberately **not** done by the build session (hard
boundary: no remotes, no publishing, nothing public, no real UI eyeballing).
Work top to bottom.

## A. Manual verification in a real terminal (before sharing with testers)

Rewritten 2026-07-26 against the **current** keymap (the `g` goto layer, as
shipped in 0.1.0-beta6) and rc02's behaviour. The previous version described
pre-`g`-layer bindings and was marked stale; `I`/`O`/`B`/`A`/`Ctrl+P` and
bare `g`/`t`/`f`/`p` no longer mean what it said.

`Tests/tools/drive-psmm-ui.py` now replays most of the navigation below with
real keystrokes in a real ConPTY and passes end to end, so the boxes here are
for the things a machine cannot judge — **does it look right, and does it
behave right against your own configs.**

Safest way to drive the working tree without touching your real config:

```powershell
pwsh -NoProfile -File Tests\tools\try-psmm-branch.ps1     # your config, copied to a sandbox
```

Or against the real thing:

```powershell
$repo = '<path to your psmm clone>'
Import-Module $repo\psmm.psd1
Invoke-PSMMStartup    # against your real configs - check the report + timings
psmm
```

### A1. rc02 behaviour (new — check these first)

- [ ] **Nothing at shell start waits on the network.** With a `Latest` entry
      in your config, the prompt appears immediately; the update happens
      afterwards. Previously this was a gallery round trip before the prompt.
- [ ] The startup report shows a **`missing`** row (warn-coloured `○`) for a
      `Load` module that is not installed, and says which it is: `not loaded,
      check-only`, or `installing in the background, available next session`.
- [ ] A module installed by that background job is **not** imported into the
      running session — it is there next time you open a shell.
- [ ] A module pinned to an exact version does **not** re-download on every
      shell start (watch the background task line across two or three shell
      starts).
- [ ] Pressing `u` on an exactly pinned row says there is nothing to update
      rather than silently reinstalling.
- [ ] A **range**-pinned entry (`"Version": "[1.0,2.0)"`) shows a `pin≈`
      marker, and if it is flagged for update, taking the update clears the
      flag.
- [ ] `g t` tasks: `x` cancels a running task and it reads **cancelled**, not
      failed. `u` runs `Update-Help`; if it genuinely fails it now reports
      **failed** rather than done.
- [ ] `m` (unmanaged) still lists the modules that ship with PowerShell, but
      their scope column reads **`system`** rather than `all`. Drill into one
      and `b` still browses its commands and help.
- [ ] Press `m`, then drill into any row: it still shows its version and
      **does not** claim to be missing. (Toggling used to blank the disk
      state of every module in the grid.)
- [ ] Your own modules show scope **`user`**, not `all ro` — check one you
      installed yourself. Then `x` on a module with duplicate versions
      actually offers to remove them instead of "not elevated".
- [ ] No blinking cursor anywhere: drill into a module (`enter`), open the
      tasks screen with no tasks (`g t`), and pause on any "press any key"
      prompt.
- [ ] `g f` files: disable a file holding a loaded module, `a` (apply) — it
      stays loaded, and apply says so.
- [ ] The row under the cursor shows a `⚠` notice line when an entry sets
      `Install` while `Mode` is `Ignore`.

### A2. Frame, navigation and restoration

- [ ] `psmm` opens in the **alternate screen**; on quit (`esc` / `^q` / `^x`)
      your previous terminal content is exactly restored.
- [ ] First run ever floats the **welcome overlay** (three tips); any key
      closes it and it never returns.
- [ ] Grid: arrows / PgUp / PgDn / Home / End, `space` selects, `/` filters
      (type, `enter` keeps, `esc` clears), position indicator is right, and
      **resizing the window redraws** cleanly.
- [ ] Scrolling a long list (`m` with many rows) never changes the table
      width; a one-entry grid still shows ≥5 table rows.
- [ ] `right`/`enter` drills into a module; `left` backs out — the same pair
      on every screen.
- [ ] The `g` goto layer works from **every** screen: `g h` home · `g g`
      gallery · `g f` files · `g p` paths · `g t` tasks · `g c` conflicts ·
      `g x` cleanup · `g ?` the key reference.
- [ ] `?` shows real, per-screen help everywhere, with all five tabs.
- [ ] `^q` and `^x` both hard-quit from every screen.
- [ ] Sub-screens (`a` add, apply, cleanup, version pin…) repaint a **clean**
      page — nothing appends below the grid or pushes content up.

### A3. Actions

- [ ] `^l` / `^u` load and unload with visible per-module progress.
- [ ] `i` starts a background install and the grid **stays usable**; `k`
      runs the update check in the background and `⇡` markers appear.
- [ ] `a` with no writable config offers to create one rather than dead-ending.
- [ ] Module menu: `b` command browser (`/` works, `esc` resets the filter),
      `enter` on a command renders its tabs, including on a small window.
- [ ] Module menu: `v` pins a version from the list of what exists; `w`
      toggles prereleases; `x` prunes duplicate versions (a non-elevated
      session skips AllUsers copies with a notice); `p` moves its folder.
- [ ] Connection status and disconnect on a `Connect-*` module you actually
      use (Graph or EXO is the easiest test).
- [ ] `g g` gallery search finds and adds a module.
- [ ] `g f` files: `space` toggles Enabled and saves, `n` creates from a
      scenario template, `m` moves a file and fixes `Includes`.
- [ ] `g p` paths: your OneDrive warning is accurate, cloud-only download
      and keep-on-device behave.

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

**This is now a gate, not a memory.** `Tests/Repo.Hygiene.Tests.ps1` scans
every git-tracked file on every run of the suite — locally and in CI — for
home-directory paths carrying a real account name, for the account name of
whoever is running it (read from the environment, so it protects every
contributor and hard-codes nobody), and for personal email addresses. The
maintainer's public handle is read from the manifest's `Author` and allowed,
because identifying by handle is the policy.

It exists because during 0.1.0-rc02 a diagnostic's raw output — a real
account name and drive layout — was pasted into a handoff document as
evidence and pushed to the public remote. It was caught by review, not by a
check; the ad-hoc grep that would have caught it had been run three commits
earlier and never repeated. The history was rewritten to remove it. **A check
you have to remember to run is not a check** — hence the test.

> Rewriting published history does not unpublish it: old commits stay
> reachable by SHA on GitHub until garbage collection, and a PR keeps
> referencing them. If something genuinely sensitive ever lands, rewriting is
> the first step, not the whole remedy — rotate the secret, and ask GitHub
> Support to purge the objects.

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
