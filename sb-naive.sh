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
  [[ -n "$TAG" && "$TAG" != "null" ]] || { red "没有找到 sing-box prerelease 版本"; exit 1; }

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

need_acme() {
  [[ "${ENABLE_NAIVE}" == "true" || "${ENABLE_ANYTLS}" == "true" ]]
}

port_in_use() {
  local port="$1"
  ss -lntup 2>/dev/null | grep -qE ":${port}\b"
}

check_ports() {
  [[ "${ENABLE_NAIVE}" == "true" ]] && port_in_use "${NAIVE_PORT}" && yellow "警告：Naive 端口 ${NAIVE_PORT} 可能已被占用"
  [[ "${ENABLE_ANYTLS}" == "true" ]] && port_in_use "${ANYTLS_PORT}" && yellow "警告：AnyTLS TLS 端口 ${ANYTLS_PORT} 可能已被占用"
  [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]] && port_in_use "${ANYTLS_REALITY_PORT}" && yellow "警告：AnyTLS Reality 端口 ${ANYTLS_REALITY_PORT} 可能已被占用"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    need_acme && ufw allow 80/tcp || true
    [[ "${ENABLE_NAIVE}" == "true" ]] && ufw allow "${NAIVE_PORT}/tcp" || true
    [[ "${ENABLE_ANYTLS}" == "true" ]] && ufw allow "${ANYTLS_PORT}/tcp" || true
    [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]] && ufw allow "${ANYTLS_REALITY_PORT}/tcp" || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    need_acme && firewall-cmd --permanent --add-port=80/tcp || true
    [[ "${ENABLE_NAIVE}" == "true" ]] && firewall-cmd --permanent --add-port="${NAIVE_PORT}/tcp" || true
    [[ "${ENABLE_ANYTLS}" == "true" ]] && firewall-cmd --permanent --add-port="${ANYTLS_PORT}/tcp" || true
    [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]] && firewall-cmd --permanent --add-port="${ANYTLS_REALITY_PORT}/tcp" || true
    firewall-cmd --reload || true
  fi
}

generate_anytls_reality_keys() {
  local pair
  pair="$(sing-box generate reality-keypair)"
  ANYTLS_REALITY_PRIVATE_KEY="$(echo "$pair" | awk '/PrivateKey|Private key|private_key/ {print $2; exit}')"
  ANYTLS_REALITY_PUBLIC_KEY="$(echo "$pair" | awk '/PublicKey|Public key|public_key/ {print $2; exit}')"
  [[ -n "${ANYTLS_REALITY_PRIVATE_KEY:-}" && -n "${ANYTLS_REALITY_PUBLIC_KEY:-}" ]] || { red "AnyTLS Reality 密钥生成失败"; echo "$pair"; exit 1; }
  ANYTLS_REALITY_SHORT_ID="$(openssl rand -hex 8)"
}

write_meta() {
  mkdir -p "$CONFIG_DIR"
  cat > "$META_FILE" <<EOF
SERVER_HOST="${SERVER_HOST}"
CERT_DOMAIN="${CERT_DOMAIN}"
EMAIL="${EMAIL}"
ENABLE_NAIVE="${ENABLE_NAIVE}"
ENABLE_ANYTLS="${ENABLE_ANYTLS}"
ENABLE_ANYTLS_REALITY="${ENABLE_ANYTLS_REALITY}"
NAIVE_PORT="${NAIVE_PORT}"
NAIVE_USERNAME="${NAIVE_USERNAME}"
NAIVE_PASSWORD="${NAIVE_PASSWORD}"
ANYTLS_PORT="${ANYTLS_PORT}"
ANYTLS_NAME="${ANYTLS_NAME}"
ANYTLS_PASSWORD="${ANYTLS_PASSWORD}"
ANYTLS_REALITY_PORT="${ANYTLS_REALITY_PORT}"
ANYTLS_REALITY_NAME="${ANYTLS_REALITY_NAME}"
ANYTLS_REALITY_PASSWORD="${ANYTLS_REALITY_PASSWORD}"
ANYTLS_REALITY_PRIVATE_KEY="${ANYTLS_REALITY_PRIVATE_KEY}"
ANYTLS_REALITY_PUBLIC_KEY="${ANYTLS_REALITY_PUBLIC_KEY}"
ANYTLS_REALITY_SHORT_ID="${ANYTLS_REALITY_SHORT_ID}"
ANYTLS_REALITY_SNI="${ANYTLS_REALITY_SNI}"
EOF
}

