#!/bin/bash
# layer install script — Moonraker dashboard/console for Quickshell.
# Writes only per-user config: matugen template registration, and the
# machine-local printer list on a fresh clone.
# Idempotent; safe to re-run. No root, no package installs.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

echo "Installing layer from $REPO"

for tool in quickshell curl; do
  command -v "$tool" >/dev/null 2>&1 || echo "NOTE — missing tool: $tool"
done

# ── 1. matugen template (additive; never rewrites the rest of the config) ─
MGCONF="$HOME/.config/matugen/config.toml"
MGDIR="$HOME/.config/matugen"
MAT_TEMPLATE="$REPO/assets/matugen/layer-colors.json"

if command -v matugen >/dev/null 2>&1; then
  mkdir -p "$MGDIR/templates"
  cp -n "$MAT_TEMPLATE" "$MGDIR/templates/layer-colors.json"
  if ! grep -q "layer-colors.json" "$MGCONF" 2>/dev/null; then
    cp "$MGCONF" "$MGCONF.layer.bak" 2>/dev/null || true
    cat >> "$MGCONF" <<EOF

# added by layer install.sh
[templates.layer]
input_path = '~/.config/matugen/templates/layer-colors.json'
output_path = '~/.cache/matugen/layer-colors.json'
EOF
    echo "  registered matugen template (backup: $MGCONF.layer.bak)"
  fi
else
  echo "  matugen not found — colors won't update; edit src/theme/Colors.qml defaults"
fi

# ── 2. Printer list (machine-local; gitignored, never committed) ─────────
PRINTERS="$REPO/src/config/printers.json"
PRINTERS_EXAMPLE="$REPO/src/config/printers.example.json"

if [ ! -f "$PRINTERS" ]; then
  cp "$PRINTERS_EXAMPLE" "$PRINTERS"
  echo "  seeded src/config/printers.json — replace the example hosts with your own"
else
  echo "  src/config/printers.json exists — left alone"
fi

echo "Done."