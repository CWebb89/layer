# AGENTS.md — layer

Standalone Quickshell app: a Moonraker control surface for Voron printers
— dashboard, GCode console, file list and viewer, history, machine control —
built in the webb-shell design language. Started as the Phase 1 port
of klip-tui; structured to fold into webb-shell as a plugin later.

## Ground truth

- **Name: `layer`.** The program, the repo and the directory are `layer`; the
  distribution name is `layer-app` — AUR, and any registry where the bare word
  is taken or unsearchable. The family is `layer` (control surface),
  `next-layer` (slicer), `LayerMind` (diagnostics), `HFW` (engine). Former names:
  `klip-shell`, `QuickKlipshell`, `klipshell`.

- Current code is authoritative. The design brief: the shell grammar in
  `src/components` (section headers, separators, sliders, list rows, detail
  pills) + matugen Material-You colors via the same 36-key MD3
  contract webb-shell consumes (`assets/matugen/layer-colors.json`,
  rendered to `~/.cache/matugen/layer-colors.json`, watched by `Colors`).
- klip-tui (the retired Rust TUI) is no longer on this machine; its harvested
  feature inventory is brain `moonraker/mainsail-feature-inventory.md`. Mainsail
  is the primary reference — layer is a Quickshell rebuild of that surface.
  The original Phase 1 scope (polled HTTP JSON-RPC service + Dashboard +
  Console) is long since passed.
- Project history — the engineering log 2026-09-20 → 2026-09-23, chronological,
  newest last — is `docs/HISTORY.md`. Grep it; it records what was believed on
  the day. Current truth is the project memory
  (`~/.pi/agent/projects-memory/layer/MEMORY.md`), not that log.

## Architecture

- `shell.qml`: `ShellRoot` hosting `MainWindow`. No logic of its own.
- `src/views/MainWindow.qml`: `FloatingWindow` (`Metrics.windowWidth/Height`),
  sidebar view switcher, header chrome, and the single `Keys` owner
  (`Keys.BeforeItem`; Enter switches views, Esc returns to Dashboard).
- `src/views/`: `Dashboard`, `Console`, `GcodeFiles`, `GcodeViewer`,
  `Heightmap`, `History`, `Layermind`, `Machine`, `SettingsPopup`,
  `LayoutPopup` (drag-to-arrange editor for the dashboard's cards).
- `src/components/`: 17 grammar components (Card, Panel, SectionHeader,
  Separator, Slider, ListRow, Gauge, Ring, Donut, Bars, Chart, TempGraphCard,
  KV, Chip, Button, Hero, ConfirmDialog) + `qmldir`.
- `src/theme/`: `Colors` (matugen MD3 roles, watched file), `Metrics`, `Type`,
  `Icons` singletons. Hardcoded palette hex belongs only in `Colors.qml`.
- `src/moonraker/MoonrakerService.qml`: polled HTTP JSON-RPC client
  (curl Process slot pool on a `Settings.pollMs` timer, Transport-agnostic
  state so a QtWebsockets swap later touches only this file).
- `src/config/`: `Settings.qml` singleton (`settings-logic.js` for the pure
  logic) and `printers.json` (printer names + Moonraker endpoints).
- `src/gcode/GcodeParse.js`: GCode parser, pure JS so `node` can test it.
- Paths: `Quickshell.shellDir` reaches checkout-relative files — today only
  `MoonrakerService`'s `src/config/printers.json`, which the printer editor
  also writes back in place. Everything else persists outside the checkout:
  settings, dashboard layout, presets and viewer state under
  `~/.local/state/layer/<store>.json`, Layermind under
  `~/.local/state/layermind/<printer>.json`. Never a fixed checkout path.

## Shell grammar (as implemented)

- Cards: solid fill (`Card` defaults to `surfaceContainer`; callers pass
  `surfaceContainerLow`/`Lowest` per context), `outlineVariant` border at
  `Metrics.cardBorderWidth` (2px), radius `Metrics.radiusLarge/Medium/Small`.
- Section headers: bold, `Colors.textTertiary` (surfaceVariantText @ 70%,
  5.6:1 against the 14.3:1 of textPrimary), `Type.sizeCaption` — not accent,
  not ALL-CAPS (`SectionHeader`).
- Separators: 1px rule, `Colors.separator` = textPrimary @ 12% alpha
  (`Separator`).
- Selection: accent text on `Colors.selectedFill` (textPrimary @ 8% fill),
  subtle border — hover 8%, pressed 22% (`ListRow` / control tokens).
- Sliders/gauges: track `Metrics.gaugeTrack` (5px) filled with
  `Colors.accent`/textPrimary, knob `Metrics.gaugeKnob` (19px), fill width and
  knob x animated 140ms OutCubic, knob hover scale 110ms (`Slider`).
- Header = solid surface, first-class chrome.

## Verification and API sources

`tools/verify.sh` is the single gate command; the individual check steps, what each one proves, and the API/doc sources for Quickshell and Moonraker live in `AGENTS-REFERENCE.md`. Load it before running checks or resolving an API question.

## Version control & rollback

Public repo: `git@github.com:CWebb89/Layer.git` (branch `main`). The local
checkout is the source of truth and git is the primary revert source.
`tools/snapshot.sh` remains a second net for risky multi-file passes — it writes
a timestamped tar of the whole checkout to
`~/.local/state/layer/snapshots/` (newest 20 kept) and prints its sha256.

```bash
./tools/snapshot.sh pre-refactor
```

One commit identity for this repo: `webbwerkx <webbwerkx@gmail.com>`, set
repo-locally (there is no machine-wide git identity).

**The repo is public, so real printer addresses never enter a tracked file.**
`src/config/printers.json` is gitignored (it is machine-local and the printer
editor writes it back in place); a fresh clone gets it from
`src/config/printers.example.json` via `install.sh`. Docs count too —
`docs/HISTORY.md`'s live-printer addresses were replaced with the example host
before the first push. Check `git check-ignore -v <path>` and grep the tracked
set before adding anything that describes the LAN.

## Instance discipline

Never more than one layer instance at a time. Every launch is preceded by
an instance check, and a second instance is a defect — not a convenience.

```fish
quickshell list -p /home/cwebb/dev/layer
quickshell kill -p /home/cwebb/dev/layer
quickshell -n -p /home/cwebb/dev/layer
```

- Always pass the absolute repo path to `list`/`kill`/`-p`. A relative `-p .`
  is only valid when cwd is the repo root, and instance lookup is by resolved
  config path — a check with the wrong path reports nothing and lets a second
  instance through.
- `-n` is a backstop, not a licence to skip the check. Run `list` first, every
  time, including for `shot app` one-shot captures.
- Never `pkill quickshell`: webb-shell runs under the same binary. Scope kills
  with `-p <dir>` so only the layer config dies.