load_meta() {
  [[ -f "$META_FILE" ]] || return 1
  source "$META_FILE"
  SERVER_HOST="${SERVER_HOST:-${DOMAIN:-}}"
  CERT_DOMAIN="${CERT_DOMAIN:-${DOMAIN:-}}"
  EMAIL="${EMAIL:-}"
  ENABLE_NAIVE="${ENABLE_NAIVE:-true}"
  ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}"
  ENABLE_ANYTLS_REALITY="${ENABLE_ANYTLS_REALITY:-false}"
  NAIVE_PORT="${NAIVE_PORT:-443}"
  NAIVE_USERNAME="${NAIVE_USERNAME:-}"
  NAIVE_PASSWORD="${NAIVE_PASSWORD:-}"
  ANYTLS_PORT="${ANYTLS_PORT:-8443}"
  ANYTLS_NAME="${ANYTLS_NAME:-}"
  ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-}"
  ANYTLS_REALITY_PORT="${ANYTLS_REALITY_PORT:-9443}"
  ANYTLS_REALITY_NAME="${ANYTLS_REALITY_NAME:-}"
  ANYTLS_REALITY_PASSWORD="${ANYTLS_REALITY_PASSWORD:-}"
  ANYTLS_REALITY_PRIVATE_KEY="${ANYTLS_REALITY_PRIVATE_KEY:-}"
  ANYTLS_REALITY_PUBLIC_KEY="${ANYTLS_REALITY_PUBLIC_KEY:-}"
  ANYTLS_REALITY_SHORT_ID="${ANYTLS_REALITY_SHORT_ID:-}"
  ANYTLS_REALITY_SNI="${ANYTLS_REALITY_SNI:-www.bing.com}"
}

build_certificate_json() {
  if need_acme; then
    cat <<EOF
  "certificate_providers": [
    {
      "type": "acme",
      "tag": "shared-cert",
      "domain": [
        "${CERT_DOMAIN}"
      ],
      "email": "${EMAIL}",
      "data_directory": "${ACME_DIR}",
      "default_server_name": "${CERT_DOMAIN}",
      "disable_tls_alpn_challenge": true,
      "key_type": "p256"
    }
  ],
EOF
  fi
}

build_inbounds_json() {
  local first="true"

  if [[ "${ENABLE_NAIVE}" == "true" ]]; then
    cat <<EOF
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
        "server_name": "${CERT_DOMAIN}",
        "certificate_provider": "shared-cert",
        "handshake_timeout": "15s"
      }
    }
EOF
    first="false"
  fi

  if [[ "${ENABLE_ANYTLS}" == "true" ]]; then
    [[ "$first" == "false" ]] && echo "    ,"
    cat <<EOF
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
        "server_name": "${CERT_DOMAIN}",
        "certificate_provider": "shared-cert",
        "handshake_timeout": "15s"
      }
    }
EOF
    first="false"
  fi

  if [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]]; then
    [[ "$first" == "false" ]] && echo "    ,"
    cat <<EOF
    {
      "type": "anytls",
      "tag": "anytls-reality-in",
      "listen": "::",
      "listen_port": ${ANYTLS_REALITY_PORT},
      "users": [
        {
          "name": "${ANYTLS_REALITY_NAME}",
          "password": "${ANYTLS_REALITY_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${ANYTLS_REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${ANYTLS_REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${ANYTLS_REALITY_PRIVATE_KEY}",
          "short_id": [
            "${ANYTLS_REALITY_SHORT_ID}"
          ]
        }
      }
    }
