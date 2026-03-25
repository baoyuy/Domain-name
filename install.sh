#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO_URL="https://github.com/baoyuy/Domain-name.git"
CADDY_SITES_DIR="/etc/caddy/sites-enabled"
CADDY_FILE="/etc/caddy/Caddyfile"
LEGACY_APP_DIR="/opt/oneproxy"
LEGACY_BIN="/usr/local/bin/oneproxy"

DOMAINS="${ONEPROXY_DOMAIN:-}"
UPSTREAM="${ONEPROXY_UPSTREAM:-}"
EMAIL="${ONEPROXY_EMAIL:-}"
TTY_FD=""

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 运行，例如：sudo bash install.sh"
  exit 1
fi

log() {
  echo "[oneproxy] $1"
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
  --email, -e     可选，Caddy 证书通知邮箱
  --help, -h      显示帮助

环境变量:
  ONEPROXY_DOMAIN
  ONEPROXY_UPSTREAM
  ONEPROXY_EMAIL

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
      --email|-e)
        EMAIL="${2:-}"
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

prompt_if_missing() {
  ensure_tty_input

  if [[ -z "${DOMAINS}" ]]; then
    read -r -u "${TTY_FD}" -p "请输入反代域名，多个域名用英文逗号分隔: " DOMAINS
  fi

  if [[ -z "${UPSTREAM}" ]]; then
    read -r -u "${TTY_FD}" -p "请输入源站地址，例如 127.0.0.1:3000: " UPSTREAM
  fi

  if [[ -z "${EMAIL}" ]]; then
    read -r -u "${TTY_FD}" -p "请输入通知邮箱，可直接回车跳过: " EMAIL
  fi
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

  echo "当前执行环境无法交互输入，请使用参数方式执行：" >&2
  echo "curl -fsSL https://raw.githubusercontent.com/baoyuy/Domain-name/main/install.sh | sudo bash -s -- --domain example.com --to 127.0.0.1:3000" >&2
  exit 1
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

install_base_packages() {
  local pm="$1"
  if [[ "$pm" == "apt" ]]; then
    apt-get update
    apt-get install -y curl ca-certificates gnupg git
    return
  fi
  if [[ "$pm" == "dnf" ]]; then
    dnf install -y curl ca-certificates gnupg2 git
    return
  fi
  if [[ "$pm" == "yum" ]]; then
    yum install -y curl ca-certificates gnupg2 git
    return
  fi
  echo "不支持当前 Linux 发行版。" >&2
  exit 1
}

install_node() {
  local pm="$1"
  if has_cmd node; then
    log "Node 已安装: $(node -v)"
    return
  fi

  log "检测到未安装 Node，开始安装"
  if [[ "$pm" == "apt" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    return
  fi
  if [[ "$pm" == "dnf" ]]; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    dnf install -y nodejs
    return
  fi
  if [[ "$pm" == "yum" ]]; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    yum install -y nodejs
    return
  fi
}

install_caddy() {
  local pm="$1"
  if has_cmd caddy; then
    log "Caddy 已安装: $(caddy version)"
    return
  fi

  log "检测到未安装 Caddy，开始安装"
  if [[ "$pm" == "apt" ]]; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
    return
  fi
  if [[ "$pm" == "dnf" ]]; then
    dnf install -y 'dnf-command(copr)'
    dnf copr enable -y @caddy/caddy
    dnf install -y caddy
    return
  fi
  if [[ "$pm" == "yum" ]]; then
    yum install -y yum-plugin-copr
    yum copr enable -y @caddy/caddy
    yum install -y caddy
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

ensure_caddy_layout() {
  mkdir -p "${CADDY_SITES_DIR}"

  if [[ ! -f "${CADDY_FILE}" ]]; then
    touch "${CADDY_FILE}"
  fi

  if ! grep -Fq "import ${CADDY_SITES_DIR}/*.caddy" "${CADDY_FILE}"; then
    printf '\nimport %s/*.caddy\n' "${CADDY_SITES_DIR}" >> "${CADDY_FILE}"
  fi

  if [[ -n "${EMAIL}" ]] && ! grep -Eq '^[[:space:]]*\{[[:space:]]*$' "${CADDY_FILE}"; then
    printf '{\n  email %s\n}\n\nimport %s/*.caddy\n' "${EMAIL}" "${CADDY_SITES_DIR}" > "${CADDY_FILE}"
  fi
}

write_site_config() {
  local domains_csv="$1"
  local upstream="$2"
  local file_path="${CADDY_SITES_DIR}/$(site_id "${domains_csv}").caddy"
  local joined_domains

  joined_domains="$(normalize_domains "${domains_csv}" | paste -sd ", " -)"
  cat > "${file_path}" <<EOF
${joined_domains} {
  reverse_proxy ${upstream}
}
EOF
}

reload_caddy() {
  systemctl enable caddy >/dev/null 2>&1 || true
  systemctl restart caddy
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
  local_ips="$(get_local_ips)"

  log "开始检查域名解析"
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

    echo "  域名: ${domain}"
    echo "  解析: ${resolved:-未解析到 IP}"
    echo "  本机: ${local_ips:-无法获取本机 IP}"
    if [[ "${ok}" == "yes" ]]; then
      echo "  结果: 正常"
    else
      echo "  结果: 异常，域名暂未解析到当前服务器"
    fi
  done < <(normalize_domains "${domains_csv}")
}

check_upstream() {
  local upstream="$1"
  log "开始检查源站连通性"
  if curl -k -I -L --max-time 8 "${upstream}" >/tmp/oneproxy_upstream_check.out 2>/tmp/oneproxy_upstream_check.err; then
    head -n 1 /tmp/oneproxy_upstream_check.out || true
    echo "  结果: 正常"
  else
    sed -n '1p' /tmp/oneproxy_upstream_check.err || true
    echo "  结果: 异常，请确认源站已启动、端口已监听、协议填写正确"
  fi
  rm -f /tmp/oneproxy_upstream_check.out /tmp/oneproxy_upstream_check.err
}

cleanup_legacy_files() {
  rm -rf "${LEGACY_APP_DIR}" 2>/dev/null || true
  rm -f "${LEGACY_BIN}" 2>/dev/null || true
  log "已清理部署流程中无用的旧项目文件"
}

print_finish() {
  cat <<EOF

[oneproxy] 反代流程已完成
  域名   : ${DOMAINS}
  源站   : ${UPSTREAM}
  配置文件: ${CADDY_SITES_DIR}/$(site_id "${DOMAINS}").caddy

后续如果要新增或修改站点，直接重新执行这条命令即可。
仓库源码不会常驻在服务器，只保留 Caddy 配置和必要依赖。
EOF
}

main() {
  local pm normalized_upstream

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

  normalized_upstream="$(normalize_upstream "${UPSTREAM}")"
  UPSTREAM="${normalized_upstream}"

  install_base_packages "${pm}"
  install_node "${pm}"
  install_caddy "${pm}"
  ensure_caddy_layout
  write_site_config "${DOMAINS}" "${UPSTREAM}"
  reload_caddy
  check_domains "${DOMAINS}"
  check_upstream "${UPSTREAM}"
  cleanup_legacy_files
  print_finish

  if [[ -n "${TTY_FD}" ]]; then
    exec 3<&-
  fi
}

main "$@"
