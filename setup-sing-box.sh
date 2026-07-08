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
