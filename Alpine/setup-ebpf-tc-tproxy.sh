#!/bin/bash
# ==========================================
# 🚀 eBPF TC TProxy 一键部署脚本 (高性能增强版)
# 
# 作者: shangkouyou Duang Scu
# 优化: Antigravity
# 版本: v2.3 (Host IP Safety Fix)
# ==========================================

if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

set -e

# --- 配置 ---
LOG_FILE="/var/log/ebpf-tc-tproxy.log"
EBPF_DIR="/etc/ebpf-tc-tproxy"
EBPF_SCRIPT="$EBPF_DIR/tproxy.sh"
TPROXY_PORT=9420
TPROXY_MARK=0x2333
TABLE_ID=100
DOCKER_PORT=9277

# --- 辅助函数 ---
log() {
    echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"
}

detect_mihomo_routing_mark() {
    local mihomo_config="/etc/mihomo/config.yaml"
    if [ -f "$mihomo_config" ]; then
        local routing_mark=$(grep -E "^routing-mark:" "$mihomo_config" 2>/dev/null | awk '{print $2}' | tr -d ' ' | head -n1)
        if [ -n "$routing_mark" ] && [[ "$routing_mark" =~ ^[0-9]+$ ]]; then
            printf "0x%X" "$routing_mark" 2>/dev/null
            return 0
        fi
    fi
    echo "0x2333"
}

# IP转Hex (Big Endian for BPF)
ip_to_hex() {
    if [ -z "$1" ]; then echo "0"; return; fi
    local IFS=.
    read -r a b c d <<< "$1"
    printf "0x%02X%02X%02X%02X" "$a" "$b" "$c" "$d"
}

# --- 核心逻辑 ---

mkdir -p "$EBPF_DIR"
log "🚀 开始配置 eBPF TC TProxy 环境 (v2.3)..."

