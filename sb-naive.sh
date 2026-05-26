#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
META_FILE="/etc/sing-box/meta.info"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
ACME_DIR="/var/lib/sing-box/acme"

red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

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
    red "不支持的系统，仅建议 Debian/Ubuntu/CentOS/RHEL 系"
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

  sing-box version | head -n 3
}

enable_bbr() {
  modprobe tcp_bbr 2>/dev/null || true
  grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp || true
    ufw allow "${NAIVE_PORT}/tcp" || true
    ufw allow "${ANYTLS_PORT}/tcp" || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=80/tcp || true
    firewall-cmd --permanent --add-port="${NAIVE_PORT}/tcp" || true
    firewall-cmd --permanent --add-port="${ANYTLS_PORT}/tcp" || true
    firewall-cmd --reload || true
  fi
}

write_meta() {
  mkdir -p "$CONFIG_DIR"
  cat > "$META_FILE" <<EOF
DOMAIN="${DOMAIN}"
EMAIL="${EMAIL}"
NAIVE_PORT="${NAIVE_PORT}"
NAIVE_USERNAME="${NAIVE_USERNAME}"
NAIVE_PASSWORD="${NAIVE_PASSWORD}"
ANYTLS_PORT="${ANYTLS_PORT}"
ANYTLS_NAME="${ANYTLS_NAME}"
ANYTLS_PASSWORD="${ANYTLS_PASSWORD}"
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
      "tag": "shared-cert",
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
      "listen_port": ${NAIVE_PORT},
      "network": "tcp",
      "users": [
        {
          "username": "${NAIVE_USERNAME}",
          "password": "${NAIVE_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_provider": "shared-cert",
        "handshake_timeout": "15s"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [
        {
          "name": "${ANYTLS_NAME}",
          "password": "${ANYTLS_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_provider": "shared-cert",
        "handshake_timeout": "15s"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
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

show_links() {
  load_meta || { red "未安装"; return; }

  echo
  green "Naive URI："
  echo "https://${NAIVE_USERNAME}:${NAIVE_PASSWORD}@${DOMAIN}:${NAIVE_PORT}"

  echo
  green "Naive sing-box outbound："
  cat <<EOF
{
  "type": "naive",
  "tag": "naive-out",
  "server": "${DOMAIN}",
  "server_port": ${NAIVE_PORT},
  "username": "${NAIVE_USERNAME}",
  "password": "${NAIVE_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}"
  }
}
EOF

  echo
  green "AnyTLS sing-box outbound："
  cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "${DOMAIN}",
  "server_port": ${ANYTLS_PORT},
  "password": "${ANYTLS_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}"
  }
}
EOF

  echo
  green "当前服务端信息："
  echo "域名: ${DOMAIN}"
  echo "Naive 端口: ${NAIVE_PORT}"
  echo "Naive 用户名: ${NAIVE_USERNAME}"
  echo "Naive 密码: ${NAIVE_PASSWORD}"
  echo "AnyTLS 端口: ${ANYTLS_PORT}"
  echo "AnyTLS 用户名: ${ANYTLS_NAME}"
  echo "AnyTLS 密码: ${ANYTLS_PASSWORD}"
}

install_all() {
  read -rp "请输入域名: " DOMAIN
  read -rp "请输入 ACME 邮箱: " EMAIL

  read -rp "请输入 Naive 端口 [默认443]: " NAIVE_PORT
  NAIVE_PORT="${NAIVE_PORT:-443}"

  read -rp "请输入 AnyTLS 端口 [默认8443]: " ANYTLS_PORT
  ANYTLS_PORT="${ANYTLS_PORT:-8443}"

  read -rp "请输入 Naive 用户名 [留空随机]: " NAIVE_USERNAME
  NAIVE_USERNAME="${NAIVE_USERNAME:-naive_$(openssl rand -hex 4)}"

  read -rp "请输入 Naive 密码 [留空随机]: " NAIVE_PASSWORD
  NAIVE_PASSWORD="${NAIVE_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"

  read -rp "请输入 AnyTLS 用户名 [留空随机]: " ANYTLS_NAME
  ANYTLS_NAME="${ANYTLS_NAME:-anytls_$(openssl rand -hex 4)}"

  read -rp "请输入 AnyTLS 密码 [留空随机]: " ANYTLS_PASSWORD
  ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"

  install_deps
  install_singbox_prerelease
  enable_bbr
  write_meta
  write_config
  write_service
  open_firewall
  restart_singbox
  show_links
}

change_naive_password() {
  load_meta || { red "未安装"; return; }
  read -rp "请输入 Naive 新密码 [留空随机]: " NEW_PASSWORD
  NAIVE_PASSWORD="${NEW_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"
  write_meta
  write_config
  restart_singbox
  green "Naive 密码修改成功"
  show_links
}

change_anytls_password() {
  load_meta || { red "未安装"; return; }
  read -rp "请输入 AnyTLS 新密码 [留空随机]: " NEW_PASSWORD
  ANYTLS_PASSWORD="${NEW_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"
  write_meta
  write_config
  restart_singbox
  green "AnyTLS 密码修改成功"
  show_links
}

change_ports() {
  load_meta || { red "未安装"; return; }
  read -rp "请输入新的 Naive 端口 [当前 ${NAIVE_PORT}]: " NEW_NAIVE_PORT
  read -rp "请输入新的 AnyTLS 端口 [当前 ${ANYTLS_PORT}]: " NEW_ANYTLS_PORT
  NAIVE_PORT="${NEW_NAIVE_PORT:-$NAIVE_PORT}"
  ANYTLS_PORT="${NEW_ANYTLS_PORT:-$ANYTLS_PORT}"
  [[ "$NAIVE_PORT" =~ ^[0-9]+$ ]] || { red "Naive 端口不合法"; return; }
  [[ "$ANYTLS_PORT" =~ ^[0-9]+$ ]] || { red "AnyTLS 端口不合法"; return; }
  write_meta
  write_config
  open_firewall
  restart_singbox
  green "端口修改成功"
  show_links
}

update_singbox() {
  install_deps
  systemctl stop sing-box || true
  install_singbox_prerelease
  restart_singbox
  green "sing-box 更新完成"
}

uninstall_singbox() {
  read -rp "确认卸载 sing-box 和配置？[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || return

  systemctl stop sing-box || true
  systemctl disable sing-box || true
  rm -f "$SERVICE_FILE"
  rm -rf "$CONFIG_DIR"
  rm -rf "$ACME_DIR"
  rm -f /usr/local/bin/sing-box
  systemctl daemon-reload

  green "卸载完成"
}

menu() {
  while true; do
    clear
    echo "========================================"
    echo " sing-box Naive + AnyTLS 管理脚本"
    echo "========================================"
    echo "1. 安装 / 重装 Naive + AnyTLS"
    echo "2. 查看链接 + outbound"
    echo "3. 修改 Naive 密码"
    echo "4. 修改 AnyTLS 密码"
    echo "5. 修改端口"
    echo "6. 重启 sing-box"
    echo "7. 查看状态"
    echo "8. 查看日志"
    echo "9. 更新 sing-box 预发布版"
    echo "10. 卸载 sing-box"
    echo "0. 退出"
    echo

    read -rp "请选择: " choice

    case "$choice" in
      1) install_all ;;
      2) show_links ;;
      3) change_naive_password ;;
      4) change_anytls_password ;;
      5) change_ports ;;
      6) restart_singbox && green "已重启" ;;
      7) systemctl status sing-box --no-pager || true ;;
      8) journalctl -u sing-box -f ;;
      9) update_singbox ;;
      10) uninstall_singbox ;;
      0) exit 0 ;;
      *) red "无效选项" ;;
    esac

    echo
    read -rp "按回车继续..."
  done
}

menu
