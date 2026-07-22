# Optional UI keystroke test (not part of the Pester suite)

`drive-psmm-ui.py` launches the REAL psmm TUI inside a ConPTY
pseudo-terminal and drives it with actual keystrokes: open on a zero-config
setup (asserts the main config is auto-created, seeded with
PwshSpectreConsole) → wait for the unmanaged scan → `m` → `?` help →
PageDown → esc → `a` add-entry wizard end-to-end (name, friendly,
description, install policy, mode → row appears in the grid) → esc quit,
asserting on the rendered stream (and that the alternate-screen restore
code is emitted, with no error text anywhere).

Requires Python 3 + `pip install pywinpty` (Windows only). Run:

```powershell
python Tests/tools/drive-psmm-ui.py
```

It found a real bug the headless Pester suite could not (the pager's
Mandatory `[string[]]` parameter rejecting blank lines), so extend it as
screens gain behaviour worth replaying.

## Running the working tree by hand

`try-psmm-branch.ps1` launches the psmm **working tree** against a throwaway
copy of your real config, so a build under test cannot scribble on the real
one:

```powershell
pwsh -NoProfile -File Tests\tools\try-psmm-branch.ps1                 # your config, copied
pwsh -NoProfile -File Tests\tools\try-psmm-branch.ps1 -Fresh          # synthetic config over fake modules
pwsh -NoProfile -File Tests\tools\try-psmm-branch.ps1 -AllowInstalls  # keep the real Install policies
```

It sets UTF-8 output (without it the box drawing and state glyphs render as
garbage), copies every discovered config source into a sandbox and repoints
`$PSMM_MainConfigPath` & co at the copies, runs `Invoke-PSMMStartup` exactly as
a `$PROFILE` would, prints what actually landed in the session, then opens the
manager.

Two things it deliberately makes loud:

- **which build is live.** `Import-Module <repo>\psmm.psd1 -Force` does *not*
  replace an already-loaded psmm - it loads a **second** module of the same
  name and command resolution between them is anyone's guess. The script
  removes first, then prints the module path and a green/red "working tree?"
  line.
- **what escapes the sandbox.** The config is isolated; the module folders and
  your environment are not. `p` (move a module) and `m` (move a location's
  contents) act on real folders unless you pass `-Fresh`; `n` offers to write
  your user `PSModulePath`; `s`/`r` write your real `powershell.config.json`;
  `i`/`u` do real gallery installs.
