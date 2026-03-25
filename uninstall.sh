#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/oneproxy"
DATA_DIR="/opt/oneproxy/data"
CADDY_SITES_DIR="/etc/caddy/sites-enabled"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash uninstall.sh"
  exit 1
fi

echo "[oneproxy] This will remove oneproxy files, data, and generated Caddy site configs."
read -r -p "[oneproxy] Continue? [y/N]: " CONFIRM

if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
  echo "[oneproxy] Cancelled."
  exit 0
fi

rm -f /usr/local/bin/oneproxy
rm -rf "$APP_DIR"

if [[ -d "$CADDY_SITES_DIR" ]]; then
  find "$CADDY_SITES_DIR" -maxdepth 1 -type f -name "*.caddy" -delete
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl reload caddy || true
fi

echo "[oneproxy] Uninstall complete."
