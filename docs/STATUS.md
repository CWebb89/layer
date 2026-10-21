# klipshell status — 2026-10-21

Where the project actually is, in plain language, checked against the Voron V2.4
while it was powered on. Everything under "verified" was exercised against the
live printer from `10.0.0.22:7125` on this date. Everything under "unverified"
has not been run against hardware yet and should not be described as working.

## What klipshell is

A desktop control panel for the Vorons — the Mainsail screen rebuilt as a
native app instead of a browser tab. One window, eight views: Dashboard,
Console, G-Code Files, History, Heightmap, GCode Viewer, Machine, Layermind.
It reads from Moonraker (the small web service that sits on each printer) and
sends G-code back through it. It does not replace anything on the printer; it
is another client, the same way Mainsail and Orca are clients.

## How it talks to the printer

It asks Moonraker for a status report every 2 seconds over plain HTTP, and
Moonraker answers with JSON. That is what "polled HTTP JSON-RPC" means: no
permanent connection, a question every two seconds, an answer each time.

The alternative is a websocket — one permanent connection that pushes changes
the instant they happen. It is faster and cheaper for the printer, and it is
what Mainsail uses. klipshell was built with polling first because it needs no
extra component and is easy to reason about; the transport lives in one file
(`src/moonraker/MoonrakerService.qml`) specifically so swapping to a websocket
later touches nothing else. Nothing about the UI depends on which one is used.

The cost of polling: eight parallel `curl` calls per tick, each capped at five
seconds, eight slots total. When every slot is busy a request used to be thrown
away silently — see the fixed-latency defect below.

## Verified working today (live V2.4)

| Area | What was checked | Result |
|---|---|---|
| Connection | API reachable without a key, live data instead of demo fixtures | ok |
| Dashboard | Temps, print state, file list, console mirror, jog controls, presets | ok |
| Console | Sent `M115`, the command and its reply appeared | ok |
| G-Code Files | 41 files, sizes, dates, thumbnails, slicer metadata, print/total time | ok |
| History | 968 jobs, 1127 h 46 m printed, donut, bar chart, 40 recent rows | ok |
| Heightmap | Live 25×25 mesh from the saved `default` profile, range −0.008…+0.072 mm | ok |
| GCode Viewer | 3D grid renders, empty state is explicit | ok (no file loaded yet) |
| Machine | System info, MCU loads, config files, endstops, update manager | ok |
| Layermind | Missing-snapshot diagnostic names the exact expected path | ok (needs its daemon) |

Endstop state, update-manager state and bed mesh are read from Klipper live, not
from fixtures. Endstops read X open, Y triggered, Z open, which matches the
toolhead sitting at Y minimum.

## Fixed today

1. **A view opened on its empty state.** Data was only fetched when you switched
   *to* a view, so G-Code Files read "no gcode files on the printer" and History
   read "0 of 0 jobs" until you left and came back. The view the shell starts on
   now loads itself.
2. **A busy moment silently lost a request.** Eight request slots, and anything
   that could not get one was dropped forever — which is what produced the empty
   Files and History above and the "printer unreachable" text on the Machine
   card. Dropped requests now queue and run when a slot frees.
3. **The temperature graph had no scale.** It drew a line and nothing else, so a
   flat 25 °C standby line sat in empty space with no way to read it. It now has
   grid rules and labelled values (5°/15°/25°/35°/45°).
4. **PAUSE and CANCEL were live in STANDBY.** They are now only active while a
   job is actually running or paused.
5. **Screenshots were unreliable.** Captures now go through
   `tools/shot-view.sh <view> <out.png>`, which uses an empty workspace, waits
   for the window, refuses to capture anything but the window, and verifies the
   image is the window's size. Views are selected with `KLIPSHELL_VIEW=<id>`
   instead of editing source.

## Still wrong, in priority order

1. **The bottom of the screen is cut off.** klipshell asks for a 1900×1060
   window; this seat gives it 1900×1022 because the Hyprland bar and gaps take
   the rest. Views that lay out a fixed stack of cards (Machine, the Console
   input row, the bottom of the Dashboard) overflow by roughly 38 px and the
   last row is sliced. This is why the Console's send field looks like a thin
   strip with no button. It needs a decision: shrink the design height to what
   the seat actually gives, or make dense views scroll. Not guessed at.
2. **Loading states lie.** The Machine card says "no components reported
   (printer unreachable or updater disabled)" while it is simply still waiting;
   INVALID update rows show `?` instead of why they are invalid.
3. **Heightmap shows nothing when Klipper has no mesh loaded**, even though
   saved profiles are listed. Clicking a profile should load it. Currently the
   list is there but the view stays blank until something else loads a mesh.
4. **Non-ASCII file names render as boxes** (`obj_13□□□.step_PLA_3h57m.gcode`).
   The font in use has no CJK glyphs; the files themselves are fine.
5. **26 qmllint warnings**, all the same block-scoped `var` style issue. No
   behavioural effect; not worth touching until something else forces edits in
   those files.

## Unverified — needs a print, not just a printer

Nothing involving a running job has been tested against hardware:

- Start / pause / resume / cancel from the Dashboard, and object exclusion.
- Jog buttons, HOME/QGL macros, heater targets, Z-offset babystep.
- `SAVE Z (ENDSTOP/PROBE)` → `SAVE_CONFIG` (it now waits for Klipper to have a
  pending config change, which was the last session's fix, still unproven live).
- Upload from Orca into the shell's file list, delete, rename.
- Update Manager's CHECK / UPDATE buttons.
- GCode Viewer loading a real file (local or from the printer).
- Settings, printer editor, and the LAYOUT popup's drag-to-arrange.

## About the GitHub issues

They are older than the code. Drag-to-reorder was replaced by the LAYOUT popup,
so anything about dragging dashboard cards no longer describes the shell. They
should be closed and replaced by the list above, which is measured rather than
remembered.

## What to do next

1. **Decide the window height question** (item 1 above) — it is the only defect
   that touches every view, and it is a one-line change plus a check of three
   views.
2. **Load a print and drive it**: start, pause, resume, exclude an object,
   cancel — plus the Z-offset save path. That closes the entire "unverified"
   list above in one session and is the last thing standing between klipshell
   and a web front end.
3. Then Mainsail parity items that are genuinely missing: the job queue
   (`server.job_queue.*` never appears in the codebase), pause-at-layer,
   reprint, and printer power control if the Vorons use it.
4. Job queue and power devices are self-contained views; the queue is
   Mainsail's own priority-one feature and the natural next build.

## How to check it yourself

```bash
./tools/verify.sh                       # static checks, 6/6 today
./tools/shot-view.sh machine /tmp/m.png # screenshot one view, live or not
quickshell -n -p /home/cwebb/dev/klipshell
```
