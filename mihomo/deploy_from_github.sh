#!/bin/bash
# 从 GitHub 下载并部署 eBPF TC TProxy 规则
# 使用固定的加速域名

# GitHub 原始路径
GITHUB_REPO="Scu9277/eBPF"
GITHUB_BRANCH="refs/heads/main"
GITHUB_PATH="mihomo"
BPF_FILE="tproxy_tc.bpf.c"
LOADER_FILE="tproxy_tc_loader.sh"

# 固定加速域名
PROXY_DOMAIN="https://ghfast.top"

# 日志函数
log() {
    local msg="[$(date +"%Y-%m-%d %H:%M:%S")] $1"
    echo "$msg"
}

# 构建下载 URL（使用固定加速域名）
build_download_url() {
    local filename=$1
    # ghfast.top 格式：https://ghfast.top/raw.githubusercontent.com/...
    echo "${PROXY_DOMAIN}/raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/${GITHUB_PATH}/${filename}"
}

# 下载函数
download_file() {
    local filename=$1
    local output=$2
    
    local url=$(build_download_url "$filename")
    
    log "开始下载 ${filename}..."
    log "使用加速域名: $PROXY_DOMAIN"
    log "完整URL: $url"
    
    # 尝试下载，最多重试3次
    for ((i=1; i<=3; i++)); do
        log "第 $i 次尝试下载"
        local http_code=$(curl -s -L -w "%{http_code}" -o "$output" "$url" 2>/dev/null || echo "000")
        local actual_code="${http_code: -3}"
        
        if [ "$actual_code" = "200" ] && [ -s "$output" ]; then
            log "✅ 成功下载 ${filename} (HTTP $actual_code)"
            return 0
        else
            log "下载失败 (HTTP ${actual_code:-未知})"
            [ -f "$output" ] && rm -f "$output"
        fi
        sleep 1
    done
    
    log "❌ 下载 ${filename} 失败，请检查网络连接或 URL 是否正确"
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
    if ! download_file "$BPF_FILE" "tproxy_tc.bpf.c"; then
        log "❌ 部署失败"
        exit 1
    fi
    
    if ! download_file "$LOADER_FILE" "tproxy_tc_loader.sh"; then
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