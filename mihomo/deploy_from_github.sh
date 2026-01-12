#!/bin/bash
# 从 GitHub 下载并部署 eBPF TC TProxy 规则
# 支持多个加速域名，带ping测试和手动选择功能

# GitHub 原始地址
GITHUB_REPO="Scu9277/eBPF"
GITHUB_BRANCH="main"
BPF_FILE="tproxy_tc.bpf.c"
LOADER_FILE="tproxy_tc_loader.sh"

# 加速域名前缀列表（只保留前缀，不带/raw）
ACCELERATION_PREFIXES=(
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

# Ping 测试函数
ping_test() {
    local domain=$1
    local host=$(echo "$domain" | sed -E 's|^https?://||' | cut -d'/' -f1)
    
    # 使用ping测试延迟，只测试1次，超时1秒
    if ping -c 1 -W 1 "$host" &> /dev/null; then
        # 获取平均延迟
        local delay=$(ping -c 4 -W 1 "$host" 2>/dev/null | grep -oP 'avg = \K[0-9.]+')
        echo "$delay"
    else
        echo "timeout"
    fi
}

# 测试所有域名延迟
test_all_domains() {
    log "开始测试所有加速域名延迟..."
    echo -e "\n序号 | 加速域名 | 延迟"
    echo "----------------------------------------"
    
    local domain_info=()
    local i=1
    
    for prefix in "${ACCELERATION_PREFIXES[@]}"; do
        local delay=$(ping_test "$prefix")
        domain_info+=([$i]="$prefix $delay")
        printf "%3d | %-30s | %s\n" $i "$prefix" "$delay ms"
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

# 下载函数
download_file() {
    local prefix=$1
    local file=$2
    local output=$3
    
    # 构建完整URL
    local url="$prefix/$GITHUB_REPO/$GITHUB_BRANCH/mihomo/$file"
    
    log "开始下载 $file..."
    log "使用域名: $prefix"
    log "完整URL: $url"
    
    # 尝试下载，最多重试3次
    for ((i=1; i<=3; i++)); do
        log "第 $i 次尝试下载"
        if curl -s -L -o "$output" "$url" && [ -s "$output" ]; then
            log "✅ 成功下载 $file"
            return 0
        fi
        sleep 1
    done
    
    log "❌ 下载 $file 失败"
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
    
    # 检查ping是否安装
    if ! command -v ping &> /dev/null; then
        log "❌ 错误: ping 未安装，请先安装 ping"
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
    
    # 下载文件
    if ! download_file "$selected_prefix" "$BPF_FILE" "$BPF_FILE"; then
        log "❌ 部署失败"
        exit 1
    fi
    
    if ! download_file "$selected_prefix" "$LOADER_FILE" "$LOADER_FILE"; then
        log "❌ 部署失败"
        exit 1
    fi
    
    # 赋予执行权限
    chmod +x "$LOADER_FILE"
    
    # 执行部署脚本
    log "开始执行部署脚本..."
    if ./"$LOADER_FILE"; then
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