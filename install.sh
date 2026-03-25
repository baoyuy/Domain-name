#!/usr/bin/env bash
set -Eeuo pipefail

NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
LEGACY_APP_DIR="/opt/oneproxy"
LEGACY_BIN="/usr/local/bin/oneproxy"

DOMAINS="${ONEPROXY_DOMAIN:-}"
UPSTREAM="${ONEPROXY_UPSTREAM:-}"
EMAIL="${ONEPROXY_EMAIL:-}"
TTY_FD=""

SITE_NAME=""
SITE_FILE=""
SITE_LINK=""
CONFIG_WRITTEN="0"
DEPLOY_COMPLETED="0"
BACKUP_DIR=""
HAD_OLD_FILE="0"
HAD_OLD_LINK="0"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_BOLD=$'\033[1m'
  COLOR_DIM=$'\033[2m'
  COLOR_BLUE=$'\033[34m'
  COLOR_CYAN=$'\033[36m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_RED=$'\033[31m'
else
  COLOR_RESET=""
  COLOR_BOLD=""
  COLOR_DIM=""
  COLOR_BLUE=""
  COLOR_CYAN=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_RED=""
fi

log() {
  printf '%b[oneproxy]%b %s\n' "${COLOR_BLUE}${COLOR_BOLD}" "${COLOR_RESET}" "$1"
}

section() {
  printf '\n%b[oneproxy] ==== %s ====%b\n' "${COLOR_CYAN}${COLOR_BOLD}" "$1" "${COLOR_RESET}"
}

success() {
  printf '%b[oneproxy]%b %s\n' "${COLOR_GREEN}${COLOR_BOLD}" "${COLOR_RESET}" "$1"
}

warn() {
  printf '%b[oneproxy]%b %s\n' "${COLOR_YELLOW}${COLOR_BOLD}" "${COLOR_RESET}" "$1" >&2
}

error() {
  printf '%b[oneproxy]%b %s\n' "${COLOR_RED}${COLOR_BOLD}" "${COLOR_RESET}" "$1" >&2
}

kv() {
  printf '%b%-10s%b %s\n' "${COLOR_DIM}" "$1" "${COLOR_RESET}" "$2"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
用法:
  bash install.sh --domain example.com --to 127.0.0.1:3000 --email admin@example.com

参数:
  --domain, -d    反代域名，多个域名用英文逗号分隔
  --to, -t        源站地址，例如 127.0.0.1:3000 或 http://127.0.0.1:3000
  --email, -e     可选，HTTPS 证书通知邮箱
  --help, -h      显示帮助

示例:
  curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- --domain example.com --to 127.0.0.1:3000 --email admin@example.com
EOF
}

if [[ "${EUID}" -ne 0 ]]; then
  error "请使用 root 运行，例如：sudo bash install.sh"
  exit 1
fi

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
      --email|-e)
        EMAIL="${2:-}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "未知参数: $1"
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

  error "当前执行环境无法交互输入，请改用参数方式执行。"
  printf '%s\n' "curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- --domain example.com --to 127.0.0.1:3000 --email admin@example.com" >&2
  exit 1
}

prompt_if_missing() {
  ensure_tty_input

  echo
  success "将创建一个 Nginx HTTPS 反代站点"

  if [[ -z "${DOMAINS}" ]]; then
    read -r -u "${TTY_FD}" -p "1/3 请输入反代域名: " DOMAINS
  fi

  if [[ -z "${UPSTREAM}" ]]; then
    read -r -u "${TTY_FD}" -p "2/3 请输入源站地址，例如 127.0.0.1:3000: " UPSTREAM
  fi

  if [[ -z "${EMAIL}" ]]; then
    read -r -u "${TTY_FD}" -p "3/3 请输入邮箱，可直接回车跳过: " EMAIL
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
    log "安装基础依赖: curl ca-certificates"
    apt_quiet_install curl ca-certificates
    return
  fi

  if [[ "$pm" == "dnf" ]]; then
    log "安装基础依赖: curl ca-certificates"
    dnf install -y -q curl ca-certificates >/dev/null
    return
  fi

  if [[ "$pm" == "yum" ]]; then
    log "安装基础依赖: curl ca-certificates"
    yum install -y -q curl ca-certificates >/dev/null
    return
  fi

  error "不支持当前 Linux 发行版。"
  exit 1
}

