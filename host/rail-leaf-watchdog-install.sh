#!/bin/bash
# Install the rail leaf watchdog as a systemd timer. Idempotent; run on the lab host.
#   ./rail-leaf-watchdog-install.sh            install and start
#   ./rail-leaf-watchdog-install.sh uninstall  stop, disable and remove
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" = uninstall ]; then
  systemctl disable --now rail-leaf-watchdog.timer 2>/dev/null || true
  rm -f /etc/systemd/system/rail-leaf-watchdog.{service,timer}
  systemctl daemon-reload; echo "removed"; exit 0
fi
install -m 644 rail-leaf-watchdog.service rail-leaf-watchdog.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now rail-leaf-watchdog.timer
echo "installed:"; systemctl status rail-leaf-watchdog.timer --no-pager | head -4
systemctl list-timers rail-leaf-watchdog.timer --no-pager | head -3
