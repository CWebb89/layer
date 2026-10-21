#!/bin/bash
# klipshell capture harness — one view per invocation, on an unused workspace.
#
# The failure this exists to prevent: launching without first focusing an empty
# workspace puts the window on whatever workspace the caller is on, so the
# capture either shows the agent's terminal or an empty workspace. Every step
# here is checked and the instance is always killed on exit.
#
# Usage: ./tools/shot-view.sh <view> <out.png> [--keep] [--wait N] [--attach]
#   view   dash console files hist heightmap gcodeview machine layermind
#   --keep leave the instance running (it stays on the capture workspace)
#   --attach capture the instance that is already running (no kill, no launch,
#            no view switching — the view is wherever the live shell is)
#   --wait seconds to wait for the window before giving up (default 20)
#   --settle seconds to let the view paint and its first polls land (default 3.5)
#
# Requires: Hyprland seat, quickshell 0.3.x, shot (never grim directly).

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="${1:-}"
OUT="${2:-}"
KEEP=0
ATTACH=0
WAIT=20
SETTLE=3.5

shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --attach) ATTACH=1 ;;
    --wait) WAIT="${2:-}"; shift ;;
    --settle) SETTLE="${2:-}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

VIEWS="dash console files hist heightmap gcodeview machine layermind"
case " $VIEWS " in
  *" $VIEW "*) ;;
  *) echo "usage: $0 <${VIEWS// /|}> <out.png> [--keep|--attach] [--wait N] [--settle S]" >&2; exit 2 ;;
esac
if [ -z "$OUT" ]; then
  echo "usage: $0 <${VIEWS// /|}> <out.png> [--keep|--attach] [--wait N] [--settle S]" >&2
  exit 2
fi

for bin in /usr/bin/quickshell /usr/bin/env /usr/bin/hyprctl; do
  [ -x "$bin" ] || { echo "missing $bin" >&2; exit 2; }
done
command -v shot >/dev/null || { echo "missing shot" >&2; exit 2; }
command -v python3 >/dev/null || { echo "missing python3" >&2; exit 2; }

clients() { /usr/bin/hyprctl clients -j; }

caller_ws="$(/usr/bin/hyprctl activeworkspace -j | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')"

read -r _mon_x _mon_y monitor_w monitor_h <<<"$(/usr/bin/hyprctl monitors -j | python3 -c '
import sys, json
m = [x for x in json.load(sys.stdin) if x["focused"]][0]
print(m["x"], m["y"], m["width"], m["height"])')"

cleanup() {
  if [ "$ATTACH" -eq 0 ] && [ "$KEEP" -eq 0 ]; then
    /usr/bin/quickshell kill -p "$REPO" >/dev/null 2>&1
  fi
  shot restore-ws "$caller_ws" >/dev/null 2>&1
}
trap cleanup EXIT

if [ "$ATTACH" -eq 1 ]; then
  if ! /usr/bin/quickshell list -p "$REPO" 2>/dev/null | grep -q 'Instance '; then
    echo "--attach: no instance is running for $REPO" >&2
    exit 1
  fi
  win="$(clients | python3 -c '
import sys, json
found = [c for c in json.load(sys.stdin)
         if c.get("class") == "org.quickshell" and "klipshell" in c.get("title", "")]
if len(found) > 1:
    print("MULTIPLE")
elif found:
    c = found[0]
    print("%s %d,%d %dx%d" % (c["address"], c["at"][0], c["at"][1],
                              c["size"][0], c["size"][1]))')"
  ws="(attached)"
else
  if /usr/bin/quickshell list -p "$REPO" 2>/dev/null | grep -q 'Instance '; then
    echo "closing the instance already running for $REPO"
    /usr/bin/quickshell kill -p "$REPO" >/dev/null 2>&1
    sleep 2
  fi

# Pick a workspace with nothing on it, and never the caller's if it holds a window:
# `shot focus-empty` trusts Hyprland's workspace list, which still contains
# workspaces that exist but are empty — that is fine — but it also returns the
# caller's own workspace when nothing is on it, which is how a capture ended up
# containing the caller's terminal. Choose from the client list, then verify.
ws="$(clients | python3 -c '
import sys, json
taken = {c["workspace"]["id"] for c in json.load(sys.stdin)}
i = 1
while i in taken:
    i += 1
