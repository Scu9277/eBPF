# eBPF TC TProxy for Mihomo

这是一个使用 eBPF TC 技术实现的透明代理解决方案，替代了传统的 iptables TProxy 规则，适用于 Mihomo (sing-box) 代理工具。

## 功能特性

- ✅ 基于 eBPF TC 技术，性能更优
- ✅ 与原有 iptables TProxy 规则功能完全兼容
- ✅ 支持 TCP 和 UDP 流量转发
- ✅ 自动豁免局域网和本地流量
- ✅ 配置简单，一键部署

## 原理说明

该方案通过以下步骤实现透明代理：

1. 使用 TC (Traffic Control) ingress 钩子捕获进入网卡的流量
2. 通过 eBPF 程序检查流量，豁免本地和局域网流量
3. 对需要代理的流量设置标记 (0x2333) 并转发到 TProxy 端口 (9420)
4. 通过策略路由将标记的流量引导到 Mihomo 代理

## 前提条件

### 硬件要求
- 支持 eBPF 的 Linux 内核 (推荐 5.4 以上)

### 软件要求
- Debian 13 (Bookworm)
- clang 和 llvm (用于编译 eBPF 程序)
- iproute2 (用于管理 TC 规则)
- bpftool (用于调试 eBPF 程序)

## 安装依赖

```bash
sudo apt update
sudo apt install -y clang llvm iproute2 bpftool
```

## 部署步骤

### 1. 准备文件

将以下文件上传到服务器上的同一目录：

- `tproxy_tc.bpf.c` (eBPF 程序源代码)
- `tproxy_tc_loader.sh` (加载脚本)

### 2. 配置 Mihomo

确保 Mihomo 配置文件 (`config.yaml`) 中已正确配置：

```yaml
tproxy-port: 9420         # TProxy 端口
routing-mark: 9139        # 路由标记 (0x2333 的十进制)
allow-lan: true           # 允许局域网连接
```

### 3. 运行加载脚本

```bash
# 赋予执行权限
sudo chmod +x tproxy_tc_loader.sh

# 运行脚本
sudo ./tproxy_tc_loader.sh
```

## 脚本功能说明

### 自动检测
- 自动检测默认网络接口
- 自动检查依赖是否安装

### 编译 eBPF 程序
- 使用 clang 编译 eBPF 程序到目标文件

### 清理旧规则
- 清理旧的 TC 规则
- 清理旧的策略路由

### 加载新规则
- 添加 TC clsact 队列规则
- 加载 eBPF 程序到 TC ingress 钩子
- 配置策略路由
- 优化 sysctl 参数

## 配置参数

脚本中的主要配置参数位于文件开头：

| 参数名 | 说明 | 默认值 |
|--------|------|--------|
| LOG_FILE | 日志文件路径 | `/var/log/tproxy_tc.log` |
| TPROXY_PORT | TProxy 端口 | 9420 |
| TPROXY_MARK | 路由标记 | 0x2333 |
| TABLE_ID | 路由表 ID | 100 |
| DOCKER_PORT | Docker 端口 (豁免) | 9277 |
| INTERFACE | 网络接口 (自动检测) | 默认网关接口 |

## 豁免规则

以下流量会被自动豁免，不经过代理：

- 10.0.0.0/8 (局域网)
- 172.16.0.0/12 (局域网)
- 192.168.0.0/16 (局域网)
- 127.0.0.0/8 (本地回环)
- 255.255.255.255 (广播地址)
- Docker 端口 9277

## 查看状态

### 查看 TC 规则

```bash
tc filter show dev <interface> ingress
```

### 查看 eBPF 程序

```bash
bpftool prog list
bpftool prog show id <prog_id>
```

### 查看策略路由

```bash
ip rule show
ip route show table 100
```

### 查看日志

```bash
tail -f /var/log/tproxy_tc.log
```

## 卸载规则

```bash
# 清理 TC 规则
sudo tc qdisc del dev <interface> clsact

# 清理策略路由
sudo ip rule del fwmark 0x2333 table 100
sudo ip route flush table 100
```

## 故障排查

### 1. 流量未被代理

- 检查 Mihomo 是否正常运行
- 检查 TC 规则是否正确加载
- 检查策略路由是否配置正确
- 查看日志文件 `/var/log/tproxy_tc.log`

### 2. 局域网设备无法上网

- 确保服务器的 IP 转发已开启：`sysctl net.ipv4.ip_forward`
- 确保防火墙允许相关流量
- 检查 Mihomo 配置中的 `allow-lan` 是否为 `true`

### 3. eBPF 程序编译失败

- 确保 clang 和 llvm 已正确安装
- 检查内核版本是否支持 eBPF
- 查看编译错误信息

## 与原有 iptables 方案的对比

| 特性 | eBPF TC 方案 | iptables 方案 |
|------|-------------|--------------|
| 性能 | 更高 | 一般 |
| 资源占用 | 更低 | 更高 |
| 灵活性 | 更高 | 一般 |
| 兼容性 | 需要较新内核 | 广泛兼容 |
| 配置复杂度 | 简单 | 复杂 |

## 系统优化建议

### 1. 启用 BBR 拥塞控制

```bash
sudo sysctl -w net.core.default_qdisc=fq
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
```

### 2. 优化内核参数

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv4.tcp_tw_reuse=1
sudo sysctl -w net.core.somaxconn=4096
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=4096
```

## 注意事项

1. 该方案仅支持 IPv4 流量
2. 需要 root 权限运行脚本
3. 建议在测试环境中验证后再部署到生产环境
4. 定期查看日志文件，及时发现问题

## 许可证

GPL-2.0

## 更新日志

### v1.0.0
- 初始版本
- 实现基本的 eBPF TC TProxy 功能
- 支持 TCP 和 UDP 流量
- 自动豁免局域网流量
