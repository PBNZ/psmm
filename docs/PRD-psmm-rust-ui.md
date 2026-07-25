# PRD — psmm Rust UI layer (Ratatui/Crossterm)

| Field | Value |
|---|---|
| Document | PRD-psmm-rust-ui |
| Version | 0.2 (draft for review) |
| Status | Answered — see `docs/rust-ui-plan.md` |
| Date | 2026-07-25 |
| Changes in 0.2 | Added FR-0 screen layout, FR-10 module workspace, FR-11 in-app settings and theming, FR-12 in-app help; reworked FR-1/FR-2/FR-3 to sit inside the layout; added region/tab keys (§9.3) and frame mouse model (§10.2); §13 narrowed to Windows + Linux with a single Gallery verification requirement, signing removed from scope |
| Owner | PBNZ |
| Repo | https://github.com/PBNZ/psmm (MIT, prerelease on PowerShell Gallery) |
| Supersedes | The evolved planning prompt this document was distilled from |
| Related | `DECISIONS.md`, `ROADMAP.md`, `docs/config-schema.md`, `CHECKPOINT.md`, `RELEASE-CHECKLIST.md` |

> **Read `docs/rust-ui-plan.md` alongside this.** The planning session this
> document called for ran on 2026-07-25/26. It re-derived §8 and §9.1 from
> `src/` and **corrected several assumptions here** — most importantly: the
> `Mode`x`Install` matrix is implemented four times, not once (§8.7);
> `Enter` is already bound, so KB-7 is wrong; `^x` is already a second
> hard-quit; an exact pin does *not* neuter `Latest` (Q-3); and §15's
> strangler was replaced by a two-release cutover with no dual UI. Where this
> document and the plan disagree, the plan wins.

---

## 0. How to use this document

This PRD is the input to a **design and planning session**, not to an implementation
session. It defines *what must be true*; the planning session produces the architecture,
the ADRs, and the phased plan. **No production code is written until Phase 0 completes.**

Requirement IDs (`C-n`, `FR-n`, `NFR-n`, `KB-n`, `MS-n`, `Q-n`, `V-n`) are stable
references — use them in commits, ADRs and issues.

Three tiers of statement appear throughout:

- **MUST / MUST NOT** — non-negotiable. A design that breaks one is rejected.
- **SHOULD** — strong default; deviation needs a recorded reason.
- **OPEN (`Q-n`)** — a decision PBNZ owes the project. Listed in §17.

Sections marked **[unverified]** are drawn from `README.md` and `docs/config-schema.md`
rather than from source, and MUST be re-derived from `src/` in Phase 0.

---

## 1. Summary

psmm today is a pure-PowerShell module: a platform-neutral engine, a `$PROFILE` startup
loader, and a keyboard-driven interactive manager built on Spectre.Console via
PwshSpectreConsole (`DECISIONS.md` D-TUI, D-STRUCT, D-UI-ARCH).

This initiative **replaces the UI layer with a Rust binary** built on Ratatui 0.30 /
Crossterm 0.29 / Tokio, keeping the engine, config semantics and public API in PowerShell.
It simultaneously (a) ratifies the `Mode` × `Install` behavioural matrix as a written spec
and reconciles the implementation against it, (b) streamlines the keyboard model, (c) adds
full mouse parity in the Herdr mould, (d) establishes a persistent three-region layout —
loaded modules top-left, background tasks bottom-left, tabbed managed/unmanaged module pane
on the right (FR-0) — and (e) lands the feature requests around loaded-module visibility,
background work, unmanaged-module classification, per-module drill-in, in-app settings, help
and theming, config location, and session lifetime.

**Shipping targets are Windows and Linux**; macOS is future work (§13).

The rewrite is delivered **strangler-style**: psmm remains installable, working and
shippable to the Gallery at every step.

---

## 2. Background

### 2.1 Why now

- The UI is the largest body of code in the repo and the part that is hardest to test
  (`D-STRUCT`). Ratatui's `TestBackend` gives frame-level assertions natively, where the
  current design needed a bespoke `StringWriter`-backed `IAnsiConsole` (`D-UI-ARCH`).
- `ROADMAP.md` #34 (full non-Windows support) is blocked on key handling, scope detection
  and alternate-screen behaviour having only been exercised on Windows. Crossterm carries
  that burden as a maintained cross-platform dependency, so the rewrite *advances* #34
  rather than competing with it.
- Mouse support is wanted. `D-TUI` explicitly rejected Terminal.Gui in part for being
  "boxy, mouse-centric" — **that judgement is now reversed** and this PRD supersedes the
  mouse-related reasoning in D-TUI. A superseding ADR is required (§15, Phase 0).
- The UI dependency creates real complexity: `D-OWN-MODULES` exists solely because psmm
  imports PwshSpectreConsole into its own session state and must subtract it by instance
  from `Get-Module`. A Rust UI has **no PowerShell dependency at all**, so most of that
  machinery becomes deletable (§11.9).
- The `Mode` × `Install` semantics were designed but never written down as a normative
  matrix. Ambiguity there is a latent correctness bug and must be resolved *before* a
  rewrite bakes it in.

### 2.2 What stays true

psmm is a personal tool, human-designed and largely AI-written, shipped MIT for friends,
colleagues and anyone who wants it. It is Windows-first with a platform-neutral engine.
It requires PowerShell 7.0+ (`D4`). None of that changes.

---

## 3. Goals and non-goals

### 3.1 Goals

| # | Goal |
|---|---|
| G1 | Rebuild the interactive manager as a Rust TUI (Ratatui/Crossterm/Tokio) with no loss of existing capability |
| G2 | Keep all module loading in PowerShell, in the user's live global session scope |
| G3 | Ratify `Mode` × `Install` as a written spec and reconcile the code against it |
| G4 | Streamline the keyboard model against terminal-app convention without losing what works |
| G5 | Achieve full, bidirectional keyboard/mouse parity |
| G6 | Ship the six feature requests in §11 |
| G7 | Keep psmm shippable at every phase boundary |
| G8 | Reduce, not increase, the runtime dependency surface |

### 3.2 Non-goals

| # | Non-goal | Note |
|---|---|---|
| NG1 | Changing the config **schema** | `D-CONFIG` holds: existing `psmm-config.json` files work byte-for-byte unchanged. New fields, if any, are optional with defaults |
| NG2 | Changing the public API | `Invoke-PSMMStartup`, `Show-PSModuleManager`/`psmm`, `Get-PSMMConfigPath`, `$PSMM_*` knobs all preserved |
| NG3 | Rewriting the engine in Rust | The engine stays PowerShell. This is a UI-layer rewrite |
| NG4 | Roadmap items #31 (Edge profile auth), #39 (elevation), #40 (credential manager), #30 (deep Graph handling) | Out of scope; #39 becomes *easier* under the new boundary and should be revisited after |
| NG5 | Lockfile/export, lazy-load stubs, assembly-conflict advisor | `ROADMAP.md` §4 shelf items. §8.6 reserves design space for lazy-load stubs as a future `Mode` |
| NG6 | Remote-machine module management | Explicitly skipped in `ROADMAP.md`; still skipped |

---

## 4. Success criteria

| # | Criterion | Measure |
|---|---|---|
| S1 | Startup cost unchanged or better | Time from `pwsh` launch to typeable prompt, with a reference config, is ≤ current median. `Import-Module psmm` gets *cheaper* (no UI `.ps1` to dot-source) |
| S2 | `psmm` launch is near-instant | Time from typing `psmm` to interactive first frame < 150 ms warm, on a reference Windows machine |
| S3 | Scrollback preserved | Automated + manual check: terminal scrollback byte-identical before and after a UI session |
| S4 | Terminal restored exactly | Cursor position, style, mouse mode, alternate screen all restored — including after panic and after SIGKILL of the parent |
| S5 | Global-scope loading proven | A module loaded via the Rust UI is visible to `Get-Module` **at the user's prompt**, and its commands resolve there |
| S6 | Zero orphans | After closing the terminal, no `psmm-ui` process and no psmm background job survives. Verified by process enumeration in CI and manually |
| S7 | Parity | Every action reachable by keyboard *and* by mouse; verified by a checklist test, not by eyeball |
| S8 | Matrix conformance | Every one of the nine `Mode` × `Install` cells has a passing Pester test asserting the ratified behaviour |
| S9 | Shippable throughout | Each phase ends with a Gallery-publishable prerelease that passes CI |

---

## 5. Hard constraints (invariants)

| # | Constraint |
|---|---|
| C1 | **Module loading MUST happen in PowerShell, in the user's session, with `-Global`.** Per `D-IMPORT-SCOPE`, an `Import-Module` from inside a module without `-Global` lands in *psmm's* session state, is invisible at the prompt, and psmm's own `Get-Module` keeps reporting it loaded. The static AST guard test in `Tests/Engine.Load.Tests.ps1` MUST survive the rewrite unchanged |
| C2 | A separate Rust process **MUST NOT** attempt to import modules. It decides and drives; PowerShell executes |
| C3 | **Terminal scrollback MUST NOT be wiped.** The alternate screen buffer (`ESC[?1049h` / `ESC[?1049l`) remains the mechanism — Crossterm's `EnterAlternateScreen`/`LeaveAlternateScreen` |
| C4 | **The terminal MUST be restored exactly on exit** — including on panic, on error, and on abnormal parent death |
| C5 | **Fast startup is sacred.** Only the user's `Load` modules must be ready before the prompt is typeable. Everything else is background |
| C6 | **No background work outlives the terminal session.** Closing the shell or the window disposes psmm and all its jobs. Reopening gives a genuinely clean slate |
| C7 | Config schema compatibility (`D-CONFIG`, NG1) |
| C8 | Public API compatibility (NG2) |
| C9 | PowerShell 7.0 floor, `CompatiblePSEditions = Core` (`D4`) |
| C10 | The UI MUST remain fully usable with mouse reporting unavailable (SSH, restrictive terminals, mouse disabled). Mouse is additive, never required |
| C11 | Exactly one process writes to the terminal at a time. While the Rust UI owns the screen, the PowerShell side emits nothing to the host — all streams captured and returned as data |
| C12 | No credential, token or secret is ever rendered, logged or written to disk by psmm (relevant to FR-1 connection display) |