EOF
  fi
}

write_config() {
  mkdir -p "$CONFIG_DIR" "$ACME_DIR"
  cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
$(build_certificate_json)  "inbounds": [
$(build_inbounds_json)
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
  green "当前安装模式："
  [[ "${ENABLE_NAIVE}" == "true" ]] && echo "- Naive: 已启用" || echo "- Naive: 未启用"
  [[ "${ENABLE_ANYTLS}" == "true" ]] && echo "- AnyTLS TLS: 已启用" || echo "- AnyTLS TLS: 未启用"
  [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]] && echo "- AnyTLS Reality: 已启用" || echo "- AnyTLS Reality: 未启用"

  if [[ "${ENABLE_NAIVE}" == "true" ]]; then
    echo
    green "Naive URI："
    echo "https://${NAIVE_USERNAME}:${NAIVE_PASSWORD}@${CERT_DOMAIN}:${NAIVE_PORT}"
    echo
    green "Naive sing-box outbound："
    cat <<EOF
{
  "type": "naive",
  "tag": "naive-out",
  "server": "${SERVER_HOST}",
  "server_port": ${NAIVE_PORT},
  "username": "${NAIVE_USERNAME}",
  "password": "${NAIVE_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${CERT_DOMAIN}"
  }
}
EOF
  fi

  if [[ "${ENABLE_ANYTLS}" == "true" ]]; then
    echo
    green "AnyTLS TLS sing-box outbound："
    cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-out",
  "server": "${SERVER_HOST}",
  "server_port": ${ANYTLS_PORT},
  "password": "${ANYTLS_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${CERT_DOMAIN}"
  }
}
EOF
  fi

  if [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]]; then
    echo
    green "AnyTLS Reality sing-box outbound："
    cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-reality-out",
  "server": "${SERVER_HOST}",
  "server_port": ${ANYTLS_REALITY_PORT},
  "password": "${ANYTLS_REALITY_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${ANYTLS_REALITY_SNI}",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "${ANYTLS_REALITY_PUBLIC_KEY}",
      "short_id": "${ANYTLS_REALITY_SHORT_ID}"
    }
  }
}
EOF
  fi

  echo
  green "当前服务端信息："
  echo "连接地址: ${SERVER_HOST}"
  need_acme && echo "证书域名: ${CERT_DOMAIN}"
  [[ "${ENABLE_NAIVE}" == "true" ]] && echo "Naive: ${NAIVE_PORT} / ${NAIVE_USERNAME} / ${NAIVE_PASSWORD}"
  [[ "${ENABLE_ANYTLS}" == "true" ]] && echo "AnyTLS TLS: ${ANYTLS_PORT} / ${ANYTLS_NAME} / ${ANYTLS_PASSWORD}"
  [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]] && echo "AnyTLS Reality: ${ANYTLS_REALITY_PORT} / ${ANYTLS_REALITY_NAME} / ${ANYTLS_REALITY_PASSWORD} / SNI=${ANYTLS_REALITY_SNI} / ShortID=${ANYTLS_REALITY_SHORT_ID}"
}

