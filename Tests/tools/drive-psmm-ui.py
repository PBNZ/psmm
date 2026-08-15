"""Drive the real psmm TUI in a ConPTY with actual keystrokes.

Replays PBNZ's failed live session on a zero-config machine:
open (auto-creates the main config, managing PwshSpectreConsole) ->
background scan -> 'm' (show unmanaged) -> '?' (help) -> esc ->
'a' (add a new entry end-to-end) -> esc quit.
"""
import base64
import sys
import tempfile
import threading
import time

sys.stdout.reconfigure(errors="replace")

import winpty

from pathlib import Path
REPO = str(Path(__file__).resolve().parents[2])   # repo root, wherever it's cloned
tmp = tempfile.mkdtemp()

prelude = (
    f"$global:PSMM_MainConfigPath='{tmp}\\a\\psmm-config.json'; "
    f"$global:PSMM_ProfileConfigPath='{tmp}\\b\\psmm-config.json'; "
    f"$global:PSMM_JsonPath=@('{tmp}\\c\\*.json'); "
    "$global:PSMM_UpdateCheck=$false; "   # deterministic: no gallery call

    f"Import-Module '{REPO}\\.tools\\PwshSpectreConsole'; "
    f"Import-Module '{REPO}\\psmm.psd1'; "
    "Show-PSModuleManager; "
    "Write-Host ('PSMM-EXITED-' + 'CLEAN')"
)
b64 = base64.b64encode(prelude.encode("utf-16-le")).decode()

proc = winpty.PtyProcess.spawn(
    f"pwsh -NoProfile -EncodedCommand {b64}", dimensions=(40, 150)
)

buf = []
buf_lock = threading.Lock()

def reader():
    while True:
        try:
            data = proc.read(4096)
        except Exception:
            return
        if not data:
            return
        with buf_lock:
            buf.append(data)

t = threading.Thread(target=reader, daemon=True)
t.start()

def stream() -> str:
    with buf_lock:
        return "".join(buf)

def wait_for(needle: str, timeout: float, label: str) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in stream():
            print(f"OK   {label}")
            return
        time.sleep(0.25)
    print(f"FAIL {label}: '{needle}' not seen within {timeout}s")
    tail = stream()[-3000:].replace("\x1b", "<ESC>")
    print("---- tail ----")
    print(tail)
    proc.terminate()
    sys.exit(1)

import re

def wait_for_re(pattern: str, timeout: float, label: str) -> None:
    deadline = time.time() + timeout
    rx = re.compile(pattern)
    while time.time() < deadline:
        if rx.search(stream()):
            print(f"OK   {label}")
            return
        time.sleep(0.25)
    print(f"FAIL {label}: /{pattern}/ not seen within {timeout}s")
    tail = stream()[-3000:].replace("\x1b", "<ESC>")
    print("---- tail ----")
    print(tail)
    proc.terminate()
    sys.exit(1)

ESC = "\x1b"

# A string only the GRID renders - "r  reload" from its second hint row.
# Used to detect "we are back on the grid" after a screen change.
#
# NOT "PS Session Module Manager": that is the WINDOW TITLE, emitted once
# when the manager starts and never again, so looking for it in the stream
# AFTER a screen change could never match. Every check below it was
# therefore unreachable.
GRID_MARK = "reload"

# 1. the grid appears (UI sourced, deps loaded, state initialised, no crash)
wait_for("PS Session Module Manager", 90, "grid opened")
# 1a. the header carries the running version next to the name
wait_for_re(r"psmm v\d+\.\d+\.\d+", 10, "version shown in the grid header")
# 1b. zero configs -> the main config was auto-created, seeded with psmm's
#     own UI dependency as a managed entry (2026-07-05 feedback)
wait_for("UI dependency is managed there", 15, "main config auto-created on first run")
wait_for("PwshSpectreConsole", 15, "seeded PwshSpectreConsole row in the grid")
# 1c. FIRST RUN ONLY: the welcome overlay (0.1.0-beta8) floats over the first
#     paint and blocks the grid loop on ReadKey until a key arrives. It is
#     always due here because the sandbox config dir is fresh, so dismiss it
#     before waiting on anything the grid has to repaint to show. (Without
#     this the run hangs at the scan notice - which it did, silently, from
#     beta8 until 2026-07-26, because the harness predates the overlay.)
wait_for("the three keys worth knowing", 20, "first-run welcome overlay shown")
proc.write(" ")          # "any key closes this"; space is swallowed by the overlay
time.sleep(0.5)

