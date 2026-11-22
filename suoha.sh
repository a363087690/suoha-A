#!/usr/bin/env bash
# =============================================================
#  suoha.sh - 智能双通道代理一键部署
#
#  主通道: VLESS + Vision + REALITY (TCP, 默认 443, 无需域名/证书)
#  备通道: Hysteria2 (UDP/QUIC, 默认 8443, 自签证书 + pinSHA256)
#
#  特性:
#    - 自动识别系统/架构/公网 IP
#    - 支持 IPv4-only / IPv6-only / 双栈，双栈同时下发 v4/v6 节点
#    - 自动测速挑选 REALITY 伪装目标
#    - 443 被占用时自动换端口
#    - Hysteria2 不可用时自动降级为纯 REALITY
#    - BBR + fq + 文件句柄优化
#    - systemd 崩溃自动重启
#    - 生成客户端链接和 Clash Meta 自动择优配置
#
#  支持: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma/Fedora, Arch (systemd)
#  前提: 服务器有公网 IPv4 或 IPv6（NAT/无公网 IP 需另用 CDN/Argo 方案）
#
#  用法:
#    bash suoha.sh                 交互菜单（非交互环境直接部署）
#    bash suoha.sh --install       部署（已安装则只显示状态）
#    bash suoha.sh --install --force
#    bash suoha.sh --status
#    bash suoha.sh --links
#    bash suoha.sh --update
#    bash suoha.sh --uninstall [--yes]
#    bash suoha.sh --no-hysteria   仅部署 REALITY
# =============================================================
set -uo pipefail

if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

info() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[x]${NC} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
line() { printf '%s\n' "------------------------------------------------------------"; }

SUOHA_DIR="/etc/suoha"
STATE_FILE="$SUOHA_DIR/state.env"
XRAY_BIN="/usr/local/bin/suoha-xray"
XRAY_CONF="/usr/local/etc/suoha/xray.json"
XRAY_UNIT="/etc/systemd/system/suoha-xray.service"
HY_BIN="/usr/local/bin/suoha-hysteria"
HY_CONF="$SUOHA_DIR/hysteria.yaml"
HY_UNIT="/etc/systemd/system/suoha-hysteria.service"
CLASH_FILE="$SUOHA_DIR/clash-meta.yaml"
SYSCTL_FILE="/etc/sysctl.d/99-suoha-ai.conf"

PKG_MGR=""
ARCH=""
XRAY_ASSET=""
HY_ASSET=""
TMP_DIR=""

FORCE=0
ASSUME_YES=0
HY_ENABLED=1

LISTEN_ADDR=""
CLIENT_HOST=""
CLIENT_V4=""
CLIENT_V6=""
HOST_IS_V6=0
DUAL_STACK=0
PUB_V4=""
PUB_V6=""
PORT=""
REALITY_SNI=""
REALITY_PRIV=""
REALITY_PUB=""
UUID=""
SID=""
HY_PORT="0"
HY_PASS=""
HY_SNI="www.bing.com"
HY_PIN=""

SELF="${0##*/}"
case "$SELF" in
  bash|sh|dash|-bash|"") SELF="suoha.sh" ;;
esac

cleanup() {
  [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ensure_tmp() {
  if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
    TMP_DIR="$(mktemp -d)" || die "无法创建临时目录"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "请使用 root 运行（sudo bash $SELF ...）"
  fi
}

detect_os() {
  [ -r /etc/os-release ] || die "无法读取 /etc/os-release，不支持该系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_PRETTY="${PRETTY_NAME:-${ID:-Linux}}"
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"

  case "$OS_ID" in
    debian|ubuntu|linuxmint|raspbian|pop) PKG_MGR="apt" ;;
    centos|rhel|rocky|almalinux|ol|fedora) PKG_MGR="dnf" ;;
    arch|manjaro|endeavouros) PKG_MGR="pacman" ;;
    *)
      case "$OS_LIKE" in
        *debian*|*ubuntu*) PKG_MGR="apt" ;;
        *rhel*|*fedora*) PKG_MGR="dnf" ;;
        *) die "不支持的发行版: $OS_PRETTY（仅支持 Debian/Ubuntu、RHEL 系、Arch）" ;;
      esac
      ;;
  esac
  if [ "$PKG_MGR" = "dnf" ] && ! have dnf; then
    PKG_MGR="yum"
  fi

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)   XRAY_ASSET="Xray-linux-64.zip";        HY_ASSET="hysteria-linux-amd64" ;;
    i386|i686)      XRAY_ASSET="Xray-linux-32.zip";        HY_ASSET="hysteria-linux-386" ;;
    aarch64|arm64)  XRAY_ASSET="Xray-linux-arm64-v8a.zip"; HY_ASSET="hysteria-linux-arm64" ;;
    armv7l|armv7)   XRAY_ASSET="Xray-linux-arm32-v7a.zip"; HY_ASSET="hysteria-linux-arm" ;;
    armv6l)         XRAY_ASSET="Xray-linux-arm32-v6.zip";  HY_ASSET="hysteria-linux-arm" ;;
    *) die "不支持的 CPU 架构: $ARCH" ;;
  esac
}

