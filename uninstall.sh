#!/usr/bin/env bash
set -euo pipefail

NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"

DOMAIN="${1:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 运行，例如：sudo bash uninstall.sh your-domain.com"
  exit 1
fi

if [[ -z "${DOMAIN}" ]]; then
  echo "用法: sudo bash uninstall.sh your-domain.com"
  exit 1
fi

SITE_FILE="${NGINX_SITES_AVAILABLE}/${DOMAIN}.conf"
SITE_LINK="${NGINX_SITES_ENABLED}/${DOMAIN}.conf"

read -r -p "[oneproxy] 这会删除 ${DOMAIN} 的 Nginx 配置，并尝试删除对应证书。是否继续？[y/N]: " CONFIRM

if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
  echo "[oneproxy] 已取消。"
  exit 0
fi

rm -f "${SITE_LINK}" "${SITE_FILE}"

if command -v certbot >/dev/null 2>&1; then
  certbot delete --cert-name "${DOMAIN}" --non-interactive >/dev/null 2>&1 || true
fi

if command -v nginx >/dev/null 2>&1; then
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
fi

echo "[oneproxy] 已删除 ${DOMAIN} 的配置。"
