#!/bin/sh
# ============================================================================
# setup-sing-box.sh
# Alpine Linux (NAT VPS) 一键部署 VLESS + Reality (sing-box)
#
# 用法:
#   sh setup-sing-box.sh -p <端口> [-n 4|6|dual] [-s <SNI域名>] [-v <版本号>]
#
# 示例:
#   sh setup-sing-box.sh -p 40001
#   sh setup-sing-box.sh -p 40001 -n 4 -s www.microsoft.com
#
# 注意 (NAT VPS 场景):
#   -p 传入的端口必须是"内部监听端口"，也就是你在服务商面板里做端口转发时
#   映射到的那个内部端口。脚本无法帮你判断外部端口是否与内部端口相同，
#   连接时请以服务商面板显示的"外部端口"为准填入客户端。
# ============================================================================
set -eu

# ---------------------------- 默认参数 -------------------------------------
PORT=""
IP_MODE="dual"          # 4 / 6 / dual
SNI="images.apple.com"
VERSION="1.13.14"
CONFIG_DIR="/etc/sing-box"
BIN_PATH="/usr/local/bin/sing-box"

usage() {
  cat <<USAGE
用法: $0 -p <端口> [-n 4|6|dual] [-s <SNI域名>] [-v <版本号>]

  -p  内部监听端口 (必填，NAT VPS 请填面板里映射的内部端口)
  -n  监听模式: 4=仅IPv4  6=仅IPv6  dual=双栈监听 (默认: dual)
  -s  Reality 使用的 SNI 伪装域名 (默认: images.apple.com)
  -v  sing-box 版本号，不带 v 前缀 (默认: ${VERSION})
  -h  显示本帮助

示例:
  $0 -p 40001
  $0 -p 40001 -n 4 -s www.microsoft.com
USAGE
  exit 1
}

# ---------------------------- 参数解析 --------------------------------------
while getopts "p:n:s:v:h" opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    n) IP_MODE="$OPTARG" ;;
    s) SNI="$OPTARG" ;;
    v) VERSION="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

[ -n "$PORT" ] || { echo "错误: 必须使用 -p 指定端口"; usage; }

case "$PORT" in
  ''|*[!0-9]*) echo "错误: 端口必须为数字"; exit 1 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "错误: 端口范围必须在 1-65535 之间"
  exit 1
fi

case "$IP_MODE" in
  4) LISTEN_ADDR="0.0.0.0" ;;
  6) LISTEN_ADDR="::" ;;
  dual) LISTEN_ADDR="::" ;;   # 依赖内核默认 net.ipv6.bindv6only=0 实现双栈
  *) echo "错误: -n 参数只能是 4 / 6 / dual"; exit 1 ;;
esac

# ---------------------------- 环境检查 --------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 请使用 root 权限运行此脚本"
  exit 1
fi

if [ ! -f /etc/alpine-release ]; then
  echo "警告: 此脚本专为 Alpine Linux 设计，检测到非 Alpine 系统，继续执行可能出错。"
fi

if [ "$IP_MODE" = "dual" ]; then
  BINDV6ONLY=$(sysctl -n net.ipv6.bindv6only 2>/dev/null || echo "0")
  if [ "$BINDV6ONLY" = "1" ]; then
    echo "警告: 检测到 net.ipv6.bindv6only=1，双栈监听可能失效，届时只有 IPv6 客户端能连接。"
    echo "      可执行: sysctl -w net.ipv6.bindv6only=0  然后重跑本脚本。"
  fi
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  SB_ARCH="amd64" ;;
  aarch64) SB_ARCH="arm64" ;;
  armv7l)  SB_ARCH="armv7" ;;
  *) echo "错误: 不支持的架构 $ARCH"; exit 1 ;;
esac

# ---------------------------- 安装依赖 --------------------------------------
echo ">> 安装依赖..."
apk update
apk add --no-cache wget tar ca-certificates openrc

echo ">> 同步系统时间 (Reality 对系统时间较敏感)..."
ntpd -q -p pool.ntp.org 2>/dev/null || echo "   时间同步失败，继续执行；如后续握手异常请手动同步时间。"

# ---------------------------- 下载并安装 sing-box ---------------------------
DL_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}-musl.tar.gz"
TARBALL="/tmp/sing-box-${VERSION}-${SB_ARCH}.tar.gz"
EXTRACT_DIR="/tmp/sing-box-extract-$$"

echo ">> 下载 sing-box v${VERSION} (${SB_ARCH})..."
rm -f "$TARBALL"
i=0
until wget -q -O "$TARBALL" "$DL_URL"; do
  i=$((i + 1))
  if [ "$i" -ge 3 ]; then
    echo "错误: 下载失败，请检查网络，或确认版本号 v${VERSION} 是否存在:"
    echo "      $DL_URL"
    exit 1
  fi
  echo "   下载失败，重试 ($i/3)..."
  sleep 2
