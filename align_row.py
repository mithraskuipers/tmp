#!/usr/bin/env python3
"""
Global hotkey that aligns the currently selected shapes in PowerPoint
onto one row (same behavior as native "Align Middle": centers every
shape on the vertical midpoint of the whole selection's bounding box).

Setup:
    pip3 install pynput

    Grant permission to whatever runs this (Terminal, iTerm, or the
    python3 binary itself) under:
      System Settings > Privacy & Security > Accessibility
      System Settings > Privacy & Security > Input Monitoring

    First run will also prompt "Terminal wants to control Microsoft
    PowerPoint" (Automation permission) - allow it.

Run:
    python3 align_row.py

Then, with 2+ objects selected in PowerPoint, press the hotkey below.
"""

import argparse
import subprocess
from datetime import datetime

from pynput import keyboard

HOTKEY = "<cmd>+<alt>+r"  # change to whatever combo you want


def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


ALIGN_MIDDLE_SCRIPT = '''
tell application "Microsoft PowerPoint"
    set theRange to shape range of selection of active window
    set n to count shapes of theRange
    if n < 2 then return

    set topList to {}
    set botList to {}
    repeat with i from 1 to n
        tell shape i of theRange
            set t to top
            set h to height
        end tell
        set end of topList to t
        set end of botList to (t + h)
    end repeat

    set minTop to item 1 of topList
    set maxBot to item 1 of botList
    repeat with i from 2 to n
        if item i of topList < minTop then set minTop to item i of topList
        if item i of botList > maxBot then set maxBot to item i of botList
    end repeat
    set centerY to (minTop + maxBot) / 2

    repeat with i from 1 to n
        tell shape i of theRange
            set h to height
            -- swap the line below for "set top to minTop" to align tops instead of centers
            set top to centerY - (h / 2)
        end tell
    end repeat
end tell
'''


def align_row():
    log(f"Hotkey {HOTKEY} activated - aligning selection...")
    result = subprocess.run(
        ["osascript", "-e", ALIGN_MIDDLE_SCRIPT], capture_output=True, text=True
    )
    if result.returncode != 0:
        log(f"AppleScript error: {result.stderr.strip()}")
    else:
        log("Done.")


def test_keys():
    """Logs every keypress so you can confirm the listener actually
    receives keyboard input (i.e. Input Monitoring permission is granted).
    Press Esc to stop."""
    log("Key test mode - press any key, Esc to stop.")

    def on_press(key):
        log(f"key pressed: {key}")
        if key == keyboard.Key.esc:
            return False

    with keyboard.Listener(on_press=on_press) as listener:
        listener.join()
    log("Key test finished. If nothing was logged above, macOS hasn't granted Input Monitoring yet.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--test-keys",
        action="store_true",
        help="log every keypress instead of listening for the hotkey, to verify the listener works",
    )
    args = parser.parse_args()

    if args.test_keys:
        test_keys()
        return

    log(f"Listening for {HOTKEY} - select 2+ objects in PowerPoint, then press it.")
    with keyboard.GlobalHotKeys({HOTKEY: align_row}) as h:
        h.join()


if __name__ == "__main__":
    main()
