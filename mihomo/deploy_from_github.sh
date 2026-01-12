#!/bin/bash
# 从 GitHub 下载并部署 eBPF TC TProxy 规则
# 支持多个加速域名并自动选择最快的

# GitHub 原始路径
GITHUB_REPO="Scu9277/eBPF"
GITHUB_BRANCH="refs/heads/main"
GITHUB_PATH="mihomo"
BPF_FILE="tproxy_tc.bpf.c"
LOADER_FILE="tproxy_tc_loader.sh"

# 加速域名列表
PROXY_DOMAINS=(
    "https://raw.githubusercontent.com"
    "https://ghfast.top"
    "https://gh-proxy.org"
    "https://hk.gh-proxy.org"
    "https://cdn.gh-proxy.org"
    "https://edgeone.gh-proxy.org"
)

# 日志函数
log() {
    local msg="[$(date +"%Y-%m-%d %H:%M:%S")] $1"
    echo "$msg"
}

# 测试域名延迟
test_domain_latency() {
    local domain=$1
    local test_url="${domain}/${GITHUB_REPO}/${GITHUB_BRANCH}/${GITHUB_PATH}/${BPF_FILE}"
    
    # 使用 timeout 和 curl 测试延迟（最多等待3秒）
    local start_time=$(date +%s%N)
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 --connect-timeout 3 "$test_url" 2>/dev/null)
    local end_time=$(date +%s%N)
    
    if [ "$http_code" = "200" ]; then
        local latency_ms=$(( (end_time - start_time) / 1000000 ))
        echo "$latency_ms"
        return 0
    else
        echo "timeout"
        return 1
    fi
}

# 测试所有加速域名并选择最快的
select_fastest_domain() {
    log "开始测试所有加速域名延迟..."
    
    local best_domain=""
    local best_latency=999999
    local results=()
    
    echo ""
    echo "序号 | 加速域名 | 延迟"
    echo "----------------------------------------"
    
    for i in "${!PROXY_DOMAINS[@]}"; do
        local domain="${PROXY_DOMAINS[$i]}"
        local num=$((i + 1))
        local display_domain="${domain#https://}"
        
        # 显示测试中
        printf "  %d | %-30s | 测试中...\r" "$num" "$display_domain"
        
        local latency=$(test_domain_latency "$domain")
        
        if [ "$latency" = "timeout" ]; then
            printf "  %d | %-30s | timeout ms\n" "$num" "$display_domain"
            results+=("$num|$domain|timeout")
        else
            printf "  %d | %-30s | %d ms\n" "$num" "$display_domain" "$latency"
            results+=("$num|$domain|$latency")
            
            # 更新最快域名
            if [ "$latency" -lt "$best_latency" ]; then
                best_latency=$latency
                best_domain="$domain"
            fi
        fi
    done
    
    echo ""
    
    # 如果没有找到可用的域名，使用第一个作为默认
    if [ -z "$best_domain" ]; then
        log "警告: 所有域名测试超时，使用默认域名: ${PROXY_DOMAINS[0]}"
        best_domain="${PROXY_DOMAINS[0]}"
    else
        log "已选择加速域名: $best_domain (延迟: ${best_latency}ms)"
    fi
    
    echo "$best_domain"
}

# 交互式选择域名
interactive_select_domain() {
    echo ""
    echo "序号 | 加速域名 | 延迟"
    echo "----------------------------------------"
    
    local results=()
    for i in "${!PROXY_DOMAINS[@]}"; do
        local domain="${PROXY_DOMAINS[$i]}"
        local num=$((i + 1))
        local display_domain="${domain#https://}"
        
        printf "  %d | %-30s | 测试中...\r" "$num" "$display_domain"
        local latency=$(test_domain_latency "$domain")
        
        if [ "$latency" = "timeout" ]; then
            printf "  %d | %-30s | timeout ms\n" "$num" "$display_domain"
            results+=("$num|$domain|timeout")
        else
            printf "  %d | %-30s | %d ms\n" "$num" "$display_domain" "$latency"
            results+=("$num|$domain|$latency")
        fi
    done
    
    echo ""
    read -p "请选择要使用的加速域名序号 (1-${#PROXY_DOMAINS[@]}, 0=自动选择最快): " choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        # 自动选择最快的
        local best_domain=""
        local best_latency=999999
        
        for result in "${results[@]}"; do
            local num=$(echo "$result" | cut -d'|' -f1)
            local domain=$(echo "$result" | cut -d'|' -f2)
            local latency=$(echo "$result" | cut -d'|' -f3)
            
            if [ "$latency" != "timeout" ] && [ "$latency" -lt "$best_latency" ]; then
                best_latency=$latency
                best_domain="$domain"
            fi
        done
        
        if [ -z "$best_domain" ]; then
            best_domain="${PROXY_DOMAINS[0]}"
            log "所有域名测试超时，使用默认域名: $best_domain"
        else
            log "已选择加速域名: $best_domain (延迟: ${best_latency}ms)"
        fi
        
        echo "$best_domain"
    elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#PROXY_DOMAINS[@]}" ]; then
        local selected_domain="${PROXY_DOMAINS[$((choice - 1))]}"
        log "已选择加速域名: $selected_domain"
        echo "$selected_domain"
    else
        log "无效选择，使用默认域名: ${PROXY_DOMAINS[0]}"
        echo "${PROXY_DOMAINS[0]}"
    fi
}

# 下载函数
download_file() {
    local base_url=$1
    local filename=$2
    local output=$3
    
    local url="${base_url}/${GITHUB_REPO}/${GITHUB_BRANCH}/${GITHUB_PATH}/${filename}"
    
    log "开始下载 ${filename}..."
    log "使用域名: $base_url"
    log "完整URL: $url"
    
    # 尝试下载，最多重试3次
    for ((i=1; i<=3; i++)); do
        log "第 $i 次尝试下载"
        if curl -s -L -f -o "$output" "$url" && [ -s "$output" ]; then
            log "✅ 成功下载 ${filename}"
            return 0
        fi
        sleep 1
    done
    
    log "❌ 下载 ${filename} 失败"
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
    
    # 选择加速域名（自动选择最快的）
    SELECTED_DOMAIN=$(select_fastest_domain)
    
    # 创建临时目录
    TEMP_DIR="/tmp/ebpftproxy-$(date +%s)"
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || exit 1
    
    log "工作目录: $TEMP_DIR"
    
    # 下载文件
    if ! download_file "$SELECTED_DOMAIN" "$BPF_FILE" "tproxy_tc.bpf.c"; then
        log "❌ 部署失败"
        exit 1
    fi
    
    if ! download_file "$SELECTED_DOMAIN" "$LOADER_FILE" "tproxy_tc_loader.sh"; then
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