#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
META_FILE="/etc/sing-box/meta.info"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
ACME_DIR="/var/lib/sing-box/acme"

red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }

[[ "$EUID" -eq 0 ]] || { red "请用 root 运行"; exit 1; }

install_deps() {
  if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y curl wget tar jq openssl ca-certificates iproute2 dnsutils lsof
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl wget tar jq openssl ca-certificates iproute bind-utils lsof
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget tar jq openssl ca-certificates iproute bind-utils lsof
  else
    red "不支持的系统"
    exit 1
  fi
}

install_singbox_prerelease() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) SB_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64" ;;
    armv7l) SB_ARCH="armv7" ;;
    *) red "不支持架构: $ARCH"; exit 1 ;;
  esac

  RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases)"
  TAG="$(echo "$RELEASE_JSON" | jq -r '[.[] | select(.prerelease == true)][0].tag_name')"

  [[ -n "$TAG" && "$TAG" != "null" ]] || {
    red "没有找到 sing-box prerelease 版本"
    exit 1
  }

  VERSION="${TAG#v}"
  FILE="sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
  URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/${FILE}"

  green "安装 sing-box 预发布版: ${TAG}"

  TMP_DIR="$(mktemp -d)"
  cd "$TMP_DIR"
  wget -O "$FILE" "$URL"
  tar -xzf "$FILE"
  install -m 755 "sing-box-${VERSION}-linux-${SB_ARCH}/sing-box" /usr/local/bin/sing-box
  cd /
  rm -rf "$TMP_DIR"
}

enable_bbr() {
  modprobe tcp_bbr 2>/dev/null || true
  grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
}

write_meta() {
  mkdir -p "$CONFIG_DIR"
  cat > "$META_FILE" <<EOF
DOMAIN="${DOMAIN}"
EMAIL="${EMAIL}"
PORT="${PORT}"
USERNAME="${USERNAME}"
PASSWORD="${PASSWORD}"
NETWORK="${NETWORK}"
EOF
}

load_meta() {
  [[ -f "$META_FILE" ]] || return 1
  source "$META_FILE"
}

write_config() {
  mkdir -p "$CONFIG_DIR" "$ACME_DIR"

  cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "certificate_providers": [
    {
      "type": "acme",
      "tag": "naive-cert",
      "domain": [
        "${DOMAIN}"
      ],
      "email": "${EMAIL}",
      "data_directory": "${ACME_DIR}",
      "default_server_name": "${DOMAIN}",
      "disable_tls_alpn_challenge": true,
      "key_type": "p256"
    }
  ],
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": ${PORT},
      "network": "${NETWORK}",
      "users": [
        {
          "username": "${USERNAME}",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_provider": "naive-cert",
        "handshake_timeout": "15s"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

restart_singbox() {
  sing-box check -c "$CONFIG_FILE"
  systemctl daemon-reload
  systemctl enable --now sing-box
  systemctl restart sing-box
}

show_link() {
  load_meta || { red "未安装"; return; }

  echo
  green "Naive URI："
  echo "https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}"

  echo
  green "sing-box outbound："

  cat <<EOF
{
  "type": "naive",
  "tag": "naive-out",
  "server": "${DOMAIN}",
  "server_port": ${PORT},
  "username": "${USERNAME}",
  "password": "${PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}"
  }
}
EOF
}

install_naive() {
  read -rp "请输入域名: " DOMAIN
  read -rp "请输入 ACME 邮箱: " EMAIL
  read -rp "请输入端口 [默认443]: " PORT
  PORT="${PORT:-443}"

  read -rp "请输入网络 tcp/udp [默认tcp]: " NETWORK
  NETWORK="${NETWORK:-tcp}"

  read -rp "请输入用户名 [留空随机]: " USERNAME
  USERNAME="${USERNAME:-naive_$(openssl rand -hex 4)}"

  read -rp "请输入密码 [留空随机]: " PASSWORD
  PASSWORD="${PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"

  install_deps
  install_singbox_prerelease
  enable_bbr
  write_meta
  write_config
  write_service
  restart_singbox
  show_link
}

menu() {
  while true; do
    clear

    echo "========================================"
    echo " sing-box Naive 管理脚本"
    echo "========================================"

    echo "1. 安装 / 重装"
    echo "2. 查看链接"
    echo "0. 退出"

    echo

    read -rp "请选择: " choice

    case "$choice" in
      1) install_naive ;;
      2) show_link ;;
      0) exit 0 ;;
      *) red "无效选项" ;;
    esac

    echo
    read -rp "按回车继续..."
  done
}

menu
