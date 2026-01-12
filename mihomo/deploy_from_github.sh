#!/bin/bash
# 从 GitHub 下载并部署 eBPF TC TProxy 规则
# 支持多个加速域名，带ping测试和手动选择功能

# GitHub 完整文件 URL
GITHUB_BPF_URL="https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/mihomo/tproxy_tc.bpf.c"
GITHUB_LOADER_URL="https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/mihomo/tproxy_tc_loader.sh"

# 加速域名前缀列表
ACCELERATION_PREFIXES=(
    "https://raw.githubusercontent.com"  # 原始地址
    "https://ghfast.top"                # 加速地址1
    "https://gh-proxy.org"              # 加速地址2
    "https://hk.gh-proxy.org"           # 加速地址3
    "https://cdn.gh-proxy.org"          # 加速地址4
    "https://edgeone.gh-proxy.org"      # 加速地址5
)

# 日志函数
log() {
    local msg="[$(date +"%Y-%m-%d %H:%M:%S")] $1"
    echo "$msg"
}

# Ping 测试函数 - 修复延迟显示问题
test_domain_delay() {
    local prefix=$1
    local domain=$(echo "$prefix" | sed -E 's|^https?://||' | cut -d'/' -f1)
    
    # 使用ping测试延迟，只测试3次，超时1秒
    if command -v ping &> /dev/null; then
        # 捕获ping输出，处理不同系统的ping输出格式
        local ping_output=$(ping -c 3 -W 1 "$domain" 2>&1)
        
        if echo "$ping_output" | grep -q "0% packet loss" || echo "$ping_output" | grep -q "received" && ! echo "$ping_output" | grep -q "0 received"; then
            # 尝试多种格式提取延迟
            local delay=$(echo "$ping_output" | grep -oE 'avg[=/ ]*[0-9.]+' | grep -oE '[0-9.]+' | head -1)
            
            if [ -z "$delay" ]; then
                # 尝试另一种格式
                delay=$(echo "$ping_output" | grep -oE '平均[=: ]*[0-9.]+' | grep -oE '[0-9.]+' | head -1)
            fi
            
            if [ -z "$delay" ]; then
                # 尝试提取最小延迟作为备选
                delay=$(echo "$ping_output" | grep -oE '[0-9.]+ ?ms' | grep -oE '[0-9.]+' | head -1)
            fi
            
            if [ -z "$delay" ]; then
                echo "unknown"
            else
                echo "$delay"
            fi
        else
            echo "timeout"
        fi
    else
        echo "noping"
    fi
}

# 测试所有域名延迟
test_all_domains() {
    log "开始测试所有加速域名延迟..."
    echo -e "\n序号 | 加速域名 | 延迟"
    echo "----------------------------------------"
    
    local i=1
    for prefix in "${ACCELERATION_PREFIXES[@]}"; do
        local delay=$(test_domain_delay "$prefix")
        printf "%3d | %-30s | %s ms\n" $i "$prefix" "$delay"
        ((i++))
    done
    
    echo -e "\n"
    return 0
}

# 让用户选择域名
select_domain() {
    local total=${#ACCELERATION_PREFIXES[@]}
    
    while true; do
        read -p "请选择要使用的加速域名序号 (1-$total, 0=退出): " choice
        
        if [[ "$choice" == "0" ]]; then
            log "用户选择退出"
            exit 0
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
            local selected_prefix="${ACCELERATION_PREFIXES[$choice-1]}"
            log "已选择加速域名: $selected_prefix"
            echo "$selected_prefix"
            return 0
        else
            echo "无效选择，请输入 1-$total 之间的数字"
        fi
    done
}

# 构建代理 URL
build_proxy_url() {
    local prefix=$1
    local original_url=$2
    
    if [[ "$prefix" == "https://raw.githubusercontent.com" ]]; then
        # 原始地址，直接返回
        echo "$original_url"
    else
        # 加速地址，构建格式：prefix + / + original_domain + rest_of_url
        local proxy_url="$prefix/$original_url"
        echo "$proxy_url"
    fi
}

# 下载函数
download_file() {
    local prefix=$1
    local original_url=$2
    local output=$3
    
    # 构建代理 URL
    local proxy_url=$(build_proxy_url "$prefix" "$original_url")
    
    log "开始下载文件..."
    log "原始 URL: $original_url"
    log "代理 URL: $proxy_url"
    log "保存到: $output"
    
    # 尝试下载，最多重试3次
    for ((i=1; i<=3; i++)); do
        log "第 $i 次尝试下载"
        if curl -s -L -o "$output" "$proxy_url" && [ -s "$output" ]; then
            log "✅ 成功下载文件"
            return 0
        fi
        sleep 1
    done
    
    log "❌ 下载文件失败"
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
    
    # 测试所有域名延迟
    test_all_domains
    
    # 让用户选择域名
    selected_prefix=$(select_domain)
    
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
    
    # 下载 eBPF 程序文件
    if ! download_file "$selected_prefix" "$GITHUB_BPF_URL" "tproxy_tc.bpf.c"; then
        log "❌ 部署失败"
        exit 1
    fi
    
    # 下载加载脚本
    if ! download_file "$selected_prefix" "$GITHUB_LOADER_URL" "tproxy_tc_loader.sh"; then
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