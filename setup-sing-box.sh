#!/bin/sh
# ============================================================================
# setup-sing-box.sh
# Alpine Linux one-shot installer for sing-box VLESS + Reality.
# ============================================================================
set -eu

PORT=""
EXT_PORT=""
IP_MODE="dual"
SNI="images.apple.com"
VERSION="latest"
DNS_OPT=""
CUSTOM_HOST=""
ALLOW_PROXY=0
EXPECTED_SHA256=""

CONFIG_DIR="/etc/sing-box"
BIN_PATH="/usr/local/bin/sing-box"
SERVICE_PATH="/etc/init.d/sing-box"
ERROR_LOG="/var/log/sing-box-error.log"
FALLBACK_VERSION="1.13.14"

TARBALL=""
EXTRACT_DIR=""
API_JSON=""
TEMP_CONF=""
NEW_BIN=""
BACKUP_SUFFIX=""
BIN_BAK=""
CONFIG_BAK=""
INIT_BAK=""
SERVICE_WAS_RUNNING=0

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

usage() {
  exit_code="${1:-1}"
  cat <<USAGE
Usage: $0 -p <internal-port> [options]

Required:
  -p  Internal listening port from your NAT VPS provider panel.

Options:
  -e  External mapped port for the client link. Defaults to -p.
  -H  Client connection host, IP, or domain. Recommended for NAT VPS.
  -i  IP listen mode: 4, 6, or dual. Default: dual.
  -s  Reality SNI camouflage domain. Default: images.apple.com.
  -d  Custom DNS server IP. Domain names are intentionally rejected.
  -v  sing-box version without leading v. Default: latest.
  -S  Expected SHA256 of the release tarball.
  -P  Allow third-party GitHub proxy download, only with SHA256 verification.
  -h  Show this help.
USAGE
  exit "$exit_code"
}

cleanup() {
  [ -n "$TARBALL" ] && rm -f "$TARBALL"
  [ -n "$API_JSON" ] && rm -f "$API_JSON"
  [ -n "$TEMP_CONF" ] && rm -f "$TEMP_CONF"
  [ -n "$NEW_BIN" ] && rm -f "$NEW_BIN"
  [ -n "$EXTRACT_DIR" ] && rm -rf "$EXTRACT_DIR"
}

trap cleanup EXIT INT TERM

while getopts "p:e:H:i:s:v:d:S:hP" opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    e) EXT_PORT="$OPTARG" ;;
    H) CUSTOM_HOST="$OPTARG" ;;
    i) IP_MODE="$OPTARG" ;;
    s) SNI="$OPTARG" ;;
    v) VERSION="$OPTARG" ;;
    d) DNS_OPT="$OPTARG" ;;
    S) EXPECTED_SHA256="$OPTARG" ;;
    P) ALLOW_PROXY=1 ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

is_uint_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_domain_name() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
}

has_only_host_chars() {
  case "$1" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.:-]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_valid_custom_host() {
  host="$1"

  case "$host" in
    *'['*|*']'*)
      case "$host" in
        \[*\]) inner="${host#\[}"; inner="${inner%\]}" ;;
        *) return 1 ;;
      esac
      case "$inner" in
        *'['*|*']'*) return 1 ;;
      esac
      ;;
    *) inner="$host" ;;
  esac

  has_only_host_chars "$inner" || return 1

  case "$inner" in
    *:*) printf '%s\n' "$inner" | grep -Eq '^[0-9A-Fa-f:]+$' ;;
    *) return 0 ;;
  esac
}

is_safe_ip_literal() {
  case "$1" in
    *:*) printf '%s\n' "$1" | grep -Eq '^[0-9A-Fa-f:]+$' ;;
    *) printf '%s\n' "$1" | grep -Eq '^[0-9.]+$' ;;
  esac
}

is_safe_version() {
  [ "$1" = "latest" ] && return 0
  printf '%s\n' "$1" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+([-._~A-Za-z0-9]+)?$'
}

is_sha256() {
  printf '%s\n' "$1" | grep -Eq '^[0-9A-Fa-f]{64}$'
}

normalize_link_host() {
  host="$1"
  case "$host" in
    \[*\]) printf '%s\n' "$host" ;;
    *:*) printf '[%s]\n' "$host" ;;
    *) printf '%s\n' "$host" ;;
  esac
}

fetch_direct() {
  url="$1"
  out="$2"
  wget -q -T 15 -t 2 -O "$out" "$url"
}

extract_release_tag() {
  sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' "$1" | head -n 1
}

