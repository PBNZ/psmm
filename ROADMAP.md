# ROADMAP — what remains after this build

## 0. Current programme: the Rust UI (2026-07-26)

Planned and ratified. The interactive manager is rebuilt as a Rust binary;
the engine, config semantics and public API stay PowerShell. Two releases:
**rc02** is the engine correctness work (issues #19-#29), **rc03** is the
Rust UI and deletes the Spectre one.

Full plan: [`docs/rust-ui-plan.md`](docs/rust-ui-plan.md). Requirements:
[`docs/PRD-psmm-rust-ui.md`](docs/PRD-psmm-rust-ui.md). Decision:
`DECISIONS.md` `D-RUST-UI`.

## 1. Private testing round — done

psmm has been in private use since 0.1.0-beta1 (2026-07-06); live-run
feedback has driven every beta since. `RELEASE-CHECKLIST.md` section A
remains the manual UI verification list, and is due a rewrite against the
new keymap before rc03.

## 2. Going public + publishing to the PowerShell Gallery (#33) — done

Public at github.com/PBNZ/psmm since 2026-07-06; releases are tag-triggered
through `.github/workflows/release.yml`. Current published version:
0.1.0-rc01. `RELEASE-CHECKLIST.md` sections D/E/E2 still govern the process.

## 3. Deferred features

Each was weighed for this build and deferred for the stated reason. The ones
marked **needs PBNZ's decision** should be a short joint planning session,
not a solo build.

### #31 — Auth redirect to a specific Edge profile *(needs PBNZ's decision)*
`Connect-*` flows open the system default browser; they should open in a
specific Edge profile instead. There is no PowerShell-level API for this:
options are (a) temporarily flipping the default-browser/protocol handler
(invasive), (b) an `msedge.exe --profile-directory=...` wrapper registered
as a dummy protocol handler, (c) device-code flows + manually pasting into
the right profile. All have real trade-offs on a managed machine.
**Decide:** which mechanism is acceptable, and whether it's psmm's job at all.

### #39 — Run/load a module "as admin" from a normal session *(needs PBNZ's decision)*
Elevation cannot cross process boundaries: a module can't load "as admin"
into the current non-elevated session. The honest version is launching an
elevated helper pwsh (UAC prompt) for specific actions (e.g. AllUsers
install/cleanup) and reporting results back. Security-sensitive and easy to
make annoying. **Decide:** which actions justify a UAC prompt, and whether an
elevated-helper pattern is wanted at all.

### #40 — Credential-manager integration behind Windows Hello *(needs a planning session)*
Large and security-sensitive (SecretManagement vault unlock via WHfB,
per-module credential wiring). Needs its own design session: threat model,
which vault, what psmm actually does with the credentials.

### #34 — Full non-Windows support *(folded into the Rust UI programme)*
The engine is platform-neutral by design and its tests run on Linux in CI
(`ci.yml`). The UI renders via Spectre.Console (cross-platform capable), but
key handling, scope detection and the alternate-screen behaviour have only
been exercised on Windows.

Crossterm carries the cross-platform key/terminal burden as a maintained
dependency, so the rewrite *advances* this rather than competing with it:
rc03 ships `linux-x64` and `linux-arm64` alongside Windows. It does not
finish the job on its own - `Get-PSMMScopeForPath` still buckets everything
outside `$HOME` as `AllUsers` (issue #27), and macOS remains out of scope
until after rc03. Keep #34 as its own planned work, not a side effect.

### #30 — Deep Microsoft Graph version handling
The generic part shipped: the version-cleanup screen (x) prunes stacked old
versions of any module, Graph included, and mixed-scope duplicates are
flagged. Deferred: Graph-*specific* intelligence (treating the ~40
Microsoft.Graph.* submodules as one family, aligned family updates,
v1.0-vs-beta hygiene). Domain-heavy; the payoff over generic cleanup is
unclear until real-world testing says otherwise.

## 4. Ideas from the competitor research (build later if testing wants them)

From the SAPIEN ModuleManager / ModuleFast / PSDepend / community-pain
research (2026-07-04). Already shipped from that research: duplicate-version
cleanup, install-scope awareness, per-module import timing, version pins,
failure-resilient bulk updates, PSResourceGet/PowerShellGet engine indicator.
Still on the shelf:

- **Lockfile / machine export** — `psmm export` writes the current machine's
  module state as a config; config + lockfile makes a new laptop
  reproducible (ModuleFast's `-CI` model).
- **Lazy-load stubs** — a third Mode that generates proxy stubs which import
  the real module on first command use; attacks Graph/Az startup cost harder
  than anything on the market.
- **Assembly-conflict advisor** — detect known shared-DLL collisions
  (Az.Accounts vs Microsoft.Graph.*) and recommend load order.
- **Az/Graph family curation view** — group `Az.*`/`Microsoft.Graph.*` into
  families, show imported-vs-merely-installed, offer "trim unused".
- **ModuleFast as optional install backend** for parallel installs of big
  sets.
- Explicitly skipped (wrong audience for a terminal tool): remote-machine
  module management, module publishing workflows.
