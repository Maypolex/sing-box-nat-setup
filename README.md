# sing-box-nat-setup

Alpine Linux NAT VPS 一键部署 **VLESS + Reality**，基于 [sing-box](https://github.com/SagerNet/sing-box)。

适用场景：小鸡 / NAT VPS / IPv6-only VPS，只有部分端口被转发到公网，想快速起一个 Reality 节点并生成可直接导入客户端的 `vless://` 链接。

## 特性

- 一条命令完成依赖安装、sing-box 下载、配置生成、OpenRC 服务注册与启动
- 支持 IPv4 / IPv6 / 双栈监听
- 支持 NAT 外部端口和内部监听端口不同的场景
- 支持手动指定客户端连接 host，适合 NAT VPS、域名接入、IPv6 地址
- 自动生成 UUID、Reality 密钥对、Short ID
- 自动生成 `/etc/sing-box/client-info.txt` 和 `vless://` 链接
- 默认解析 sing-box 最新版本，失败时回退到脚本内置版本
- 优先使用 GitHub Release API 提供的 SHA256 摘要校验下载包
- 可选 GitHub 代理下载，但必须有 SHA256 摘要保护
- 部署前校验新配置，部署失败自动回滚旧二进制、旧配置和旧 OpenRC 服务
- 启动后会再次确认 sing-box 仍在运行，避免“脚本成功但服务已退出”的假成功
- 重复执行会备份旧配置并重启服务

## 环境要求

- **系统**：Alpine Linux
- **权限**：root
- **服务管理**：OpenRC
- **依赖工具**：`apk`、`wget`、`tar`、`ca-certificates`、`openssl`、`openrc`
- **架构**：x86_64 / aarch64 / armv7l
- **网络**：VPS 需要能访问 GitHub Release；如果不手动指定 `-H`，脚本还会访问 `api.ipify.org`、`api6.ipify.org` 或 `ifconfig.me` 来生成客户端链接里的 host

已在 Alpine 3.23.5 IPv4 NAT 和 Alpine 3.19.1 IPv6 环境中验证部署、OpenRC 启动和 40001 端口连通性。

## 快速开始

下载脚本并执行：

```bash
wget -O setup-sing-box.sh https://raw.githubusercontent.com/Maypolex/sing-box-nat-setup/main/setup-sing-box.sh
chmod +x setup-sing-box.sh
./setup-sing-box.sh -p 40001
```

NAT VPS 推荐同时指定外部端口和客户端连接 host：

```bash
./setup-sing-box.sh -p 40001 -e 50001 -H your.domain.example -i 4
```

一行流直接运行：

```bash
wget -qO- https://raw.githubusercontent.com/Maypolex/sing-box-nat-setup/main/setup-sing-box.sh | sh -s -- -p 40001 -e 50001 -H your.domain.example -i 4
```

`sh -s --` 用于把后面的参数传给脚本本身，不建议省略。

## 参数说明

```text
Usage: setup-sing-box.sh -p <internal-port> [options]

Required:
  -p  内部监听端口，也就是 sing-box 在 VPS 上实际监听的端口

Options:
  -e  外部映射端口，用于生成客户端链接；默认等于 -p
  -H  客户端连接 host、IP 或域名；NAT VPS 推荐显式指定
  -i  监听模式：4、6、dual；默认 dual
  -s  Reality SNI 伪装域名；默认 images.apple.com
  -d  自定义 DNS 服务器 IP；只接受 IPv4 / IPv6 字面量
  -v  sing-box 版本号，不带 v 前缀；默认 latest
  -S  下载包的预期 SHA256
  -P  允许第三方 GitHub 代理下载；必须能取得 SHA256 摘要
  -h  显示帮助
```

## 示例

默认双栈监听，内部和外部端口都是 40001：

```bash
./setup-sing-box.sh -p 40001
```

仅 IPv4，外部端口和内部端口相同：

```bash
./setup-sing-box.sh -p 40001 -e 40001 -H 154.9.224.140 -i 4
```

NAT 映射：公网外部端口 50001 转发到 VPS 内部 40001：

```bash
./setup-sing-box.sh -p 40001 -e 50001 -H 154.9.224.140 -i 4
```

IPv6 VPS：

```bash
./setup-sing-box.sh -p 40001 -e 40001 -H 2400:c620:22:259::a -i 6
```

IPv6 地址可以不加方括号，脚本生成 `vless://` 链接时会自动加上。

自定义 SNI、DNS 和 sing-box 版本：

```bash
./setup-sing-box.sh -p 40001 -e 40001 -H example.com -i dual -s www.microsoft.com -d 8.8.8.8 -v 1.13.14
```

使用代理下载 release：

```bash
./setup-sing-box.sh -p 40001 -P
```

`-P` 只在直连 GitHub 下载失败时尝试代理，并且要求脚本能从 GitHub API 取得 SHA256 摘要，或你通过 `-S` 显式提供摘要。

## NAT VPS 端口映射

`-p` 是 **VPS 内部监听端口**。这是 sing-box 在机器上实际绑定的端口。

`-e` 是 **公网外部端口**。这是客户端连接时应该使用的端口，也会写入生成的 `vless://` 链接。

常见情况：

```text
公网 40001 -> VPS 40001
./setup-sing-box.sh -p 40001 -e 40001 -H 公网IP或域名

公网 50001 -> VPS 40001
./setup-sing-box.sh -p 40001 -e 50001 -H 公网IP或域名
```

如果没有指定 `-e`，脚本会默认外部端口等于内部端口。

如果没有指定 `-H`，脚本会尝试自动探测公网 IP：

- `-i 6` 会优先探测 IPv6
- `-i 4` 和 `dual` 会优先探测 IPv4
- 探测失败时，客户端链接中的 host 会变成 `auto-detect-failed`

NAT VPS、端口转发 VPS、使用域名连接、IPv6-only VPS 都建议显式指定 `-H`。

## 部署完成后

脚本会把客户端信息保存到：

```bash
cat /etc/sing-box/client-info.txt
```

内容包括：

- Host
- 内部端口
- 外部端口
- 监听模式
- DNS
- UUID
- Flow
- SNI
- PublicKey
- ShortId
- `vless://` 链接

该文件权限为 `600`，仅 root 可读。不要把完整内容公开发布。

## 常用运维命令

```bash
rc-service sing-box status
rc-service sing-box restart
rc-service sing-box stop

/usr/local/bin/sing-box check -c /etc/sing-box/config.json
tail -f /var/log/sing-box-error.log
cat /etc/sing-box/client-info.txt
```

当前 OpenRC 服务把标准输出丢弃到 `/dev/null`，错误日志写入 `/var/log/sing-box-error.log`。

如果你用 `telnet`、`nc`、端口扫描器或裸 TCP 探测端口，错误日志里可能出现类似 `REALITY: processed invalid connection` 的记录。这通常只说明流量到达了 sing-box，但不是合法的 Reality 握手。

## 重新运行 / 更换配置

直接重新执行脚本即可：

```bash
./setup-sing-box.sh -p 40001 -e 50001 -H your.domain.example -i 4
```

重新运行时：

- 会生成全新的 UUID / Reality 密钥对 / Short ID
- 旧客户端配置会失效，需要重新导入新的 `vless://` 链接
- 旧二进制会备份为 `/usr/local/bin/sing-box.bak.<时间戳>`
- 旧配置会备份为 `/etc/sing-box/config.json.bak.<时间戳>`
- 旧 OpenRC 服务脚本会备份为 `/etc/init.d/sing-box.bak.<时间戳>`
- 新配置校验失败时不会替换当前服务
- 新服务启动失败或启动后退出时会自动回滚

## SNI 选择

Reality 的 SNI 需要是域名，不能是 IP。

脚本会用 `openssl s_client` 检查目标 SNI 是否支持 TLS 1.3。如果检查失败，脚本只会给出警告并继续部署，因为失败也可能是网络抖动或远端临时不可达。

默认 SNI 是：

```text
images.apple.com
```

## 防火墙 / 安全组

脚本不会处理云厂商安全组、服务商 NAT 面板、防火墙面板或端口转发规则。

你需要自己确认：

- 服务商面板已经把外部端口转发到 `-p` 指定的内部端口
- 客户端使用的端口是 `-e` 指定的外部端口
- 云厂商安全组或防火墙已经放行对应 TCP 端口

## License

MIT
