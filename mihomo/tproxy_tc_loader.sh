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
    local deps=(clang llvm iproute2 bpftool libbpf-dev)
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "${dep%% *}" &> /dev/null && [ "$dep" != "libbpf-dev" ]; then
            missing_deps+=($dep)
        fi
    done
    
    # 检查 libbpf-dev 是否安装
    if [ ! -d "/usr/include/bpf" ]; then
        missing_deps+=("libbpf-dev")
    fi
    
    # 尝试多种方法检查内核头文件
    local found_headers=false
    local kernel_headers_pkg="linux-headers-$(uname -r)"
    
    # 检查常见的头文件位置
    if [ -f "/usr/include/asm/types.h" ] || \
       [ -f "/usr/src/$kernel_headers_pkg/include/asm/types.h" ] || \
       [ -d "/usr/include/x86_64-linux-gnu/asm" ]; then
        found_headers=true
    fi
    
    # 如果找不到头文件，添加到依赖列表
    if [ "$found_headers" = false ]; then
        missing_deps+=($kernel_headers_pkg)
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
    
    # 查找正确的头文件路径
    local kernel_headers_pkg="linux-headers-$(uname -r)"
    local header_paths=""
    local compile_success=false
    
    # 添加可能的头文件路径
    if [ -d "/usr/include/x86_64-linux-gnu/asm" ]; then
        header_paths="-I/usr/include/x86_64-linux-gnu"
    elif [ -d "/usr/src/$kernel_headers_pkg/include" ]; then
        header_paths="-I/usr/src/$kernel_headers_pkg/include"
    fi
    
    # 调试信息
    log "调试: 当前目录: $SCRIPT_DIR"
    log "调试: 目录内容: $(ls -la "$SCRIPT_DIR")"
    log "调试: 头文件路径: $header_paths"
    
    # 尝试使用 clang 编译
    log "尝试使用 clang 编译..."
    local clang_output
    clang_output=$(clang $header_paths -O2 -target bpf -c "$BPF_PROG" -o "$BPF_FILE" 2>&1)
    local clang_status=$?
    
    if [ -n "$clang_output" ]; then
        echo "$clang_output" | tee -a "$LOG_FILE"
    fi
    
    if [ $clang_status -eq 0 ] && [ -f "$BPF_FILE" ]; then
        log "clang 编译成功"
        compile_success=true
    else
        log "clang 编译失败，状态码: $clang_status"
    fi
    
    # 如果 clang 失败，尝试使用 bpftool
    if [ "$compile_success" = false ]; then
        log "尝试使用 bpftool 编译..."
        local bpftool_output
        bpftool_output=$(bpftool gen object "$BPF_FILE" "$BPF_PROG" 2>&1)
        local bpftool_status=$?
        
        if [ -n "$bpftool_output" ]; then
            echo "$bpftool_output" | tee -a "$LOG_FILE"
        fi
        
        if [ $bpftool_status -eq 0 ] && [ -f "$BPF_FILE" ]; then
            log "bpftool 编译成功"
            compile_success=true
        else
            log "bpftool 编译也失败，状态码: $bpftool_status"
        fi
    fi
    
    # 最终检查
    if [ "$compile_success" = true ] && [ -f "$BPF_FILE" ]; then
        log "eBPF 程序编译成功: $(ls -lh "$BPF_FILE")"
    else
        log "错误: eBPF 程序编译失败"
        log "调试: 检查 bpftool 版本: $(bpftool --version 2>&1 | head -1)"
        log "调试: 检查内核版本: $(uname -r)"
        log "调试: 查找 bpf 头文件: $(find /usr -name 'bpf_endian.h' 2>/dev/null | head -3)"
        exit 1
    fi
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
    
    # 检查文件是否存在
    if [ ! -f "$SCRIPT_DIR/$BPF_FILE" ]; then
        log "错误: eBPF 文件不存在: $SCRIPT_DIR/$BPF_FILE"
        exit 1
    fi
    
    log "eBPF 文件信息: $(ls -lh "$SCRIPT_DIR/$BPF_FILE")"
    
    # 添加 clsact 队列规则
    tc qdisc add dev "$INTERFACE" clsact 2>/dev/null || {
        log "错误: 无法添加 clsact 队列规则"
        exit 1
    }
    
    # 加载 eBPF 程序到 ingress 钩子
    tc filter add dev "$INTERFACE" ingress bpf da obj "$SCRIPT_DIR/$BPF_FILE" sec classifier
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
