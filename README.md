# sing-box Naive 一键安装脚本

一个基于 sing-box 最新预发布版（1.14+）的 NaiveProxy 一键安装与管理脚本。

## 特性

- 自动安装 sing-box 最新 prerelease
- NaiveProxy 入站
- 内置 ACME 自动申请 TLS 证书
- 最小 TLS 配置（已移除 tls.alpn）
- 自动开启 BBR
- 自动生成 Naive URI
- 自动生成 sing-box outbound
- 菜单式管理
- 支持修改：
  - 用户名
  - 密码
  - 端口
  - tcp/udp
- 支持自动更新 sing-box
- 支持 systemd

---

## 支持系统

- Debian 11+
- Ubuntu 20.04+
- CentOS 7+
- Rocky Linux
- AlmaLinux

推荐使用纯净系统。

---

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/akaagiao1/sing-box-naive-install/main/sb-naive.sh)
```

---

## 菜单功能

```text
1. 安装 / 重装 NaiveProxy
2. 查看 Naive 链接 + outbound
3. 修改密码
4. 修改用户名
5. 修改端口
6. 修改网络 tcp/udp
7. 重启 sing-box
8. 查看状态
9. 查看日志
10. 更新 sing-box
11. 卸载 sing-box
0. 退出
```

---

## Naive URI 示例

```text
https://username:password@example.com:443
```

---

## sing-box outbound 示例

```json
{
  "type": "naive",
  "tag": "naive-out",
  "server": "example.com",
  "server_port": 443,
  "username": "username",
  "password": "password",
  "tls": {
    "enabled": true,
    "server_name": "example.com"
  }
}
```

---

## 注意事项

### 1. 域名必须解析到 VPS

确保：

- A 记录
- AAAA 记录（如果有 IPv6）

已经正确解析到服务器。

---

### 2. 安全组必须放行端口

至少放行：

```text
80/tcp
443/tcp
```

如果修改了端口，需要同步放行。

---

### 3. 推荐使用最小 TLS 配置

当前脚本已经移除：

```json
"alpn": [
  "h2",
  "http/1.1"
]
```

原因：

部分 sing-box alpha / Naive 客户端会出现：

- GitHub 提示连接不安全
- TLS 协商异常
- HTTP/2 兼容问题

最小 TLS 配置反而更加稳定。

---

## 查看日志

```bash
journalctl -u sing-box -f
```

---

## 查看状态

```bash
systemctl status sing-box
```

---

## 重启

```bash
systemctl restart sing-box
```

---

## 卸载

脚本菜单：

```text
11. 卸载 sing-box
```

---

## Star

如果这个项目对你有帮助，欢迎 Star。