# 2. the unmanaged scan lands and the notice shows
wait_for_re(r"\d+ installed module\(s\) not in your config", 120, "scan notice shown")
time.sleep(0.5)

# 3. press m -> unmanaged rows appear (status: 'showing N unmanaged module(s)')
proc.write("m")
wait_for_re(r"showing \d+ unmanaged module\(s\)", 30, "m revealed unmanaged rows")
wait_for_re(r"row 1/\d+", 10, "position indicator present")

# 4. press ? -> real help opens ('MAIN SCREEN' is on the first visible page;
#    'KEYS THAT WORK EVERYWHERE' may be below the fold at this height)
proc.write("?")
wait_for("MAIN SCREEN (module grid)", 30, "? opened the help screen")
# scroll down a page and confirm content below the fold is reachable.
# NB: assert on text the SOURCE actually renders. This waited on
# 'KEYS THAT WORK EVERYWHERE' - a heading that had not existed since the v2
# help rewrite - so it could only ever have passed by never being reached.
proc.write("\x1b[6~")  # PageDown
wait_for("unload from this session", 15, "help scrolls (PageDown)")

# 5. esc -> back to the grid (a fresh grid frame renders)
before = len(stream())
proc.write(ESC)
deadline = time.time() + 30
while time.time() < deadline:
    if GRID_MARK in stream()[before:]:
        break
    time.sleep(0.25)
else:
    print("FAIL esc did not return to the grid")
    proc.terminate()
    sys.exit(1)
print("OK   esc returned from help to the grid")

# 5b. 'g p' -> module locations screen (PSModulePath + OneDrive diagnostics).
#     Bare 'p' was the pre-0.1.0-beta6 binding; navigation moved behind the
#     'g' goto layer and single letters became verbs only.
proc.write("g")
time.sleep(0.3)
proc.write("p")
#     the breadcrumb reads "home > paths"; the old "Module locations" title
#     went away with the v2 header bar
wait_for("search order = list order", 20, "'g p' opened the module locations screen")
wait_for("set primary location", 10, "paths screen shows its actions")
# 5c. 'g' then 'h' -> the goto-home chord returns to the grid from a sub-screen
before = len(stream())
proc.write("g")
time.sleep(0.3)
proc.write("h")
deadline = time.time() + 20
while time.time() < deadline:
    if GRID_MARK in stream()[before:]:
        break
    time.sleep(0.25)
else:
    print("FAIL 'g h' did not return to the grid")
    proc.terminate()
    sys.exit(1)
print("OK   'g h' chord jumped home from a sub-screen")

# 6. 'a' -> add a new entry end-to-end: the screen must CLEAR (no append
#    below the grid - the Clear() no-op bug) and the wizard must run since a
#    config file now exists (auto-created in step 1b)
proc.write("a")
wait_for("New entry", 15, "'a' opened the new-entry wizard")
wait_for("Module name", 15, "wizard prompts for a module name (no dead end)")
proc.write("DummyPsmmTestModule\r")
wait_for("Friendly name", 15, "wizard prompts for friendly name")
proc.write("\r")  # empty
wait_for("Description", 15, "wizard prompts for description")
proc.write("\r")  # empty
wait_for("Install policy", 20, "wizard prompts for install policy")
proc.write("\r")  # IfMissing
wait_for("Mode", 10, "wizard prompts for mode")
proc.write("\r")  # Load
# the prerelease opt-in (gh#6) was added to the wizard after this harness was
# written, so the run used to stall here with the selector still on screen
wait_for("Versions", 10, "wizard prompts for the prerelease opt-in")
proc.write("\r")  # stable only
# back on the grid: the new entry is in the table (missing - it isn't real)
before = len(stream())
deadline = time.time() + 60  # rescan after save does the ListAvailable sweep
while time.time() < deadline:
    if "DummyPsmmTestModule" in stream()[before:]:
        break
    time.sleep(0.25)