choose_install_mode() {
  echo
  echo "请选择安装模式："
  echo "1. 只安装 Naive（需要证书域名 + ACME）"
  echo "2. 只安装 AnyTLS TLS（需要证书域名 + ACME）"
  echo "3. 只安装 AnyTLS Reality（不需要域名/ACME，可直接用 VPS IP）"
  echo "4. Naive + AnyTLS TLS"
  echo "5. Naive + AnyTLS Reality"
  echo "6. AnyTLS TLS + AnyTLS Reality"
  echo "7. Naive + AnyTLS TLS + AnyTLS Reality"
  echo
  read -rp "请选择 [默认7]: " mode
  mode="${mode:-7}"
  case "$mode" in
    1) ENABLE_NAIVE="true"; ENABLE_ANYTLS="false"; ENABLE_ANYTLS_REALITY="false" ;;
    2) ENABLE_NAIVE="false"; ENABLE_ANYTLS="true"; ENABLE_ANYTLS_REALITY="false" ;;
    3) ENABLE_NAIVE="false"; ENABLE_ANYTLS="false"; ENABLE_ANYTLS_REALITY="true" ;;
    4) ENABLE_NAIVE="true"; ENABLE_ANYTLS="true"; ENABLE_ANYTLS_REALITY="false" ;;
    5) ENABLE_NAIVE="true"; ENABLE_ANYTLS="false"; ENABLE_ANYTLS_REALITY="true" ;;
    6) ENABLE_NAIVE="false"; ENABLE_ANYTLS="true"; ENABLE_ANYTLS_REALITY="true" ;;
    7) ENABLE_NAIVE="true"; ENABLE_ANYTLS="true"; ENABLE_ANYTLS_REALITY="true" ;;
    *) red "无效安装模式"; return 1 ;;
  esac
}

prompt_common() {
  read -rp "请输入客户端连接地址 SERVER_HOST（VPS IP 或域名）: " SERVER_HOST
  [[ -n "$SERVER_HOST" ]] || { red "SERVER_HOST 不能为空"; return 1; }
  if need_acme; then
    read -rp "请输入证书域名 CERT_DOMAIN（默认同 SERVER_HOST，必须已解析到 VPS）: " CERT_DOMAIN
    CERT_DOMAIN="${CERT_DOMAIN:-$SERVER_HOST}"
    read -rp "请输入 ACME 邮箱: " EMAIL
    [[ -n "$EMAIL" ]] || { red "需要 ACME 邮箱"; return 1; }
  else
    CERT_DOMAIN=""
    EMAIL=""
  fi
}

prompt_protocols() {
  if [[ "${ENABLE_NAIVE}" == "true" ]]; then
    read -rp "请输入 Naive 端口 [默认443]: " NAIVE_PORT
    NAIVE_PORT="${NAIVE_PORT:-443}"
    read -rp "请输入 Naive 用户名 [留空随机]: " NAIVE_USERNAME
    NAIVE_USERNAME="${NAIVE_USERNAME:-naive_$(openssl rand -hex 4)}"
    read -rp "请输入 Naive 密码 [留空随机]: " NAIVE_PASSWORD
    NAIVE_PASSWORD="${NAIVE_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"
  else
    NAIVE_PORT="${NAIVE_PORT:-443}"; NAIVE_USERNAME="${NAIVE_USERNAME:-}"; NAIVE_PASSWORD="${NAIVE_PASSWORD:-}"
  fi

  if [[ "${ENABLE_ANYTLS}" == "true" ]]; then
    read -rp "请输入 AnyTLS TLS 端口 [默认8443]: " ANYTLS_PORT
    ANYTLS_PORT="${ANYTLS_PORT:-8443}"
    read -rp "请输入 AnyTLS TLS 用户名 [留空随机]: " ANYTLS_NAME
    ANYTLS_NAME="${ANYTLS_NAME:-anytls_$(openssl rand -hex 4)}"
    read -rp "请输入 AnyTLS TLS 密码 [留空随机]: " ANYTLS_PASSWORD
    ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"
  else
    ANYTLS_PORT="${ANYTLS_PORT:-8443}"; ANYTLS_NAME="${ANYTLS_NAME:-}"; ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-}"
  fi

  if [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]]; then
    read -rp "请输入 AnyTLS Reality 端口 [默认9443]: " ANYTLS_REALITY_PORT
    ANYTLS_REALITY_PORT="${ANYTLS_REALITY_PORT:-9443}"
    read -rp "请输入 AnyTLS Reality 用户名 [留空随机]: " ANYTLS_REALITY_NAME
    ANYTLS_REALITY_NAME="${ANYTLS_REALITY_NAME:-anytls_reality_$(openssl rand -hex 4)}"
    read -rp "请输入 AnyTLS Reality 密码 [留空随机]: " ANYTLS_REALITY_PASSWORD
    ANYTLS_REALITY_PASSWORD="${ANYTLS_REALITY_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"
    read -rp "请输入 AnyTLS Reality 伪装 SNI [默认www.bing.com]: " ANYTLS_REALITY_SNI
    ANYTLS_REALITY_SNI="${ANYTLS_REALITY_SNI:-www.bing.com}"
  else
    ANYTLS_REALITY_PORT="${ANYTLS_REALITY_PORT:-9443}"; ANYTLS_REALITY_NAME="${ANYTLS_REALITY_NAME:-}"; ANYTLS_REALITY_PASSWORD="${ANYTLS_REALITY_PASSWORD:-}"; ANYTLS_REALITY_SNI="${ANYTLS_REALITY_SNI:-www.bing.com}"
  fi
}