extract_asset_digest() {
  json="$1"
  asset_name="$2"
  awk -v name="$asset_name" '
    index($0, "\"name\"") && index($0, "\"" name "\"") { found = 1 }
    found && index($0, "\"digest\": \"sha256:") {
      sub(/^.*"digest": "sha256:/, "")
      sub(/".*$/, "")
      print
      exit
    }
    found && index($0, "\"browser_download_url\"") { found = 0 }
  ' "$json" | head -n 1
}

download_asset() {
  url="$1"
  out="$2"

  if fetch_direct "$url" "$out"; then
    return 0
  fi

  [ "$ALLOW_PROXY" = "1" ] || return 1
  [ -n "$EXPECTED_SHA256" ] || die "proxy download requires -S or GitHub API sha256 digest"

  warn "direct GitHub download failed; trying proxy mirrors with sha256 verification"
  for proxy in "https://gh-proxy.com/" "https://ghproxy.net/" "https://mirror.ghproxy.com/"; do
    echo "Trying proxy: $proxy"
    if fetch_direct "${proxy}${url}" "$out"; then
      return 0
    fi
  done

  return 1
}

verify_sha256_if_available() {
  file="$1"

  if [ -z "$EXPECTED_SHA256" ]; then
    warn "no sha256 digest available; direct GitHub TLS is the only authenticity check"
    return 0
  fi

  actual="$(sha256sum "$file" | awk '{print $1}')"
  expected_lc="$(printf '%s\n' "$EXPECTED_SHA256" | tr 'A-F' 'a-f')"
  actual_lc="$(printf '%s\n' "$actual" | tr 'A-F' 'a-f')"

  [ "$actual_lc" = "$expected_lc" ] || die "sha256 mismatch for downloaded tarball"
  echo ">> SHA256 verification passed"
}

rollback() {
  warn "service start failed; rolling back"

  if [ -n "$BIN_BAK" ] && [ -f "$BIN_BAK" ]; then
    cp "$BIN_BAK" "$BIN_PATH"
    chmod +x "$BIN_PATH"
  fi

  if [ -n "$CONFIG_BAK" ] && [ -f "$CONFIG_BAK" ]; then
    cp "$CONFIG_BAK" "$CONFIG_DIR/config.json"
    chmod 600 "$CONFIG_DIR/config.json"
  fi

  if [ -n "$INIT_BAK" ] && [ -f "$INIT_BAK" ]; then
    cp "$INIT_BAK" "$SERVICE_PATH"
    chmod +x "$SERVICE_PATH"
  fi

  if [ "$SERVICE_WAS_RUNNING" = "1" ] && [ -f "$SERVICE_PATH" ] && [ -f "$BIN_PATH" ] && [ -f "$CONFIG_DIR/config.json" ]; then
    rc-service sing-box restart >/dev/null 2>&1 || true
  else
    rc-service sing-box stop >/dev/null 2>&1 || true
  fi
}

print_service_failure_context() {
  warn "sing-box did not stay running"
  rc-service sing-box status >&2 2>/dev/null || true
  if [ -s "$ERROR_LOG" ]; then
    warn "recent $ERROR_LOG:"
    tail -n 40 "$ERROR_LOG" >&2 || true
  fi
}

if [ -z "$PORT" ]; then
  if [ -t 0 ]; then
    printf "Internal port: "
    IFS= read -r PORT || PORT=""
  fi
  [ -n "$PORT" ] || { echo "ERROR: -p is required" >&2; usage 1; }
fi

[ -z "$EXT_PORT" ] && EXT_PORT="$PORT"

is_uint_port "$PORT" || die "internal port must be 1-65535"
is_uint_port "$EXT_PORT" || die "external port must be 1-65535"
is_safe_version "$VERSION" || die "invalid version format"
is_domain_name "$SNI" || die "invalid SNI domain"

if [ -n "$CUSTOM_HOST" ]; then
  is_valid_custom_host "$CUSTOM_HOST" || die "invalid custom host; do not include a port, use -e for the external port"
fi

if [ -n "$DNS_OPT" ]; then
  is_safe_ip_literal "$DNS_OPT" || die "DNS must be an IPv4 or IPv6 literal"
fi

if [ -n "$EXPECTED_SHA256" ]; then
  is_sha256 "$EXPECTED_SHA256" || die "invalid sha256 format"
fi

case "$IP_MODE" in
  4)
    LISTEN_ADDR="0.0.0.0"
    STRATEGY="ipv4_only"
    DNS_SERVER="${DNS_OPT:-8.8.8.8}"
    ;;
  6)
    LISTEN_ADDR="::"
    STRATEGY="ipv6_only"
    DNS_SERVER="${DNS_OPT:-2001:4860:4860::8888}"
    ;;
  dual)
    LISTEN_ADDR="::"
    STRATEGY="prefer_ipv6"
    DNS_SERVER="${DNS_OPT:-8.8.8.8}"
    ;;
  *) die "-i must be 4, 6, or dual" ;;
