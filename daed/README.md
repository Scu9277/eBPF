# daed Alpine 一键安装脚本

> 在 **Alpine Linux x86_64** 上自动安装 [daed](https://github.com/daeuniverse/daed)（dae 的 Web UI 控制面板）  
> 自动配置 eBPF 环境检查、OpenRC 自启服务、系统调优和默认代理配置

[![License](https://img.shields.io/badge/license-MIT-green)](https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/daed/install_daed_alpine.sh)

---

## 功能特性

| 功能 | 说明 |
|------|------|
| 🔍 **eBPF 预检** | 自动检查内核 BPF / DEBUG_INFO_BTF / KPROBES / BPF_EVENTS |
| 📦 **依赖安装** | curl、unzip、ca-certificates、nftables |
| 🌐 **版本检测** | 从 GitHub API 自动获取最新版，支持手动指定 |
| 🚀 **镜像加速** | 通过 `MIRROR` 变量指定 GitHub 镜像，国内友好 |
| ⚙️ **系统调优** | 开启 IPv4/v6 转发、关闭 ICMP 重定向 |
| 🔄 **OpenRC 服务** | 生成 init.d 脚本，支持 `rc-service` 管理 |
| 📝 **默认配置** | 自动生成 TPROXY + DNS 分流配置，自动检测网卡 |
| 🖥️ **Web UI** | 默认监听 `0.0.0.0:80`，浏览器即可管理 |

---

## 环境要求

| 项目 | 要求 |
|------|------|
| 系统 | Alpine Linux 3.18+ |
| 架构 | x86_64 (amd64) |
| 内核 | >= 5.10，开启 eBPF |
| 权限 | 需 root 运行 |
| 网络 | 能访问 GitHub（或使用镜像） |

---

## 快速开始

### 一行命令安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/daed/install_daed_alpine.sh)"
```

### 或者分步下载执行

```bash
curl -fsSL -o install_daed_alpine.sh \
  https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/daed/install_daed_alpine.sh
bash install_daed_alpine.sh
```

安装完成后，浏览器访问 `http://<本机IP>:80/` 即可进入 daed 管理界面。

---

## 环境变量

通过环境变量控制脚本行为。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `VERSION` | 自动检测 | 指定版本号，如 `1.27.0` |
| `MIRROR` | `https://ghfast.top` | GitHub 镜像前缀 |
| `PORT` | `80` | Web UI 端口 |
| `LISTEN_ADDR` | `0.0.0.0` | 监听地址 |

### 使用示例

```bash
# 最简安装
bash install_daed_alpine.sh

# 指定端口 + 国内镜像加速
PORT=8080 MIRROR=https://ghproxy.com bash install_daed_alpine.sh

# 指定版本 + 仅本机访问
VERSION=1.27.0 PORT=9090 LISTEN_ADDR=127.0.0.1 bash install_daed_alpine.sh

# 国外 VPS 直连
MIRROR= bash install_daed_alpine.sh
```

---

## 安装流程

```
架构检查 → 内核 eBPF 检查 → 安装依赖 → 下载解压
→ 安装二进制/数据文件 → sysctl 调优 → 生成默认配置
→ 注册 OpenRC 服务 → 启动 → 验证
```

---

## 日常管理

### 服务管理

```bash
rc-service daed start      # 启动
rc-service daed stop       # 停止
rc-service daed restart    # 重启
rc-service daed status     # 查看状态
rc-service daed status -v  # 查看详细日志
```

### 开机自启

```bash
rc-update add daed default   # 添加开机自启
rc-update del daed           # 取消开机自启
rc-update show               # 查看所有自启服务
```

### 修改配置

```bash
vi /etc/daed/config.dae
rc-service daed restart
```

---

## 客户端配置

将设备的 **网关** 和 **DNS** 指向运行 daed 的机器 IP。

```
IP 地址：运行 daed 的机器 IP（安装完成后脚本会自动显示）
子网掩码：按原设置
网关：    运行 daed 的机器 IP
DNS：     8.8.8.8（或其他）
```

> 确保客户端与 daed 在同一网段。

---

## 默认配置说明

脚本自动生成 `/etc/daed/config.dae`，实现 TPROXY + DNS 分流：

- **TCP 代理端口**：12345
- **DNS**：国内域名走阿里 DNS（223.5.5.5），其余走 Google DNS（8.8.8.8）
- **路由**：私有地址和国内 IP 直连，其余走代理
- **网卡**：自动检测第一个非 lo 的物理网卡

> 注意：`lan_interface` 由脚本自动检测，无需手动修改。如需要可编辑 `/etc/daed/config.dae` 调整。

---

## 常见问题

### Q1: 提示 `missing: BPF / DEBUG_INFO_BTF / KPROBES / BPF_EVENTS`

内核缺少 eBPF 相关支持。安装 `linux-lts` 内核后重启：

```bash
apk add linux-lts
reboot
```

### Q2: 下载失败 / 版本检测失败

GitHub 连接不稳定，使用镜像重试：

```bash
MIRROR=https://ghproxy.com bash install_daed_alpine.sh
```

### Q3: Web UI 无法访问

检查进程、端口和防火墙：

```bash
pgrep -af daed
ss -tlnp | grep 80
nft list ruleset
```

### Q4: 客户端无法上网

确认 IP 转发和 nftables 正常：

```bash
sysctl net.ipv4.ip_forward
nft list ruleset
```

---

## 卸载方法

```bash
# 停止并移除自启
rc-service daed stop
rc-update del daed

# 删除文件
rm -f /usr/local/bin/daed
rm -rf /etc/daed
rm -f /etc/init.d/daed
rm -f /etc/sysctl.d/60-ip-forward.conf

# 清理 BPF
find /sys/fs/bpf/daed -mindepth 1 -delete 2>/dev/null || true
```

---

## 参考资料

- [daed GitHub](https://github.com/daeuniverse/daed) — dae 的 Web UI
- [dae GitHub](https://github.com/daeuniverse/dae) — eBPF 代理核心
- [Alpine Linux OpenRC 文档](https://wiki.alpinelinux.org/wiki/OpenRC)

---

## 许可

MIT
