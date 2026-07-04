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
