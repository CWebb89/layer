# klipshell status — 2026-10-21, live print pass

Where the project actually is, in plain language. Everything under "verified"
was exercised against the Voron V2.4 (`10.0.0.22`) on this date, most of it
while a real job — `Handy+Halter+3cm_PLA_1h47m.gcode`, 591 layers — was running.

## What klipshell is

A desktop control panel for the Vorons — the Mainsail screen rebuilt as a
native app instead of a browser tab. One window, eight views: Dashboard,
Console, G-Code Files, History, Heightmap, GCode Viewer, Machine, Layermind.
It reads from Moonraker (the small web service on each printer) and sends
G-code back through it. It replaces nothing on the printer; it is another
client, the same way Mainsail and Orca are clients.

## How it talks to the printer

It asks Moonraker for a status report every 2 seconds over plain HTTP, and
Moonraker answers with JSON. That is "polled HTTP JSON-RPC": no permanent
connection, a question every two seconds, an answer each time.

The alternative is a websocket — one permanent connection that pushes changes
the instant they happen. Faster, and cheaper for the printer; it is what
Mainsail uses. klipshell was built with polling first because it needs no extra
component. The transport lives in one file (`src/moonraker/MoonrakerService.qml`)
so a websocket swap touches nothing else; nothing in the UI depends on which is
used.

## Driving the shell without clicking

`quickshell ipc call klipshell <fn>` now reaches every action the views perform,
through the same functions a click calls:

```text
quickshell ipc call klipshell status
quickshell ipc call klipshell view machine
quickshell ipc call klipshell preheat heater_bed 65
quickshell ipc call klipshell start "file.gcode"
quickshell ipc call klipshell pause | resume | cancel
quickshell ipc call klipshell jog X 10 50    zAdjust 0.005    saveZ endstop
```

`status` returns one line: printer, connection, state, file, progress, layer,
both heater pairs, Z, Z-offset, pending config changes, excluded objects. This
is how the shell is verified without synthetic clicks, and it is the seam an
external helper (an Orca device tab, a keybind) would use later.

## Verified working (live V2.4, this pass)

| Area | What was checked | Result |
| --- | --- | --- |
| Print control | start, pause, resume from the shell | ok |
| Preheat | `SET_HEATER_TEMPERATURE` for extruder and bed, both held | ok |
| Console send | `M115` echoed to Klipper, reply shown | ok |
| Live values | speed/flow/fan factor writes read back from Klipper | ok |
| Babystep | `SET_GCODE_OFFSET Z_ADJUST` both directions, returns exactly | ok |
| Job display | PRINTING/PAUSED state, progress, elapsed, time left | ok |
| GCode Viewer | LOAD CURRENT parsed 170 228 lines → 113 371 segments, 591 layers, 3D render, scrubber | ok |
| Heightmap | 25×25 mesh `default`, range −0.008…+0.072 mm, variance 0.079 | ok |
| Machine | host + 3 MCUs, loads, endstops, config browser, update manager | ok |
| Files / History | 41 files with slicer metadata; 968 jobs, 1127 h printed | ok |
| Console view | live transcript, including the shell's own sends | ok |
| Layermind | missing-snapshot diagnostic names the expected path | ok (needs its daemon) |

## Fixed during this pass

1. **Progress read 0.0% while paused.** The card zeroed progress unless the
   state was exactly `printing`, so pausing made the job look unstarted.
2. **The job being printed still said NOT PRINTED** in the file list —
   `fileStateOf` only consulted history, which has no entry until a job ends.
3. **A busy moment silently dropped a request** (from the earlier offline pass):
   eight request slots, anything that could not get one discarded forever. That
   was behind "no gcode files on the printer" and "0 of 0 jobs". Now queued.
4. **Views only fetched on switch**, so the view the shell opened on stayed
   empty until you left and came back.
5. **The temperature chart had no scale.** Grid rules and labelled values added.
6. **Hidden legend chips were invisible** (`outlineVariant` on dark), so the
   bed and sensor series could not be found, let alone toggled.
7. **The viewer's Segments row read `undefined → undefined`** — a var-object
   binding that never re-evaluated after the parse filled the job in.
8. **`fan.power` does not exist** on Klipper's `fan` object (it is `fan.speed`),
   so that field was always zero.
9. **PAUSE/CANCEL were clickable in STANDBY**; gated on the live state now.
10. **Screenshots**: `tools/shot-view.sh <view> <out> [--attach]`. It refuses to
    capture anything but the window, verifies focus at shutter time, checks the
    PNG against the window size, and `--attach` captures a running instance
    instead of killing it.

## Second pass — the print finished, then nine more fixes