require_systemd() {
  if ! have systemctl || [ ! -d /run/systemd/system ]; then
    die "需要 systemd 才能注册开机自启服务；当前环境不支持（OpenVZ/LXC 容器请换 KVM VPS）。"
  fi
}

install_deps() {
  local need=""
  have curl || need="$need curl"
  have unzip || need="$need unzip"
  have openssl || need="$need openssl"
  have ss || need="$need iproute2"
  have pgrep || need="$need procps"
  if [ -z "$need" ]; then
    return 0
  fi

  info "安装依赖: $need"
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq || warn "apt update 失败，继续尝试安装"
      apt-get install -y -qq curl unzip openssl ca-certificates iproute2 procps || return 1
      ;;
    dnf)
      dnf -y -q install curl unzip openssl ca-certificates iproute procps-ng || return 1
      ;;
    yum)
      yum -y -q install curl unzip openssl ca-certificates iproute procps-ng || return 1
      ;;
    pacman)
      pacman -S --noconfirm --needed curl unzip openssl iproute2 procps-ng || return 1
      ;;
  esac

  local c
  for c in curl unzip openssl ss; do
    have "$c" || die "缺少命令: $c"
  done
  return 0
}

fetch() {
  local url="$1" out="$2"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 600 -o "$out" "$url"
}

install_xray_core() {
  ensure_tmp
  info "下载 Xray-core ($XRAY_ASSET)..."
  if ! fetch "https://github.com/XTLS/Xray-core/releases/latest/download/$XRAY_ASSET" "$TMP_DIR/xray.zip"; then
    return 1
  fi
  rm -rf "$TMP_DIR/xray"
  mkdir -p "$TMP_DIR/xray"
  unzip -oq "$TMP_DIR/xray.zip" -d "$TMP_DIR/xray" || return 1
  install -m 0755 "$TMP_DIR/xray/xray" "$XRAY_BIN" || return 1
  info "Xray: $("$XRAY_BIN" version 2>/dev/null | sed -n '1p')"
  return 0
}

install_hysteria_core() {
  ensure_tmp
  info "下载 Hysteria2 ($HY_ASSET)..."
  if ! fetch "https://github.com/apernet/hysteria/releases/latest/download/$HY_ASSET" "$TMP_DIR/hysteria"; then
    return 1
  fi
  install -m 0755 "$TMP_DIR/hysteria" "$HY_BIN" || return 1
  info "Hysteria: $("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2; exit}')"
  return 0
}

gen_material() {
  local out
  out="$("$XRAY_BIN" x25519 2>/dev/null)" || die "生成 REALITY 密钥失败"
  REALITY_PRIV="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
  REALITY_PUB="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}')"
  if [ -z "$REALITY_PRIV" ] || [ -z "$REALITY_PUB" ]; then
    REALITY_PRIV="$(printf '%s\n' "$out" | sed -n 's/^Private[Kk]ey: *//p' | sed -n '1p')"
    REALITY_PUB="$(printf '%s\n' "$out" | sed -n 's/^Password (PublicKey): *//p' | sed -n '1p')"
  fi
  [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ] || die "解析 REALITY 密钥失败"

  UUID="$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  SID="$(openssl rand -hex 8)"
  HY_PASS="$(openssl rand -hex 16)"
}

SNI_CANDIDATES=(
  "www.cloudflare.com"
  "dl.google.com"
  "www.bing.com"
  "www.samsung.com"
  "www.lovelive-anime.jp"
)

