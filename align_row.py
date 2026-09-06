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

import subprocess
from pynput import keyboard

HOTKEY = "<cmd>+<alt>+r"  # change to whatever combo you want

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
    subprocess.run(["osascript", "-e", ALIGN_MIDDLE_SCRIPT])


def main():
    print(f"Listening for {HOTKEY} - select 2+ objects in PowerPoint, then press it.")
    with keyboard.GlobalHotKeys({HOTKEY: align_row}) as h:
        h.join()


if __name__ == "__main__":
    main()
