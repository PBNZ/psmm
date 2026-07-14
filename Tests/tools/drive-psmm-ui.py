"""Drive the real psmm TUI in a ConPTY with actual keystrokes.

Replays Peter's failed live session on a zero-config machine:
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

# 1. the grid appears (UI sourced, deps loaded, state initialised, no crash)
wait_for("PS Session Module Manager", 90, "grid opened")
# 1a. the header carries the running version next to the name
wait_for_re(r"psmm v\d+\.\d+\.\d+", 10, "version shown in the grid header")
# 1b. zero configs -> the main config was auto-created, seeded with psmm's
#     own UI dependency as a managed entry (2026-07-05 feedback)
wait_for("UI dependency is managed there", 15, "main config auto-created on first run")
wait_for("PwshSpectreConsole", 15, "seeded PwshSpectreConsole row in the grid")
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
# scroll down a page and confirm the global key reference is reachable
proc.write("\x1b[6~")  # PageDown
wait_for("KEYS THAT WORK EVERYWHERE", 15, "help scrolls (PageDown)")

# 5. esc -> back to the grid (a fresh grid frame renders)
before = len(stream())
proc.write(ESC)
deadline = time.time() + 30
while time.time() < deadline:
    if "PS Session Module Manager" in stream()[before:]:
        break
    time.sleep(0.25)
else:
    print("FAIL esc did not return to the grid")
    proc.terminate()
    sys.exit(1)
print("OK   esc returned from help to the grid")

# 5b. 'p' -> module locations screen (PSModulePath + OneDrive diagnostics)
proc.write("p")
wait_for("Module locations", 20, "'p' opened the module locations screen")
wait_for("set primary location", 10, "paths screen shows its actions")
# 5c. 'g' then 'h' -> the goto-home chord returns to the grid from a sub-screen
before = len(stream())
proc.write("g")
time.sleep(0.3)
proc.write("h")
deadline = time.time() + 20
while time.time() < deadline:
    if "PS Session Module Manager" in stream()[before:]:
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