bench_sni() {
  local host="$1" t
  if [ "${HOST_IS_V6:-0}" = "1" ] && [ "${DUAL_STACK:-0}" != "1" ]; then
    t="$(curl -6 -o /dev/null -sS --max-time 5 -w '%{time_appconnect}' "https://$host" 2>/dev/null)"
  else
    t="$(curl -4 -o /dev/null -sS --max-time 5 -w '%{time_appconnect}' "https://$host" 2>/dev/null)"
  fi
  awk -v t="${t:-0}" 'BEGIN { if (t+0 > 0) printf "%d", t*1000; else print 999999 }'
}

choose_sni() {
  local host ms best="" best_ms=999999
  info "测速选择 REALITY 伪装目标..."
  for host in "${SNI_CANDIDATES[@]}"; do
    ms="$(bench_sni "$host")"
    if [ "$ms" -lt 999999 ]; then
      printf '    %-26s %5s ms\n' "$host" "$ms"
    else
      printf '    %-26s 超时\n' "$host"
    fi
    if [ "$ms" -lt "$best_ms" ]; then
      best_ms="$ms"
      best="$host"
    fi
  done
  if [ -z "$best" ]; then
    best="www.cloudflare.com"
    best_ms=0
    warn "所有候选目标均不可达，回退到 $best"
  fi
  REALITY_SNI="$best"
  info "已选择 $REALITY_SNI（${best_ms} ms）"
}

is_private_v4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^127\. ]] && return 0
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  return 1
}

get_public_ipv4() {
  local url ip
  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! is_private_v4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done

  # 外部接口不可用时，退回读取本机公网网卡地址
  while IFS= read -r ip; do
    if ! is_private_v4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  return 1
}

get_public_ipv6() {
  local url ip low
  for url in "https://api64.ipify.org" "https://ipv6.icanhazip.com" "https://ifconfig.co/ip"; do
    ip="$(curl -6 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')"
    low="$(printf '%s' "$ip" | tr 'A-Z' 'a-z')"
    if [[ "$ip" == *:* ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
      case "$low" in
        fe80:*|fc*|fd*|::1) ;;
        *) printf '%s' "$ip"; return 0 ;;
      esac
    fi
  done

  while IFS= read -r ip; do
    low="$(printf '%s' "$ip" | tr 'A-Z' 'a-z')"
    case "$low" in
      fe80:*|fc*|fd*|::1) continue ;;
    esac
    if [[ "$ip" == *:* ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done < <(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  return 1
}

detect_endpoint() {
  info "检测公网 IP..."
  PUB_V4="$(get_public_ipv4 || true)"
  PUB_V6="$(get_public_ipv6 || true)"
  CLIENT_V4="$PUB_V4"
  CLIENT_V6="$PUB_V6"

  if [ -n "$PUB_V4" ] && [ -n "$PUB_V6" ]; then
    CLIENT_HOST="$PUB_V4"
    LISTEN_ADDR="::"
    HOST_IS_V6=0
    DUAL_STACK=1
    info "公网 IPv4: $PUB_V4"
    info "公网 IPv6: $PUB_V6"
    info "检测到双栈，将同时下发 IPv4 和 IPv6 节点"
  elif [ -n "$PUB_V4" ]; then
    CLIENT_HOST="$PUB_V4"
    LISTEN_ADDR="0.0.0.0"
    HOST_IS_V6=0
    DUAL_STACK=0
    info "公网 IPv4: $PUB_V4（单栈 IPv4）"
  elif [ -n "$PUB_V6" ]; then
    CLIENT_HOST="$PUB_V6"
    LISTEN_ADDR="::"
    HOST_IS_V6=1
    DUAL_STACK=0
    info "公网 IPv6: $PUB_V6（单栈 IPv6）"
  else
    die "未检测到公网 IP。若在 NAT/容器内，请先做端口映射；本脚本需要公网 VPS。"
  fi
}

tcp_port_free() {
  local addrs
  addrs="$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}')" || return 0
  case $'\n'"$addrs"$'\n' in
    *":$1"$'\n'*) return 1 ;;
  esac
  return 0
}

udp_port_free() {
  local addrs
  addrs="$(ss -lun 2>/dev/null | awk 'NR>1 {print $4}')" || return 0
  case $'\n'"$addrs"$'\n' in
    *":$1"$'\n'*) return 1 ;;
  esac
  return 0
}

