#!/bin/bash
# IPv4-only TProxy for sing-box using eBPF TC
# 替代原有 iptables TProxy 规则
# 一键部署脚本：自动安装依赖、编译、加载、配置自动启动

LOG_FILE="/var/log/tproxy_tc.log"
TPROXY_PORT=9420
TPROXY_MARK=0x2333
TABLE_ID=100
DOCKER_PORT=9277
INTERFACE="$(ip -4 route show default | grep -oP '(?<=dev )\S+' | head -n1)"
BPF_FILE="tproxy_tc.bpf.o"
BPF_PROG="tproxy_tc.bpf.c"
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SERVICE_NAME="tproxy-tc"

# 日志函数
log() {
    local msg="[$(date +"%Y-%m-%d %H:%M:%S")] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log "开始加载 IPv4 TProxy eBPF TC 规则 (接口: $INTERFACE)..."

# 检查并安装依赖
check_and_install_deps() {
    log "检查依赖..."
    local deps=(clang llvm iproute2 bpftool)
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "${dep%% *}" &> /dev/null; then
            missing_deps+=($dep)
        fi
    done
    
    # 检查内核头文件是否安装
    if [ ! -f "/usr/include/asm/types.h" ]; then
        missing_deps+=("linux-headers-$(uname -r)")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log "正在安装缺少的依赖: ${missing_deps[*]}"
        apt-get update > /dev/null
        apt-get install -y ${missing_deps[*]} > /dev/null
        if [ $? -ne 0 ]; then
            log "错误: 依赖安装失败"
            exit 1
        fi
        log "依赖安装完成"
    else
        log "所有依赖已安装"
    fi
}

# 编译 eBPF 程序
compile_bpf() {
    log "编译 eBPF 程序..."
    cd "$SCRIPT_DIR" || exit 1
    clang -O2 -target bpf -c "$BPF_PROG" -o "$BPF_FILE"
    if [ $? -ne 0 ]; then
        log "错误: eBPF 程序编译失败"
        exit 1
    fi
    log "eBPF 程序编译成功"
}

# 清理旧规则
cleanup_old_rules() {
    log "清理旧规则..."
    
    # 清理 TC 规则
    tc qdisc del dev "$INTERFACE" clsact 2>/dev/null || true
    
    # 清理策略路由
    ip rule del fwmark "$TPROXY_MARK" table "$TABLE_ID" 2>/dev/null || true
    ip route flush table "$TABLE_ID" 2>/dev/null || true
    
    # 清理旧的 systemd 服务
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME.service" 2>/dev/null || true
    
    log "旧规则清理完成"
}

# 加载 eBPF 程序到 TC
load_bpf_to_tc() {
    log "加载 eBPF 程序到 TC..."
    
    # 添加 clsact 队列规则
    tc qdisc add dev "$INTERFACE" clsact 2>/dev/null || {
        log "错误: 无法添加 clsact 队列规则"
        exit 1
    }
    
    # 加载 eBPF 程序到 ingress 钩子
    tc filter add dev "$INTERFACE" ingress bpf da obj "$BPF_FILE" sec classifier
    if [ $? -ne 0 ]; then
        log "错误: 无法加载 eBPF 程序到 TC"
        exit 1
    fi
    
    log "eBPF 程序加载到 TC 成功"
}

# 配置策略路由
configure_policy_routing() {
    log "配置策略路由..."
    
    # 添加策略路由规则
    ip rule add fwmark "$TPROXY_MARK" table "$TABLE_ID"
    if [ $? -ne 0 ]; then
        log "错误: 无法添加策略路由规则"
        exit 1
    fi
    
    # 添加本地默认路由
    ip route add local default dev lo table "$TABLE_ID"
    if [ $? -ne 0 ]; then
        log "错误: 无法添加本地默认路由"
        exit 1
    fi
    
    log "策略路由配置成功"
}

# 配置 sysctl 参数
configure_sysctl() {
    log "配置 sysctl 参数..."
    
    # 启用 IP 转发
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    
    # 启用本地端口重用（用于 TProxy）
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" > /dev/null
    sysctl -w net.ipv4.tcp_tw_reuse=1 > /dev/null
    
    log "sysctl 参数配置成功"
}

# 创建 systemd 服务
create_systemd_service() {
    log "创建 systemd 服务..."
    
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=eBPF TC TProxy for Mihomo
After=network.target mihomo.service
Wants=mihomo.service
# 延迟30秒启动，确保 mihomo 先启动
ExecStartPre=/bin/sleep 30

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH --load-only
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    
    if [ $? -ne 0 ]; then
        log "错误: 无法创建 systemd 服务文件"
        exit 1
    fi
    
    # 重新加载 systemd 配置
    systemctl daemon-reload
    
    # 启用服务
    systemctl enable "$SERVICE_NAME" 2>/dev/null || {
        log "警告: 无法启用 systemd 服务，但已创建服务文件"
    }
    
    log "systemd 服务创建成功，已设置延迟30秒启动"
}

# 只加载规则（用于 systemd 服务）
load_only() {
    log "仅加载模式：开始加载 eBPF TC 规则..."
    cleanup_old_rules
    load_bpf_to_tc
    configure_policy_routing
    configure_sysctl
    log "✅ 仅加载模式完成"
    exit 0
}

# 显示帮助
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --load-only    仅加载规则，不编译或创建服务"
    echo "  --help         显示帮助信息"
    echo ""
    echo "一键部署 eBPF TC TProxy 规则，包括："
    echo "  - 检查并安装依赖"
    echo "  - 编译 eBPF 程序"
    echo "  - 加载 eBPF TC 规则"
    echo "  - 配置策略路由"
    echo "  - 创建 systemd 服务（延迟30秒启动）"
    exit 0
}

# 检查命令行参数
check_args() {
    for arg in "$@"; do
        case "$arg" in
            --load-only)
                load_only
                ;;
            --help)
                show_help
                ;;
            *)
                log "警告: 未知参数: $arg"
                ;;
        esac
    done
}

# 主函数
main() {
    # 检查是否为 root
    if [ "$(id -u)" -ne 0 ]; then
        log "错误: 需要 root 权限运行此脚本"
        exit 1
    fi
    
    # 检查命令行参数
    check_args "$@"
    
    # 检查并安装依赖
    check_and_install_deps
    
    # 编译 eBPF 程序
    compile_bpf
    
    # 清理旧规则
    cleanup_old_rules
    
    # 加载 eBPF 程序
    load_bpf_to_tc
    
    # 配置策略路由
    configure_policy_routing
    
    # 配置 sysctl 参数
    configure_sysctl
    
    # 创建 systemd 服务
    create_systemd_service
    
    log "✅ IPv4 TProxy eBPF TC 规则加载完成 (接口: $INTERFACE)"
    log "✅ 自动启动服务已创建，将延迟30秒启动"
    log "✅ 部署完成！"
}

# 执行主函数
main "$@"
