# AGENTS-REFERENCE.md — klipshell

Durable reference moved out of `AGENTS.md` on 2026-10-05. `AGENTS.md` auto-loads in
every session in this repo; this file does not. Load it when a turn touches one of
the sections below.

## Verification

```bash
./tools/verify.sh
```

`tools/verify.sh` is the whole gate in one command: it runs every check below,
reports PASS / FAIL / SKIP per step, exits 1 on any blocking failure, and ends
with the qmllint warnings that `--silent` hides (advisory — they do not fail the
gate). Individual steps, when you need just one:

```bash
bash -O globstar -c 'qmllint --silent shell.qml src/**/*.qml'
bash -n install.sh
bash -n launch.sh
node src/gcode/test-parse.js
node src/config/test-settings.js
python3 tools/check-icons.py
python3 tools/test-transport.py
```

`--silent` plus the repo's `.qmllint.ini` (which disables the `UncreatableType`
and `MissingProperty` warnings) means the qmllint gate reports errors only — a
clean run says nothing about warnings. `tools/verify.sh` therefore always runs a
second, non-silent pass and prints it.

`tools/check-icons.py` validates the `Icons` singleton's glyphs.
`src/config/test-settings.js` covers the settings store's pure logic in
`settings-logic.js`.

`tools/test-transport.py` boots the app against a stub Moonraker on a loopback
port and asserts the JSON-RPC result envelope handling (POST replies are wrapped
in `{"result": …}`), path/quote escaping, and the signals the views listen to.
It needs a Hyprland seat; without one it exits 2 and skips.

`quickshell -p .` is a nonterminating visual run on a Hyprland seat — not a
pass/fail check; runtime validation needs a live session.

## API sources

Installed `.qmltypes` first (`/usr/lib/qt6/qml/Quickshell`), webb-shell repo
patterns, quickshell.org docs matching version 0.3.1, doc.qt.io/qt-6.

Moonraker behaviour: the brain maps `moonraker/mainsail-store-map.md` (WS
notification routing / HTTP poll equivalents) and
`moonraker/mainsail-feature-inventory.md` (Mainsail surface → the Moonraker
object each needs) first, then the Mainsail checkout at `mainsail/` (branch
`develop`) — `src/store/*` for API calls, `src/components/gcodeviewer/*` for the
renderer GcodeViewer mirrors, `src/components/panels/*` for panel layouts. That
checkout is gitignored and excluded from `tools/snapshot.sh` (nested read-only
upstream clone); keep it fast-forwarded with `git -C mainsail pull --ff-only`.