pick_tcp_port() {
  if tcp_port_free 443; then
    printf '443'
    return 0
  fi
  local p
  for _ in $(seq 1 30); do
    p=$((RANDOM % 20000 + 20000))
    if tcp_port_free "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf '24443'
}

pick_udp_port() {
  if udp_port_free 8443; then
    printf '8443'
    return 0
  fi
  local p
  for _ in $(seq 1 30); do
    p=$((RANDOM % 20000 + 20000))
    if udp_port_free "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf '28443'
}

write_xray_config() {
  ensure_tmp
  mkdir -p "$(dirname "$XRAY_CONF")"
  cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "$LISTEN_ADDR",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$REALITY_SNI:443",
          "xver": 0,
          "serverNames": ["$REALITY_SNI"],
          "privateKey": "$REALITY_PRIV",
          "shortIds": ["$SID"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
  chmod 600 "$XRAY_CONF"

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >"$TMP_DIR/xray-test.log" 2>&1; then
    cat "$TMP_DIR/xray-test.log"
    return 1
  fi
  return 0
}

write_hysteria_config() {
  mkdir -p "$SUOHA_DIR"
  chmod 700 "$SUOHA_DIR"

  info "生成 Hysteria2 自签证书..."
  "$HY_BIN" cert --host "$HY_SNI" \
      --cert "$SUOHA_DIR/cert.pem" \
      --key "$SUOHA_DIR/key.pem" \
      --valid-for 87600h --overwrite >/dev/null 2>&1 || {
    openssl ecparam -genkey -name prime256v1 -out "$SUOHA_DIR/key.pem" >/dev/null 2>&1 || return 1
    openssl req -new -x509 -days 3650 -key "$SUOHA_DIR/key.pem" \
      -out "$SUOHA_DIR/cert.pem" -subj "/CN=$HY_SNI" >/dev/null 2>&1 || return 1
  }

  HY_PIN="$(openssl x509 -in "$SUOHA_DIR/cert.pem" -outform der 2>/dev/null \
    | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')"
  [ -n "$HY_PIN" ] || return 1

  local hy_listen
  if [ "${DUAL_STACK:-0}" = "1" ]; then
    hy_listen=":$HY_PORT"
  elif [ "${HOST_IS_V6:-0}" = "1" ]; then
    hy_listen="[::]:$HY_PORT"
  else
    hy_listen="0.0.0.0:$HY_PORT"
  fi

  cat > "$HY_CONF" <<EOF
listen: "$hy_listen"
tls:
  cert: $SUOHA_DIR/cert.pem
  key: $SUOHA_DIR/key.pem
  sniGuard: disable
auth:
  type: password
  password: $HY_PASS
masquerade:
  type: proxy
  proxy:
    url: https://$HY_SNI/
    rewriteHost: true
EOF
  chmod 600 "$HY_CONF" "$SUOHA_DIR/key.pem"

  # 启动 4 秒做配置校验；正常启动会被 timeout 杀掉并返回 124
  local test_out rc
  test_out="$(timeout -k 2 4 "$HY_BIN" server --disable-update-check -c "$HY_CONF" 2>&1)"
  rc=$?
  if [ "$rc" -ne 124 ]; then
    printf '%s\n' "$test_out" | tail -n 20
    return 1
  fi
  return 0
}

write_units() {
  cat > "$XRAY_UNIT" <<EOF
[Unit]
Description=Suoha AI - Xray REALITY
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$XRAY_BIN run -c $XRAY_CONF
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  if [ "$HY_ENABLED" = "1" ]; then
    cat > "$HY_UNIT" <<EOF
[Unit]
Description=Suoha AI - Hysteria2
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$HY_BIN server --disable-update-check -c $HY_CONF
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  else
    rm -f "$HY_UNIT"
  fi
}

optimize_kernel() {
  local cc
  cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

  {
    echo "# suoha-ai: 自动生成的网络优化参数"
    echo "fs.file-max = 1048576"
    echo "net.core.somaxconn = 65535"
    echo "net.core.rmem_max = 16777216"
    echo "net.core.wmem_max = 16777216"
    echo "net.ipv4.tcp_fastopen = 3"
    echo "net.ipv4.tcp_max_syn_backlog = 65535"
    if printf '%s' "$cc" | grep -qw "bbr"; then
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    fi
  } > "$SYSCTL_FILE"

  sysctl --system >/dev/null 2>&1 || warn "部分 sysctl 参数应用失败（容器环境常见），不影响代理运行"

  if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    info "已启用 BBR + fq 拥塞控制"
  elif printf '%s' "$cc" | grep -qw "bbr"; then
    warn "内核支持 BBR，但当前未成功启用（可能是权限限制）"
  else
    warn "当前内核不支持 BBR，已跳过"
  fi
}

open_firewall() {
  local ufw_status=""
  if have ufw; then
    ufw_status="$(ufw status 2>/dev/null || true)"
  fi

  if [ -n "$ufw_status" ] && [[ "$ufw_status" == *"Status: active"* ]]; then
    ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
    if [ "$HY_ENABLED" = "1" ]; then
      ufw allow "$HY_PORT/udp" >/dev/null 2>&1 || true
    fi
    info "已在本机 ufw 放行端口"
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 || true
    if [ "$HY_ENABLED" = "1" ]; then
      firewall-cmd --permanent --add-port="$HY_PORT/udp" >/dev/null 2>&1 || true
    fi
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "已在本机 firewalld 放行端口"
  fi

  if [ "$HY_ENABLED" = "1" ]; then
    warn "请确认云厂商安全组已放行 TCP $PORT 和 UDP $HY_PORT"
  else
    warn "请确认云厂商安全组已放行 TCP $PORT"
  fi
}

save_state() {
  mkdir -p "$SUOHA_DIR"
  chmod 700 "$SUOHA_DIR"
  cat > "$STATE_FILE" <<EOF
CLIENT_HOST="$CLIENT_HOST"
CLIENT_V4="$CLIENT_V4"
CLIENT_V6="$CLIENT_V6"
HOST_IS_V6=$HOST_IS_V6
DUAL_STACK=$DUAL_STACK
PORT=$PORT
REALITY_SNI="$REALITY_SNI"
UUID="$UUID"
REALITY_PUB="$REALITY_PUB"
SID="$SID"
HY_ENABLED=$HY_ENABLED
HY_PORT=$HY_PORT
HY_PASS="$HY_PASS"
HY_SNI="$HY_SNI"
HY_PIN="$HY_PIN"
EOF
  chmod 600 "$STATE_FILE"
}

load_state() {
  if [ ! -f "$STATE_FILE" ]; then
    die "尚未安装，请先运行: bash $SELF --install"
  fi
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  DUAL_STACK="${DUAL_STACK:-0}"
  CLIENT_V4="${CLIENT_V4:-}"
  CLIENT_V6="${CLIENT_V6:-}"
  if [ -z "$CLIENT_V4" ] && [ "${HOST_IS_V6:-0}" = "0" ]; then
    CLIENT_V4="$CLIENT_HOST"
  fi
  if [ -z "$CLIENT_V6" ] && [ "${HOST_IS_V6:-0}" = "1" ]; then
    CLIENT_V6="$CLIENT_HOST"
  fi
}

fmt_host() {
  case "$1" in
    *:*) printf '[%s]' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

reality_link() {
  local host="$1" tag="${2:-Suoha-REALITY}"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s' \
    "$UUID" "$(fmt_host "$host")" "$PORT" "$REALITY_SNI" "$REALITY_PUB" "$SID" "$tag"
}

hysteria_link() {
  local host="$1" tag="${2:-Suoha-Hysteria2}"
  local params="sni=$HY_SNI&insecure=1"
  if [ -n "${HY_PIN:-}" ]; then
    params="$params&pinSHA256=$HY_PIN"
  fi
  printf 'hysteria2://%s@%s:%s/?%s#%s' \
    "$HY_PASS" "$(fmt_host "$host")" "$HY_PORT" "$params" "$tag"
}

clash_proxies_for() {
  local server="$1" suffix="$2"
  cat <<EOF
  - name: "Suoha-REALITY$suffix"
    type: vless
    server: "$server"
    port: $PORT
    uuid: "$UUID"
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: "$REALITY_SNI"
    client-fingerprint: chrome
    reality-opts:
      public-key: "$REALITY_PUB"
      short-id: "$SID"
EOF
  if [ "$HY_ENABLED" = "1" ]; then
    cat <<EOF
  - name: "Suoha-Hysteria2$suffix"
    type: hysteria2
    server: "$server"
    port: $HY_PORT
    password: "$HY_PASS"
    sni: "$HY_SNI"
    skip-cert-verify: true
EOF
  fi
}

clash_group_members() {
  local suffix="$1"
  printf '      - "Suoha-REALITY%s"\n' "$suffix"
  if [ "$HY_ENABLED" = "1" ]; then
    printf '      - "Suoha-Hysteria2%s"\n' "$suffix"
  fi
}

write_clash_config() {
  local dual="${DUAL_STACK:-0}" s4="" s6=""
  if [ "$dual" = "1" ] && [ -n "${CLIENT_V6:-}" ]; then
    s4="-v4"
    s6="-v6"
  else
    dual=0
  fi

  {
    cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
proxies:
EOF
    clash_proxies_for "${CLIENT_V4:-$CLIENT_HOST}" "$s4"
    if [ "$dual" = "1" ]; then
      clash_proxies_for "$CLIENT_V6" "$s6"
    fi
    cat <<EOF
proxy-groups:
  - name: "Auto"
    type: url-test
    proxies:
EOF
    clash_group_members "$s4"
    if [ "$dual" = "1" ]; then
      clash_group_members "$s6"
    fi
    cat <<EOF
    url: "https://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50
rules:
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - MATCH,Auto
EOF
  } > "$CLASH_FILE"
  chmod 600 "$CLASH_FILE"
}

print_node_links() {
  local host="$1" suffix="$2"
  printf "  REALITY:\n  %s\n\n" "$(reality_link "$host" "Suoha-REALITY$suffix")"
  if [ "$HY_ENABLED" = "1" ]; then
    printf "  Hysteria2:\n  %s\n\n" "$(hysteria_link "$host" "Suoha-Hysteria2$suffix")"
  else
    printf "  Hysteria2: 未启用\n\n"
  fi
}

show_links() {
  need_root
  load_state
  echo
  line
  printf "  %s\n" "客户端节点"
  line
  if [ "${DUAL_STACK:-0}" = "1" ] && [ -n "${CLIENT_V6:-}" ]; then
    printf "  ===== IPv4 =====\n"
    print_node_links "$CLIENT_V4" "-v4"
    printf "  ===== IPv6 =====\n"
    print_node_links "$CLIENT_V6" "-v6"
  else
    print_node_links "$CLIENT_HOST" ""
  fi
  printf "  Clash Meta 配置: %s\n" "$CLASH_FILE"
  printf "  配置中的 Auto 组会每 300 秒测速，自动选择更快的通道。\n"
  printf "  公开分享前请修改/删除该文件。\n"
}

show_status() {
  need_root
  load_state
  echo
  line
  printf "  %s\n" "Suoha 智能代理状态"
  line
  printf "  系统      : %s / %s\n" "$(uname -s)" "$(uname -m)"
  if [ -n "${CLIENT_V4:-}" ]; then
    printf "  IPv4      : %s\n" "$CLIENT_V4"
  fi
  if [ -n "${CLIENT_V6:-}" ]; then
    printf "  IPv6      : %s\n" "$CLIENT_V6"
  fi
  printf "  REALITY   : TCP %s, SNI %s\n" "$PORT" "$REALITY_SNI"
  if [ "$HY_ENABLED" = "1" ]; then
    printf "  Hysteria2 : UDP %s, SNI %s\n" "$HY_PORT" "$HY_SNI"
  else
    printf "  Hysteria2 : 未启用\n"
  fi
  echo

  if have systemctl; then
    local svc state
    for svc in suoha-xray suoha-hysteria; do
      if [ "$svc" = "suoha-hysteria" ] && [ "$HY_ENABLED" != "1" ]; then
        continue
      fi
      state="$(systemctl is-active "$svc" 2>/dev/null || true)"
      printf "  %-14s: %s\n" "$svc" "${state:-unknown}"
    done
  fi

  echo
  printf "  监听端口:\n"
  ss -lntup 2>/dev/null | grep -E "suoha-(xray|hysteria)" || printf "  （未发现监听进程）\n"
}

show_summary() {
  echo
  line
  printf "  %s\n" "部署完成"
  line
  printf "  主通道  : VLESS + Vision + REALITY (TCP $PORT)\n"
  if [ "$HY_ENABLED" = "1" ]; then
    printf "  备通道  : Hysteria2 (UDP $HY_PORT)\n"
  else
    printf "  备通道  : 未启用（自动降级）\n"
  fi
  if [ "${DUAL_STACK:-0}" = "1" ] && [ -n "${CLIENT_V6:-}" ]; then
    printf "  节点 IP : %s / %s\n" "$CLIENT_V4" "$CLIENT_V6"
  else
    printf "  节点 IP : %s\n" "$(fmt_host "$CLIENT_HOST")"
  fi
  printf "  伪装目标: %s\n" "$REALITY_SNI"
  printf "  服务名  : suoha-xray"
  [ "$HY_ENABLED" = "1" ] && printf ", suoha-hysteria"
  printf "\n"
  printf "  管理命令: bash %s --status | --links | --update | --uninstall\n" "$SELF"
}

do_install() {
  need_root

  if [ -f "$STATE_FILE" ] && [ "$FORCE" != "1" ] && \
     have systemctl && systemctl is-active --quiet suoha-xray 2>/dev/null; then
    warn "检测到已安装。为避免更换凭证导致现有客户端失效，本次仅显示状态。"
    warn "如需重新部署（会生成新 UUID/密码）: bash $SELF --install --force"
    show_status
    show_links
    return 0
  fi

  detect_os
  require_systemd
  install_deps || die "依赖安装失败"

  ensure_tmp
  info "开始智能部署：$OS_PRETTY / $ARCH"

  install_xray_core || die "Xray-core 下载失败，请检查服务器到 GitHub 的网络"
  if [ "$HY_ENABLED" = "1" ]; then
    if ! install_hysteria_core; then
      warn "Hysteria2 下载失败，自动降级为仅 REALITY"
      HY_ENABLED=0
    fi
  fi

  detect_endpoint
  gen_material
  choose_sni

  if [ -f "$STATE_FILE" ]; then
    info "停止旧服务，释放端口..."
    systemctl stop suoha-xray suoha-hysteria >/dev/null 2>&1 || true
    sleep 1
  fi

  PORT="$(pick_tcp_port)"
  if [ "$PORT" != "443" ]; then
    warn "本机 443 已被占用，改用 TCP $PORT（记得在安全组放行）"
  fi
  if [ "$HY_ENABLED" = "1" ]; then
    HY_PORT="$(pick_udp_port)"
  else
    HY_PORT="0"
  fi

  mkdir -p "$(dirname "$XRAY_CONF")" "$SUOHA_DIR"
  chmod 700 "$SUOHA_DIR"

  info "写入 Xray REALITY 配置..."
  write_xray_config || die "Xray 配置校验失败"
  info "Xray 配置校验通过"

  if [ "$HY_ENABLED" = "1" ]; then
    if write_hysteria_config; then
      info "Hysteria2 配置校验通过"
    else
      warn "Hysteria2 配置校验失败，自动降级为仅 REALITY"
      HY_ENABLED=0
      HY_PORT="0"
    fi
  fi

  save_state
  write_clash_config
  if [ "$HY_ENABLED" != "1" ]; then
    systemctl disable --now suoha-hysteria >/dev/null 2>&1 || true
  fi
  write_units
  optimize_kernel
  open_firewall

  systemctl daemon-reload
  systemctl enable suoha-xray >/dev/null 2>&1 || true
  systemctl restart suoha-xray >/dev/null 2>&1 || die "Xray 服务启动失败"
  sleep 2
  if ! systemctl is-active --quiet suoha-xray; then
    journalctl -u suoha-xray -n 30 --no-pager 2>/dev/null || true
    die "Xray 未能启动，请查看上面的日志"
  fi

  if [ "$HY_ENABLED" = "1" ]; then
    systemctl enable suoha-hysteria >/dev/null 2>&1 || true
    systemctl restart suoha-hysteria >/dev/null 2>&1 || warn "Hysteria2 服务启动失败"
    sleep 2
    if ! systemctl is-active --quiet suoha-hysteria; then
      journalctl -u suoha-hysteria -n 30 --no-pager 2>/dev/null || true
      warn "Hysteria2 未能启动，已自动从客户端配置中移除"
      HY_ENABLED=0
      HY_PORT="0"
      save_state
      write_clash_config
      systemctl disable --now suoha-hysteria >/dev/null 2>&1 || true
      write_units
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  fi

  show_summary
  show_links
}

do_update() {
  need_root
  detect_os
  require_systemd
  install_deps || die "依赖安装失败"
  load_state

  install_xray_core || die "Xray-core 下载失败"
  if [ "$HY_ENABLED" = "1" ]; then
    install_hysteria_core || warn "Hysteria2 下载失败，保留旧版本"
  fi

  systemctl restart suoha-xray || die "Xray 重启失败"
  if [ "$HY_ENABLED" = "1" ]; then
    systemctl restart suoha-hysteria || warn "Hysteria2 重启失败"
  fi
  info "内核更新完成"
  show_status
}

do_uninstall() {
  need_root
  if [ "$ASSUME_YES" != "1" ]; then
    local ans
    read -rp "确认卸载 Suoha 代理? [y/N]: " ans || ans=""
    case "$ans" in
      y|Y|yes|YES) ;;
      *) printf '已取消\n'; return 0 ;;
    esac
  fi

  local svc
  for svc in suoha-xray suoha-hysteria; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$svc.service"
  done
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -f "$XRAY_BIN" "$HY_BIN" "$XRAY_CONF" "$HY_CONF" "$STATE_FILE" "$CLASH_FILE"
  rm -f "$SUOHA_DIR/cert.pem" "$SUOHA_DIR/key.pem" "$SYSCTL_FILE"
  rm -rf "$SUOHA_DIR" "$(dirname "$XRAY_CONF")"

  sysctl --system >/dev/null 2>&1 || true
  info "已卸载。ufw/firewalld 和云安全组中的放行规则请自行清理。"
}

