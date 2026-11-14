#!/usr/bin/env python3
"""Live monitor of the stick, with a saved log. Nothing to install (Linux).

    python3 watch_stick.py              until Ctrl+C
    python3 watch_stick.py 60           for 60 seconds

Shows every button and lever direction that reaches the PC through /dev/input/jsN. At the end it
saves logs/stick-input-<date>.txt with everything received and a summary: presses per button,
directions seen, and presses shorter than 30 ms (a wire touching GND now and then).
"""
import datetime
import glob
import os
import struct
import sys
import time

NUM_BUTTONS = 4
GHOST = 0.030         # a real press lasts more than 30 ms
FAR = 16000           # axis "fully over" (the kernel reports -32767 to 32767)
JS_BUTTON, JS_AXIS, JS_INIT = 0x01, 0x02, 0x80
DIRECTIONS = {(0, -1): "LEFT", (0, 1): "RIGHT", (1, -1): "UP", (1, 1): "DOWN"}


def find_stick():
    for js in sorted(glob.glob("/dev/input/js*")):
        with open(f"/sys/class/input/{os.path.basename(js)}/device/name") as f:
            name = f.read().strip()
        if "arduino" in name.lower() or "leonardo" in name.lower():
            return js, name
    sys.exit("The stick is not visible: plug it in with a data cable and check `ls /dev/input/js*`.")


path, name = find_stick()
duration = float(sys.argv[1]) if len(sys.argv) > 1 else None
start = time.time()
lines = []
presses = [0] * NUM_BUTTONS
ghosts = [0] * NUM_BUTTONS
pressed_at = [None] * NUM_BUTTONS
directions = set()
axes = [0, 0]


def note(text):
    line = f"{time.time() - start:7.3f} s  {text}"
    lines.append(line)
    print(line, flush=True)


print(f"{name} on {path}. Press the buttons and move the lever"
      + (f" ({duration:.0f} s)." if duration else " (Ctrl+C to stop).") + "\n")
fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
try:
    while duration is None or time.time() - start < duration:
        try:
            data = os.read(fd, 8)
        except BlockingIOError:
            time.sleep(0.005)
            continue
        ms, value, kind, num = struct.unpack("IhBB", data)
        if kind & JS_INIT:             # initial state the kernel sends on open: not a press
            if kind & ~JS_INIT == JS_AXIS and num < 2:
                axes[num] = value
            continue
        now = ms / 1000                # kernel timestamp, more precise than the read time
        if kind == JS_BUTTON and num < NUM_BUTTONS:
            if value:
                presses[num] += 1
                pressed_at[num] = now
                note(f"BUTTON {num + 1} (pin {num + 2}) pressed")
            else:
                held = now - pressed_at[num] if pressed_at[num] is not None else None
                short = held is not None and held < GHOST
                ghosts[num] += short
                note(f"BUTTON {num + 1} released" + (f" after {held * 1000:.0f} ms" if held is not None else "")
                     + ("  <- too short: loose wire?" if short else ""))
        elif kind == JS_AXIS and num < 2:
            axes[num] = value
            sign = -1 if value < -FAR else 1 if value > FAR else 0
            if sign:
                directions.add(DIRECTIONS[num, sign])
                note(f"LEVER {DIRECTIONS[num, sign]}")
            elif abs(axes[0]) < FAR and abs(axes[1]) < FAR:
                note("LEVER centre")
except KeyboardInterrupt:
    pass
finally:
    os.close(fd)

# ---------- Summary and log ----------
seconds = time.time() - start
summary = [f"Duration: {seconds:.0f} s"]
for b in range(NUM_BUTTONS):
    state = "OK" if presses[b] and not ghosts[b] else "NOT PRESSED" if not presses[b] else "GHOSTS"
    summary.append(f"Button {b + 1} (pin {b + 2}): {presses[b]} press{'' if presses[b] == 1 else 'es'}, "
                   f"{ghosts[b]} shorter than {GHOST * 1000:.0f} ms -> {state}")
missing = [d for d in DIRECTIONS.values() if d not in directions]
summary.append("Lever: " + ("all 4 directions -> OK" if not missing else "missing " + ", ".join(missing)))
all_ok = all(presses) and not any(ghosts) and not missing
summary.append("RESULT: " + ("everything arrives correctly" if all_ok else "check the marked items"))
print("\n" + "\n".join(summary))

stamp = datetime.datetime.now()
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", f"stick-input-{stamp:%Y-%m-%d-%H%M}.txt")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as g:
    g.write(f"Stick input log · {stamp:%Y-%m-%d %H:%M} · {name} ({path})\n"
            f"Written by watch_stick.py\n\n## Summary\n" + "\n".join(summary)
            + "\n\n## Everything received\n" + "\n".join(lines) + "\n")
print(f"\nSaved to {os.path.relpath(out)}")
