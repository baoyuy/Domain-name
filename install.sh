#!/usr/bin/env bash
set -euo pipefail

NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
LEGACY_APP_DIR="/opt/oneproxy"
LEGACY_BIN="/usr/local/bin/oneproxy"

DOMAINS="${ONEPROXY_DOMAIN:-}"
UPSTREAM="${ONEPROXY_UPSTREAM:-}"
TTY_FD=""

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 运行，例如：sudo bash install.sh"
  exit 1
fi

log() {
  echo "[oneproxy] $1"
}

section() {
  echo
  echo "[oneproxy] ==== $1 ===="
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
用法:
  bash install.sh --domain example.com --to 127.0.0.1:3000

参数:
  --domain, -d    反代域名，多个域名用英文逗号分隔
  --to, -t        源站地址，例如 127.0.0.1:3000 或 http://127.0.0.1:3000
  --help, -h      显示帮助

示例:
  curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- --domain example.com --to 127.0.0.1:3000
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain|-d)
        DOMAINS="${2:-}"
        shift 2
        ;;
      --to|-t)
        UPSTREAM="${2:-}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

ensure_tty_input() {
  if [[ -n "${TTY_FD}" ]]; then
    return
  fi

  if [[ -r /dev/tty ]]; then
    exec 3</dev/tty
    TTY_FD="3"
    return
  fi

  echo "当前执行环境无法交互输入，请改用参数方式执行：" >&2
  echo "curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- --domain example.com --to 127.0.0.1:3000" >&2
  exit 1
}

prompt_if_missing() {
  ensure_tty_input

  echo
  echo "[oneproxy] 将创建一个 Nginx 反代站点"

  if [[ -z "${DOMAINS}" ]]; then
    read -r -u "${TTY_FD}" -p "1/2 请输入反代域名: " DOMAINS
  fi

  if [[ -z "${UPSTREAM}" ]]; then
    read -r -u "${TTY_FD}" -p "2/2 请输入源站地址，例如 127.0.0.1:3000: " UPSTREAM
  fi
}

detect_pm() {
  if has_cmd apt-get; then
    echo "apt"
    return
  fi
  if has_cmd dnf; then
    echo "dnf"
    return
  fi
  if has_cmd yum; then
    echo "yum"
    return
  fi
  echo ""
}

apt_quiet_install() {
  apt-get install -y -qq "$@" >/dev/null
}

install_base_packages() {
  local pm="$1"
  section "检查系统依赖"

  if [[ "$pm" == "apt" ]]; then
    log "更新软件源"
    apt-get update -qq
    log "安装基础依赖: curl"
    apt_quiet_install curl
    return
  fi

  if [[ "$pm" == "dnf" ]]; then
    log "安装基础依赖: curl"
    dnf install -y -q curl >/dev/null
    return
  fi

  if [[ "$pm" == "yum" ]]; then
    log "安装基础依赖: curl"
    yum install -y -q curl >/dev/null
    return
  fi

  echo "不支持当前 Linux 发行版。" >&2
  exit 1
}

install_nginx() {
  local pm="$1"
  section "检查 Nginx"

  if has_cmd nginx; then
    log "Nginx 已安装: $(nginx -v 2>&1)"
    return
  fi

  log "检测到未安装 Nginx，开始安装"

  if [[ "$pm" == "apt" ]]; then
    apt_quiet_install nginx
    return
  fi

  if [[ "$pm" == "dnf" ]]; then
    dnf install -y -q nginx >/dev/null
    return
  fi

  if [[ "$pm" == "yum" ]]; then
    yum install -y -q nginx >/dev/null
    return
  fi
}

