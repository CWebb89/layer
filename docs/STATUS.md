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

## Still wrong, in priority order

1. **klipshell launches tiled** if the target workspace already has a window —
   Hyprland tiles a 1900-wide shell into half the screen and the layout is
   unusable at 948 px. It needs a window rule (`float`, `size`) for
   `class:^(org.quickshell)$,title:^(klipshell.*)`. Not added: that is a change
   to `~/.config/hypr`, not to this repo.
2. **Layer count and object exclusion are unavailable for this file.** Klipper
   reports `current_layer: null` and an empty `exclude_object.objects` because
   the slicer emitted no object labels. Not a shell bug — Orca needs
   "Label objects" on — but the shell should say "no layer data in this file"
   rather than `0/0`.
3. **The window is 38 px taller than the design target** (asks 1900×1060, this
   seat grants 1900×1022 with the bar). Pages are Flickables so nothing is
   unreachable; the last row just needs a scroll the design assumed away.
4. **Chart ticks land on odd values** (4°/62°/119°/177°/234°) because ticks are
   derived from the data range instead of a fixed 5°/10° grid.
5. **INVALID update rows show `?`** instead of the reason Moonraker returns.
6. **26 qmllint warnings**, all the same block-scoped `var` style issue. No
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

1. A window rule so the shell is always floating and correctly sized on launch
   (item 1 above) — one small edit to `~/.config/hypr`.
2. Finish the untested actions in a second pass, ideally on a short sacrificial
   file: cancel, exclude (with a labelled file), jog, then the Z-offset save path
   on its own.
3. Then Mainsail parity: the job queue (`server.job_queue.*` appears nowhere in
   the codebase), pause-at-layer, reprint, power devices.
4. The web front end after that, once this list is empty.

## How to check it yourself

```bash
./tools/verify.sh                        # static checks, 8/8 today
./tools/shot-view.sh machine /tmp/m.png  # one view, own instance
./tools/shot-view.sh dash /tmp/d.png --attach   # capture the running shell
quickshell ipc call klipshell status
quickshell -n -p /home/cwebb/dev/klipshell
```
