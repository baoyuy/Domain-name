#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/oneproxy"
REPO_URL="${ONEPROXY_REPO_URL:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash install.sh"
  exit 1
fi

log() {
  echo "[oneproxy] $1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
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
  echo "Unsupported package manager." >&2
  exit 1
}

install_node() {
  local pm="$1"
  if has_cmd node; then
    log "Node already installed: $(node -v)"
    return
  fi

  log "Installing Node.js"
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
    log "Caddy already installed: $(caddy version)"
    return
  fi

  log "Installing Caddy"
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

install_project() {
  mkdir -p "$APP_DIR"

  if [[ -n "$REPO_URL" ]]; then
    log "Cloning project from $REPO_URL"
    rm -rf "$APP_DIR"
    git clone "$REPO_URL" "$APP_DIR"
  elif [[ -f "./package.json" && -d "./src" ]]; then
    log "Using current directory as project source"
    cp -R . "$APP_DIR"
  else
    echo "Project source not found." >&2
    echo "When installing from GitHub raw script, set ONEPROXY_REPO_URL." >&2
    exit 1
  fi

  chmod +x "$APP_DIR/src/cli.js"
  if [[ -f "$APP_DIR/uninstall.sh" ]]; then
    chmod +x "$APP_DIR/uninstall.sh"
  fi
  ln -sf "$APP_DIR/src/cli.js" /usr/local/bin/oneproxy
}

enable_services() {
  systemctl enable caddy
  systemctl restart caddy
}

main() {
  local pm
  pm="$(detect_pm)"
  if [[ -z "$pm" ]]; then
    echo "Unsupported Linux distribution." >&2
    exit 1
  fi

  install_base_packages "$pm"
  install_node "$pm"
  install_caddy "$pm"
  install_project
  enable_services

  log "Install complete."
  log "Run: sudo oneproxy"
}

main "$@"