ensure_anytls_reality_materials() {
  if [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]]; then
    if [[ -z "${ANYTLS_REALITY_PRIVATE_KEY:-}" || -z "${ANYTLS_REALITY_PUBLIC_KEY:-}" || -z "${ANYTLS_REALITY_SHORT_ID:-}" ]]; then
      generate_anytls_reality_keys
    fi
  fi
}

install_all() {
  choose_install_mode || return
  prompt_common || return
  prompt_protocols
  install_deps
  install_singbox_prerelease
  enable_bbr
  ensure_anytls_reality_materials
  check_ports
  write_meta
  write_config
  write_service
  open_firewall
  restart_singbox
  show_links
}

switch_mode() {
  load_meta || { red "未安装"; return; }
  choose_install_mode || return
  read -rp "请输入客户端连接地址 SERVER_HOST [当前 ${SERVER_HOST}]: " NEW_SERVER_HOST
  SERVER_HOST="${NEW_SERVER_HOST:-$SERVER_HOST}"
  if need_acme; then
    read -rp "请输入证书域名 CERT_DOMAIN [当前 ${CERT_DOMAIN:-$SERVER_HOST}]: " NEW_CERT_DOMAIN
    CERT_DOMAIN="${NEW_CERT_DOMAIN:-${CERT_DOMAIN:-$SERVER_HOST}}"
    if [[ -z "${EMAIL:-}" ]]; then read -rp "请输入 ACME 邮箱: " EMAIL; fi
  else
    CERT_DOMAIN=""; EMAIL=""
  fi
  prompt_protocols
  ensure_anytls_reality_materials
  write_meta
  write_config
  open_firewall
  restart_singbox
  green "安装模式已切换"
  show_links
}

change_naive_password() {
  load_meta || { red "未安装"; return; }
  [[ "${ENABLE_NAIVE}" == "true" ]] || { red "Naive 未启用"; return; }
  read -rp "请输入 Naive 新密码 [留空随机]: " NEW_PASSWORD
  NAIVE_PASSWORD="${NEW_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"
  write_meta; write_config; restart_singbox; green "Naive 密码修改成功"; show_links
}

change_anytls_password() {
  load_meta || { red "未安装"; return; }
  [[ "${ENABLE_ANYTLS}" == "true" ]] || { red "AnyTLS TLS 未启用"; return; }
  read -rp "请输入 AnyTLS TLS 新密码 [留空随机]: " NEW_PASSWORD
  ANYTLS_PASSWORD="${NEW_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"
  write_meta; write_config; restart_singbox; green "AnyTLS TLS 密码修改成功"; show_links
}

change_anytls_reality_password() {
  load_meta || { red "未安装"; return; }
  [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]] || { red "AnyTLS Reality 未启用"; return; }
  read -rp "请输入 AnyTLS Reality 新密码 [留空随机]: " NEW_PASSWORD
  ANYTLS_REALITY_PASSWORD="${NEW_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/')}"
  write_meta; write_config; restart_singbox; green "AnyTLS Reality 密码修改成功"; show_links
}

