#!/bin/bash
# eBPF TC TProxy 诊断脚本

echo "=== eBPF TC TProxy 诊断工具 ==="
echo ""

# 检测主网卡
MAIN_IF=$(ip -4 route show default | grep -oP '(?<=dev )\S+' | head -n1)
echo "1. 主网卡: $MAIN_IF"
echo ""

# 检查 TC 规则
echo "2. TC 规则状态:"
tc qdisc show dev "$MAIN_IF" 2>/dev/null || echo "  ❌ 未找到 TC qdisc"
tc filter show dev "$MAIN_IF" ingress 2>/dev/null || echo "  ❌ 未找到 TC filter"
echo ""

# 检查 eBPF 程序
echo "3. eBPF 程序状态:"
bpftool prog list | grep -i tproxy || echo "  ❌ 未找到 TProxy eBPF 程序"
echo ""

# 检查策略路由
echo "4. 策略路由状态:"
ip rule show | grep -E "0x2333|9139" || echo "  ❌ 未找到策略路由规则"
ip route show table 100 2>/dev/null || echo "  ❌ 路由表 100 不存在或为空"
echo ""

# 检查 IP 转发
echo "5. IP 转发状态:"
ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
if [ "$ip_forward" = "1" ]; then
    echo "  ✅ IP 转发已启用"
else
    echo "  ❌ IP 转发未启用 (当前值: $ip_forward)"
fi
echo ""

# 检查 Mihomo 服务
echo "6. Mihomo 服务状态:"
if systemctl is-active --quiet mihomo; then
    echo "  ✅ Mihomo 服务正在运行"
    mihomo_pid=$(systemctl show -p MainPID --value mihomo 2>/dev/null)
    if [ -n "$mihomo_pid" ]; then
        echo "  PID: $mihomo_pid"
        # 检查 TProxy 端口是否监听
        if netstat -tuln 2>/dev/null | grep -q ":9420" || ss -tuln 2>/dev/null | grep -q ":9420"; then
            echo "  ✅ TProxy 端口 9420 正在监听"
        else
            echo "  ❌ TProxy 端口 9420 未监听"
        fi
    fi
else
    echo "  ❌ Mihomo 服务未运行"
fi
echo ""

# 检查防火墙
echo "7. 防火墙状态:"
if command -v ufw &> /dev/null; then
    ufw_status=$(ufw status 2>/dev/null | head -1)
    echo "  UFW: $ufw_status"
fi
if command -v iptables &> /dev/null; then
    iptables_rules=$(iptables -L -n 2>/dev/null | wc -l)
    echo "  iptables 规则数: $iptables_rules"
fi
echo ""

# 检查网络接口 IP
echo "8. 网络接口信息:"
ip -4 addr show "$MAIN_IF" | grep "inet " || echo "  ❌ 未找到 IPv4 地址"
echo ""

# 测试数据包标记
echo "9. 测试数据包标记功能:"
echo "  运行以下命令测试（需要 root 权限）:"
echo "  # 在另一个终端执行: ping 8.8.8.8"
echo "  # 然后检查: ip rule show"
echo ""

# 检查日志
echo "10. 最近日志:"
if [ -f "/var/log/tproxy_tc.log" ]; then
    echo "  最后 10 行日志:"
    tail -10 /var/log/tproxy_tc.log
else
    echo "  ⚠️  日志文件不存在"
fi
echo ""

echo "=== 诊断完成 ==="
echo ""
echo "建议检查项:"
echo "1. 确保 Mihomo 正在运行并监听 9420 端口"
echo "2. 确保 IP 转发已启用"
echo "3. 确保防火墙允许转发流量"
echo "4. 检查 TC 规则是否正确加载"
echo "5. 检查策略路由是否正确配置"