normalize_upstream() {
  if [[ "$1" =~ ^https?:// ]]; then
    echo "$1"
  else
    echo "http://$1"
  fi
}

normalize_domains() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

first_domain() {
  normalize_domains "$1" | head -n 1
}

site_id() {
  first_domain "$1" | sed 's/[^a-z0-9.-]/-/g'
}

joined_domains() {
  normalize_domains "$1" | paste -sd' ' -
}

ensure_nginx_layout() {
  mkdir -p "${NGINX_SITES_AVAILABLE}" "${NGINX_SITES_ENABLED}"
}

write_site_config() {
  local domains_csv="$1"
  local upstream="$2"
  local site_name file_path enabled_path

  site_name="$(site_id "${domains_csv}")"
  file_path="${NGINX_SITES_AVAILABLE}/${site_name}.conf"
  enabled_path="${NGINX_SITES_ENABLED}/${site_name}.conf"

  cat > "${file_path}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $(joined_domains "${domains_csv}");

    location / {
        proxy_pass ${upstream};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  ln -sf "${file_path}" "${enabled_path}"
}

validate_nginx() {
  section "校验配置"
  if nginx -t >/tmp/oneproxy_nginx_test.out 2>/tmp/oneproxy_nginx_test.err; then
    log "Nginx 配置校验通过"
    rm -f /tmp/oneproxy_nginx_test.out /tmp/oneproxy_nginx_test.err
    return
  fi

  echo "[oneproxy] Nginx 配置校验失败" >&2
  sed -n '1,20p' /tmp/oneproxy_nginx_test.err >&2 || true
  rm -f /tmp/oneproxy_nginx_test.out /tmp/oneproxy_nginx_test.err
  exit 1
}

detect_port_owner() {
  local port="$1"

  if has_cmd ss; then
    ss -ltnp "( sport = :${port} )" 2>/dev/null | tail -n +2
    return
  fi

  if has_cmd lsof; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null
    return
  fi
}

summarize_nginx_failure() {
  local status_text journal_text combined

  status_text="$(systemctl --no-pager --full status nginx 2>&1 || true)"
  journal_text="$(journalctl --no-pager -u nginx -n 20 2>&1 || true)"
  combined="${status_text}"$'\n'"${journal_text}"

  if echo "${combined}" | grep -qi "bind() to 0.0.0.0:80 failed"; then
    echo "[oneproxy] Nginx 启动失败：80 端口已被其他程序占用。" >&2
    echo "建议处理：" >&2
    echo "- 查看是谁占用了 80 端口" >&2
    echo "- 停掉旧的 Nginx、Apache、宝塔或其他 Web 服务后重试" >&2
    echo >&2
    echo "[80 端口占用情况]" >&2
    detect_port_owner 80 >&2 || echo "无法自动识别占用进程，请手动执行: ss -ltnp | grep :80" >&2
    return
  fi

  if echo "${combined}" | grep -qi "permission denied"; then
    echo "[oneproxy] Nginx 启动失败：监听端口时权限不足。" >&2
    echo "建议处理：" >&2
    echo "- 确认脚本是用 root 或 sudo 执行的" >&2
    return
  fi

  echo "[oneproxy] Nginx 启动失败。" >&2
  echo "脚本暂时无法自动归类这个错误，请查看下面的原始诊断信息。" >&2
}

reload_nginx() {
  section "启动服务"
  systemctl enable nginx >/dev/null 2>&1 || true

  if systemctl restart nginx; then
    log "Nginx 已启动"
    return
  fi

  summarize_nginx_failure
  echo >&2
  echo "[oneproxy] 下面是原始诊断信息：" >&2
  echo >&2
  echo "[systemctl status]" >&2
  systemctl --no-pager --full status nginx 2>&1 | tail -n 20 >&2 || true
  echo >&2
  echo "[journalctl]" >&2
  journalctl --no-pager -u nginx -n 20 2>&1 >&2 || true
  exit 1
}

get_local_ips() {
  hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
}

resolve_domain() {
  local domain="$1"
  if has_cmd getent; then
    getent ahosts "${domain}" | awk '{print $1}' | sort -u
    return
  fi
  if has_cmd host; then
    host "${domain}" | awk '/has address/ {print $4}'
    return
  fi
  if has_cmd nslookup; then
    nslookup "${domain}" 2>/dev/null | awk '/^Address: / {print $2}'
    return
  fi
}

check_domains() {
  local domains_csv="$1"
  local local_ips resolved ok
  local has_failure="0"
  local_ips="$(get_local_ips)"

  section "检查域名解析"
  while IFS= read -r domain; do
    [[ -z "${domain}" ]] && continue
    resolved="$(resolve_domain "${domain}" || true)"
    ok="no"

    if [[ -n "${resolved}" && -n "${local_ips}" ]]; then
      while IFS= read -r ip; do
        [[ -z "${ip}" ]] && continue
        if echo "${local_ips}" | grep -Fxq "${ip}"; then
          ok="yes"
          break
        fi
      done <<< "${resolved}"
    fi

    echo "域名: ${domain}"
    echo "解析: ${resolved:-未解析到 IP}"
    echo "本机: ${local_ips:-无法获取本机 IP}"
    if [[ "${ok}" == "yes" ]]; then
      echo "结果: 正常"
    else
      echo "结果: 异常，域名暂未解析到当前服务器"
      has_failure="1"
    fi
    echo
  done < <(normalize_domains "${domains_csv}")

  return "${has_failure}"
}

check_upstream() {
  local upstream="$1"
  section "检查源站连通性"

  if curl -k -I -L --max-time 8 "${upstream}" >/tmp/oneproxy_upstream_check.out 2>/tmp/oneproxy_upstream_check.err; then
    log "源站可访问"
    sed -n '1p' /tmp/oneproxy_upstream_check.out || true
    rm -f /tmp/oneproxy_upstream_check.out /tmp/oneproxy_upstream_check.err
    return 0
  else
    echo "[oneproxy] 源站检测失败" >&2
    sed -n '1,5p' /tmp/oneproxy_upstream_check.err >&2 || true
    echo "请确认源站已启动、端口已监听、协议填写正确。" >&2
    rm -f /tmp/oneproxy_upstream_check.out /tmp/oneproxy_upstream_check.err
    return 1
  fi
}

cleanup_legacy_files() {
  section "清理残留"
  rm -rf "${LEGACY_APP_DIR}" 2>/dev/null || true
  rm -f "${LEGACY_BIN}" 2>/dev/null || true
  log "已清理旧版项目残留文件"
}

print_finish() {
  cat <<EOF

[oneproxy] 部署完成
域名    : ${DOMAINS}
源站    : ${UPSTREAM}
配置文件: ${NGINX_SITES_AVAILABLE}/$(site_id "${DOMAINS}").conf

以后如果要新增或修改域名，重新执行同一条命令即可。
EOF
}

print_partial_failure() {
  cat <<EOF

[oneproxy] 配置已写入，但部署未通过最终检查
域名    : ${DOMAINS}
源站    : ${UPSTREAM}
配置文件: ${NGINX_SITES_AVAILABLE}/$(site_id "${DOMAINS}").conf

失败原因通常是：
- 域名还没有解析到当前服务器
- 源站服务未启动
- 源站端口未监听
- 防火墙未放行

请先修复上面的检查项，再重新执行同一条命令。
EOF
}

main() {
  local pm
  local domain_check_ok="0"
  local upstream_check_ok="0"

  parse_args "$@"
  prompt_if_missing

  if [[ -z "${DOMAINS}" || -z "${UPSTREAM}" ]]; then
    echo "域名和源站不能为空。" >&2
    exit 1
  fi

  pm="$(detect_pm)"
  if [[ -z "${pm}" ]]; then
    echo "不支持当前 Linux 发行版。" >&2
    exit 1
  fi

  UPSTREAM="$(normalize_upstream "${UPSTREAM}")"

  section "部署信息"
  echo "域名: ${DOMAINS}"
  echo "源站: ${UPSTREAM}"
  echo "系统: ${pm}"

  install_base_packages "${pm}"
  install_nginx "${pm}"
  ensure_nginx_layout
  write_site_config "${DOMAINS}" "${UPSTREAM}"
  validate_nginx
  reload_nginx
  if check_domains "${DOMAINS}"; then
    domain_check_ok="1"
  fi
  if check_upstream "${UPSTREAM}"; then
    upstream_check_ok="1"
  fi
  cleanup_legacy_files

  if [[ "${domain_check_ok}" == "1" && "${upstream_check_ok}" == "1" ]]; then
    print_finish
  else
    print_partial_failure >&2
    exit 1
  fi

  if [[ -n "${TTY_FD}" ]]; then
    exec 3<&-
  fi
}

main "$@"