# 1. 依赖安装
log "📦 检查编译依赖..."
MISSING_PKGS=()
for cmd in clang llvm iptables ip tc grep; do
     if ! command -v $cmd > /dev/null 2>&1; then
        case $cmd in
            clang|llvm) MISSING_PKGS+=("clang" "llvm" "make") ;;
            iptables) MISSING_PKGS+=("iptables") ;;
            tc) MISSING_PKGS+=("iproute2") ;;
            ip) MISSING_PKGS+=("iproute2") ;;
            grep) MISSING_PKGS+=("grep") ;;
        esac
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    log "📥 安装依赖: ${MISSING_PKGS[*]}"
    if [ -f /etc/alpine-release ]; then
        apk update && apk add "${MISSING_PKGS[@]}" "linux-headers" "musl-dev" "libbpf-dev" "gcc"
    elif [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y "${MISSING_PKGS[@]}" "linux-headers-$(uname -r)" "libbpf-dev" "build-essential"
    elif [ -f /etc/redhat-release ]; then
        yum install -y "${MISSING_PKGS[@]}" "kernel-devel" "kernel-headers" "libbpf-devel" "gcc"
    fi
fi

# 2. 检查 eBPF 支持
check_ebpf_support() {
    if [ ! -e /sys/fs/bpf ]; then
        return 1
    fi
    if ! tc filter help 2>&1 | grep -q "bpf"; then
        return 1
    fi
    return 0
}

# 3. 编译 eBPF 程序
compile_ebpf() {
    local src="$EBPF_DIR/tproxy.bpf.c"
    local obj="$EBPF_DIR/tproxy.bpf.o"
    
    # 获取 LAN IP
    local lan_if=$(ip -4 route show default 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}' | head -n1)
    [ -z "$lan_if" ] && lan_if=$(ip -4 link show | grep -E '^[0-9]+:' | grep -v 'lo:' | head -n1 | awk -F': ' '{print $2}' | awk '{print $1}')
    local main_ip=$(ip -4 addr show "$lan_if" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    
    local host_ip_hex=$(ip_to_hex "$main_ip")
    log "ℹ️  Host IP: $main_ip ($host_ip_hex)"

    cat > "$src" <<EOF
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef TC_ACT_OK
#define TC_ACT_OK 0
#endif
#ifndef TC_ACT_PIPE
#define TC_ACT_PIPE 3
#endif

// 宏定义
#define MARK $TPROXY_MARK
#define HOST_IP $host_ip_hex

SEC("tc")
int tproxy_ingress(struct __sk_buff *skb) {
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    
    struct ethhdr *eth = data;
    if (data + sizeof(*eth) > data_end)
        return TC_ACT_OK;

    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return TC_ACT_OK;

    struct iphdr *ip = data + sizeof(*eth);
    if ((void *)ip + sizeof(*ip) > data_end)
        return TC_ACT_OK;

    __u32 daddr = ip->daddr; // Network Byte Order

    // 1. Host IP Exemption (防止误伤 WAN 访问 Host)
    if (daddr == bpf_htonl(HOST_IP))
        return TC_ACT_OK;

    // 2. Loopback Exemption
    if ((bpf_ntohl(ip->saddr) & 0xFF000000) == 0x7F000000) return TC_ACT_OK;

    // 3. Lane Exemptions
    if ((bpf_ntohl(ip->daddr) & 0xFF000000) == 0x0A000000) return TC_ACT_OK; // 10.0.0.0/8
    if ((bpf_ntohl(ip->daddr) & 0xFFF00000) == 0xAC100000) return TC_ACT_OK; // 172.16.0.0/12 (Docker)
    if ((bpf_ntohl(ip->daddr) & 0xFFFF0000) == 0xC0A80000) return TC_ACT_OK; // 192.168.0.0/16
    if (ip->daddr == 0xFFFFFFFF) return TC_ACT_OK; // Broadcast

    // 4. Mark
    skb->mark = MARK;

    return TC_ACT_OK; 
}

char _license[] SEC("license") = "GPL";
EOF

    log "🔨 正在编译 eBPF..."
    local kinc=""
    if [ -d "/usr/include" ]; then kinc="-I/usr/include"; fi
    
    clang -O2 -target bpf -c "$src" -o "$obj" $kinc
    
    if [ -f "$obj" ]; then
        log "✅ 编译成功"
        return 0
    else
        log "❌ 编译失败"
        return 1
    fi
}

USE_EBPF=false
if check_ebpf_support; then
    if compile_ebpf; then
        USE_EBPF=true
    fi
else
    log "⚠️  系统不支持 eBPF，将使用优化的 iptables 模式"
fi


# 4. 生成脚本
cat > "$EBPF_SCRIPT" <<EOF
#!/bin/bash
# eBPF TC TProxy Script (v2.3)

LOG_FILE="/var/log/ebpf-tc-tproxy.log"
TPROXY_PORT=$TPROXY_PORT
TPROXY_MARK=$TPROXY_MARK
TABLE_ID=$TABLE_ID
DOCKER_PORT=$DOCKER_PORT
EBPF_OBJ="$EBPF_DIR/tproxy.bpf.o"
USE_EBPF=$USE_EBPF

log() {
    echo "[\$(date '+%F %T')] \$1" | tee -a "\$LOG_FILE"
}

LAN_IF="\$(ip -4 route show default 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print \$2}' | head -n1)"
[ -z "\$LAN_IF" ] && LAN_IF="\$(ip -4 link show | grep -E '^[0-9]+:' | grep -v 'lo:' | head -n1 | awk -F': ' '{print \$2}' | awk '{print \$1}')"
MAIN_IP="\$(ip -4 addr show "\$LAN_IF" 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1 | head -n1)"

log "🚀 启动 TProxy (接口: \$LAN_IF, 模式: \$( [ "\$USE_EBPF" = "true" ] && echo "eBPF TC" || echo "iptables" ))"

# 清理
tc qdisc del dev "\$LAN_IF" clsact 2>/dev/null || true
iptables -t mangle -D PREROUTING -i "\$LAN_IF" -j TPROXY_CHAIN 2>/dev/null || true
iptables -t mangle -F TPROXY_CHAIN 2>/dev/null || true
iptables -t mangle -X TPROXY_CHAIN 2>/dev/null || true
ip rule del fwmark \$TPROXY_MARK table \$TABLE_ID 2>/dev/null || true
ip route flush table \$TABLE_ID 2>/dev/null || true

# 创建链
iptables -t mangle -N TPROXY_CHAIN

# QUIC 阻断
iptables -t mangle -A TPROXY_CHAIN -p udp --dport 443 -j DROP

if [ "\$USE_EBPF" = "true" ]; then
    # eBPF 模式: 加载 TC + iptables TPROXY target
    tc qdisc add dev "\$LAN_IF" clsact
    tc filter add dev "\$LAN_IF" ingress bpf direct-action obj "\$EBPF_OBJ" sec tc
    log "✅ TC eBPF 挂载成功"
    
    iptables -t mangle -A TPROXY_CHAIN -m mark --mark \$TPROXY_MARK -p tcp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$TPROXY_MARK
    iptables -t mangle -A TPROXY_CHAIN -m mark --mark \$TPROXY_MARK -p udp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$TPROXY_MARK
    
    iptables -t mangle -I PREROUTING -i "\$LAN_IF" -j TPROXY_CHAIN
else
    # iptables 模式
    iptables -t mangle -A TPROXY_CHAIN -d 127.0.0.0/8 -j RETURN
    if [ -n "\$MAIN_IP" ]; then
        iptables -t mangle -A TPROXY_CHAIN -d "\$MAIN_IP" -j RETURN
        iptables -t mangle -A TPROXY_CHAIN -s "\$MAIN_IP" -j RETURN
    fi
    iptables -t mangle -A TPROXY_CHAIN -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A TPROXY_CHAIN -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A TPROXY_CHAIN -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A TPROXY_CHAIN -p tcp --dport \$DOCKER_PORT -j RETURN
    iptables -t mangle -A TPROXY_CHAIN -p udp --dport \$DOCKER_PORT -j RETURN
    
    iptables -t mangle -A TPROXY_CHAIN -p tcp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$TPROXY_MARK
    iptables -t mangle -A TPROXY_CHAIN -p udp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$TPROXY_MARK
    
    iptables -t mangle -I PREROUTING -i "\$LAN_IF" -j TPROXY_CHAIN
fi

ip rule add fwmark \$TPROXY_MARK table \$TABLE_ID
ip route add local default dev lo table \$TABLE_ID

log "✅ 配置完成"
EOF

chmod +x "$EBPF_SCRIPT"

# 5. Service
if [ -f /etc/alpine-release ]; then
    cat > /etc/init.d/ebpf-tproxy <<EOFRC
#!/sbin/openrc-run
description="Sing-box eBPF TProxy Service"
command="$EBPF_SCRIPT"
command_background="yes"
pidfile="/run/ebpf-tproxy.pid"
depend() {
    need net mihomo
    after firewall
}
EOFRC
    chmod +x /etc/init.d/ebpf-tproxy
    rc-update add ebpf-tproxy default 2>/dev/null
    rc-service ebpf-tproxy restart
else
    cat > /etc/systemd/system/ebpf-tproxy.service <<EOFSD
[Unit]
Description=Sing-box eBPF TProxy Service
After=network.target mihomo.service

[Service]
Type=oneshot
ExecStart=$EBPF_SCRIPT
RemainAfterExit=yes
ExecStop=/usr/bin/tc qdisc del dev \$(ip -4 route show default | awk '{print \$5}') clsact
ExecStop=/usr/bin/iptables -t mangle -F TPROXY_CHAIN

[Install]
WantedBy=multi-user.target
EOFSD
    systemctl daemon-reload
    systemctl enable ebpf-tproxy
    systemctl restart ebpf-tproxy
fi

log "🎉 eBPF TProxy 部署完成！"
