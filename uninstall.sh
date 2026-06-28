#!/usr/bin/env bash
# Remove the sunset-nag systemd user unit and restore original Night Light settings.
# Also cleans up any legacy auto-grayscale units.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# Stop and remove sunset-nag.
systemctl --user disable --now sunset-nag.service 2>/dev/null || true
rm -f "$UNIT_DIR/sunset-nag.service"

# Best-effort restore of Night Light via the saved state.
if [[ -x "$DIR/sunset-nag" ]]; then
    "$DIR/sunset-nag" off 2>/dev/null || true
fi

# Legacy cleanup: any leftover auto-grayscale units.
systemctl --user disable --now auto-grayscale.service 2>/dev/null || true
systemctl --user disable --now auto-grayscale.timer  2>/dev/null || true
rm -f "$UNIT_DIR/auto-grayscale.service" \
      "$UNIT_DIR/auto-grayscale.timer"  \
      "$UNIT_DIR/timers.target.wants/auto-grayscale.timer"

# Remove the state file (no longer needed).
rm -f "$DIR/.state.json"

systemctl --user daemon-reload

echo "Uninstalled. Night Light restored to its previous state."
