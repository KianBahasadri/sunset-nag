#!/usr/bin/env bash
# Install the sunset-nag systemd user service. Safe to re-run.
# Migrates away from the older auto-grayscale service if present.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/sunset-nag"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

chmod +x "$SCRIPT"
mkdir -p "$UNIT_DIR"

if [[ ! -f "$DIR/.env" && -f "$DIR/.env.example" ]]; then
    cp "$DIR/.env.example" "$DIR/.env"
fi

# ---------------------------------------------------------------------------
# Migrate away from the old auto-grayscale service.
# ---------------------------------------------------------------------------
if systemctl --user is-enabled auto-grayscale.service &>/dev/null; then
    echo "Migrating from old auto-grayscale service..."
    systemctl --user disable --now auto-grayscale.service 2>/dev/null || true
    "$DIR/auto-grayscale" off 2>/dev/null || true
    rm -f "$UNIT_DIR/auto-grayscale.service"
fi

# Clean up any legacy timer (auto-grayscale used a per-minute timer at one point).
if systemctl --user list-unit-files auto-grayscale.timer &>/dev/null; then
    systemctl --user disable --now auto-grayscale.timer 2>/dev/null || true
    rm -f "$UNIT_DIR/auto-grayscale.timer"
fi

# Remove the old auto-grayscale script (no longer used).
rm -f "$DIR/auto-grayscale"

# ---------------------------------------------------------------------------
# Install sunset-nag.
# ---------------------------------------------------------------------------

cat > "$UNIT_DIR/sunset-nag.service" <<EOF
[Unit]
Description=sunset-nag: progressive Night Light nag at sunset with snooze
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
WorkingDirectory=$DIR
ExecStart=$SCRIPT daemon
Restart=always
RestartSec=5
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus DISPLAY=:0

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now sunset-nag.service

echo
echo "Installed sunset-nag."
echo "Your screen will gently warm up after sunset and nag you with a"
echo "desktop notification every few minutes to wind down."
echo
systemctl --user --no-pager status sunset-nag.service | head -6 || true
echo
"$SCRIPT" status
