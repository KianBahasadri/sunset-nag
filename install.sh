#!/usr/bin/env bash
# Install the auto-grayscale systemd user timer. Safe to re-run.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/auto-grayscale"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

chmod +x "$SCRIPT"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/auto-grayscale.service" <<EOF
[Unit]
Description=Apply auto-grayscale (grayscale from sunset to sunrise)
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStart=$SCRIPT apply
EOF

cat > "$UNIT_DIR/auto-grayscale.timer" <<EOF
[Unit]
Description=Run auto-grayscale every minute

[Timer]
OnCalendar=*:0/1
AccuracySec=1s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now auto-grayscale.timer

echo
echo "Installed. The screen will be grayscale from sunset to sunrise."
echo
systemctl --user list-timers auto-grayscale.timer --no-pager || true
echo
"$SCRIPT" status
