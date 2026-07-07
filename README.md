# sing-box-nat-setup

Alpine Linux (NAT VPS) 一键部署 **VLESS + Reality** (基于 [sing-box](https://github.com/SagerNet/sing-box))。

适用场景：小鸡 / NAT VPS，只有部分端口被转发到公网，需要快速起一个 Reality 节点。

## 特性

- 一条命令完成安装、配置生成、OpenRC 服务注册与启动
- 支持通过参数自定义端口 / 监听模式 / SNI 伪装域名 / sing-box 版本
- UUID、Reality 密钥对、Short ID 自动生成并写入配置，无需手动复制粘贴
- 幂等：重复执行会备份旧配置、平滑重启服务，不会因为"服务已存在"报错
- 结束后自动清理安装包、解压目录、apk 缓存
- 自动生成 `client-info.txt` 和 `vless://` 订阅链接，方便直接导入客户端

## 环境要求

- **系统**：Alpine Linux（依赖 `apk`、`openrc`、busybox `ntpd`）
- **权限**：root
- **架构**：x86_64 / aarch64 / armv7
- **网络**：VPS 需要能出网访问 GitHub（下载 sing-box release）和 api.ipify.org / ifconfig.me（探测公网 IP，仅用于生成订阅链接，失败不影响部署）

## 快速开始

下载脚本并执行：

```bash
wget -O setup-sing-box.sh https://raw.githubusercontent.com/你的用户名/sing-box-nat-setup/main/setup-sing-box.sh
chmod +x setup-sing-box.sh
./setup-sing-box.sh -p 40001
```

或者一行流直接跑（`-s --` 是让参数正确传给脚本本身，不能省略）：

```bash
wget -qO- https://raw.githubusercontent.com/你的用户名/sing-box-nat-setup/main/setup-sing-box.sh | sh -s -- -p 40001
```

## 参数说明

```
用法: setup-sing-box.sh -p <端口> [-n 4|6|dual] [-s <SNI域名>] [-v <版本号>]

  -p  内部监听端口 (必填)
  -n  监听模式: 4=仅IPv4  6=仅IPv6  dual=双栈监听 (默认: dual)
  -s  Reality 使用的 SNI 伪装域名 (默认: images.apple.com)
  -v  sing-box 版本号，不带 v 前缀 (默认脚本内置版本)
  -h  显示帮助
```

示例：

```bash
# 默认双栈监听，40001 端口
./setup-sing-box.sh -p 40001

# 仅 IPv4，自定义 SNI 和版本
./setup-sing-box.sh -p 40001 -n 4 -s www.microsoft.com -v 1.13.14
```

## ⚠️ NAT VPS 端口映射，请务必注意

`-p` 传入的是**服务器内部监听端口**，也就是你在服务商面板做端口转发时映射到的那个内部端口。

- 有些服务商外部端口和内部端口相同，直接用同一个数字没问题。
- 有些服务商外部端口和内部端口不同（比如外部 `50001` 转发到内部 `40001`）。

脚本无法替你判断这一点。**客户端连接时请以服务商面板里显示的"外部端口"为准**，而不是盲目照抄脚本里的 `-p` 参数或生成的订阅链接里的端口。

## 部署完成后

脚本结尾会打印一份客户端信息，同时保存在服务器上：

```bash
cat /etc/sing-box/client-info.txt
```

内容包括：探测到的公网 IP、内部端口、UUID、PublicKey、ShortId、SNI，以及拼好的 `vless://` 订阅链接（记得按上面说的核对端口）。

该文件权限为 `600`，仅 root 可读，请妥善保管，不要直接粘贴分享给别人。

## 常用运维命令

```bash
rc-service sing-box status     # 查看状态
rc-service sing-box restart    # 重启
rc-service sing-box stop       # 停止

tail -f /var/log/sing-box.log        # 运行日志
tail -f /var/log/sing-box-error.log  # 错误日志
```

## 重新运行 / 更换配置

直接重新执行脚本（可以换不同的 `-p` / `-n` / `-s`）即可：

- 旧的 `config.json` 会自动备份为 `config.json.bak.<时间戳>`
- 会生成全新的 UUID / 密钥对 / Short ID（旧的客户端配置需要同步更新）
- 服务会被平滑重启，不需要你手动 stop

## 防火墙 / 安全组

脚本**不处理**云厂商控制台层面的安全组、或 VPS 独立防火墙层的放行，需要你自己确认 `-p` 对应端口（以及外部映射端口）已放行。Alpine 本地默认没有开启 iptables，一般无需额外处理。

## License

MIT
