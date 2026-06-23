#!/usr/bin/env bash
# Install the auto-grayscale systemd user service. Safe to re-run.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/auto-grayscale"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

chmod +x "$SCRIPT"
mkdir -p "$UNIT_DIR"

# Migrate away from the old per-minute timer if it is installed.
if systemctl --user list-unit-files auto-grayscale.timer >/dev/null 2>&1; then
    systemctl --user disable --now auto-grayscale.timer 2>/dev/null || true
    rm -f "$UNIT_DIR/auto-grayscale.timer"
fi

cat > "$UNIT_DIR/auto-grayscale.service" <<EOF
[Unit]
Description=auto-grayscale: fade screen to grayscale around sunset/sunrise
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$SCRIPT daemon
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now auto-grayscale.service

echo
echo "Installed. The screen will fade to grayscale around sunset and back at sunrise."
echo
systemctl --user --no-pager status auto-grayscale.service | head -6 || true
echo
"$SCRIPT" status