else:
    print("FAIL added entry did not appear in the grid")
    proc.terminate()
    sys.exit(1)
print("OK   added entry appears in the grid as a managed row")

# 6a. drill into a module and check the CURSOR IS HIDDEN there.
#     Spectre's LiveDisplay shows the cursor again when it exits, and the
#     module menu renders without a live display, so it used to blink a
#     cursor over the frame. The fix re-hides on every live exit and every
#     full-screen repaint; this asserts the last cursor sequence in the
#     stream, from the moment the menu opened, is the HIDE.
before = len(stream())
proc.write("\r")   # enter -> module action menu
wait_for("browse commands", 20, "enter opened the module menu")
time.sleep(0.4)
tail_since_menu = stream()[before:]
hide, show = tail_since_menu.rfind("[?25l"), tail_since_menu.rfind("[?25h")
if hide == -1 and show == -1:
    print("WARN no cursor sequences seen after opening the module menu")
elif hide > show:
    print("OK   cursor is hidden on the module menu (last sequence is ?25l)")
else:
    print("FAIL cursor left VISIBLE on the module menu: ?25h came after ?25l")
    proc.terminate()
    sys.exit(1)
before = len(stream())
proc.write(ESC)
deadline = time.time() + 20
while time.time() < deadline:
    if GRID_MARK in stream()[before:]:
        break
    time.sleep(0.25)
else:
    print("FAIL esc did not return from the module menu to the grid")
    proc.terminate()
    sys.exit(1)
print("OK   esc returned from the module menu to the grid")

# 6b. 'g t' -> the tasks screen, which by now holds the finished unmanaged
#     scan. Checks the 0.1.0-rc02 additions: the cancel verb exists, and the
#     output column reports a line count.
proc.write("g")
time.sleep(0.3)
proc.write("t")
wait_for_re(r"home\s*.\s*tasks", 20, "'g t' opened the background-tasks screen")
wait_for("scan: unmanaged modules", 15, "the scan task is listed")
wait_for("cancel", 10, "the tasks screen offers x=cancel (rc02)")
wait_for_re(r"\d+ line\(s\)", 10, "the tasks screen reports an output line count")
before = len(stream())
proc.write(ESC)
deadline = time.time() + 20
while time.time() < deadline:
    if GRID_MARK in stream()[before:]:
        break
    time.sleep(0.25)
else:
    print("FAIL esc did not return from tasks to the grid")
    proc.terminate()
    sys.exit(1)
print("OK   esc returned from tasks to the grid")

# 7. esc on the grid -> quit cleanly, alt screen restored, sentinel printed
proc.write(ESC)
wait_for("PSMM-EXITED-CLEAN", 30, "esc quit the UI cleanly (no error)")
if "\x1b[?1049l" in stream():
    print("OK   alternate screen buffer was exited (scrollback restore code sent)")
else:
    print("WARN alt-screen leave code not observed in stream")

deadline = time.time() + 20
while proc.isalive() and time.time() < deadline:
    time.sleep(0.25)
print(f"OK   pwsh exited: alive={proc.isalive()}")

s = stream()
for bad in ("Cannot bind argument", "Exception", "is not recognized"):
    if bad in s:
        print(f"FAIL error text present in session: '{bad}'")
        sys.exit(1)
print("ALL UI KEYSTROKE CHECKS PASSED")
