#!/bin/bash
# 从 GitHub 下载并部署 eBPF TC TProxy 规则
# 直接使用固定加速 URL 下载

# 固定加速下载 URL
BPF_URL="https://ghfast.top/raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/mihomo/tproxy_tc.bpf.c"
LOADER_URL="https://ghfast.top/raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/mihomo/tproxy_tc_loader.sh"

# 日志函数
log() {
    local msg="[$(date +"%Y-%m-%d %H:%M:%S")] $1"
    echo "$msg"
}

# 下载函数
download_file() {
    local url=$1
    local output=$2
    
    log "开始下载 $output..."
    log "下载 URL: $url"
    
    # 尝试下载，最多重试3次
    for ((i=1; i<=3; i++)); do
        log "第 $i 次尝试下载"
        if curl -s -L -o "$output" "$url" && [ -s "$output" ]; then
            log "✅ 成功下载 $output"
            return 0
        fi
        sleep 1
    done
    
    log "❌ 下载 $output 失败"
    return 1
}

# 主函数
main() {
    log "=== eBPF TC TProxy 部署脚本 ==="
    
    # 检查curl是否安装
    if ! command -v curl &> /dev/null; then
        log "❌ 错误: curl 未安装，请先安装 curl"
        exit 1
    fi
    
    # 检查root权限
    if [ "$(id -u)" -ne 0 ]; then
        log "❌ 错误: 需要 root 权限运行此脚本"
        exit 1
    fi
    
    # 创建临时目录
    TEMP_DIR="/tmp/ebpftproxy-$(date +%s)"
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || exit 1
    
    log "工作目录: $TEMP_DIR"
    
    # 下载文件
    if ! download_file "$BPF_URL" "tproxy_tc.bpf.c"; then
        log "❌ 部署失败"
        exit 1
    fi
    
    if ! download_file "$LOADER_URL" "tproxy_tc_loader.sh"; then
        log "❌ 部署失败"
        exit 1
    fi
    
    # 赋予执行权限
    chmod +x "tproxy_tc_loader.sh"
    
    # 执行部署脚本
    log "开始执行部署脚本..."
    if ./"tproxy_tc_loader.sh"; then
        log "✅ 部署成功！"
        log "清理临时文件..."
        rm -rf "$TEMP_DIR"
        log "=== 部署完成 ==="
        exit 0
    else
        log "❌ 部署脚本执行失败"
        log "临时文件保留在: $TEMP_DIR"
        exit 1
    fi
}

# 执行主函数
main