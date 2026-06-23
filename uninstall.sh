#!/usr/bin/env bash
# Remove the auto-grayscale systemd user units and return the screen to color.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

systemctl --user disable --now auto-grayscale.service 2>/dev/null || true
systemctl --user disable --now auto-grayscale.timer 2>/dev/null || true
rm -f "$UNIT_DIR/auto-grayscale.service" \
      "$UNIT_DIR/auto-grayscale.timer" \
      "$UNIT_DIR/timers.target.wants/auto-grayscale.timer"
systemctl --user daemon-reload

# Make sure we don't leave the screen stuck in grayscale.
"$DIR/auto-grayscale" off || true

echo "Uninstalled. Grayscale turned off."
