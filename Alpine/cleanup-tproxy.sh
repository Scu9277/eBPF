#!/bin/bash
# ==========================================
# 🧹 TProxy 一键清理脚本
# 
# 作者: shangkouyou Duang Scu
# 微信: shangkouyou
# 邮箱: shangkouyou@gmail.com
# 版本: v1.0
#
# 功能：完全清理所有 TProxy 相关配置
# ==========================================

set -e

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

echo -e "${BLUE}=================================================="
echo -e "🧹 TProxy 一键清理脚本"
echo -e "==================================================${NC}"
echo ""

# 检测系统类型
if [ -f /etc/alpine-release ]; then
    OS_DIST="alpine"
elif [ -f /etc/debian_version ]; then
    OS_DIST="debian"
elif [ -f /etc/redhat-release ]; then
    OS_DIST="redhat"
else
    OS_DIST="other"
fi

echo -e "${YELLOW}检测到系统: $OS_DIST${NC}"
echo ""

# 确认操作
read -p "$(echo -e ${RED}⚠️  此操作将清理所有 TProxy 配置，是否继续？ \(y/N\): ${NC})" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}已取消操作${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}🧹 开始清理 TProxy 配置...${NC}"
echo ""

# 1. 停止并禁用服务
echo -e "${BLUE}1. 停止并禁用服务...${NC}"
if [ "$OS_DIST" == "alpine" ]; then
    # OpenRC
    if rc-service tproxy status > /dev/null 2>&1; then
        rc-service tproxy stop 2>/dev/null || true
        rc-update del tproxy default 2>/dev/null || true
        echo -e "   ${GREEN}✅ 已停止并禁用 tproxy 服务${NC}"
    fi
    
    if rc-service ebpf-tproxy status > /dev/null 2>&1; then
        rc-service ebpf-tproxy stop 2>/dev/null || true
        rc-update del ebpf-tproxy default 2>/dev/null || true
        echo -e "   ${GREEN}✅ 已停止并禁用 ebpf-tproxy 服务${NC}"
    fi
else
    # systemd
    if systemctl is-active --quiet tproxy.service 2>/dev/null; then
        systemctl stop tproxy.service 2>/dev/null || true
        systemctl disable tproxy.service 2>/dev/null || true
        echo -e "   ${GREEN}✅ 已停止并禁用 tproxy.service${NC}"
    fi
    
    if systemctl is-active --quiet ebpf-tproxy.service 2>/dev/null; then
        systemctl stop ebpf-tproxy.service 2>/dev/null || true
        systemctl disable ebpf-tproxy.service 2>/dev/null || true
        echo -e "   ${GREEN}✅ 已停止并禁用 ebpf-tproxy.service${NC}"
    fi
fi

# 2. 清理 iptables 规则
echo -e "${BLUE}2. 清理 iptables 规则...${NC}"
# 清理所有可能的链名称
for chain in TPROXY_CHAIN TPROXY tproxy; do
    iptables -t mangle -D PREROUTING -j $chain 2>/dev/null || true
    iptables -t mangle -F $chain 2>/dev/null || true
    iptables -t mangle -X $chain 2>/dev/null || true
done
echo -e "   ${GREEN}✅ 已清理 iptables mangle 表规则${NC}"

# 3. 清理 TC eBPF 规则
echo -e "${BLUE}3. 清理 TC eBPF 规则...${NC}"
# 获取所有网卡
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    tc qdisc del dev "$iface" clsact 2>/dev/null || true
    tc filter del dev "$iface" ingress 2>/dev/null || true
    tc filter del dev "$iface" egress 2>/dev/null || true
done
echo -e "   ${GREEN}✅ 已清理 TC 规则${NC}"

# 4. 清理策略路由
echo -e "${BLUE}4. 清理策略路由...${NC}"
# 清理所有可能的 mark 值
for mark in 0x2333 0x23B3 0x23b3 9139; do
    for table in 100 101 102; do
        ip rule del fwmark $mark table $table 2>/dev/null || true
        ip route flush table $table 2>/dev/null || true
    done
done
echo -e "   ${GREEN}✅ 已清理策略路由规则${NC}"

# 5. 删除服务文件
echo -e "${BLUE}5. 删除服务文件...${NC}"
if [ "$OS_DIST" == "alpine" ]; then
    rm -f /etc/init.d/tproxy 2>/dev/null || true
    rm -f /etc/init.d/ebpf-tproxy 2>/dev/null || true
else
    rm -f /etc/systemd/system/tproxy.service 2>/dev/null || true
    rm -f /etc/systemd/system/ebpf-tproxy.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
fi
echo -e "   ${GREEN}✅ 已删除服务文件${NC}"

# 6. 删除配置目录
echo -e "${BLUE}6. 删除配置目录...${NC}"
rm -rf /etc/tproxy 2>/dev/null || true
rm -rf /etc/ebpf-tc-tproxy 2>/dev/null || true
echo -e "   ${GREEN}✅ 已删除配置目录${NC}"

# 7. 清理日志文件
echo -e "${BLUE}7. 清理日志文件...${NC}"
rm -f /var/log/tproxy*.log 2>/dev/null || true
rm -f /var/log/ebpf-tproxy*.log 2>/dev/null || true
echo -e "   ${GREEN}✅ 已清理日志文件${NC}"

# 8. 卸载 eBPF 程序
echo -e "${BLUE}8. 卸载 eBPF 程序...${NC}"
rm -f /sys/fs/bpf/tproxy_prog 2>/dev/null || true
echo -e "   ${GREEN}✅ 已卸载 eBPF 程序${NC}"

echo ""
echo -e "${GREEN}=================================================="
echo -e "✅ TProxy 配置清理完成！"
echo -e "==================================================${NC}"
echo ""
echo -e "${YELLOW}验证清理结果：${NC}"
echo ""

# 验证
echo -e "${BLUE}iptables 规则：${NC}"
if iptables -t mangle -L PREROUTING -n 2>/dev/null | grep -q "TPROXY"; then
    echo -e "   ${RED}❌ 仍有 TPROXY 规则残留${NC}"
else
    echo -e "   ${GREEN}✅ 无 TPROXY 规则${NC}"
fi

echo ""
echo -e "${BLUE}策略路由：${NC}"
if ip rule show | grep -q "fwmark"; then
    echo -e "   ${YELLOW}⚠️  仍有 fwmark 规则（可能是其他服务）${NC}"
    ip rule show | grep "fwmark"
else
    echo -e "   ${GREEN}✅ 无 fwmark 规则${NC}"
fi

echo ""
echo -e "${BLUE}服务状态：${NC}"
if [ "$OS_DIST" == "alpine" ]; then
    if rc-service tproxy status > /dev/null 2>&1 || rc-service ebpf-tproxy status > /dev/null 2>&1; then
        echo -e "   ${RED}❌ 仍有服务运行${NC}"
    else
        echo -e "   ${GREEN}✅ 所有服务已停止${NC}"
    fi
else
    if systemctl is-active --quiet tproxy.service 2>/dev/null || systemctl is-active --quiet ebpf-tproxy.service 2>/dev/null; then
        echo -e "   ${RED}❌ 仍有服务运行${NC}"
    else
        echo -e "   ${GREEN}✅ 所有服务已停止${NC}"
    fi
fi

echo ""
echo -e "${YELLOW}💡 提示：如需重新配置 TProxy，请运行 setup.sh 脚本${NC}"