install_nginx() {
  local pm="$1"
  section "检查 Nginx"

  if has_cmd nginx; then
    success "Nginx 已安装: $(nginx -v 2>&1)"
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

install_certbot() {
  local pm="$1"
  section "检查 Certbot"

  if has_cmd certbot; then
    success "Certbot 已安装: $(certbot --version 2>/dev/null | head -n 1)"
  else
    log "检测到未安装 Certbot，开始安装"
  fi

  if [[ "$pm" == "apt" ]]; then
    apt_quiet_install certbot python3-certbot-nginx
    return
  fi

  if [[ "$pm" == "dnf" ]]; then
    dnf install -y -q certbot python3-certbot-nginx >/dev/null
    return
  fi

  if [[ "$pm" == "yum" ]]; then
    yum install -y -q epel-release >/dev/null || true
    yum install -y -q certbot python3-certbot-nginx >/dev/null
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

prepare_site_paths() {
  SITE_NAME="$(site_id "${DOMAINS}")"
  SITE_FILE="${NGINX_SITES_AVAILABLE}/${SITE_NAME}.conf"
  SITE_LINK="${NGINX_SITES_ENABLED}/${SITE_NAME}.conf"
}

ensure_nginx_layout() {
  mkdir -p "${NGINX_SITES_AVAILABLE}" "${NGINX_SITES_ENABLED}"
}

backup_existing_site_config() {
  BACKUP_DIR="$(mktemp -d /tmp/oneproxy-backup.XXXXXX)"
  HAD_OLD_FILE="0"
  HAD_OLD_LINK="0"

  if [[ -f "${SITE_FILE}" ]]; then
    cp "${SITE_FILE}" "${BACKUP_DIR}/site.conf"
    HAD_OLD_FILE="1"
  fi

  if [[ -L "${SITE_LINK}" ]]; then
    readlink "${SITE_LINK}" > "${BACKUP_DIR}/site.link"
    HAD_OLD_LINK="1"
  fi
}

restore_site_backup() {
  if [[ -z "${BACKUP_DIR}" || ! -d "${BACKUP_DIR}" ]]; then
    rm -f "${SITE_LINK}" "${SITE_FILE}" 2>/dev/null || true
    return
  fi

  rm -f "${SITE_LINK}" "${SITE_FILE}" 2>/dev/null || true

  if [[ "${HAD_OLD_FILE}" == "1" && -f "${BACKUP_DIR}/site.conf" ]]; then
    cp "${BACKUP_DIR}/site.conf" "${SITE_FILE}"
  fi

  if [[ "${HAD_OLD_LINK}" == "1" && -f "${BACKUP_DIR}/site.link" ]]; then
    ln -sf "$(cat "${BACKUP_DIR}/site.link")" "${SITE_LINK}"
  fi
}

cleanup_backup_dir() {
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    rm -rf "${BACKUP_DIR}" 2>/dev/null || true
  fi
}

rollback_site_config() {
  if [[ "${CONFIG_WRITTEN}" != "1" || "${DEPLOY_COMPLETED}" == "1" ]]; then
    cleanup_backup_dir
    return
  fi

  warn "检测到部署中断，正在回滚站点配置"
  restore_site_backup

  if has_cmd nginx && nginx -t >/tmp/oneproxy_rollback.out 2>/tmp/oneproxy_rollback.err; then
    systemctl reload nginx >/dev/null 2>&1 || true
    success "站点配置已回滚"
  else
    error "自动回滚后 Nginx 配置校验失败，请手动检查。"
    sed -n '1,20p' /tmp/oneproxy_rollback.err >&2 || true
  fi

  rm -f /tmp/oneproxy_rollback.out /tmp/oneproxy_rollback.err
  cleanup_backup_dir
}

on_error() {
  local exit_code="$1"
  rollback_site_config
  exit "${exit_code}"
}

trap 'on_error $?' ERR

write_site_config() {
  cat > "${SITE_FILE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $(joined_domains "${DOMAINS}");

    location / {
        proxy_pass ${UPSTREAM};
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

  ln -sf "${SITE_FILE}" "${SITE_LINK}"
  CONFIG_WRITTEN="1"

  if [[ "${HAD_OLD_FILE}" == "1" || "${HAD_OLD_LINK}" == "1" ]]; then
    warn "检测到已有同名站点配置，本次已先做备份，成功后将覆盖旧配置"
  else
    success "已创建新的 HTTP 站点配置"
  fi
}

validate_nginx() {
  section "校验 Nginx 配置"
  if nginx -t >/tmp/oneproxy_nginx_test.out 2>/tmp/oneproxy_nginx_test.err; then
    success "Nginx 配置校验通过"
    rm -f /tmp/oneproxy_nginx_test.out /tmp/oneproxy_nginx_test.err
    return
  fi

  error "Nginx 配置校验失败"
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

  if echo "${combined}" | grep -Eqi "bind\(\) to .*:80 failed|bind\(\) to .*:443 failed|address already in use"; then
    error "Nginx 启动失败：80 或 443 端口已被其他程序占用。"
    warn "建议处理："
    printf '%s\n' "- 查看是谁占用了 80/443 端口" >&2
    printf '%s\n' "- 停掉旧的 Nginx、Apache、宝塔或其他 Web 服务后重试" >&2
    echo >&2
    printf '%b[80 端口占用情况]%b\n' "${COLOR_YELLOW}${COLOR_BOLD}" "${COLOR_RESET}" >&2
    detect_port_owner 80 >&2 || true
    printf '%b[443 端口占用情况]%b\n' "${COLOR_YELLOW}${COLOR_BOLD}" "${COLOR_RESET}" >&2
    detect_port_owner 443 >&2 || true
    return
  fi

  if echo "${combined}" | grep -qi "permission denied"; then
    error "Nginx 启动失败：监听端口时权限不足。"
    warn "建议处理："
    printf '%s\n' "- 确认脚本是用 root 或 sudo 执行的" >&2
    return
  fi

  error "Nginx 启动失败。"
  warn "脚本暂时无法自动归类这个错误，请查看下面的原始诊断信息。"
}

reload_nginx() {
  section "启动 Nginx"
  systemctl enable nginx >/dev/null 2>&1 || true

  if systemctl restart nginx; then
    success "Nginx 已启动"
    return
  fi

  summarize_nginx_failure
  echo >&2
  warn "下面是原始诊断信息："
  echo >&2
  printf '%b[systemctl status]%b\n' "${COLOR_YELLOW}${COLOR_BOLD}" "${COLOR_RESET}" >&2
  systemctl --no-pager --full status nginx 2>&1 | tail -n 20 >&2 || true
  echo >&2
  printf '%b[journalctl]%b\n' "${COLOR_YELLOW}${COLOR_BOLD}" "${COLOR_RESET}" >&2
  journalctl --no-pager -u nginx -n 20 2>&1 >&2 || true
  exit 1
}

get_local_ips() {
  hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
}

get_public_ips() {
  {
    curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
    echo
    curl -4 -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null || true
    echo
    curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true
    echo
  } | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort -u
}

collect_server_ips() {
  {
    get_local_ips
    get_public_ips
  } | sed '/^$/d' | sort -u
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
  local server_ips resolved ok
  local has_failure="0"
  server_ips="$(collect_server_ips)"

  section "检查域名解析"
  while IFS= read -r domain; do
    [[ -z "${domain}" ]] && continue
    resolved="$(resolve_domain "${domain}" || true)"
    ok="no"

    if [[ -n "${resolved}" && -n "${server_ips}" ]]; then
      while IFS= read -r ip; do
        [[ -z "${ip}" ]] && continue
        if echo "${server_ips}" | grep -Fxq "${ip}"; then
          ok="yes"
          break
        fi
      done <<< "${resolved}"
    fi

    kv "域名:" "${domain}"
    kv "解析:" "${resolved:-未解析到 IP}"
    kv "服务器IP:" "${server_ips:-无法获取服务器 IP}"
    if [[ "${ok}" == "yes" ]]; then
      success "结果: 正常"
    else
      warn "结果: 异常，域名暂未解析到当前服务器"
      has_failure="1"
    fi
    echo
  done < <(normalize_domains "${DOMAINS}")

  return "${has_failure}"
}

check_upstream() {
  section "检查源站连通性"

  if curl -k -I -L --max-time 8 "${UPSTREAM}" >/tmp/oneproxy_upstream_check.out 2>/tmp/oneproxy_upstream_check.err; then
    success "源站可访问"
    sed -n '1p' /tmp/oneproxy_upstream_check.out || true
    rm -f /tmp/oneproxy_upstream_check.out /tmp/oneproxy_upstream_check.err
    return 0
  fi

  error "源站检测失败"
  sed -n '1,5p' /tmp/oneproxy_upstream_check.err >&2 || true
  warn "请确认源站已启动、端口已监听、协议填写正确。"
  rm -f /tmp/oneproxy_upstream_check.out /tmp/oneproxy_upstream_check.err
  return 1
}

build_certbot_args() {
  CERTBOT_ARGS=(--nginx --redirect --non-interactive --agree-tos)

  if [[ -n "${EMAIL}" ]]; then
    CERTBOT_ARGS+=(--email "${EMAIL}")
  else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
  fi

  while IFS= read -r domain; do
    [[ -n "${domain}" ]] && CERTBOT_ARGS+=(-d "${domain}")
  done < <(normalize_domains "${DOMAINS}")
}

summarize_certbot_failure() {
  local output
  output="$(cat /tmp/oneproxy_certbot.err 2>/dev/null || true)"

  if echo "${output}" | grep -qi "NXDOMAIN"; then
    error "HTTPS 申请失败：域名不存在或 DNS 记录未生效。"
    return
  fi

  if echo "${output}" | grep -Eqi "Timeout during connect|Connection refused|unauthorized|Invalid response"; then
    error "HTTPS 申请失败：Let's Encrypt 无法通过 80 端口验证当前域名。"
    warn "建议处理："
    printf '%s\n' "- 确认域名已经解析到当前服务器公网 IP" >&2
    printf '%s\n' "- 确认 80 端口已对外放行" >&2
    printf '%s\n' "- 确认 CDN 或代理没有拦截验证请求" >&2
    return
  fi

  error "HTTPS 申请失败。"
}

cleanup_failed_certificate() {
  local primary_domain
  primary_domain="$(first_domain "${DOMAINS}")"

  if [[ -n "${primary_domain}" && -d "/etc/letsencrypt/live/${primary_domain}" ]]; then
    certbot delete --cert-name "${primary_domain}" --non-interactive >/dev/null 2>&1 || true
  fi
}

enable_https() {
  local -a CERTBOT_ARGS
  section "申请 HTTPS 证书"

  build_certbot_args

  if certbot "${CERTBOT_ARGS[@]}" >/tmp/oneproxy_certbot.out 2>/tmp/oneproxy_certbot.err; then
    success "HTTPS 证书申请成功，已自动配置 80 -> 443"
    rm -f /tmp/oneproxy_certbot.out /tmp/oneproxy_certbot.err
    return
  fi

  summarize_certbot_failure
  warn "正在回滚刚写入的 HTTP 配置"
  cleanup_failed_certificate
  rollback_site_config
  echo >&2
  warn "下面是 Certbot 原始输出："
  sed -n '1,40p' /tmp/oneproxy_certbot.err >&2 || true
  rm -f /tmp/oneproxy_certbot.out /tmp/oneproxy_certbot.err
  exit 1
}

validate_final_access() {
  local primary_domain http_status https_status
  primary_domain="$(first_domain "${DOMAINS}")"

  section "最终访问验证"

  http_status="$(curl -I --max-time 15 -o /dev/null -s -w '%{http_code}' "http://${primary_domain}" || true)"
  https_status="$(curl -I --max-time 15 -o /dev/null -s -w '%{http_code}' "https://${primary_domain}" || true)"

  kv "HTTP:" "${http_status:-000}"
  kv "HTTPS:" "${https_status:-000}"

  if [[ "${https_status}" =~ ^(200|301|302|308)$ ]]; then
    success "最终访问验证通过"
    return
  fi

  warn "最终访问验证未通过，但配置和证书已完成。"
  warn "这通常意味着外部网络、防火墙或 CDN 仍有拦截。"
}

cleanup_legacy_files() {
  section "清理残留"
  rm -rf "${LEGACY_APP_DIR}" 2>/dev/null || true
  rm -f "${LEGACY_BIN}" 2>/dev/null || true
  success "已清理旧版项目残留文件"
}

print_finish() {
  printf '\n%b[oneproxy] 部署完成%b\n' "${COLOR_GREEN}${COLOR_BOLD}" "${COLOR_RESET}"
  kv "域名:" "${DOMAINS}"
  kv "源站:" "${UPSTREAM}"
  kv "HTTP配置:" "${SITE_FILE}"
  kv "HTTPS:" "已开启"
  echo
  printf '%s\n' "以后如果要新增或修改域名，重新执行同一条命令即可。"
}

print_partial_failure() {
  printf '\n%b[oneproxy] 部署未通过最终检查，未写入 HTTP 配置%b\n' "${COLOR_YELLOW}${COLOR_BOLD}" "${COLOR_RESET}" >&2
  kv "域名:" "${DOMAINS}" >&2
  kv "源站:" "${UPSTREAM}" >&2
  echo >&2
  printf '%s\n' "失败原因通常是：" >&2
  printf '%s\n' "- 域名还没有解析到当前服务器" >&2
  printf '%s\n' "- 源站服务未启动" >&2
  printf '%s\n' "- 源站端口未监听" >&2
  printf '%s\n' "- 防火墙未放行" >&2
  echo >&2
  printf '%s\n' "请先修复上面的检查项，再重新执行同一条命令。" >&2
}

main() {
  local pm
  local domain_check_ok="0"
  local upstream_check_ok="0"

  parse_args "$@"
  prompt_if_missing

  if [[ -z "${DOMAINS}" || -z "${UPSTREAM}" ]]; then
    error "域名和源站不能为空。"
    exit 1
  fi

  pm="$(detect_pm)"
  if [[ -z "${pm}" ]]; then
    error "不支持当前 Linux 发行版。"
    exit 1
  fi

  UPSTREAM="$(normalize_upstream "${UPSTREAM}")"
  prepare_site_paths

  section "部署信息"
  kv "域名:" "${DOMAINS}"
  kv "源站:" "${UPSTREAM}"
  kv "系统:" "${pm}"
  kv "邮箱:" "${EMAIL:-未提供，将使用无邮箱模式申请证书}"

  install_base_packages "${pm}"
  install_nginx "${pm}"
  install_certbot "${pm}"

  if check_domains; then
    domain_check_ok="1"
  fi
  if check_upstream; then
    upstream_check_ok="1"
  fi

  if [[ "${domain_check_ok}" != "1" || "${upstream_check_ok}" != "1" ]]; then
    cleanup_legacy_files
    print_partial_failure
    exit 1
  fi

  ensure_nginx_layout
  backup_existing_site_config
  write_site_config
  validate_nginx
  reload_nginx
  enable_https
  validate_nginx
  reload_nginx
  validate_final_access
  cleanup_legacy_files
  cleanup_backup_dir
  DEPLOY_COMPLETED="1"
  print_finish

  if [[ -n "${TTY_FD}" ]]; then
    exec 3<&-
  fi
}

main "$@"
