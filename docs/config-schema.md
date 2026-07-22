# psmm config schema reference

psmm reads declarative JSON config files named `psmm-config.json` (plus any
files you point it at). This page is the complete reference. Existing config
files from the original `$PROFILE`-block era work unchanged.

## Where psmm looks (discovery order)

| # | Source | Notes |
|---|--------|-------|
| 1 | Inline JSON in `$PSMM_InlineJson` | Set in `$PROFILE` before `Import-Module psmm`. Read-only in the UI. |
| 2 | **Main config** — `~/.psmm/psmm-config.json` | The only file whose `Includes` are honoured. Override the path with `$PSMM_MainConfigPath`. |
| 3 | The main config's `Includes` | One level deep — an included file's own `Includes` are ignored (this is what makes circular references impossible). `~` and `%ENV%` variables are expanded. |
| 4 | Profile-directory config — `<dir of $PROFILE>/psmm-config.json` | Override with `$PSMM_ProfileConfigPath`. |
| 5 | Legacy globs — `$PSMM_JsonPath` | Default: `psmodules.d/*.json` next to `$PROFILE`. |

`Get-PSMMConfigPath` prints this list with resolved paths and existence.
No file is ever loaded twice, even if reachable via two sources.

## File-level fields

```json
{
  "Enabled": true,
  "Includes": ["C:\\configs\\work-modules.json", "~/lab.json"],
  "_legend": { "any": "free-form self-documentation, preserved on save" },
  "Modules": [ ... ]
}
```

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `Enabled` | bool | `true` | `false` = the file is parsed (and shown in the UI) but **nothing in it is actioned**. This is the "switch a module set on/off" feature. A disabled file's entries are preserved on save — never silently dropped. |
| `Includes` | string[] | `[]` | Absolute paths of further config files. **Honoured only in the main config**; anywhere else it is ignored with a warning. |
| `_legend` | object | — | Self-documenting help, kept verbatim across saves. |
| `Modules` | array | required | The module entries (below). |

## Module entry fields

```json
{
  "Name": "ImportExcel",
  "FriendlyName": "Import Excel",
  "Description": "Read/write .xlsx without Excel",
  "Install": "IfMissing",
  "Mode": "Load",
  "Version": "7.8.10",
  "Prerelease": false
}
```

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `Name` | string | **required** | The module's PowerShell Gallery name. |
| `FriendlyName` | string | = `Name` | Display name in the report and UI. |
| `Description` | string | — | Free text, shown in the module details. |
| `Install` | string | `IfMissing` | Disk/gallery policy: `CheckOnly` (never install, only report), `IfMissing` (install when absent), `Latest` (check the gallery and update at startup). |
| `Mode` | string | `Load` | Session policy: `Load` (import into the session at startup, foreground), `InstallOnly` (disk/gallery work only, deferred to a background job), `Ignore` (parsed, visible in the UI, not actioned). |
| `Version` | string | — | Optional pin: an exact version (`"1.2.3"`), an exact prerelease (`"1.2.3-beta4"`) or a NuGet range (`"[1.0,2.0)"`). Exact pins are honoured on import (`-RequiredVersion`) and install; pinned modules are never flagged "update available". A prerelease pin implies `-Prerelease` on install and imports by its **base** version, because `-RequiredVersion` is typed `[version]` and a prerelease shares its base-version folder. Ranges require PSResourceGet (on PowerShellGet-only machines a range falls back to latest, with a warning). |
| `Prerelease` | bool | `false` | Allow prerelease versions from the gallery for this module. Affects install, update, the update check and the version-pin picker. The UI shows it as `+pre` in the **gallery** column, and every version cell then renders its full label (`0.1.0-beta8`, not `0.1.0`). Toggle it with `w` in the module menu. |

**A note on prerelease labels.** A prerelease label lives in the manifest's
`PrivateData.PSData.Prerelease`, *not* in the `[version]` — `0.1.0-beta8` and
`0.1.0` are both `[version]0.1.0`. psmm therefore carries the label alongside
every version it reads and shows it everywhere a version appears. Ordering
follows SemVer: a release outranks any prerelease of the same base version,
and `beta8` outranks `beta2`.

Independently of this setting, a module whose *installed* copy is already a
prerelease keeps being updated along the prerelease track — a
prerelease-label-only bump is invisible to `Update-PSResource`, so
`Install-PSResource -Prerelease -Reinstall` is the only thing that moves it.

**`Install` and `Mode` are orthogonal.** `Mode` decides load-vs-not and
foreground-vs-background; `Install` decides the disk/gallery policy. So
`CheckOnly` + `Load` imports synchronously but never installs, and
`Latest` + `InstallOnly` updates in the background without ever importing.

Invalid `Install`/`Mode`/`Version` values never break a file: the entry
degrades to the default with an issue flag (`!` column; details under `c`).

## Conflict rules (same module name in several files)

1. The **main config always wins** — a warning names the overridden file.
2. Among non-main files, the **first-loaded wins** — an error-style warning
   tells you to fix your configs.
3. Disabled files don't participate (but their entries stay in the file).

Warnings appear at startup, on the psmm grid, and in the conflicts view (`c`).

## What saves look like

The UI writes files back with: `Enabled` only if the file had it (or is
disabled), `Includes` only in the main config, `_legend` preserved verbatim,
`FriendlyName` omitted when it equals `Name`, `Version` only when pinned.
Round-trips are stable — saving twice produces identical bytes.

## Compatibility promise

Config files written for the original profile block load unchanged (this is
covered by tests against the real legacy shape). New optional fields —
currently `Version` and `Prerelease` — are additive. Unknown fields never cause errors:
they are ignored on load. Note that when the **UI saves** a file it writes
only the fields it knows (same behaviour as the original block), so custom
extra fields on a *module entry* don't survive a UI edit of that file —
`_legend` and file-level `Enabled`/`Includes` are always preserved.