---

## 6. Baseline — current behaviour to preserve

Sourced from `README.md` and `docs/config-schema.md`. This is the regression contract.

### 6.1 Config discovery — five sources, in order

| # | Source | Notes |
|---|---|---|
| 1 | Inline JSON in `$PSMM_InlineJson` | Read-only in the UI |
| 2 | Main config `~/.psmm/psmm-config.json` | The only file whose `Includes` are honoured. Overridable via `$PSMM_MainConfigPath` |
| 3 | The main config's `Includes` | One level deep — an included file's own `Includes` are ignored, which is what makes circular references impossible. `~` and `%ENV%` expanded |
| 4 | Profile-directory config | `<dir of $PROFILE>/psmm-config.json`, overridable via `$PSMM_ProfileConfigPath` |
| 5 | Legacy globs `$PSMM_JsonPath` | Default `psmodules.d/*.json` next to `$PROFILE` |

No file is ever loaded twice even if reachable two ways. `Get-PSMMConfigPath` prints the
list with resolved paths and existence.

**Conflict rules:** main config always wins (with a warning naming the overridden file);
among non-main files, first-loaded wins (error-style warning); disabled files don't
participate but keep their entries.

### 6.2 File-level fields

`Enabled` (default `true`; `false` = parsed and shown but nothing actioned, entries
preserved on save), `Includes` (main config only), `_legend` (preserved verbatim),
`Modules` (required).

### 6.3 Module entry fields

`Name` (required), `FriendlyName`, `Description`, `Install` (default `IfMissing`),
`Mode` (default `Load`), `Version` (exact pin, exact prerelease pin, or NuGet range),
`Prerelease` (default `false`).

Behaviour worth restating because the rewrite must not lose it:

- Exact pins honoured on import (`-RequiredVersion`) and install; **pinned modules are
  never flagged "update available"**.
- A prerelease pin implies `-Prerelease` on install and imports by its **base** version,
  because `-RequiredVersion` is typed `[version]` and a prerelease shares its base-version
  folder.
- Ranges require PSResourceGet; on PowerShellGet-only machines a range falls back to
  latest with a warning.
- Prerelease labels live in `PrivateData.PSData.Prerelease`, not in `[version]`. psmm
  carries the label alongside every version it reads and shows it everywhere a version
  appears. Ordering follows SemVer.
- A module whose *installed* copy is already a prerelease keeps being updated along the
  prerelease track regardless of the flag; a label-only bump is invisible to
  `Update-PSResource` and only `Install-PSResource -Prerelease -Reinstall` moves it.
- Invalid `Install`/`Mode`/`Version` values never break a file: the entry degrades to the
  default with an issue flag (`!` column).
- UI saves write only known fields; `_legend` and file-level `Enabled`/`Includes` always
  preserved; round-trips are byte-stable.

### 6.4 Interactive manager — existing capability

One grid row per module: state (`●` loaded / `◐` installed / `○` missing / `◌` unmanaged),
startup action, upkeep, version (`⇡` = update available), scope, source file, plus a
plain-words context sentence for the row under the cursor.

Capabilities: load/unload, install/update, update checks, gallery search (word matches
names/descriptions/tags in relevance order; pattern like `Az.*` matches names across every
registered repository) with add-to-config, version pinning from a list of what exists,
prerelease opt-in, stacked-version cleanup, command browsing with full help, config file
management and creation from scenario templates, module-location management, three themes
(`glacier` default, `ember`, `moss`) via `$PSMM_Theme`, background tasks with a
non-blocking progress line, conflicts view, first-launch quick-tips panel.

Module-location screen specifics: shows `$env:PSModulePath`; warns when the CurrentUser
module folder is inside OneDrive; downloads cloud-only module files in parallel
(`D-PARALLEL`: `ForEach-Object -Parallel`, capped at logical processor count, floor 2,
ceiling 16, with the cap *and its reason* shown) or pins them local; adds a new location;
moves a location's contents behind a typed confirmation; moves the primary location via the
documented `powershell.config.json` override.

Self-management: a background update check runs at most once a day, never delaying the
prompt, cached and shown at the next profile load and in the UI; psmm's update path knows
about the prerelease-reinstall quirk; `$PSMM_UpdateCheck = $false` disables it.

`D-OWN-MODULES`: psmm and its UI dependency render as `◈ psmm's own`, are excluded from the
"N loaded" count and the unmanaged scan, are never unloaded, but remain visible, installable
and updatable. Subtraction is **by instance, not by name**.

> **Already present, contrary to a common reading of the feature list:** connection status
> for `Connect-*` modules, and a background-tasks screen (`g t`). FR-1 and FR-2 below are
> *evolutions* of shipped behaviour, not greenfield.

### 6.5 Source layout and test posture

`src/Engine` (platform-neutral, parsed at import), `src/Public` (exported commands, parsed
at import), `src/UI` (dot-sourced on first `psmm` call so `Import-Module psmm` stays fast).
One function per file. Tests: `Invoke-Pester -Path Tests`, `Invoke-ScriptAnalyzer -Path .
-Recurse -Settings ./PSScriptAnalyzerSettings.psd1`. CI (`D6`): lint + full Pester on
`windows-latest`; engine-only Pester on `ubuntu-latest` via tag filter.

`D-RENDER`: code/commands, links, prose and versions render only via the primitives in
`src/UI/04-Render.ps1`; no colour literal outside the theme sources; guard tests enforce
both.

---

## 7. Target architecture

### 7.1 The problem, stated precisely

Module state lives in the **process memory of the user's PowerShell session**. A Rust
process cannot mutate it. Per `D-IMPORT-SCOPE`, even PowerShell code running *inside the
psmm module* cannot mutate it correctly without `-Global`, and there is no supported way to
enumerate the global module table from inside a module.

Therefore: **the Rust process is a view and a controller; PowerShell is the only actuator.**
Every design below is a variation on how the controller talks to the actuator.

### 7.2 Options to evaluate

| Option | Shape | Verdict to test |
|---|---|---|
| **A — One-shot plan** | `psmm` shim runs the binary; binary prints a PowerShell script or a JSON plan on exit; shim executes it in the caller's scope | Simplest, no IPC, no concurrency. But one UI session = one batch of actions; no live feedback; no "load, look, load again". `Invoke-Expression` is a PSScriptAnalyzer smell. **Likely insufficient for an interactive manager** |
| **B — Long-lived child, PowerShell message pump (RECOMMENDED)** | Shim spawns `psmm-ui` and then *blocks* in a read loop. Child sends NDJSON requests over its stdin/stdout pipes; the shim executes each in the session and replies. Child renders to the console device directly, not to stdout | The session is idle and blocked while the UI runs, so mutating it is safe. Full interactivity. `-Global` semantics unchanged. Requires care on terminal ownership (C11) and on separating the protocol channel from the render channel |
| **C — Named pipe / loopback socket** | As B, but the transport is a named pipe (`\\.\pipe\psmm-<pid>-<nonce>`) or loopback TCP instead of stdio | Frees stdout entirely, and matches Herdr's server/client socket model. Costs: pipe naming, ACLs, port/permission handling, an extra failure mode. **Keep as fallback if stdio proves awkward** |
| **D — Rust as a native library in-process** | Compile Rust as a `cdylib`, load into `pwsh` via P/Invoke, UI runs on a thread in the same process | Perfect scope semantics — same process. But FFI marshalling, thread-affinity of the PowerShell runspace, contention with the .NET console host over the terminal, per-RID native loading, and **a Rust panic takes down the user's shell**. High risk for the benefit |
| **E — Rust hosts PowerShell** | Embed the PowerShell SDK in the Rust process | **Rejected outright.** A hosted runspace is a *different session*. It does not solve the problem it appears to solve; it disguises it |

### 7.3 Evaluation criteria for the ADR