esac

[ "$(id -u)" -eq 0 ] || die "please run as root"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) SB_ARCH="amd64" ;;
  aarch64) SB_ARCH="arm64" ;;
  armv7l) SB_ARCH="armv7" ;;
  *) die "unsupported architecture: $ARCH" ;;
esac

BINDV6ONLY="$(sysctl -n net.ipv6.bindv6only 2>/dev/null || echo "0")"
if [ "$IP_MODE" = "dual" ] && [ "$BINDV6ONLY" = "1" ]; then
  warn "net.ipv6.bindv6only=1; dual mode will not accept IPv4 on ::"
elif [ "$IP_MODE" = "6" ] && [ "$BINDV6ONLY" = "0" ]; then
  warn "net.ipv6.bindv6only=0; IPv6 listen on :: may also accept IPv4"
fi

echo ">> Installing dependencies"
apk add --no-cache wget tar ca-certificates openrc openssl

echo ">> Syncing time"
ntpd -q -p pool.ntp.org 2>/dev/null || warn "time sync failed; continuing"

echo ">> Checking SNI TLS 1.3 support"
if timeout 8 openssl s_client -connect "${SNI}:443" -servername "$SNI" -tls1_3 -brief </dev/null 2>&1 | grep -q "TLSv1.3"; then
  echo ">> SNI supports TLS 1.3"
else
  warn "$SNI may not support TLS 1.3, or the check timed out"
fi

TARBALL="$(mktemp)"
EXTRACT_DIR="$(mktemp -d)"
API_JSON="$(mktemp)"

if [ "$VERSION" = "latest" ]; then
  echo ">> Resolving latest sing-box version"
  if fetch_direct "https://api.github.com/repos/SagerNet/sing-box/releases/latest" "$API_JSON"; then
    VERSION="$(extract_release_tag "$API_JSON")"
  fi
  if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
    warn "failed to resolve latest; falling back to $FALLBACK_VERSION"
    VERSION="$FALLBACK_VERSION"
    : > "$API_JSON"
  fi
fi

ASSET_NAME="sing-box-${VERSION}-linux-${SB_ARCH}-musl.tar.gz"
DL_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${ASSET_NAME}"

if [ -z "$EXPECTED_SHA256" ]; then
  if ! grep -q '"tag_name"' "$API_JSON" 2>/dev/null; then
    fetch_direct "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${VERSION}" "$API_JSON" || true
  fi
  if grep -q '"assets"' "$API_JSON" 2>/dev/null; then
    EXPECTED_SHA256="$(extract_asset_digest "$API_JSON" "$ASSET_NAME" || true)"
  fi
fi

if [ "$ALLOW_PROXY" = "1" ] && [ -z "$EXPECTED_SHA256" ]; then
  die "-P requires a sha256 digest from GitHub API or explicit -S"
fi

echo ">> Downloading sing-box v${VERSION} (${SB_ARCH})"
download_asset "$DL_URL" "$TARBALL" || die "download failed"
verify_sha256_if_available "$TARBALL"

tar -tzf "$TARBALL" >/dev/null 2>&1 || die "tarball is corrupt or incomplete"
tar -zxf "$TARBALL" -C "$EXTRACT_DIR"

SB_BIN="$(find "$EXTRACT_DIR" -type f -name sing-box | head -n 1 || true)"
[ -n "$SB_BIN" ] || die "sing-box binary not found in tarball"
chmod +x "$SB_BIN"

echo ">> Generating credentials"
UUID="$("$SB_BIN" generate uuid)"
KEYPAIR="$("$SB_BIN" generate reality-keypair)"
PRIVATE_KEY="$(printf '%s\n' "$KEYPAIR" | awk '/PrivateKey/ {print $2}')"
PUBLIC_KEY="$(printf '%s\n' "$KEYPAIR" | awk '/PublicKey/ {print $2}')"
SHORT_ID="$("$SB_BIN" generate rand --hex 4)"

[ -n "$UUID" ] || die "UUID generation failed"
[ -n "$PRIVATE_KEY" ] || die "Reality private key generation failed"
[ -n "$PUBLIC_KEY" ] || die "Reality public key generation failed"
[ -n "$SHORT_ID" ] || die "Reality short id generation failed"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

TEMP_CONF="${CONFIG_DIR}/config.json.new.$$"
cat > "$TEMP_CONF" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "remote-dns",
        "type": "udp",
        "server": "${DNS_SERVER}"
      }
    ],
    "strategy": "${STRATEGY}"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