done
[ -s "$TARBALL" ] || { echo "错误: 下载的文件为空"; exit 1; }

mkdir -p "$EXTRACT_DIR"
tar -zxf "$TARBALL" -C "$EXTRACT_DIR"
SB_BIN=$(find "$EXTRACT_DIR" -type f -name sing-box | head -n1)
[ -n "$SB_BIN" ] || { echo "错误: 解压后未找到 sing-box 可执行文件"; exit 1; }

if [ -f "$BIN_PATH" ] && rc-service sing-box status >/dev/null 2>&1; then
  echo ">> 检测到旧版本正在运行，先停止服务再替换二进制..."
  rc-service sing-box stop || true
fi

cp "$SB_BIN" "$BIN_PATH"
chmod +x "$BIN_PATH"
"$BIN_PATH" version >/dev/null 2>&1 || { echo "错误: sing-box 安装校验失败"; exit 1; }
echo ">> $("$BIN_PATH" version | head -n1)"

# ---------------------------- 生成 UUID / 密钥 / ShortID --------------------
echo ">> 生成 UUID / Reality 密钥对 / Short ID..."
UUID=$("$BIN_PATH" generate uuid)
KEYPAIR=$("$BIN_PATH" generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "PrivateKey" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep -i "PublicKey" | awk '{print $2}')
SHORT_ID=$("$BIN_PATH" generate rand --hex 4)

if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ]; then
  echo "错误: 密钥生成失败，reality-keypair 原始输出如下："
  echo "$KEYPAIR"
  exit 1
fi

# ---------------------------- 生成配置文件 -----------------------------------
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_DIR/config.json" ]; then
  cp "$CONFIG_DIR/config.json" "$CONFIG_DIR/config.json.bak.$(date +%s)"
  echo ">> 已备份旧配置到 $CONFIG_DIR/config.json.bak.*"
fi

cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "system-dns",
        "type": "local"
      }
    ]
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
chmod 600 "$CONFIG_DIR/config.json"

echo ">> 校验配置文件..."
"$BIN_PATH" check -c "$CONFIG_DIR/config.json"

# ---------------------------- 写入 OpenRC 服务 -------------------------------
cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box daemon with auto-restart"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
supervisor="supervise-daemon"
respawn_delay="1"
respawn_max="5"
respawn_period="60"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box-error.log"
pidfile="/run/sing-box.pid"

depend() {
    need net
    after firewall
}

start_pre() {
    $command check -c /etc/sing-box/config.json
    if [ $? -ne 0 ]; then
        eerror "sing-box configuration check failed! Aborting start to prevent crash loop."
        return 1
    fi
}
EOF
chmod +x /etc/init.d/sing-box

# ---------------------------- 启动服务 (幂等) --------------------------------
rc-update add sing-box default 2>/dev/null || true

if rc-service sing-box status >/dev/null 2>&1; then
  echo ">> 服务已存在，执行重启..."
  rc-service sing-box restart
else
  echo ">> 首次启动服务..."
  rc-service sing-box start
fi

sleep 1
if rc-service sing-box status 2>&1 | grep -q started; then
  echo ">> sing-box 服务运行正常"
else
  echo "警告: sing-box 可能未成功启动，请检查 /var/log/sing-box-error.log"
fi

# ---------------------------- 清理临时文件 -----------------------------------
echo ">> 清理临时文件..."
rm -rf "$TARBALL" "$EXTRACT_DIR"
rm -rf /var/cache/apk/*

# ---------------------------- 输出客户端信息 ---------------------------------
SERVER_IP=$(wget -qO- https://api.ipify.org 2>/dev/null || wget -qO- https://ifconfig.me 2>/dev/null || echo "自动获取失败-请手动填写")

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#sing-box-reality"

cat > "$CONFIG_DIR/client-info.txt" <<EOF
=== sing-box VLESS Reality 客户端信息 ===
生成时间: $(date)
探测到的服务器IP: ${SERVER_IP}
  (若为 NAT VPS，请以服务商面板中显示的外部映射端口为准，可能与下方端口不同)
内部监听端口: ${PORT}
监听模式: ${IP_MODE}
UUID: ${UUID}
Flow: xtls-rprx-vision
SNI: ${SNI}
PublicKey: ${PUBLIC_KEY}
ShortId: ${SHORT_ID}

订阅链接 (请自行核对/替换端口后使用):
${VLESS_LINK}
EOF
chmod 600 "$CONFIG_DIR/client-info.txt"

echo ""
echo "================= 部署完成 ================="
cat "$CONFIG_DIR/client-info.txt"
echo "=============================================="
echo "以后可通过以下命令查看以上信息:"
echo "  cat $CONFIG_DIR/client-info.txt"
echo ""
echo "常用运维命令:"
echo "  rc-service sing-box status|restart|stop"
echo "  tail -f /var/log/sing-box.log /var/log/sing-box-error.log"