Score A–D against: correctness of global-scope loading (C1); interactivity; terminal
ownership risk (C3, C4, C11); teardown guarantees (C6); crash blast radius; cross-platform
cost (`ROADMAP.md` #34); testability; implementation and maintenance cost for a solo
project; and the elevation path (`ROADMAP.md` #39 — an elevated helper is a second actuator,
which option B accommodates naturally and option D does not).

### 7.4 Preliminary lean — option B

Recorded as a *lean*, not a decision. Phase 0 confirms or overturns it.

**Process model**

```
pwsh (user session)                       psmm-ui (Rust child)
├─ psmm module (PowerShell)               ├─ Ratatui render loop  ──> CONOUT$ / /dev/tty
│   ├─ engine                             ├─ Crossterm input      <── the same device
│   ├─ host/pump  <── NDJSON over ────>   ├─ Tokio: input, timers, protocol I/O
│   └─ ThreadJobs (all background work)   └─ owns NO durable state
└─ owns ALL module + job state
```

**Key properties**

- The shim blocks; the session is quiescent; mutation is safe.
- **All background jobs live in PowerShell** (`Start-ThreadJob`, per `D4`). The Rust process
  never owns work. This falls straight out of C6: jobs die with the session because they
  *are* the session, and a UI exit does not disturb them (FR-6).
- The Rust binary is **disposable**. Kill it and re-run `psmm` and you lose nothing but
  cursor position. This is also the answer to the state-persistence question (§11.7).
- `-Global` is unaffected: the pump calls the same engine functions, and the AST guard test
  keeps guarding the same PowerShell source (C1).

**Terminal ownership (the sharp edge)**

Because stdout is the protocol channel, the TUI MUST render to the console device
explicitly — `CONOUT$` on Windows, `/dev/tty` on Unix — rather than to the inherited stdout
handle. Crossterm executes against any `Write`, so this is a construction detail, but it is
load-bearing and must be proven in Phase 1.

The PowerShell side MUST NOT write to the host while the UI is up (C11): every stream is
captured and returned as structured data for the UI to render.

**Protocol sketch (`psmm-proto v0`)**

- NDJSON, one object per line, UTF-8, no BOM.
- Request/response correlated by `id`; plus unsolicited `event` frames PowerShell → Rust
  for job progress, completion and failure.
- Version handshake on connect; refuse to start on a major mismatch with a clear message.
- Every request carries a timeout; every long operation is a job handle, never a blocking call.
- Cancellation is a first-class message, not a disconnect.
- The protocol is a **published contract with conformance tests runnable from both sides**
  (§14).

**Teardown (C6) — belt and braces**

| Layer | Mechanism |
|---|---|
| Graceful shell exit | `Register-EngineEvent -SourceIdentifier PowerShell.Exiting` — dispose jobs, signal the child |
| Terminal window killed | `PowerShell.Exiting` does **not** fire. Windows: assign the child to a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Unix: `prctl(PR_SET_PDEATHSIG)` and/or process group |
| Child orphaned anyway | Child watchdogs the parent PID and self-terminates |
| Child dies unexpectedly | Shim detects EOF on the pipe, restores the terminal itself, returns to the prompt cleanly |

The Job Object / `PDEATHSIG` layer is what actually delivers C6. `PowerShell.Exiting` alone
is insufficient and must not be relied on.

### 7.5 Language boundary

| Stays PowerShell | Moves to Rust |
|---|---|
| Config discovery, parsing, merge, conflict resolution, save/round-trip | All rendering |
| `Mode`/`Install` policy evaluation | All input handling (keyboard + mouse) |
| All `Import-Module` / `Remove-Module` / install / update / cleanup | Layout, hit-testing, scroll, focus |
| Gallery search and version queries | Theming and palette |
| Scope and path detection, OneDrive/hydration logic | View state (cursor, filter, expansion, selection) |
| All background jobs | Nothing durable, nothing privileged |
| `Update-Help` | — |
| Public API surface | — |

**Rule of thumb:** if it touches the module store, the session, the filesystem or the
network, it is PowerShell. If it draws or reads input, it is Rust.

---

## 8. Behavioural spec — `Mode` × `Install`

This section is **normative**. The rewrite must satisfy it; the current implementation must
be audited against it (§8.7). Treat disagreement between this spec and the code as a bug in
one of them, identified explicitly, not silently reconciled.

### 8.1 Documented starting point

From `docs/config-schema.md`:

- **`Install`** — disk/gallery policy. `CheckOnly` (never install, only report), `IfMissing`
  (install when absent), `Latest` (check the gallery and update at startup). Default
  `IfMissing`.
- **`Mode`** — session policy. `Load` (import into the session at startup, **foreground**),
  `InstallOnly` (disk/gallery work only, **deferred to a background job**), `Ignore`
  (parsed, visible in the UI, not actioned). Default `Load`.
- Declared **orthogonal**, with two worked examples: `CheckOnly`+`Load` imports
  synchronously but never installs; `Latest`+`InstallOnly` updates in the background
  without ever importing.

### 8.2 The structural finding

**`Mode` is not one axis. It is two.** It bundles *session policy* (import or not) with
*scheduling policy* (foreground or background). That is why `Load` + `Latest` is
problematic: `Load` says "foreground", `Latest` says "hit the gallery", and the product is
a **network round trip in the foreground on every shell start** — a direct violation of C5
and FR-6.

Two candidate resolutions, both needing a ruling (`Q-1`):

- **8.2a — Hard rule (preferred, no schema change).** *Gallery I/O is never foreground.*
  `Mode` keeps its two meanings, but scheduling is derived: import is foreground, all
  disk/gallery work is background, always. `Latest` + `Load` therefore imports what is on
  disk now and updates behind the prompt.
- **8.2b — Split the axis (schema change).** Add an optional third field, e.g.
  `"Defer": "Auto" | "Foreground" | "Background"`, default `Auto` reproducing today's
  behaviour. Honest and explicit, but adds a field — weigh against `D-CONFIG` and NG1.

The remainder of §8 is written assuming **8.2a**.

### 8.3 Precedence

Normative order, highest first:

1. File-level `"Enabled": false` — nothing in the file is actioned, entries still parsed and shown.
2. Conflict resolution — main config wins; among non-main files, first-loaded wins.
3. `Mode` — `Ignore` dominates everything below it.
4. `Version` pin — an exact pin caps what `Install` may do.
5. `Install`.
6. `Prerelease` — modifies which versions are eligible at every step above.

### 8.4 Term definitions (normative)

| Term | Definition |
|---|---|
| **Present** | At least one version of the module is discoverable on `$env:PSModulePath` |
| **Eligible version** | The newest gallery version satisfying the `Version` pin/range and the `Prerelease` flag |
| **Import** | `Import-Module -Global`, with `-RequiredVersion` when an exact pin applies (base version for a prerelease pin) |
| **Install** | Acquire from a registered repository onto disk. Never implies import |
| **Update** | Install a newer eligible version alongside/over the current one. Never implies import; **never hot-swaps an already-loaded module** |
| **Check** | Query the repository for the eligible version and compare. Read-only. Suppressed entirely for exact-pinned modules |
| **Report** | Surface in the startup report, the grid row, and (for background work) the activity panel |

### 8.5 The nine cells

Each cell states: startup behaviour, interactive behaviour, and verdict.

---

#### 1. `Load` + `CheckOnly`

- **Startup.** No install, ever. If present → import (foreground). If absent → do not
  install; report `missing — not loaded` as a warning, not an error. Update check runs in
  the background and is report-only.
- **Interactive.** Row shows `●`/`○`. `i` (install) remains available as an explicit user
  override — the policy governs *automatic* behaviour, not the user's hands (see `Q-4`).
- **Verdict.** Valid and coherent. The "installs are managed elsewhere — Intune, packaging,
  a golden image — just load it" case.

#### 2. `Load` + `IfMissing` *(the default pair)*

- **Startup.** If present → import (foreground), as-is, never upgraded. If absent →
  install the eligible version, **in the background**, then import *when it lands*; if it
  lands after the prompt is live, report `installed — available next session` rather than
  importing behind the user's back mid-session (`Q-2`). Update check background, report-only.
- **Interactive.** Standard.
- **Verdict.** Valid; the sane default. The hazard is entirely in the first-run install
  path — a cold `Az` or `Microsoft.Graph` install is minutes, and must never be foreground.

#### 3. `Load` + `Latest`

- **Startup.** Import the best on-disk eligible version immediately (foreground). In the
  background: check, and update if a newer eligible version exists. **The update does not
  affect the running session** — report `updated to X — restart to use it` in the activity
  panel. If the module was absent entirely, behave as cell 2 then update.
- **Interactive.** Same, plus explicit `u`.
- **Verdict.** Valid but the highest-risk cell, and the one most likely to differ from the
  current implementation, since `docs/config-schema.md` says `Latest` "updates at startup"
  and `Mode: Load` says "foreground". **This is the primary discrepancy to hunt (`V-3`).**
- **Pin interaction (`Q-3`).** An exact pin means "never flagged update available" per the
  docs, so `Latest` is neutered — it should degrade to `IfMissing`. A *range* pin should
  make `Latest` mean "newest within the range". Both need confirming in code.

#### 4. `InstallOnly` + `CheckOnly`

- **Startup.** Nothing installed. Nothing imported. Presence and update availability
  reported (background).
- **Interactive.** Row is informational; explicit actions still available.
- **Verdict.** Valid but **inert** — the entry's entire effect is reporting. Not
  nonsensical (a deliberate watch-list is a real want) but highly likely to be chosen by
  mistake. The UI MUST state it plainly in the row's context sentence: *"watch only — psmm
  will never install or load this."*

#### 5. `InstallOnly` + `IfMissing`

- **Startup.** Install if absent, in the background. Never import.
- **Verdict.** Valid, coherent, common. "Have it on disk for when I reach for it."

#### 6. `InstallOnly` + `Latest`

- **Startup.** Keep the newest eligible version on disk, in the background. Never import.
- **Verdict.** Valid and the cleanest cell in the matrix — no hot-swap hazard exists because
  nothing is loaded. This is the cell the docs already use as the worked example.

#### 7–9. `Ignore` + `CheckOnly` / `IfMissing` / `Latest`

- **Startup.** Nothing. No install, no import, **and no gallery I/O of any kind** — `Ignore`
  must be the genuinely zero-cost mode (`Q-5` confirms whether the current code also
  suppresses the *check*).
- **Interactive.** Entry parsed and visible, marked as ignored. Explicit user actions still
  available.
- **Verdict.** `Install` is **inert** in all three. `Mode` dominates (§8.3).
  Requirements:
  - The value MUST be **preserved on save**, not normalised away — a user who sets `Ignore`
    temporarily expects their `Latest` back when they flip it.
  - The UI MUST lint it on the `!` column: *"Install policy has no effect while Mode is
    Ignore."* Not an error; a notice.

---

### 8.6 Reserved

`ROADMAP.md` §4 floats **lazy-load stubs** as a third `Mode` — proxy stubs that import the
real module on first command use. If that ever ships it becomes a fourth row of this matrix
and the design must not foreclose it. No work now; just do not paint the matrix into a
corner.

### 8.7 Verification tasks (Phase 0, against `src/`)

| # | Task |
|---|---|
| V1 | Extract the actual decision logic from `src/Engine` and tabulate all nine cells as **implemented** |
| V2 | Diff implemented against §8.5; produce a numbered discrepancy list with a fix-or-amend-spec ruling on each |
| V3 | **Priority:** determine whether `Load` + `Latest` performs a foreground gallery round trip at startup, and measure its cost on a cold cache |
| V4 | Determine whether an already-loaded module is ever removed and re-imported to apply an update, and whether that can strand a user mid-session |
| V5 | Confirm exact-pin behaviour under `Latest` (neutered?) and range-pin behaviour (newest-in-range?) |
| V6 | Confirm whether `Ignore` suppresses the update *check*, not merely install/import |
| V7 | Confirm `Enabled: false` × `Mode` precedence, and retest the `D-OWN-MODULES` failure class where `files > apply` targeted psmm's own engine because `$managed` included disabled-file entries |
| V8 | Confirm invalid-value degradation still flags `!` for every field, including combinations |
| V9 | Write one Pester test per cell (S8), each asserting install/import/check/report independently |

---

## 9. Keyboard model

### 9.1 Current bindings **[unverified — from `README.md`]**

| Scope | Key | Action |
|---|---|---|
| Global | `left` / `right` | Back out / open — *the same pair on every screen* |
| Global | `/` | Filter |
| Global | `?` | Tabbed help |
| Global | `^q` | Quit |
| Global | `g` | Goto layer |
| Goto | `g h` · `g g` · `g f` · `g p` · `g t` · `g c` · `g x` | home · gallery search · config files · module locations · background tasks · conflicts · version cleanup |
| Grid | `space` | Select |
| Grid | `^l` / `^u` | Load / unload |
| Grid | `i` · `u` · `k` | Install · update · check for updates |
| Grid | `m` | Show/hide installed-but-unmanaged |
| Module menu | `w` | Allow prereleases |
| Module menu | `p` | Move its folder to another module location |
| Files | `n` | New config file |
| Locations | `n` · `m` | Add location · move a location's contents |

Phase 0 MUST re-derive this table from `src/UI` — the README is a summary, not a spec.

### 9.2 Audit findings

| # | Finding | Severity |
|---|---|---|
| KB-1 | **`k` = check-for-updates collides with vim `k` = up.** This single binding blocks vim-style navigation from existing at all | High |
| KB-2 | **`g g` = gallery collides with vim `gg` = go to top.** The goto layer is otherwise a genuinely good idea worth keeping | High |
| KB-3 | **`^l` / `^u` for load/unload.** `Ctrl+L` is universally redraw/clear-screen; `Ctrl+U` is readline kill-line. Ctrl is doing work single letters should do, and `u` (update) sits one modifier away from `^u` (unload) — two different verbs, one destructive-ish, on the same letter | High |
| KB-4 | **`^q` is unreliable off-Windows.** On Unix ttys with `IXON` software flow control, `Ctrl+Q` is the XON resume character and never reaches the application. Fine in Windows Terminal today; a live hazard for `ROADMAP.md` #34 | Medium |
| KB-5 | **`m` is overloaded** — unmanaged toggle on the grid, move-contents on the locations screen. Context-dependent overloading is defensible, but not when one of the two is destructive | Medium |
| KB-6 | **`p` is miscast.** It means move-folder in the module menu while `g p` means module locations — and `p` is the natural mnemonic for *pin*, a far more frequent action | Medium |
| KB-7 | **No `Enter`.** `right` opens, which is consistent, but `Enter` is the universal expectation and is currently unbound | Low |
| KB-8 | **No coarse motion** — no half-page, no top/bottom, no next/prev-match after `/` | Medium |
| KB-9 | **Theme is `$PSMM_Theme` only.** A capability reachable only by editing `$PROFILE` cannot satisfy the mouse-parity rule (§10) | Medium |
| KB-10 | Terminal facts the new scheme MUST respect: `Ctrl+M` ≡ `Enter`, `Ctrl+I` ≡ `Tab`, `Ctrl+[` ≡ `Esc`. None of those three may be assigned an independent meaning | Info |

### 9.3 Proposed scheme — before/after

**Motion (new)**

| Key | Action |
|---|---|
| `j` / `k` / `↓` / `↑` | Row down / up |
| `Ctrl+d` / `Ctrl+u` | Half page down / up |
| `PgDn` / `PgUp` | Full page |
| `g g` | Top |
| `G` | Bottom |
| `Home` / `End` | Top / bottom |
| `Tab` / `Shift+Tab` | Cycle focus between panes |

**Navigation — unchanged where it works**

| Before | After | Note |
|---|---|---|
| `right` open | `l` / `→` / `Enter` open | Keeps the existing constant, adds the two universal expectations (KB-7) |
| `left` back | `h` / `←` / `Esc` back | Same |
| `g` layer | `g` layer | Kept — it works |

**Goto layer**

| Before | After | Why |
|---|---|---|
| `g g` gallery | **`g s`** gallery search | Frees `g g` for vim top (KB-2); `s` = search is the better mnemonic anyway |
| `g h` home | `g h` home | Unchanged |
| `g f` files | `g f` files | Unchanged |
| `g p` locations | `g p` paths/locations | Unchanged |
| `g t` tasks | `g t` tasks → **activity panel** (FR-2) | Same key, richer target |
| `g c` conflicts | `g c` conflicts | Unchanged |
| `g x` cleanup | `g x` cleanup | Unchanged |
| — | **`g ,`** settings | New: theme, mouse capture, layout, config path (KB-9, FR-11) |

**Regions and tabs (new — the FR-0 frame)**

The `g` layer addresses *destinations*; these address the *frame*. Both must exist: the goto
layer is faster once learnt, the tab bar is discoverable on sight.

| Key | Action |
|---|---|
| `Tab` / `Shift+Tab` | Cycle focus between regions — loaded rail, tasks panel, right pane (FR-0.9) |
| `]` / `[` | Next / previous tab in the right pane (FR-0.6) |
| `1` … `9` | Jump directly to the *n*th tab |
| `z` | Collapse/expand the focused region (FR-0.8) |
| `=` | Reset layout proportions to default (FR-0.7) |

> `1`…`9` are unbound today. Phase 0 MUST confirm they are still free once §9.1 is
> re-derived from source, and MUST confirm `[` / `]` do not collide with anything in the
> filter or palette layers.

**Row actions**

| Before | After | Why |
|---|---|---|
| `^l` load | **`L`** | Frees `l` for motion; uppercase pairs symmetrically with `U` (KB-3) |
| `^u` unload | **`U`** | Same |
| `k` check | **`c`** | `c` = check; frees `k` for motion (KB-1). No clash: `g c` is a different layer |
| `i` install | `i` install | Unchanged |
| `u` update | `u` update | Unchanged, and no longer shadowed by `^u` |
| `p` move folder | **`M`** move | Uppercase for destructive; aligns with the locations screen (KB-5, KB-6) |
| — | **`p`** pin version | Reclaimed for its natural mnemonic (KB-6) |
| `w` prerelease | `w` prerelease | Kept — established. Flag: non-mnemonic, and the only surviving arbitrary letter |
| `m` unmanaged toggle | `m` collapse/expand the unmanaged half | Same key, changed meaning: under FR-0.4 the unmanaged half is always present, so there is nothing to toggle *into view* — `m` now collapses and expands it |
| `space` select | `space` select | Unchanged |
| — | `x` cleanup this row | Mirrors `g x` at row scope |
| — | `b` browse commands | Was menu-only |

**Global**

| Before | After | Why |
|---|---|---|
| `/` filter | `/` filter, **`n`/`N`** next/prev match, `Esc` clear | KB-8 |
| `?` help | `?` help | Unchanged |
| `^q` quit | `^q` quit, **plus `Q` and `Ctrl+c`** | Guaranteed-deliverable fallbacks for `IXON` terminals (KB-4) |
| — | **`:`** command palette | New. Fuzzy-searchable list of every action with its binding. Solves discoverability, and is the keyboard twin of the mouse context menu (§10) — together they make bidirectional parity tractable instead of requiring a bespoke affordance per verb |
| — | `q` back one level / close overlay | Distinct from `^q` quit |

**Non-standard, retained deliberately:** `w` for prerelease; `m` for the unmanaged toggle.
Both are established and neither collides. Document them as such rather than pretending
they're conventional.

### 9.4 Requirements

| # | Requirement |
|---|---|
| KB-R1 | Bindings MUST live in a single declarative keymap structure, not scattered across handlers — the Rust analogue of the `D-RENDER` single-source discipline |
| KB-R2 | A guard test MUST fail the build on a duplicate binding within a scope |
| KB-R3 | The help screen (`?`) and the command palette (`:`) MUST be generated from the keymap, never hand-maintained |
| KB-R4 | Every action MUST have a keyboard route (C10) |
| KB-R5 | User-remappable bindings are **out of scope** for this rewrite; the keymap structure should not preclude them later |

---

## 10. Mouse model

Herdr's stated posture is that keyboard and mouse are **both first-class** — its own docs
describe it as a mouse-first TUI with tmux-style prefix keys alongside click, drag and split,
and its UI computes layout geometry and hit-test areas in a first pass before rendering in a
second. That two-pass `compute_view` → `render` split is the pattern to adopt: it is what
makes precise hit-testing possible without smearing geometry through the render code.

### 10.1 Invariants

| # | Invariant |
|---|---|
| MS-1 | **No action is keyboard-only.** Every verb is reachable with the mouse |
| MS-2 | **No action is mouse-only.** Parity is bidirectional (C10) — SSH, tmux without mouse mode, and restrictive terminals must remain fully capable |
| MS-3 | **Mouse capture steals the terminal's own text selection.** Once psmm requests mouse tracking, click-drag selects nothing and copy stops working. This MUST be disclosed in the help screen, MUST be toggleable (`g ,` settings, plus a direct binding), and the documented `Shift+drag` escape hatch MUST be surfaced in the UI, not just in the README |
| MS-4 | Hover requires any-motion tracking (mode 1003), which is chatty. Motion events MUST be coalesced/throttled; hover must never drive a full re-render per event |
| MS-5 | Mouse capture MUST be disabled on exit as part of terminal restoration (C4) |
| MS-6 | Every hit target MUST have a visible hover state. An invisible clickable region is a bug |
| MS-7 | Right-click anywhere on a row opens a **context menu containing every action valid for that row**. This is the mechanism that makes MS-1 achievable without a bespoke affordance for every verb |

### 10.2 Per-screen model

**Frame (FR-0) — present on every screen**

| Interaction | Behaviour |
|---|---|
| Click any region | Focus it (FR-0.9) |
| Click a tab | Switch the right pane to it (FR-0.6) |
| Drag the vertical divider | Resize left rail vs right pane (FR-0.7) |
| Drag a horizontal split | Resize loaded vs tasks, or managed vs unmanaged |
| Double-click a divider | Reset that split to default |
| Click a region header | Collapse/expand (FR-0.8) |
| Scroll within a region | Scrolls that region only, never the frame |

**Module grid (right pane, both halves)**

| Interaction | Behaviour |
|---|---|
| Hover row | Highlight; context sentence updates |
| Left click row | Move cursor to it |
| Double click row | Open detail (= `Enter`) |
| Left click state glyph (`●`/`◐`/`○`) | Toggle load/unload |
| Left click version cell | Open the version picker (pin) |
| Left click `⇡` update marker | Start the update as a job |
| Left click file cell | Jump to that file in the files screen |
| Left click checkbox column | Toggle selection |
| Shift+click | Range select |
| Right click | Context menu (MS-7) |
| Scroll wheel | Scroll rows |
| Click column header | Sort by that column; click again reverses |
| Drag column divider | Resize column |
| Click section header (`Managed`, `Yours`, `System`) | Collapse/expand (FR-3) |
| Drag scrollbar thumb | Scroll |

**Module workspace (FR-10)**

Double-click a row or choose **Open** from the context menu to enter; click the breadcrumb or
the close control to leave. Click a tab within the workspace to move between overview,
commands, config entry and history; click a command to view its help; click a `Mode` or
`Install` value to change it, with the target config file named before the write (FR-10.4).

**Settings (FR-11)**

Click the settings tab or any setting row; toggles flip on click; theme selection previews on
hover and applies on click; the preferences file path is a click target that reveals it.

**Gallery search**

Click the search field to focus; click a result to select; double-click to open details;
click **Add to config** to add; click a repository chip to filter by repository; scroll to
page results; hover shows the full description.

**Config files**

Click a file to select; double-click to open; click the `Enabled` toggle to park/unpark the
file; click **New** for the scenario-template creator; **drag to reorder** where order is
meaningful (`Includes` order drives conflict resolution — §6.1); right-click for the file
menu.

**Module locations**

Click a location to select; click the OneDrive warning badge to open the explanation; click
**Hydrate** to start parallel download (respecting the `D-PARALLEL` cap and showing its
reason); drag to reorder where `$env:PSModulePath` order is user-controlled; destructive
moves keep the typed confirmation regardless of input device.

**Activity panel (FR-2)**

Click a job to expand its full output; click the status dot to re-run or dismiss; scroll
within the panel independently; drag the panel's top border to resize; click the header to
collapse.

**Help / command palette**

Click a tab; click any listed action to execute it directly; scroll; click outside to
dismiss.

### 10.3 Requirements

| # | Requirement |
|---|---|
| MS-R1 | Hit regions MUST be produced by the layout pass and stored as data, never recomputed ad hoc in event handlers |
| MS-R2 | A parity checklist test MUST enumerate every action and assert both a keyboard route and a mouse route exist |
| MS-R3 | Mouse capture state MUST be persisted as a *preference* (§11.7), so a user who turns it off stays off |
| MS-R4 | `ratatui-interact` (focus management and mouse support for Ratatui 0.30 / Crossterm 0.29) SHOULD be evaluated in Phase 0 before hand-rolling hit-testing |

---

## 11. Feature requirements

### FR-0 — Screen layout

The frame every other requirement sits inside. This is a **fixed three-region shell**, not a
stack of full-screen views: the left rail is always present, so loaded state and background
work are permanently visible while the user works in the right pane.

```
┌────────────────────┬──────────────────────────────────────────────────────┐
│                    │  Modules │ Config files │ Locations │ Settings │ …   │
│  LOADED / ACTIVE   ├──────────────────────────────────────────────────────┤
│  (FR-1)            │                                                      │
│                    │   MANAGED — covered by the config (top half)         │
│                    │                                                      │
├────────────────────┤──────────────────────────────────────────────────────┤
│                    │                                                      │
│  BACKGROUND TASKS  │   UNMANAGED — everything else (bottom half)          │
│  (FR-2)            │   split Yours / System (FR-3)                        │
│                    │                                                      │
└────────────────────┴──────────────────────────────────────────────────────┘
```

| # | Requirement |
|---|---|
| FR-0.1 | **Top-left: loaded/active modules** (FR-1). Always visible, not a view the user navigates to |
| FR-0.2 | **Bottom-left: background tasks** (FR-2). Same — permanently on screen |
| FR-0.3 | **Right pane, top half: managed modules** — everything covered by the config file(s) |
| FR-0.4 | **Right pane, bottom half: unmanaged modules** — everything else, split Yours / System per FR-3 |
| FR-0.5 | The right pane is **tabbed**. The modules view is the first tab; further tabs hold everything that is *not* per-module — config file management, module locations, conflicts, cleanup, gallery search, settings, help |
| FR-0.6 | Tabs MUST be reachable by mouse (click) and by keyboard (the `g` goto layer, plus `Tab`/`Shift+Tab` within the pane) — the tab bar is an affordance for the same destinations the goto layer already addresses, not a second, competing navigation model |
| FR-0.7 | Region proportions MUST be adjustable — drag the vertical divider, drag the horizontal split in either column — and the chosen proportions persist as a **preference** (FR-8) |
| FR-0.8 | Either half of a column MUST be collapsible, and the layout MUST degrade sanely on a narrow or short terminal: below a stated width the left rail collapses to a summary strip rather than squeezing both panes into unreadability. The minimum supported terminal size MUST be stated and tested |
| FR-0.9 | Focus MUST be explicit and visible at all times — exactly one region has focus, and which one is unambiguous. `Tab` / `Shift+Tab` cycles regions; clicking a region focuses it |
| FR-0.10 | The layout MUST be produced by the single layout pass (MS-R1) so hit regions, resize handles and focus targets all derive from one geometry source |

### FR-1 — Loaded/active modules (top-left rail)

| # | Requirement |
|---|---|
| FR-1.1 | The loaded/active list occupies the **top-left region** (FR-0.1) and is visible regardless of which tab the right pane is showing. It is the answer to "what is actually in my session right now", so it never scrolls out of reach |
| FR-1.2 | The region MUST be collapsible, by key and by click, and its rows MUST be selectable and actionable in place — a row here supports the same verbs as the same module's row in the right pane |
| FR-1.3 | Selecting a loaded module MUST be able to **reveal it** in the right pane (jump to its row, or open its detail view per FR-10) — the two views of the same module stay connected |
| FR-1.4 | Connection state for `Connect-*` modules MUST be shown in the loaded section — **and the identity used**: UPN/account, tenant, environment, cloud, as available |
| FR-1.5 | Detection MUST be a **pluggable provider table**, not hard-coded branches: e.g. `ExchangeOnlineManagement` → `Get-ConnectionInformation`, `Microsoft.Graph.Authentication` → `Get-MgContext`, `PnP.PowerShell` → `Get-PnPConnection`, `Az.Accounts` → `Get-AzContext`, `MicrosoftTeams`. Unknown connect-style modules degrade to "connected state unknown", never to a wrong answer |
| FR-1.6 | Detection MUST be background, budgeted and cached. It MUST NOT delay the first frame, and a slow or hung provider MUST NOT block the UI |
| FR-1.7 | **No credential, token, refresh token or secret is ever displayed, logged or persisted** (C12). Account identifier and tenant only |
| FR-1.8 | `D-OWN-MODULES` holds: psmm and any infrastructure module render as `◈ psmm's own` and are excluded from the "N loaded" count |

> Connection status already exists in some form. Phase 0 audits what is there before
> designing what to add.

### FR-2 — Activity panel

| # | Requirement |
|---|---|
| FR-2.1 | A persistent activity panel occupying the **bottom-left region** (FR-0.2), listing every background job. Persistent means always on screen, not a view to navigate to |
| FR-2.2 | Status colour: green success, red failed, yellow warning, plus running and queued states |
| FR-2.3 | Clicking (or `Enter` on) a job reveals its **full captured output** — all streams |
| FR-2.4 | The UI MUST NOT block on any job. Ever |
| FR-2.5 | Jobs MUST survive UI exit and continue in the session (FR-6), and MUST NOT survive session exit (C6) |
| FR-2.6 | Every non-interactive background operation appears here — install, update, update-check, `Update-Help`, cloud-file hydration, cleanup, psmm's own self-update check |
| FR-2.7 | Completed jobs remain visible for the session with a timestamp and duration; dismissible individually and in bulk |
| FR-2.8 | Job output capture MUST be bounded (ring buffer with a stated cap) so a runaway job cannot exhaust memory |
| FR-2.9 | The panel MUST be collapsible and resizable; when collapsed it shows a one-line summary (the existing unobtrusive progress line, evolved) |

### FR-3 — User vs system split in the unmanaged view

| # | Requirement |
|---|---|
| FR-3.1 | The unmanaged half of the right pane (FR-0.4) MUST split into **Yours** and **System**, defaulting to Yours expanded and System collapsed. `m` no longer toggles unmanaged into view — the half is always present — but MUST be retained as the collapse/expand key for it |
| FR-3.2 | Classification signals, in confidence order: (a) **`PSGetModuleInfo.xml` present in the version folder** — installed from a repository via PowerShellGet/PSResourceGet, the strongest "this is yours" signal; (b) **path root** — `$PSHOME/Modules` = ships with PowerShell, `%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules` = ships with Windows, `Program Files\...\Modules` = AllUsers/admin scope, `~\Documents\PowerShell\Modules` = CurrentUser; (c) **publisher/signature** — Microsoft-signed and in a system path |
| FR-3.3 | Classification MUST be visible and explainable — the row states *why* it landed where it did |
| FR-3.4 | Classification MUST be overridable per module, and the override persisted |
| FR-3.5 | Adoption from Yours into a config MUST be one action, and MUST support multi-select |
| FR-3.6 | Classification MUST be platform-aware, not Windows-path-hard-coded (`ROADMAP.md` #34) |
| FR-3.7 | Classification MUST be engine-side (PowerShell), not UI-side |

### FR-4 — Config location move

| # | Requirement |
|---|---|
| FR-4.1 | Evaluate moving the main config from `~/.psmm/` to an XDG-style `~/.config/psmm/` |
| FR-4.2 | Three candidate schemes (`Q-6`): **(a)** `~/.config/psmm` everywhere; **(b)** platform-native — `%APPDATA%\psmm` on Windows, `$XDG_CONFIG_HOME/psmm` elsewhere; **(c)** honour `$XDG_CONFIG_HOME` when set, else `~/.config/psmm` on all platforms. **Preliminary lean: (c)** — one path to document, respects XDG when the user has an opinion, keeps Windows-first simple. **(b)** is the more Windows-correct answer and must be argued against explicitly, not ignored |
| FR-4.3 | Migration MUST be **opt-in**. Never automatic, never silent |
| FR-4.4 | On first run of the new version, if a config exists only at the old path: one-line startup notice, and an offer in the UI, recommending migration |
| FR-4.5 | Migration MUST **copy, not move**, leaving the original intact, and MUST report exactly what it wrote |
| FR-4.6 | During the transition, resolution order is: new path wins; old path still works with a persistent banner |
| FR-4.7 | `Get-PSMMConfigPath` MUST list both, marked old/new, with existence |
| FR-4.8 | `$PSMM_MainConfigPath` continues to override everything (C8) |
| FR-4.9 | A deprecation horizon for the old path MUST be stated in `CHANGELOG.md`, not left implicit |
| FR-4.10 | Migration MUST NOT touch `Includes` targets, profile-directory configs or legacy globs — only the main config location changes |

### FR-5 — `Update-Help` as a verified background job

| # | Requirement |
|---|---|
| FR-5.1 | On-demand `Update-Help`, invoked from the UI, running as a background job, surfaced in the activity panel like any other |
| FR-5.2 | **It MUST be verified to actually work** — the current state is uncertain. Phase 0 establishes whether it works today, and the rewrite proves it with a test |
| FR-5.3 | Known failure modes MUST be handled and reported plainly, not swallowed: HelpInfoUri missing, no updatable help for the module, elevation required for `AllUsers` scope, `-UICulture` mismatch, network/proxy failure |
| FR-5.4 | Scope MUST be explicit — `CurrentUser` by default; anything needing elevation is reported as such rather than silently failing (relates to `ROADMAP.md` #39) |
| FR-5.5 | Available both for a single module and for all loaded modules |

### FR-6 — Fast startup and in-session background persistence

| # | Requirement |
|---|---|
| FR-6.1 | Only `Load` modules gate the prompt. Everything else is background (C5) |
| FR-6.2 | **No gallery or network I/O in the foreground at startup**, under any `Mode`/`Install` combination (§8.2a) |
| FR-6.3 | `Import-Module psmm` MUST get *cheaper*, not dearer — there is no longer a UI body of PowerShell to dot-source (`D-STRUCT`) |
| FR-6.4 | `psmm` → first interactive frame < 150 ms warm (S2). The binary MUST render an initial frame from cached/partial state and fill in as data arrives; it MUST NOT wait for a complete model |
| FR-6.5 | Every slow operation MUST offer *wait or leave* — the user can watch it or exit the UI and let it run |
| FR-6.6 | Exiting the UI MUST NOT cancel running jobs |
| FR-6.7 | Re-entering `psmm` in the same session MUST reattach to running jobs and show their live state |
| FR-6.8 | Per-module startup timings are preserved |

### FR-7 — Session-bound lifetime

| # | Requirement |
|---|---|
| FR-7.1 | **Explicitly unlike Herdr:** nothing detaches, nothing survives, nothing reattaches across sessions |
| FR-7.2 | Closing the shell or the terminal window disposes the UI process and all jobs (C6), via the layered teardown in §7.4 |
| FR-7.3 | Reopening MUST give a genuinely clean slate |
| FR-7.4 | A stale `psmm-ui` process MUST be treated as a bug with a test, not as an acceptable edge case (S6) |

### FR-8 — Cross-session state persistence *(the open question, answered)*

**Recommendation: do not persist session state. Do persist preferences. They are different
things and conflating them is the trap.**

| Category | Examples | Recommendation |
|---|---|---|
| **Session state** | Cursor row, scroll offset, expanded sections, active filter, selection, job history | **Never persisted.** Held in the PowerShell session, so it survives UI exit *within* a session (FR-6.7) and dies with the session (C6) |
| **Preferences** | Theme, mouse capture on/off, layout proportions and collapsed regions (FR-0.7, FR-0.8), column widths and sort order, default tab, unmanaged-view classification overrides (FR-3.4) | **Persisted** — but as *config*, in the config directory, human-readable and hand-editable. Not as opaque UI state |

**Why.** The value of persisted UI state is small (it saves a keypress) and its cost is
real: a stale cached view that disagrees with reality is worse than no view, and any
persisted state file becomes a second source of truth — the exact failure `D-DOCS` rejected
`living-docs` for. Under the option-B architecture the Rust process owns nothing durable
anyway; the state naturally lives where the truth lives. The fresh-start-on-reopen behaviour
you already treat as sacred is not a constraint you're working around — it's a property
worth keeping deliberately.

**The trade-off, stated honestly.** You lose: reopening on the screen you left, remembered
filters, a job history spanning sessions. If any of those turn out to matter after real use,
the preference file is the extension point — add the specific field, not a general state
blob.

`Q-7` records this as still yours to ratify.

### FR-9 — Dependency reduction

| # | Requirement |
|---|---|
| FR-9.1 | On completion, psmm MUST have **no PowerShell module dependency for its UI**. PwshSpectreConsole is dropped |
| FR-9.2 | `D-OWN-MODULES` machinery — private import registration, instance-based subtraction from `Get-Module`, the `◈ psmm's own` rendering, the seeded config entry — MUST be reviewed for deletion. Its guard test may still be worth keeping as a cheap invariant even with nothing left to subtract |
| FR-9.3 | The seeded `PwshSpectreConsole` entry in newly created configs MUST be removed, and existing configs MUST NOT break when it is no longer needed |

### FR-10 — Module workspace (drill-in)

Today a module row is mostly a status line. It should be a door.

| # | Requirement |
|---|---|
| FR-10.1 | From **any** module row — loaded rail, managed half, unmanaged half — the user MUST be able to open a **module workspace**: one place holding everything psmm knows and can do about that module |
| FR-10.2 | Entry MUST be available by mouse (double-click, or the context menu) and by keyboard (`Enter` / `l` / `→`), and exit MUST return to the exact row departed from |
| FR-10.3 | The workspace MUST cover, at minimum: identity and version state; where it is installed and from which repository; its config entry and the `Mode` × `Install` behaviour that entry produces; **browse its exported commands**; connection identity where applicable (FR-1.4); recent job history for that module |
| FR-10.4 | **Behaviour MUST be changeable from here** — set `Mode`, set `Install`, pin or unpin a version, adopt into a config, remove from a config — and every change MUST state which config file it will be written to *before* it is written |
| FR-10.5 | Command browsing MUST be usable without leaving the UI: filterable list, synopsis, and the ability to view full help for a command. Help retrieval MUST be a background job (FR-5), never a blocking call |
| FR-10.6 | The workspace MUST work for a module that is not installed and not loaded — the same door, with the unavailable parts plainly marked, not hidden |
| FR-10.7 | Nothing in the workspace may block the UI (FR-2.4) or wait on the engine synchronously |

### FR-11 — psmm's own settings, in-app

psmm currently configures itself through `$PROFILE` and config files. It should also
configure itself through its own UI, the way it lets you manage everything else.

| # | Requirement |
|---|---|
| FR-11.1 | A **settings tab** (FR-0.5) reachable by click and by `g ,` (§9.3) |
| FR-11.2 | Settings MUST cover at least: **theme selection** (FR-11.5), mouse capture on/off (MS-3), layout proportions (FR-0.7), default sort and filter, activity-panel behaviour, config path in use (FR-4.7), and the startup behaviour psmm applies to itself |
| FR-11.3 | Changes MUST take effect immediately where technically possible, and where they cannot, MUST say so plainly rather than appearing to have applied |
| FR-11.4 | Settings MUST be written to the **human-readable, hand-editable preferences file** (FR-8) — the UI is a convenience over the file, never a replacement for it, and never a format the user cannot inspect |
| FR-11.5 | **Theme selection MUST live here**, with a live preview, and MUST respect the existing palette discipline (NFR-8) — themes are a bounded set of named palettes, not free-form colour entry |
| FR-11.6 | The settings tab MUST distinguish clearly between **psmm's own preferences** (this file) and **module management config** (the JSON configs) — two different things that must never appear to be one |
| FR-11.7 | Every setting MUST be reachable by keyboard and by mouse (MS-1, MS-2) |

### FR-12 — Help, in the same frame

| # | Requirement |
|---|---|
| FR-12.1 | Help MUST be reachable the same way as everything else — `?` from anywhere, a help tab, and a click target — rather than being a separate mode with its own rules |
| FR-12.2 | Help MUST be **generated from the keymap** (KB-R3), never hand-maintained, so it cannot drift from the bindings that actually exist |
| FR-12.3 | Help MUST be **context-aware**: it opens showing the bindings valid for the currently focused region, with the full reference one step away |
| FR-12.4 | Help MUST disclose the mouse-capture trade-off and the `Shift+drag` escape hatch (MS-3) |
| FR-12.5 | Dismissing help MUST return to the exact prior state — focus, selection, scroll position |

---

## 12. Non-functional requirements

| # | Requirement |
|---|---|
| NFR-1 | Frame render ≤ 16 ms at the 99th percentile on a 200-column terminal with 200 module rows |
| NFR-2 | Input latency (keypress → visible response) ≤ 50 ms |
| NFR-3 | Idle CPU ≈ 0 — event-driven, no polling render loop; timers only where genuinely needed |
| NFR-4 | Binary size ≤ 10 MB per RID, release profile, stripped (target, not a hard limit) |
| NFR-5 | Graceful degradation on narrow terminals — a responsive layout, per Herdr's desktop/mobile split, not a broken one |
| NFR-6 | Correct handling of wide characters, combining marks and grapheme clusters — the current Spectre implementation gets this for free and the replacement must not regress it |
| NFR-7 | Themes preserved: `glacier` (default), `ember`, `moss`, via `$PSMM_Theme` (C8) plus an in-UI switch (KB-9) |
| NFR-8 | The `D-RENDER` discipline is **ported, not abandoned**: single-source primitives for code/commands, links, prose and versions; no colour literal outside the theme module; guard tests for both |
| NFR-9 | A panic MUST restore the terminal before unwinding, and MUST leave a diagnosable message — never a corrupted terminal |
| NFR-10 | Rust MSRV pinned and stated; toolchain pinned in CI |

---

## 13. Packaging, build and distribution

**Shipping targets are Windows and Linux.** macOS is future work, not part of this rewrite —
it is paired with the non-Windows engine hardening already tracked as `ROADMAP.md` #34.
Target RIDs: `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64`.

| # | Requirement |
|---|---|
| P1 | The Gallery package carries the native binaries in per-RID subfolders; the module resolves the correct one at first UI use |
| P2 | **The package we actually produce MUST be verified to work through the PowerShell Gallery** — publish it, then install it on a clean machine for each supported RID, and confirm the UI launches. **If the package as built does not work through the Gallery, the remaining binaries MUST be made available another way** (fetched on demand from GitHub Releases) so that the Gallery package itself is always installable. Establish this early: a proven publish → install → launch round trip is a Phase 1 exit gate |
| P3 | A missing, blocked or unrunnable binary MUST fail with a plain diagnosis and a documented remedy — never a stack trace, never a hang. This is the same failure path whether the binary shipped in-package or was fetched |
| P4 | Reproducible builds; `Cargo.lock` committed |
| P5 | `cargo deny` / `cargo audit` in CI — a compiled dependency tree in a security-adjacent admin tool warrants supply-chain checks |
| P6 | The build MUST assemble binaries into the module layout *before* Pester runs, so tests exercise the shipped shape |
| P7 | `D6`'s CI matrix extends: add a Rust toolchain and a cross-compile matrix, keeping lint + full Pester on `windows-latest` and engine-only Pester on `ubuntu-latest` |
| P8 | `RELEASE-CHECKLIST.md` MUST be updated for the binary artefacts |

> Signing, notarisation and platform trust prompts are deliberately **out of scope for this
> document**. If real friction appears in real environments, it gets addressed then, on
> evidence, rather than designed for speculatively now.

---

## 14. Testing

| # | Requirement |
|---|---|
| T1 | Pester remains the engine's test framework; PSScriptAnalyzer settings unchanged |
| T2 | The `D-IMPORT-SCOPE` AST guard test survives unchanged — it guards PowerShell source, which stays PowerShell (C1) |
| T3 | **Protocol conformance suite**: golden request/response fixtures, run from the PowerShell side against a mock client *and* from the Rust side against a mock host. This is the contract that stops the two halves drifting |
| T4 | Rust UI frame tests via Ratatui's `TestBackend` — the direct successor to the `StringWriter`-backed `IAnsiConsole` capability `D-UI-ARCH` was built to enable. Do not lose headless frame assertions in the move |
| T5 | One Pester test per `Mode` × `Install` cell (S8, V9), asserting install / import / check / report independently |
| T6 | Terminal restoration tests: normal exit, error exit, panic, parent killed (S4) |
| T7 | Orphan-process test in CI (S6) |
| T8 | Keyboard/mouse parity checklist test (S7, MS-R2) |
| T9 | Keymap duplicate-binding guard test (KB-R2) |
| T10 | Palette guard test ported to Rust (NFR-8) |
| T11 | Startup timing regression test with a stated reference config and threshold (S1) |
| T12 | Config round-trip byte-stability tests preserved (§6.3) |
| T13 | Legacy-shape config tests preserved — the compatibility promise is tested against the real legacy shape today and must stay that way (C7) |
| T14 | **Layout tests** via `TestBackend` at several terminal sizes, including the stated minimum and one below it, asserting the FR-0 regions are present, proportioned and legible, and that the degraded narrow mode engages where specified (FR-0.8) |
| T15 | Focus-model test: exactly one region focused at all times, `Tab` cycles the full set and returns, and clicking a region focuses it (FR-0.9) |
| T16 | Module workspace reachability test: every module row, in every region, opens the workspace and returns to the originating row (FR-10.2) |
| T17 | **Gallery round-trip test** — publish the built package to a test feed, install it clean, launch the UI, per supported RID (P2). Automate as far as the Gallery permits; where it cannot be automated, it becomes a named manual step in `RELEASE-CHECKLIST.md` |

---

## 15. Phased delivery plan (strangler)

Every phase ends with a Gallery-publishable prerelease that passes CI (G7, S9).

### Phase 0 — Decide and specify *(no production code)*

- Re-derive keybindings and the `Mode`×`Install` implementation from `src/` (§8.7 V1–V8, §9.1).
- Produce the discrepancy list and rule on each item.
- ADRs: **D-UI-RUST** (supersedes the technology choice in `D-TUI`, including its
  mouse-centric objection to Terminal.Gui), **D-BOUNDARY** (§7.2 decision),
  **D-CONFIG-PATH** (FR-4), **D-KEYMAP** (§9.3), **D-STATE** (FR-8),
  **D-LAYOUT** (FR-0 — the three-region frame and the tab set).
- Freeze `psmm-proto v0`.
- Audit what FR-1 connection status and FR-5 `Update-Help` actually do today.
- Answer `Q-1` … `Q-7` (`Q-8` belongs to Phase 1; `Q-9` is withdrawn).

### Phase 1 — Protocol spine

Thinnest possible end-to-end slice: the PowerShell host/pump, and a Rust client that renders
the grid read-only and performs **exactly one** mutation — load a module.
`$PSMM_UI = 'rust' | 'spectre'` selects the front end; Spectre remains the default.

**Proves:** `-Global` lands correctly at the user's prompt (S5); alternate-screen and
scrollback behaviour (S3); exact terminal restoration (S4); teardown with the terminal killed
(S6); the render-device-vs-stdout split (§7.4).

*If Phase 1 cannot prove all five, the boundary decision is wrong — return to Phase 0 rather
than pressing on.*

**Also proves P2:** publish the prerelease carrying a real binary to the Gallery and install
it on a clean machine. This is the first point at which a native artefact exists to test, and
it is the cheapest point at which to discover the package does not survive the round trip.

### Phase 2 — Read-only parity, in the new frame

All screens render in Rust, **inside the FR-0 layout** — the three regions and the tab bar
exist from the moment anything renders, because retrofitting a frame around finished screens
is far more expensive than building inside one. Mutations still routed individually. The
streamlined keymap lands here, in the Rust UI only — the Spectre UI keeps its current
bindings, and the divergence is documented as a known, temporary cost of the strangler.

### Phase 3 — Action parity and the new views

Full action parity. FR-1 (loaded rail, connection state), FR-2 (activity panel), FR-3
(user/system split), FR-10 (module workspace). Rust becomes the default front end; Spectre
stays available via `$PSMM_UI`.

### Phase 4 — Mouse layer

Full mouse model (§10), MS-1…MS-7, parity checklist test, and the frame's drag/resize
affordances (FR-0.7).

### Phase 5 — Config, settings and jobs

FR-4 (config relocation and migration), FR-5 (`Update-Help` verified), FR-11 (in-app settings
and theming), FR-12 (in-app help), FR-6/FR-7 hardening with the timing and orphan tests.

### Phase 6 — Retire the old UI

Delete `src/UI`, drop PwshSpectreConsole, unwind `D-OWN-MODULES` (FR-9). `ROADMAP.md` #34
(non-Windows UI) becomes reachable and should be re-planned on the new foundation — including
macOS, which §13 defers to exactly this point.

---

## 16. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **The package we build does not install cleanly from the Gallery** — the module now carries native binaries, and the Gallery round trip is untested against that shape | P2: prove publish → install → launch on a clean machine per RID, early, as a Phase 1 gate. Fallback is on-demand fetch for the surplus binaries |
| R2 | **Two-language maintenance burden on a solo, largely AI-written project.** Rust review demands more of the human reviewer than PowerShell does | Keep the boundary narrow and the protocol small. Keep the engine in PowerShell. Be willing to stop after Phase 2 if the cost is not paying |
| R3 | **Protocol drift** between the halves | T3 conformance suite; versioned handshake; the protocol as a published contract |
| R4 | **Terminal ownership bugs** — double render, corrupted scrollback, mouse mode left on | C11 as an invariant; T6; render to the console device explicitly |
| R5 | **Semantics change breaks existing configs' expectations.** Moving `Latest` off the foreground startup path is a *behavioural* change for anyone relying on it | Announce in `CHANGELOG.md`; report the deferral visibly in the activity panel rather than silently changing when updates apply |
| R6 | **Four RIDs multiply build and test surface**, and `win-arm64` / `linux-arm64` are the ones least likely to get real hands-on use | Start with `win-x64` and `linux-x64`; add the ARM RIDs deliberately once the round trip in P2 is proven |
| R7 | **Mouse capture regresses copy/paste** — a daily-use annoyance that could sour the whole feature | MS-3: disclosed, toggleable, `Shift+drag` surfaced in-UI |
| R8 | **Scope creep** — the roadmap shelf (lockfile, lazy-load stubs, Graph families) is tempting once the UI is fresh | NG5; §8.6 reserves design space only |
| R9 | **`ROADMAP.md` #34 promises more than it delivers** — a cross-platform binary is not a cross-platform *tool* while scope detection and path logic remain Windows-shaped | FR-3.6; keep #34 as its own planned work, not a side effect |
| R10 | **Regression against a UI you already like.** The current look and feel was a deliberate `D-TUI` choice | Phase 2 is read-only parity precisely so the visual result can be judged before actions are ported |

---

## 17. Open questions

| # | Question | Owner |
|---|---|---|
| Q-1 | §8.2 — hard rule (8.2a, no schema change) or explicit `Defer` axis (8.2b, adds a field)? | PBNZ |
| Q-2 | Cell 2 — when a background install lands after the prompt is live, import it mid-session or defer to next session? | PBNZ |
| Q-3 | Cell 3 — confirm exact pin neuters `Latest`, and that a range pin makes `Latest` mean newest-in-range | Phase 0 (V5) |
| Q-4 | Does `Mode` constrain **interactive** actions, or only startup? *Preliminary lean: startup declaration only — the UI always permits explicit action on any row, and shows the deviation from declared config* | PBNZ |
| Q-5 | Does `Ignore` suppress the update **check**, not merely install and import? | Phase 0 (V6) |
| Q-6 | FR-4.2 — config path scheme (a), (b) or (c)? | PBNZ |
| Q-7 | FR-8 — ratify "preferences persist, session state does not" | PBNZ |
| Q-8 | Does the package as built publish to, and install from, the Gallery for every supported RID? If not, which binaries move to on-demand fetch? | Phase 1 (P2) |
| Q-9 | *Withdrawn.* Signing/trust is out of scope (§13) — revisit only on evidence of real friction | — |
| Q-10 | Does the Spectre UI receive the streamlined keymap, or does it stay frozen through the strangler? *Preliminary lean: frozen* | PBNZ |
| Q-11 | Is `$PSMM_UI` a permanent knob or a transitional one removed at Phase 6? | PBNZ |
| Q-12 | Does `ROADMAP.md` #39 (elevated helper) become an in-scope second actuator once the protocol exists? | PBNZ |

---

## 18. Deliverables from the planning session

Mapped to the original ten asks.

| # | Deliverable | PRD anchor |
|---|---|---|
| 1 | Target architecture: what stays PowerShell, what moves to Rust, the exact boundary | §7.5 |
| 2 | Front-end ↔ session communication recommendation with pros and cons | §7.2, §7.3, §7.4 |
| 3 | Fully specified `Mode` × `Install` matrix plus discrepancies against current behaviour | §8.5, §8.7 |
| 4 | Streamlined keybinding scheme with before/after | §9.1, §9.2, §9.3 |
| 5 | Full mouse-interaction model with keyboard parity | §10 |
| 6 | Activity panel, loaded/active section, user-vs-system split | FR-1, FR-2, FR-3 |
| 6a | Screen layout — three regions, tabbed right pane | FR-0, §10.2 |
| 6b | Module workspace: drill in, browse commands, change behaviour | FR-10 |
| 6c | psmm's own settings, theming and help, in-app | FR-11, FR-12 |
| 7 | Config-location recommendation and migration flow | FR-4 |
| 8 | Fast startup, in-session background persistence, clean teardown, state persistence | FR-6, FR-7, FR-8, §7.4 |
| 9 | Phased strangler migration plan | §15 |
| 10 | Risks and open questions: cross-platform, packaging, CI, testing | §13, §14, §16, §17 |

---

## Appendix A — Verified external facts

Checked 2026-07-25.

| Fact | Value |
|---|---|
| Ratatui latest | 0.30.2. From 0.30.0 the project is a modular workspace (`ratatui`, `ratatui-core`, `ratatui-crossterm`, …); applications should depend on `ratatui`, widget libraries on `ratatui-core` |
| Crossterm latest | 0.29.0 (released 2025-04-05) |
| Crossterm version selection | `ratatui-crossterm` selects the Crossterm version by feature flag (`crossterm_0_28`, `crossterm_0_29`); highest enabled wins; the selected crate is re-exported as `ratatui_crossterm::crossterm`. Ratatui supports at least the two most recent Crossterm versions. **Feature unification means any crate in the dependency graph that pins a Crossterm version can affect this** — worth watching |
| `ratatui-interact` | A third-party crate providing interactive components with focus management and mouse support, targeting Ratatui 0.30 / Crossterm 0.29. Evaluate in Phase 0 (MS-R4) |
| Herdr | Rust, Apache-2.0. Explicitly mouse-first with keyboard equally first-class; its UI computes layout geometry and hit-test areas in a first pass, then renders in a second; it uses a server-owned runtime with the TUI as one client over a socket API, and its changelog notes work on any-motion mouse tracking for hover events. **Its persistent, detachable sessions are the direct opposite of FR-7 — borrow the interaction model, not the lifecycle model** |

---

## Appendix B — Kickoff prompt for the planning session

> Read `PRD-psmm-rust-ui.md` in full, then read the repo at `https://github.com/PBNZ/psmm` —
> `README.md`, `DECISIONS.md`, `ROADMAP.md`, `CHECKPOINT.md`, `docs/config-schema.md`, and
> the source under `src/Engine`, `src/Public` and `src/UI`, paying particular attention to
> the keybinding definitions and to the `Mode`/`Install` decision logic.
>
> This is a **planning session — produce no production code.** Deliver the ten items in
> §18, resolving every `Q-n` you can resolve from the source and flagging the rest for me.
>
> Start by completing the Phase 0 verification tasks in §8.7 and re-deriving the current
> keybinding table for §9.1, then tell me where the PRD's assumptions are wrong before you
> propose anything.
>
> Ask me any clarifying questions before proposing the plan.