banner() {
  echo
  line
  printf "  %s\n" "Suoha 智能双通道代理"
  printf "  %s\n" "REALITY (稳定) + Hysteria2 (高速)"
  line
}

main_menu() {
  local choice default a
  while true; do
    banner
    if [ -f "$STATE_FILE" ]; then
      printf "  1) 重新部署（生成新凭证）\n"
      default=2
    else
      printf "  1) 智能部署（推荐）\n"
      default=1
    fi
    printf "  2) 查看运行状态\n"
    printf "  3) 查看节点链接\n"
    printf "  4) 更新内核\n"
    printf "  5) 卸载\n"
    printf "  0) 退出\n\n"

    read -rp "请选择 [$default]: " choice || exit 0
    choice="${choice:-$default}"

    case "$choice" in
      1)
        if [ -f "$STATE_FILE" ]; then
          read -rp "重新部署会更换 UUID/密码，现有客户端会失效。继续? [y/N]: " a || a=""
          case "$a" in
            y|Y|yes|YES) FORCE=1; do_install || true ;;
            *) ;;
          esac
        else
          do_install || true
        fi
        ;;
      2) show_status ;;
      3) show_links ;;
      4) do_update || true ;;
      5) do_uninstall ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

usage() {
  cat <<EOF
用法: bash $SELF [选项]

  --install          部署（已安装时仅显示状态）
  --install --force  强制重新部署（更换凭证）
  --no-hysteria      仅部署 REALITY
  --status           查看服务状态
  --links            查看节点链接
  --update           更新 Xray/Hysteria2 内核
  --uninstall        卸载（--yes 跳过确认）
  --help             显示帮助

不带参数时进入交互菜单；非交互环境（如 curl | bash）会直接部署。
EOF
}

main() {
  local action=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --install|install) action="install" ;;
      --status) action="status" ;;
      --links) action="links" ;;
      --update) action="update" ;;
      --uninstall) action="uninstall" ;;
      --yes|-y) ASSUME_YES=1 ;;
      --force|-f) FORCE=1 ;;
      --no-hysteria) HY_ENABLED=0 ;;
      --help|-h) usage; return 0 ;;
      *)
        err "未知参数: $1"
        usage
        return 1
        ;;
    esac
    shift
  done

  case "$action" in
    install) do_install ;;
    status) show_status ;;
    links) show_links ;;
    update) do_update ;;
    uninstall) do_uninstall ;;
    "")
      if [ -t 0 ]; then
        main_menu
      else
        do_install
      fi
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  main "$@"
fi