chmod 600 "$TEMP_CONF"

echo ">> Validating new config with new binary"
"$SB_BIN" check -c "$TEMP_CONF" >/dev/null || die "new config validation failed; current service was not touched"

BIN_DIR="$(dirname "$BIN_PATH")"
mkdir -p "$BIN_DIR"
NEW_BIN="${BIN_DIR}/.sing-box.new.$$"
cp "$SB_BIN" "$NEW_BIN"
chmod +x "$NEW_BIN"

BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"
BIN_BAK="${BIN_PATH}.bak.${BACKUP_SUFFIX}"
CONFIG_BAK="${CONFIG_DIR}/config.json.bak.${BACKUP_SUFFIX}"
INIT_BAK="${SERVICE_PATH}.bak.${BACKUP_SUFFIX}"

[ -f "$BIN_PATH" ] && cp "$BIN_PATH" "$BIN_BAK"
[ -f "$CONFIG_DIR/config.json" ] && cp "$CONFIG_DIR/config.json" "$CONFIG_BAK"
[ -f "$SERVICE_PATH" ] && cp "$SERVICE_PATH" "$INIT_BAK"
if [ -f "$SERVICE_PATH" ] && rc-service sing-box status >/dev/null 2>&1; then
  SERVICE_WAS_RUNNING=1
fi

echo ">> Installing binary, config, and OpenRC service"
mv "$NEW_BIN" "$BIN_PATH"
NEW_BIN=""
mv "$TEMP_CONF" "$CONFIG_DIR/config.json"
TEMP_CONF=""
chmod +x "$BIN_PATH"
chmod 600 "$CONFIG_DIR/config.json"

cat > "$SERVICE_PATH" <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box daemon"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
supervisor="supervise-daemon"
respawn_delay="1"
respawn_max="5"
respawn_period="60"
output_log="/dev/null"
error_log="/var/log/sing-box-error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    if ! "$command" check -c /etc/sing-box/config.json >/dev/null; then
        eerror "config check failed; aborting start"
        return 1
    fi
}
EOF
chmod +x "$SERVICE_PATH"

rc-update add sing-box default >/dev/null 2>&1 || true
mkdir -p "$(dirname "$ERROR_LOG")"
: > "$ERROR_LOG"
chmod 600 "$ERROR_LOG"

if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
  SERVICE_ACTION="restart"
else
  SERVICE_ACTION="start"
fi

if ! rc-service sing-box "$SERVICE_ACTION" >/dev/null 2>&1; then
  print_service_failure_context
  rollback
  die "deployment failed; rollback attempted"
fi

sleep 2
if ! rc-service sing-box status >/dev/null 2>&1; then
  print_service_failure_context
  rollback
  die "deployment failed; sing-box exited after start; rollback attempted"
fi

echo ">> Resolving client connection host"
if [ -n "$CUSTOM_HOST" ]; then
  SERVER_HOST="$(normalize_link_host "$CUSTOM_HOST")"
else
  if [ "$IP_MODE" = "6" ]; then
    SERVER_IP="$(wget -qO- -T 5 -t 1 https://api6.ipify.org 2>/dev/null || wget -qO- -T 5 -t 1 -6 https://ifconfig.me/ip 2>/dev/null || echo "")"
  else
    SERVER_IP="$(wget -qO- -T 5 -t 1 https://api.ipify.org 2>/dev/null || wget -qO- -T 5 -t 1 https://ifconfig.me/ip 2>/dev/null || echo "")"
  fi
  [ -n "$SERVER_IP" ] || SERVER_IP="auto-detect-failed"
  SERVER_HOST="$(normalize_link_host "$SERVER_IP")"
fi

VLESS_LINK="vless://${UUID}@${SERVER_HOST}:${EXT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#sing-box-reality"

cat > "$CONFIG_DIR/client-info.txt" <<EOF
=== sing-box VLESS Reality ===
Host: ${SERVER_HOST}
Internal port: ${PORT}
External port: ${EXT_PORT}
Mode: ${IP_MODE}
DNS: ${DNS_OPT:-default}
UUID: ${UUID}
Flow: xtls-rprx-vision
SNI: ${SNI}
PublicKey: ${PUBLIC_KEY}
ShortId: ${SHORT_ID}

VLESS link:
${VLESS_LINK}
EOF
chmod 600 "$CONFIG_DIR/client-info.txt"

echo "================ Deployment succeeded ================"
echo "Client details are stored at: $CONFIG_DIR/client-info.txt"
echo "Run this on the server to view them:"
echo "  cat $CONFIG_DIR/client-info.txt"
echo "Check your NAT provider panel/firewall for TCP port: $EXT_PORT"