1. **Z-offset saved to config.** `Z_OFFSET_APPLY_PROBE` staged it and
    `SAVE_CONFIG` committed it while idle: `[cartographer scan_model default]`
    now carries `z_offset = -0.2` (the +0.200 babystep, inverted by the probe
    model's convention). Klipper restarted clean and the offset reads 0.000.
2. **The Z-OFFSET readout shows 0.000**, not 0.0 — three decimals, readout
    widened from 96 to 108 px so the longer number cannot touch the ±0.005
    buttons.
3. **The file list now reads COMPLETED.** Two causes: the state was read
    through `data`, a plain object mutated in place so no binding ever
    re-evaluated, and history was only fetched when a view opened, so a job that
    finished while the shell was up never entered the list. History is refetched
    when Klipper reports the job ended.
4. **The STATUS card shows the printing file**, right-aligned beside the
    printer name, elided from the middle, only while a job is running.
5. **The MACHINE card no longer says "Preparing to Print..."** — that was a
    stale `M117` Klipper keeps in `display_status` forever. It shows only while
    a job is active, and the card's height is computed from its row count
    instead of the hardcoded 196 that clipped the last row.
6. **Chart rules land on round degrees** (10/20/30/40/50/60): the scale snaps
    to a 1/2/5×10ⁿ step instead of slicing the raw range into quarters.
7. **INVALID update rows explain themselves**: "invalid: cannot reach
    github.com" from Moonraker's `git_messages`, not `?`.
8. **The GCode Viewer stopped eating the CPU.** With a file loaded a repaint
    cost ~250 ms because every one of 113 000 segments allocated two arrays and
    called three functions through the projection, and a poll repainted twice a
    second whether or not anything moved. The projection is inlined (68 ms per
    paint) and a poll only repaints when the scrub position changed: 5 paints to
    load a file, then none until you touch the camera.
9. **The window floats.** A windowrule in `~/.config/hypr/modules/windowrules.lua`
    matches `class:^(org.quickshell)$` — matching on the title does not work,
    Quickshell sets the title after the window is mapped — and sizes it
    1900×1020. Every other app tiles as before.

## Still wrong, in priority order

1. **The dashboard's columns are taller than the window** (right column:
   400 + 448 + 199 + gaps = 1071 px for ~950 available), so the MACHINE card is
   sliced by the fold. The page scrolls and the console card already absorbs
   slack, but nothing pulls the taller column back to fit.
2. **A poll costs ~0.9 s of CPU.** The shell sits at 42-45% CPU while idle and
   at 3% with the poll timer stopped, on a window that is not even visible. The
   cause is the transport: every request is a `bash -c curl` process, ~10 per
   poll, so the spinner is process spawning, not parsing — a probe spawning
   `true` instead of `curl` still burned 39%. The fix is `XMLHttpRequest` (a QML
   JS builtin) inside `MoonrakerService`, the transport-agnostic swap the
   architecture was written for.
3. **Layer count and object exclusion are unavailable for this file.** Klipper
   reports `current_layer: null` and an empty `exclude_object.objects` because
   the slicer emitted no object labels — Orca needs "Label objects" on. The IPC
   `status` line now prints `layer=-` instead of `0/0`.
4. **26 qmllint warnings**, all the same block-scoped `var` style issue. No
   behavioural effect.

## Unverified

- **Cancel** — not tested; it would have ended the running job.
- **Object exclusion** — impossible on this file (no labels).
- **SAVE Z (ENDSTOP/PROBE) → SAVE_CONFIG** — stages a real `printer.cfg` edit and
  restarts Klipper, which cannot happen mid-print. Needs a deliberate session.
- **Jog / HOME / QGL buttons** — moving the toolhead mid-print was not an option.
- **Orca upload through the shell**, file delete/rename, update-manager actions,
  Settings and the printer editor, the LAYOUT popup.

## About the GitHub issues

They are older than the code. Drag-to-reorder was replaced by the LAYOUT popup,
so anything about dragging dashboard cards no longer describes the shell. Close
them and treat this file as the list.

## What to do next

1. Decide the dashboard column fit (item 1 above): trim the flexible cards, or
   make the scroll bar obvious.
2. Replace the curl-per-request transport with `XMLHttpRequest` (item 2) — the
   single biggest performance win available, ~45% CPU down to single digits,
   and it touches `MoonrakerService.qml` only.
3. Finish the untested actions on a short sacrificial file: cancel, exclude
   (with a labelled file), jog.
4. Then Mainsail parity: the job queue (`server.job_queue.*` appears nowhere in
   the codebase), pause-at-layer, reprint, power devices.
5. The web front end after that, once this list is empty.

## How to check it yourself

```bash
./tools/verify.sh                        # static checks, 8/8 today
./tools/shot-view.sh machine /tmp/m.png  # one view, own instance
./tools/shot-view.sh dash /tmp/d.png --attach   # capture the running shell
quickshell ipc call klipshell status
quickshell -n -p /home/cwebb/dev/klipshell
```