regenerate_anytls_reality() {
  load_meta || { red "未安装"; return; }
  [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]] || { red "AnyTLS Reality 未启用"; return; }
  generate_anytls_reality_keys
  write_meta; write_config; restart_singbox; green "AnyTLS Reality keypair / short_id 已重新生成"; show_links
}

change_ports() {
  load_meta || { red "未安装"; return; }
  if [[ "${ENABLE_NAIVE}" == "true" ]]; then read -rp "请输入新的 Naive 端口 [当前 ${NAIVE_PORT}]: " p; NAIVE_PORT="${p:-$NAIVE_PORT}"; fi
  if [[ "${ENABLE_ANYTLS}" == "true" ]]; then read -rp "请输入新的 AnyTLS TLS 端口 [当前 ${ANYTLS_PORT}]: " p; ANYTLS_PORT="${p:-$ANYTLS_PORT}"; fi
  if [[ "${ENABLE_ANYTLS_REALITY}" == "true" ]]; then read -rp "请输入新的 AnyTLS Reality 端口 [当前 ${ANYTLS_REALITY_PORT}]: " p; ANYTLS_REALITY_PORT="${p:-$ANYTLS_REALITY_PORT}"; fi
  [[ "$NAIVE_PORT" =~ ^[0-9]+$ ]] || { red "Naive 端口不合法"; return; }
  [[ "$ANYTLS_PORT" =~ ^[0-9]+$ ]] || { red "AnyTLS TLS 端口不合法"; return; }
  [[ "$ANYTLS_REALITY_PORT" =~ ^[0-9]+$ ]] || { red "AnyTLS Reality 端口不合法"; return; }
  write_meta; write_config; open_firewall; restart_singbox; green "端口修改成功"; show_links
}

update_singbox() {
  load_meta || true
  install_deps
  systemctl stop sing-box || true
  install_singbox_prerelease
  ensure_anytls_reality_materials
  restart_singbox
  green "sing-box 更新完成"
}

uninstall_singbox() {
  read -rp "确认卸载 sing-box 和配置？[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || return
  systemctl stop sing-box || true
  systemctl disable sing-box || true
  rm -f "$SERVICE_FILE"
  rm -rf "$CONFIG_DIR" "$ACME_DIR"
  rm -f /usr/local/bin/sing-box
  systemctl daemon-reload
  green "卸载完成"
}

menu() {
  while true; do
    clear
    echo "========================================"
    echo " sing-box Naive / AnyTLS / AnyTLS Reality 管理脚本"
    echo "========================================"
    echo "1. 安装 / 重装"
    echo "2. 查看链接 + outbound"
    echo "3. 切换安装模式"
    echo "4. 修改 Naive 密码"
    echo "5. 修改 AnyTLS TLS 密码"
    echo "6. 修改 AnyTLS Reality 密码"
    echo "7. 重新生成 AnyTLS Reality 密钥"
    echo "8. 修改端口"
    echo "9. 重启 sing-box"
    echo "10. 查看状态"
    echo "11. 查看日志"
    echo "12. 更新 sing-box 预发布版"
    echo "13. 卸载 sing-box"
    echo "0. 退出"
    echo
    read -rp "请选择: " choice
    case "$choice" in
      1) install_all ;;
      2) show_links ;;
      3) switch_mode ;;
      4) change_naive_password ;;
      5) change_anytls_password ;;
      6) change_anytls_reality_password ;;
      7) regenerate_anytls_reality ;;
      8) change_ports ;;
      9) restart_singbox && green "已重启" ;;
      10) systemctl status sing-box --no-pager || true ;;
      11) journalctl -u sing-box -f ;;
      12) update_singbox ;;
      13) uninstall_singbox ;;
      0) exit 0 ;;
      *) red "无效选项" ;;
    esac
    echo
    read -rp "按回车继续..."
  done
}

menu
