#!/bin/bash
# klipshell capture harness — one view per invocation, on an unused workspace.
#
# The failure this exists to prevent: launching without first focusing an empty
# workspace puts the window on whatever workspace the caller is on, so the
# capture either shows the agent's terminal or an empty workspace. Every step
# here is checked and the instance is always killed on exit.
#
# Usage: ./tools/shot-view.sh <view> <out.png> [--keep] [--wait N]
#   view   dash console files hist heightmap gcodeview machine layermind
#   --keep leave the instance running (it stays on the capture workspace)
#   --wait seconds to wait for the window before giving up (default 20)
#   --settle seconds to let the view paint and its first polls land (default 3.5)
#
# Requires: Hyprland seat, quickshell 0.3.x, shot (never grim directly).

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VIEW="${1:-}"
OUT="${2:-}"
KEEP=0
WAIT=20
SETTLE=3.5

shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --wait) WAIT="${2:-}"; shift ;;
    --settle) SETTLE="${2:-}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

VIEWS="dash console files hist heightmap gcodeview machine layermind"
case " $VIEWS " in
  *" $VIEW "*) ;;
  *) echo "usage: $0 <${VIEWS// /|}> <out.png> [--keep] [--wait N] [--settle S]" >&2; exit 2 ;;
esac
if [ -z "$OUT" ]; then
  echo "usage: $0 <${VIEWS// /|}> <out.png> [--keep] [--wait N] [--settle S]" >&2
  exit 2
fi

for bin in /usr/bin/quickshell /usr/bin/env /usr/bin/hyprctl; do
  [ -x "$bin" ] || { echo "missing $bin" >&2; exit 2; }
done
command -v shot >/dev/null || { echo "missing shot" >&2; exit 2; }
command -v python3 >/dev/null || { echo "missing python3" >&2; exit 2; }

clients() { /usr/bin/hyprctl clients -j; }

caller_ws="$(/usr/bin/hyprctl activeworkspace -j | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')"

cleanup() {
  if [ "$KEEP" -eq 0 ]; then
    /usr/bin/quickshell kill -p "$REPO" >/dev/null 2>&1
    shot restore-ws "$caller_ws" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

if /usr/bin/quickshell list -p "$REPO" 2>/dev/null | grep -q 'Instance '; then
  echo "closing the instance already running for $REPO"
  /usr/bin/quickshell kill -p "$REPO" >/dev/null 2>&1
  sleep 2
fi

ws="$(shot focus-empty)"
if ! printf '%s' "$ws" | grep -Eq '^[0-9]+$'; then
  echo "shot focus-empty did not report a workspace id: '$ws'" >&2
  exit 1
fi
echo "capture workspace: $ws (caller on $caller_ws)"

/usr/bin/hyprctl dispatch "hl.dsp.exec_cmd(\"/usr/bin/env KLIPSHELL_VIEW=$VIEW /usr/bin/quickshell -n -p $REPO\")" >/dev/null

monitor_w="$(/usr/bin/hyprctl monitors -j | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["width"])')"
monitor_h="$(/usr/bin/hyprctl monitors -j | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["height"])')"

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
    print("%dx%d" % (c["size"][0], c["size"][1]))
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

# A window that does not fit the seat cannot be captured whole.
ww="${win%x*}"; wh="${win#*x}"
if [ "$ww" -gt "$monitor_w" ] || [ "$wh" -gt "$monitor_h" ]; then
  echo "window $win exceeds the ${monitor_w}x${monitor_h} monitor — capture would clip it" >&2
  exit 1
fi

sleep "$SETTLE"
shot onws "$ws" "$OUT" || { echo "capture failed" >&2; exit 1; }

if [ ! -s "$OUT" ]; then
  echo "capture produced no bytes: $OUT" >&2
  exit 1
fi

printf 'view %s · workspace %s · window %s · %s (%s bytes)\n' \
  "$VIEW" "$ws" "$win" "$OUT" "$(stat -c %s "$OUT")"
