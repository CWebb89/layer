---
name: quickshell-dev
description: Live UI verification loop for klipshell (and other Quickshell shells on this machine). Use when launching or verifying the shell on a Hyprland seat, capturing dashboard/console screenshots, reviewing Quickshell UI changes, or grading a shell against the shell grammar in AGENTS.md. Encodes the launch → capture → drive → vision-review → grade loop; static checks alone (qmllint) are never enough before calling a UI change done.
---

# quickshell-dev — live UI verification loop

`quickshell -p .` is a nonterminating GUI run on a Hyprland seat. This loop
makes UI verification repeatable: launch isolated → capture → review → grade →
iterate. Run it before calling a UI change done (qmllint passing is the gate,
not the finish line).

## Machine facts (verified 2026-09-22, quickshell 0.3.1)

- Launch: `quickshell -n -p <abs path>` — `-n/--no-duplicate` exits if the same
  config is already running (double-launch guard).
- Instance control: `quickshell list -p <dir>` (add `--json` for scripting),
  `quickshell kill -p <dir>` — no bare `pkill quickshell` (would take down the
  user's main shell session too). Kills/launches target the selected config.
- No verified `ipc call reload` method on this build, but the binary carries
  internal reload machinery (`Reloadable`, `PostReloadHook`). Iteration default
  is kill + relaunch (sub-second); if a live instance survives a QML save and
  picks up the change, rely on that, but verify per instance with
  `quickshell list -p <dir>` before trusting it.
- Capture is owned by `shot` (never grim/slurp directly). `shot app`, `shot
  onws`, `shot popup` all land their target on a fresh unused workspace and
  restore the caller's workspace. The agent terminal is never on the capture
  workspace.
- Hyprland dispatches through the Lua bridge: `hyprctl dispatch 'hl.dsp.focus({workspace="N"})'`,
  `'hl.dsp.exec_cmd("/abs/path/cmd")'` (absolute paths only). See the
  hyprland-lua skill for the full surface.
- The default session model (0731, text-only) cannot view images. When the UI
  needs to be SEEN, stage a capture with `/ss` — vision-gate routes it to the
  image-capable model.

## The loop

### 0. Static gate (blocking)

```bash
bash -O globstar -c 'qmllint --silent shell.qml src/**/*.qml'
bash -n install.sh
```

Syntax errors → fix before launching. New qmllint errors are always a blocker.

### 1. Launch

**One instance, always.** Before any launch — including `shot app` one-shots:

```bash
quickshell list -p /home/cwebb/dev/klipshell   # lists running instances
quickshell kill -p /home/cwebb/dev/klipshell   # close it before opening another
```

Never open a second instance: not for a quick shot, not to "compare", not
while one is still starting. A second instance is a defect. `-n` is a backstop
for a missed check, never a licence to skip it, and it only catches launches
that pass the same resolved config path.

**Use the harness — it is the whole launch step:**

```bash
./tools/shot-view.sh <view> <out.png> [--keep] [--wait N] [--settle S]
```

Views: `dash console files hist heightmap gcodeview machine layermind`. It closes any
instance for the repo, focuses an unused workspace, launches with `KLIPSHELL_VIEW=<view>`,
waits until a klipshell window is actually on that workspace, refuses to continue if two
windows are there or if the window does not fit the seat, settles (`--settle`, default
3.5 s, enough for the first polls and demo entry), captures with `shot onws`, kills the
instance and restores the caller's workspace. `--keep` leaves it running for driving.

**Views are chosen with `KLIPSHELL_VIEW`, not synthetic input.** `MainWindow.activeView`
reads that env var at startup (unknown value → dashboard). Never temp-edit the file to
capture a view: a save reloads the live instance mid-capture, which is how a
`TypeError … 'length' of undefined` got into a log during a half-applied edit.

**The failure this replaced:** `exec_cmd` launches on whatever workspace is focused, so
without a preceding `shot focus-empty` the window lands on the caller's workspace and
`shot onws <id>` either captures an empty workspace or the user's browser. Re-check the
client's workspace with `hyprctl clients -j` instead of trusting the launch.

### 2. Drive

- View switching is keyboard-driven in normal use. For captures, set
  `KLIPSHELL_VIEW=<id>` at launch (`tools/shot-view.sh` does it) — there is no
  wtype/ydotool on this machine, so never try to press the shell's keys.
- Popups/panels are layer-surface popups: `shot popup <out.png>` after asking
  the user to open the target (popup capture needs the popup already on screen).

### 3. See it

- Text-only model: stage the capture with `/ss` for the vision model.
- Regression shots live in `~/Pictures/screenshots` (pi-screenshots-picker
  source) so they're re-reviewable.

### 4. Grade against the shell grammar (AGENTS.md)

Check each visible element against the contract, not taste:

- Cards: surfaceContainerLow fill, 1px outlineVariant border, radiusLarge/Medium/Small.
- Section headers: bold, dimmed (≈1.4× darker than textPrimary), caption size — not accent, not ALL-CAPS.
- Separators: 1px rule at textPrimary 12% alpha.
- Selection: accent text on textPrimary 8% fill, subtle border.
- Sliders/gauges: track 11% of control height, textPrimary fill, knob 38%, 140ms OutCubic width animation.
- Header: solid surface, first-class chrome.
- Colors come from matugen MD3 roles via the 33-key contract in `src/theme/Colors.qml` — hardcoded hex anywhere else is a defect.

Anything off → file it against the grammar, fix, iterate.

### 5. Iterate

```bash
quickshell kill -p /home/cwebb/dev/klipshell
# edit QML...
quickshell -n -p /home/cwebb/dev/klipshell &   # or relaunch via exec_cmd to keep the ws clean
```

`shot app` mode auto-closes what it opened — no cleanup needed. Interactive
mode: `quickshell kill -p <dir>` before relaunching to keep exactly one
instance (see `quickshell list -p <dir>`).

## Gotchas

- Plain `hyprctl dispatch workspace N` is a no-op on this machine (Lua bridge).
- Relative `-p .` breaks when the agent's cwd isn't the repo root — always use
  the absolute path.
- `shot popup` needs the popup already open; it captures the topmost layer
  surface on the current monitor.
- Don't kill by PID scoped to `quickshell` alone — the user's real shell
  (webb-shell or another config) may be running under the same binary.
- This file lives in klipshell's `.pi/skills/`; if another Quickshell project
  wants the same loop, copy it to `~/.pi/agent/skills/quickshell-dev/SKILL.md`.