print(i)')"
/usr/bin/hyprctl dispatch "hl.dsp.focus({workspace=\"$ws\"})" >/dev/null
sleep 0.4
occupied="$(clients | python3 -c '
import sys, json
ws = int(sys.argv[1])
print(sum(1 for c in json.load(sys.stdin) if c["workspace"]["id"] == ws))' "$ws")"
if [ "$occupied" != "0" ]; then
  echo "workspace $ws is not empty ($occupied window(s)) — refusing to launch there" >&2
  exit 1
fi
echo "capture workspace: $ws (caller on $caller_ws)"

/usr/bin/hyprctl dispatch "hl.dsp.exec_cmd(\"/usr/bin/env KLIPSHELL_VIEW=$VIEW /usr/bin/quickshell -n -p $REPO\")" >/dev/null

win=""
deadline=$(( $(date +%s) + WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  win="$(clients | python3 -c '
import sys, json
ws = int(sys.argv[1])
found = [c for c in json.load(sys.stdin)
         if c.get("class") == "org.quickshell"
         and c["workspace"]["id"] == ws
         and "klipshell" in c.get("title", "")]
if len(found) > 1:
    print("MULTIPLE")
elif found:
    c = found[0]
    print("%s %d,%d %dx%d" % (c["address"], c["at"][0], c["at"][1],
                              c["size"][0], c["size"][1]))
' "$ws")"
  [ -n "$win" ] && break
  sleep 0.5
done

case "$win" in
  "")
    echo "no klipshell window appeared on workspace $ws within ${WAIT}s" >&2
    exit 1 ;;
  MULTIPLE)
    echo "more than one klipshell window on workspace $ws — instance discipline broken" >&2
    exit 1 ;;
esac
fi

read -r w_addr w_at w_size <<<"$win"
ww="${w_size%x*}"; wh="${w_size#*x}"
wx="${w_at%,*}"; wy="${w_at#*,}"
if [ "$ww" -gt "$monitor_w" ] || [ "$wh" -gt "$monitor_h" ]; then
  echo "window ${ww}x${wh} exceeds the ${monitor_w}x${monitor_h} monitor — capture would clip it" >&2
  exit 1
fi

# Capture the window, not the monitor: the shell is smaller than the seat, so a
# full-output grab drags in the bar and the wallpaper and is not "the window".
# grim refuses -o and -g together, which is why `shot onws` cannot crop — so
# focus the window on the capture workspace and let `shot window` do the crop.
/usr/bin/hyprctl dispatch "hl.dsp.focus({window=\"address:$w_addr\"})" >/dev/null
active="$(/usr/bin/hyprctl activewindow -j | python3 -c 'import sys,json; print(json.load(sys.stdin).get("address", ""))')"
if [ "$active" != "$w_addr" ]; then
  echo "could not focus the klipshell window ($w_addr); active is '$active'" >&2
  exit 1
fi

sleep "$SETTLE"

# Focus is not sticky: verify the window is still the active one at capture time,
# and re-take focus once if something else grabbed it. `shot window` captures
# whatever is focused, so a stale focus silently yields a screenshot of the
# caller's terminal instead of the shell.
for attempt in 1 2; do
  active="$(/usr/bin/hyprctl activewindow -j | python3 -c 'import sys,json; print(json.load(sys.stdin).get("address", ""))')"
  [ "$active" = "$w_addr" ] && break
  [ "$attempt" = 2 ] && { echo "lost focus to '$active' before capture" >&2; exit 1; }
  /usr/bin/hyprctl dispatch "hl.dsp.focus({window=\"address:$w_addr\"})" >/dev/null
  sleep 1
done

shot window "$OUT" || { echo "capture failed" >&2; exit 1; }

# A capture that is not the window's size means something else was grabbed.
read -r png_w png_h <<<"$(python3 - "$OUT" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    head = f.read(24)
print(*struct.unpack('>II', head[16:24]))
PY
)"
if [ "$png_w" != "$ww" ] || [ "$png_h" != "$wh" ]; then
  echo "capture is ${png_w}x${png_h} but the window is ${ww}x${wh} — wrong window captured" >&2
  exit 1
fi

if [ ! -s "$OUT" ]; then
  echo "capture produced no bytes: $OUT" >&2
  exit 1
fi

printf 'view %s · workspace %s · window %sx%s at %s,%s · %s (%s bytes)\n' \
  "$VIEW" "$ws" "$png_w" "$png_h" "$wx" "$wy" "$OUT" "$(stat -c %s "$OUT")"
