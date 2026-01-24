#!/bin/bash

# 检查是否为 bash
if [ -z "$BASH_VERSION" ]; then
    echo "此脚本需要 bash 环境。正在尝试安装 bash..."
    if [ -f /etc/alpine-release ]; then
        apk add --no-cache bash
        exec bash "$0" "$@"
    else
        echo "请安装 bash 后再运行此脚本。"
        exit 1
    fi
fi

#=================================================================================
#   Mihomo / Sing-box 模块化安装脚本 (V14 - Alpine 支持版)
#
#   作者: shangkouyou Duang Scu
#   微信: shangkouyou
#   邮箱: shangkouyou@gmail.com
#   版本: v1.4 (Alpine Support & GitHub Proxy)
#
#   V14 版更新:
#   1. 完整支持 Alpine Linux 系统
#   2. 添加 GitHub 代理选择功能（适用于中国大陆用户）
#   3. 优化 IP 获取逻辑，支持多种系统
#   4. 修复配置文件部署时的目录冲突问题
#=================================================================================

# --- 颜色定义 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
WHITE="\033[1;37m"
NC="\033[0m"

# --- 作者信息 ---
AUTHOR_NAME="shangkouyou Duang Scu"
AUTHOR_WECHAT="shangkouyou"
AUTHOR_EMAIL="shangkouyou@gmail.com"
AFF_URL="https://aff.scu.indevs.in/"

# --- GitHub 代理列表 ---
GITHUB_PROXIES=(
    "直接连接 (国外/专线)"
    "https://ghfast.top/"
    "https://gh-proxy.org/"
    "https://hk.gh-proxy.org/"
    "https://cdn.gh-proxy.org/"
    "https://edgeone.gh-proxy.org/"
)

# GitHub 代理选择（全局变量）
GITHUB_PROXY=""

# --- 脚本配置 (Mihomo 专用) ---
PLACEHOLDER_IP="10.0.0.121"

# --- 脚本设置 ---
set -e
LAN_IP=""
MIHOMO_ARCH=""
SINGBOX_ARCH=""

# --- 系统检测与封装 ---
OS_DIST="unknown"
if [ -f /etc/alpine-release ]; then
    OS_DIST="alpine"
elif [ -f /etc/debian_version ]; then
    OS_DIST="debian"
elif [ -f /etc/redhat-release ]; then
    OS_DIST="redhat"
fi

# 封装包管理器
install_pkg() {
    case $OS_DIST in
        alpine) apk add --no-cache "$@" ;;
        debian) apt-get update -y && apt-get install -y "$@" ;;
        redhat) yum install -y "$@" ;;
        *) echo -e "${RED}不支持的系统: $OS_DIST${NC}"; exit 1 ;;
    esac
}

# 封装服务管理
manage_svc() {
    local action=$1
    local service=$2
    case $OS_DIST in
        alpine)
            case $action in
                enable) rc-update add $service default ;;
                disable) rc-update del $service ;;
                start) rc-service $service start ;;
                stop) rc-service $service stop ;;
                restart) rc-service $service restart ;;
                status) rc-service $service status ;;
                is-active) rc-service $service status >/dev/null 2>&1 ;;
                is-enabled) rc-update show default | grep -q $service ;;
            esac
            ;;
        *)
            case $action in
                enable) systemctl enable $service ;;
                disable) systemctl disable $service ;;
                start) systemctl start $service ;;
                stop) systemctl stop $service ;;
                restart) systemctl restart $service ;;
                status) systemctl status $service --no-pager ;;
                is-active) systemctl is-active --quiet $service ;;
                is-enabled) systemctl is-enabled --quiet $service ;;
            esac
            ;;
    esac
}

# 封装日志查看
view_logs() {
    local service=$1
    case $OS_DIST in
        alpine)
            if [ -f "/var/log/$service.log" ]; then
                tail -n 20 "/var/log/$service.log"
            else
                tail -n 20 /var/log/messages
            fi
            ;;
        *)
            journalctl -u $service -n 20 --no-pager
            ;;
    esac
}

# 封装主机名设置
set_hostname() {
    local new_name=$1
    case $OS_DIST in
        alpine)
            echo "$new_name" > /etc/hostname
            hostname -F /etc/hostname
            ;;
        *)
            hostnamectl set-hostname "$new_name"
            ;;
    esac
}

# 封装 IP 获取
get_lan_ip() {
    local ip=""
    # 尝试使用 hostname -I (Debian/Ubuntu/CentOS)
    if command -v hostname >/dev/null; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    # 如果失败，尝试使用 ip addr (Alpine 常用)
    if [ -z "$ip" ] && command -v ip >/dev/null; then
        ip=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
        [ -z "$ip" ] && ip=$(ip -o -4 addr list | grep -Ev 'lo|tun|docker' | awk '{print $4}' | cut -d/ -f1 | head -n1)
    fi

    # 如果还是失败，尝试使用 ifconfig (较老系统)
    if [ -z "$ip" ] && command -v ifconfig >/dev/null; then
        ip=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1)
    fi
    
    echo "$ip"
}

# GitHub 代理选择函数
select_github_proxy() {
    clear
    echo -e "${CYAN}"
    echo " ▗▄▄▖▗▖ ▗▖ ▗▄▖ ▗▖  ▗▖ ▗▄▄▖▗▖ ▗▖ ▗▄▖ ▗▖ ▗▖▗▖  ▗▖▗▄▖ ▗▖ ▗▖"
    echo "▐▌   ▐▌ ▐▌▐▌ ▐▌▐▛▚▖▐▌▐▌   ▐▌▗▞▘▐▌ ▐▌▐▌ ▐▌ ▝▚▞▘▐▌ ▐▌▐▌ ▐▌"
    echo " ▝▀▚▖▐▛▀▜▌▐▛▀▜▌▐▌ ▝▜▌▐▌▝▜▌▐▛▚▖ ▐▌ ▐▌▐▌ ▐▌  ▐▌ ▐▌ ▐▌▐▌ ▐▌"
    echo "▗▄▄▞▘▐▌ ▐▌▐▌ ▐▌▐▌  ▐▌▝▚▄▞▘▐▌ ▐▌▝▚▄▞▘▝▚▄▞▘  ▐▌ ▝▚▄▞▘▝▚▄▞▘"
    echo -e "${NC}"
    echo "=================================================="
    echo -e "     项目: ${BLUE}Mihomo / Sing-box 模块化安装脚本${NC}"
    echo -e "     作者: ${GREEN}${AUTHOR_NAME}${NC}"
    echo -e "     微信: ${GREEN}${AUTHOR_WECHAT}${NC} | 邮箱: ${GREEN}${AUTHOR_EMAIL}${NC}"
    echo -e "     服务器 AFF 推荐 (Scu 导航站): ${YELLOW}${AFF_URL}${NC}"
    echo "=================================================="
    echo ""
    echo -e "${YELLOW}请选择 GitHub 访问方式（适用于中国大陆用户）:${NC}"
    echo ""
    for i in "${!GITHUB_PROXIES[@]}"; do
        echo -e "  $((i+1))) ${GITHUB_PROXIES[$i]}"
    done
    echo ""
    read -p "请输入选项 [1-${#GITHUB_PROXIES[@]}]: " proxy_choice
    
    if [ -z "$proxy_choice" ] || [ "$proxy_choice" -lt 1 ] || [ "$proxy_choice" -gt ${#GITHUB_PROXIES[@]} ]; then
        echo -e "${YELLOW}使用默认选项: 直接连接${NC}"
        GITHUB_PROXY=""
    else
        selected_proxy="${GITHUB_PROXIES[$((proxy_choice-1))]}"
        if [ "$selected_proxy" == "直接连接 (国外/专线)" ]; then
            GITHUB_PROXY=""
            echo -e "${GREEN}✅ 已选择: 直接连接${NC}"
        else
            GITHUB_PROXY="$selected_proxy"
            echo -e "${GREEN}✅ 已选择: $selected_proxy${NC}"
        fi
    fi
    echo ""
}

# GitHub URL 处理函数（将 GitHub URL 转换为使用代理的 URL）
process_github_url() {
    local url="$1"
    
    # 如果没有选择代理，直接返回原 URL
    if [ -z "$GITHUB_PROXY" ]; then
        echo "$url"
        return
    fi
    
    # 如果 URL 已经包含代理前缀，直接返回
    if [[ "$url" == *"$GITHUB_PROXY"* ]]; then
        echo "$url"
        return
    fi
    
    # 处理不同类型的 GitHub URL
    if [[ "$url" == https://raw.githubusercontent.com/* ]]; then
        # raw.githubusercontent.com 格式: https://raw.githubusercontent.com/... -> https://ghfast.top/raw.githubusercontent.com/...
        url="${url#https://}"
        url="${GITHUB_PROXY}${url}"
    elif [[ "$url" == https://api.github.com/* ]]; then
        # api.github.com 格式
        url="${url#https://}"
        url="${GITHUB_PROXY}${url}"
    elif [[ "$url" == https://github.com/* ]]; then
        # github.com 格式（包括 releases 下载）
        url="${url#https://}"
        url="${GITHUB_PROXY}${url}"
    fi
    
    echo "$url"
}

# 安全的 GitHub API 请求函数（带自动回退）
# 参数: API URL
# 返回: JSON 响应内容
safe_github_api_request() {
    local api_url="$1"
    local max_retries=3
    local retry_count=0
    local response=""
    local temp_file="/tmp/github_api_response_$$.json"
    
    # 首先尝试使用代理（如果已选择）
    if [ -n "$GITHUB_PROXY" ]; then
        local proxy_url=$(process_github_url "$api_url")
        echo -e "${YELLOW}尝试使用代理获取版本信息: ${proxy_url}${NC}" >&2
        
        for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
            response=$(curl -sL --connect-timeout 10 --max-time 30 "$proxy_url" 2>/dev/null)
            
            # 检查是否是有效的 JSON（简单检查：以 { 或 [ 开头）
            if [[ "$response" =~ ^[[:space:]]*[\{\[] ]] && echo "$response" | jq . >/dev/null 2>&1; then
                echo "$response"
                rm -f "$temp_file" 2>/dev/null
                return 0
            fi
            
            if [ $retry_count -lt $max_retries ]; then
                echo -e "${YELLOW}代理请求失败，重试 $retry_count/$max_retries...${NC}" >&2
                sleep 1
            fi
        done
        
        echo -e "${YELLOW}⚠️  代理请求失败，尝试直接连接...${NC}" >&2
    fi
    
    # 如果代理失败或未使用代理，尝试直接连接
    echo -e "${YELLOW}尝试直接连接 GitHub API...${NC}" >&2
    for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
        response=$(curl -sL --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null)
        
        # 检查是否是有效的 JSON
        if [[ "$response" =~ ^[[:space:]]*[\{\[] ]] && echo "$response" | jq . >/dev/null 2>&1; then
            echo "$response"
            rm -f "$temp_file" 2>/dev/null
            return 0
        fi
        
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW}直接连接失败，重试 $retry_count/$max_retries...${NC}" >&2
            sleep 2
        fi
    done
    
    # 所有尝试都失败
    echo -e "${RED}❌ 无法获取 GitHub API 响应（所有尝试均失败）${NC}" >&2
    echo -e "${YELLOW}最后返回的内容（可能不是有效的 JSON）:${NC}" >&2
    echo "$response" | head -5 >&2
    rm -f "$temp_file" 2>/dev/null
    return 1
}

# 安全的 GitHub 脚本执行函数（带自动回退）
# 参数: 脚本 URL
safe_github_script_exec() {
    local script_url="$1"
    local max_retries=3
    local retry_count=0
    local script_content=""
    local temp_script="/tmp/github_script_$$.sh"
    
    # 首先尝试使用代理（如果已选择）
    if [ -n "$GITHUB_PROXY" ]; then
        local proxy_url=$(process_github_url "$script_url")
        
        for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
            if command -v curl >/dev/null 2>&1; then
                script_content=$(curl -sSL --connect-timeout 10 --max-time 30 "$proxy_url" 2>/dev/null)
            elif command -v wget >/dev/null 2>&1; then
                script_content=$(wget -qO- --timeout=30 "$proxy_url" 2>/dev/null)
            fi
            
            # 检查是否是有效的脚本（至少包含 #!/bin/bash 或类似内容）
            if [ -n "$script_content" ] && [[ "$script_content" =~ (#!/bin/bash|#!/bin/sh|#!/usr/bin/env) ]]; then
                echo "$script_content" > "$temp_script"
                chmod +x "$temp_script"
                bash "$temp_script"
                local result=$?
                rm -f "$temp_script"
                return $result
            fi
            
            if [ $retry_count -lt $max_retries ]; then
                sleep 1
            fi
        done
    fi
    
    # 如果代理失败或未使用代理，尝试直接连接
    for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
        if command -v curl >/dev/null 2>&1; then
            script_content=$(curl -sSL --connect-timeout 10 --max-time 30 "$script_url" 2>/dev/null)
        elif command -v wget >/dev/null 2>&1; then
            script_content=$(wget -qO- --timeout=30 "$script_url" 2>/dev/null)
        fi
        
        # 检查是否是有效的脚本
        if [ -n "$script_content" ] && [[ "$script_content" =~ (#!/bin/bash|#!/bin/sh|#!/usr/bin/env) ]]; then
            echo "$script_content" > "$temp_script"
            chmod +x "$temp_script"
            bash "$temp_script"
            local result=$?
            rm -f "$temp_script"
            return $result
        fi
        
        if [ $retry_count -lt $max_retries ]; then
            sleep 2
        fi
    done
    
    # 所有尝试都失败
    rm -f "$temp_script"
    echo -e "${RED}❌ 无法下载或执行脚本（所有尝试均失败）${NC}" >&2
    return 1
}

# 安全的 GitHub 文件下载函数（带自动回退，支持 wget 和 curl）
# 参数: 下载 URL, 输出文件路径
safe_github_download() {
    local download_url="$1"
    local output_path="$2"
    local max_retries=3
    local retry_count=0
    local download_cmd=""
    # 根据文件扩展名确定最小文件大小
    local min_size=100  # 默认最小大小（字节）
    if [[ "$output_path" =~ \.(gz|tar|tar\.gz|deb|rpm|zip)$ ]]; then
        min_size=10240  # 压缩包至少 10KB
    elif [[ "$output_path" =~ \.(sh|json|yaml|yml)$ ]]; then
        min_size=100  # 脚本和配置文件至少 100 字节
    else
        min_size=1024  # 二进制文件至少 1KB
    fi
    
    # 检测可用的下载工具
    if command -v wget >/dev/null 2>&1; then
        download_cmd="wget"
    elif command -v curl >/dev/null 2>&1; then
        download_cmd="curl"
    else
        echo -e "${RED}❌ 错误：未找到 wget 或 curl 命令！${NC}" >&2
        return 1
    fi
    
    # 首先尝试使用代理（如果已选择）
    if [ -n "$GITHUB_PROXY" ]; then
        local proxy_url=$(process_github_url "$download_url")
        echo -e "${YELLOW}尝试使用代理下载...${NC}" >&2
        
        for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
            if [ "$download_cmd" == "wget" ]; then
                if wget -O "$output_path" --timeout=30 --tries=1 "$proxy_url" 2>/dev/null; then
                    # 检查文件大小
                    if [ -f "$output_path" ] && [ $(stat -c%s "$output_path" 2>/dev/null || echo 0) -gt $min_size ]; then
                        echo -e "${GREEN}✅ 代理下载成功${NC}" >&2
                        return 0
                    fi
                fi
            else
                if curl -L -o "$output_path" --connect-timeout 30 --max-time 60 "$proxy_url" 2>/dev/null; then
                    # 检查文件大小
                    if [ -f "$output_path" ] && [ $(stat -c%s "$output_path" 2>/dev/null || echo 0) -gt $min_size ]; then
                        echo -e "${GREEN}✅ 代理下载成功${NC}" >&2
                        return 0
                    fi
                fi
            fi
            
            if [ $retry_count -lt $max_retries ]; then
                echo -e "${YELLOW}代理下载失败，重试 $retry_count/$max_retries...${NC}" >&2
                sleep 1
            fi
        done
        
        echo -e "${YELLOW}⚠️  代理下载失败，尝试直接连接...${NC}" >&2
    fi
    
    # 如果代理失败或未使用代理，尝试直接连接
    echo -e "${YELLOW}尝试直接下载...${NC}" >&2
    for ((retry_count=1; retry_count<=max_retries; retry_count++)); do
        if [ "$download_cmd" == "wget" ]; then
            if wget -O "$output_path" --timeout=30 --tries=1 "$download_url" 2>/dev/null; then
                # 检查文件大小
                if [ -f "$output_path" ] && [ $(stat -c%s "$output_path" 2>/dev/null || echo 0) -gt $min_size ]; then
                    echo -e "${GREEN}✅ 直接下载成功${NC}" >&2
                    return 0
                fi
            fi
        else
            if curl -L -o "$output_path" --connect-timeout 30 --max-time 60 "$download_url" 2>/dev/null; then
                # 检查文件大小
                if [ -f "$output_path" ] && [ $(stat -c%s "$output_path" 2>/dev/null || echo 0) -gt $min_size ]; then
                    echo -e "${GREEN}✅ 直接下载成功${NC}" >&2
                    return 0
                fi
            fi
        fi
        
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW}直接下载失败，重试 $retry_count/$max_retries...${NC}" >&2
            sleep 2
        fi
    done
    
    # 所有尝试都失败
    echo -e "${RED}❌ 下载失败（所有尝试均失败）${NC}" >&2
    return 1
}

#=================================================================================
#   SECTION 1: 核心安装程序 (Core Installers)
#=================================================================================
# (此区域函数与 V12 完全相同，未作修改)

# ----------------------------------------------------------------
#   核心 1: Mihomo 核心 (安装、配置、启动)
# ----------------------------------------------------------------
install_mihomo_core_and_config() {
    echo -e "${BLUE}--- 正在安装 [核心 1: Mihomo] ---${NC}"

    # 2. 检查架构
    echo -e "🕵️  正在检测 Mihomo 所需架构..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) MIHOMO_ARCH="amd64-v2" ;;
        aarch64) MIHOMO_ARCH="arm64-v8" ;;
        armv7l) MIHOMO_ARCH="armv7" ;;
        *) echo -e "${RED}❌ 不支持的架构: $ARCH！${NC}"; exit 1 ;;
    esac
    echo -e "${GREEN}✅ Mihomo 架构: $MIHOMO_ARCH${NC}"

    # 3. 安装 Mihomo (如果未安装)
    if command -v mihomo &> /dev/null; then
        echo -e "${GREEN}👍 Mihomo 已经安装，跳过下载。${NC}"
        mihomo -v
    else
        echo -e "📡 正在获取 Mihomo 最新版本号..."
        API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
        API_RESPONSE=$(safe_github_api_request "$API_URL")
        if [ $? -ne 0 ] || [ -z "$API_RESPONSE" ]; then
            echo -e "${RED}❌ 获取 Mihomo 最新版本号失败！${NC}"
            echo -e "${YELLOW}提示：请检查网络连接或尝试更换 GitHub 代理${NC}"
            exit 1
        fi
        
        LATEST_TAG=$(echo "$API_RESPONSE" | jq -r .tag_name 2>/dev/null)
        if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" == "null" ]; then
            echo -e "${RED}❌ 解析版本号失败！API 响应可能无效${NC}"
            echo -e "${YELLOW}API 响应内容:${NC}"
            echo "$API_RESPONSE" | head -10
            exit 1
        fi
        echo -e "${GREEN}🎉 找到最新版本: $LATEST_TAG${NC}"
        
        if [ "$OS_DIST" == "alpine" ]; then
            # Alpine 使用二进制
            GZ_FILENAME="mihomo-linux-${MIHOMO_ARCH}-${LATEST_TAG}.gz"
            DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/${GZ_FILENAME}"
            echo -e "🚀 正在下载二进制: $GZ_FILENAME"
            if ! safe_github_download "$DOWNLOAD_URL" "/usr/local/bin/mihomo.gz"; then
                echo -e "${RED}❌ Mihomo 二进制下载失败！${NC}"
                exit 1
            fi
            gunzip -f "/usr/local/bin/mihomo.gz"
            chmod +x /usr/local/bin/mihomo
        else
            DEB_FILENAME="mihomo-linux-${MIHOMO_ARCH}-${LATEST_TAG}.deb"
            DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/${DEB_FILENAME}"
            DEB_PATH="/root/${DEB_FILENAME}"
            echo -e "🚀 正在下载: $DEB_FILENAME"
            if ! safe_github_download "$DOWNLOAD_URL" "$DEB_PATH"; then
                echo -e "${RED}❌ Mihomo DEB 包下载失败！${NC}"
                exit 1
            fi
            dpkg -i "$DEB_PATH"
            rm -f "$DEB_PATH"
        fi
        mihomo -v
        echo -e "${GREEN}✅ Mihomo 安装成功！${NC}"
    fi

    # 4. 下载并配置 (带覆盖检查)
    if [ -f "/etc/mihomo/config.yaml" ]; then
        read -p "$(echo -e ${YELLOW}"⚠️  检测到已存在的 Mihomo 配置文件，是否覆盖? (y/N): "${NC})" choice
        case "$choice" in
          y|Y ) 
            echo "🔄 好的，将继续下载并覆盖配置..." 
            # 在覆盖模式下，先清理旧目录，避免 mv 时的 Directory not empty 错误
            rm -rf /etc/mihomo
            ;;
          * ) echo -e "${GREEN}👍 保留现有配置，跳过下载。${NC}"; return ;;
        esac
    fi
    echo -e "📂 正在配置您的 mihomo 配置文件..."
    CONFIG_ZIP_PATH="/root/mihomo_config.zip"
    TEMP_DIR="/root/mihomo_temp_unzip"
    CONFIG_ZIP_URL="https://github.com/Scu9277/eBPF/releases/download/mihomo/mihomo.zip"
    echo -e "📥 正在从 GitHub 下载配置文件..."
    if ! safe_github_download "$CONFIG_ZIP_URL" "$CONFIG_ZIP_PATH"; then
        echo -e "${RED}❌ 错误：配置文件下载失败！${NC}"
        exit 1
    fi
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    unzip -o "$CONFIG_ZIP_PATH" -d "$TEMP_DIR"
    
    # 统一创建目录，确保存在
    mkdir -p /etc/mihomo

    if [ -d "$TEMP_DIR/mihomo" ]; then
        # 如果解压后包含 mihomo 文件夹，则合并内容
        cp -rf "$TEMP_DIR/mihomo/"* /etc/mihomo/
        echo -e "${GREEN}✅ 配置文件已从 mihomo 文件夹部署到 /etc/mihomo${NC}"
    elif [ -f "$TEMP_DIR/config.yaml" ]; then
        # 如果是散文件，直接复制到目标目录
        cp -rf "$TEMP_DIR/"* /etc/mihomo/
        echo -e "${GREEN}✅ 配置文件已部署到 /etc/mihomo${NC}"
    else
        echo -e "${RED}❌ 错误：无法识别的 ZIP 压缩包结构！${NC}"; exit 1
    fi
    rm -f "$CONFIG_ZIP_PATH"
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}✅ 配置文件部署成功！${NC}"

    # 5. 配置 DNS 劫持 (替换 IP)
    echo -e "📡 正在获取本机局域网 IP (用于 DNS 劫持)..."
    LAN_IP=$(get_lan_ip)
    if [ -z "$LAN_IP" ]; then
        echo -e "${YELLOW}⚠️  未能自动获取局域网 IP，将跳过配置文件中的 IP 替换步骤。${NC}"
        echo -e "${YELLOW}💡 提示：如果需要，请手动修改 /etc/mihomo/config.yaml 中的占位符。${NC}"
    else
        echo -e "${GREEN}✅ 本机 IP: $LAN_IP${NC}"
        CONFIG_FILE="/etc/mihomo/config.yaml"
        if grep -q "$PLACEHOLDER_IP" "$CONFIG_FILE"; then
            echo -e "🔍 发现占位符 ${PLACEHOLDER_IP}，正在替换为 ${GREEN}${LAN_IP}${NC}..."
            sed -i "s/${PLACEHOLDER_IP}/${LAN_IP}/g" "$CONFIG_FILE"
            echo -e "${GREEN}✅ 占位符 IP 替换成功！${NC}"
        else
            echo -e "${GREEN}👍 未在 $CONFIG_FILE 中检测到占位符，假定已配置。${NC}"
        fi
    fi

    # 6. 启动 Mihomo 服务
    echo -e "🚀 正在启动并设置 mihomo 服务为开机自启..."
    if [ "$OS_DIST" == "alpine" ]; then
        # 创建 OpenRC 服务脚本
        cat > /etc/init.d/mihomo <<EOF
#!/sbin/openrc-run
description="Mihomo Service"
command="/usr/local/bin/mihomo"
command_args="-d /etc/mihomo"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/mihomo.log"
error_log="/var/log/mihomo.log"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/mihomo
    fi
    
    manage_svc enable mihomo
    manage_svc restart mihomo
    sleep 3
    if manage_svc is-active mihomo; then
        echo -e "${GREEN}✅ Mihomo 服务正在愉快地运行！${NC}"
    else
        echo -e "${RED}❌ Mihomo 服务启动失败！${NC}"; exit 1
    fi

    echo "----------------------------------------------------------------"
    echo -e "🎉 ${GREEN}Mihomo 核心安装并配置完毕！${NC}"
    # UI URL 显示调整
    DISPLAY_IP=${LAN_IP:-"[您的服务器IP]"}
    echo -e "Mihomo UI: ${YELLOW}http://${DISPLAY_IP}:9090/ui${NC} (或 http://scu.lan/ui 如果已配置DNS)"
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   核心 2: Sing-box 核心 (安装、配置、启动)
# ----------------------------------------------------------------
install_singbox_core_and_config() {
    echo -e "${BLUE}--- 正在安装 [核心 2: Sing-box] ---${NC}"

    # 1. 检测架构
    echo -e "${YELLOW}正在检测 Sing-box 所需架构...${NC}"
    ARCH_RAW=$(uname -m)
    if [ "$ARCH_RAW" == "x86_64" ] || [ "$ARCH_RAW" == "amd64" ]; then
        if command -v grep > /dev/null && [ -f /proc/cpuinfo ] && grep -q avx2 /proc/cpuinfo; then
            SINGBOX_ARCH="amd64v3"
        else
            SINGBOX_ARCH="amd64"
        fi
    elif [ "$ARCH_RAW" == "aarch64" ] || [ "$ARCH_RAW" == "arm64" ]; then
        SINGBOX_ARCH="arm64"
    else
        echo -e "${RED}错误：不支持的系统架构 $ARCH_RAW。${NC}"; exit 1
    fi
    echo -e "${GREEN}检测到架构: $SINGBOX_ARCH${NC}"

    # 2. 定义路径和 URL
    INSTALL_DIR="/usr/local/bin"
    CONFIG_DIR="/etc/sing-box"
    SINGBOX_CORE_PATH="$INSTALL_DIR/sing-box"
    
    # 从配置获取 URL
    BASE_URL=""
    case "$SINGBOX_ARCH" in
        amd64) 
            BASE_URL="https://github.com/Scu9277/eBPF/releases/download/sing-box/sing-box-1.13.0-beta.1-reF1nd-linux-amd64"
            ;;
        amd64v3) 
            BASE_URL="https://github.com/Scu9277/eBPF/releases/download/sing-box/sing-box-1.13.0-beta.1-reF1nd-linux-amd64v3"
            ;;
        arm64) 
            BASE_URL="https://github.com/Scu9277/eBPF/releases/download/sing-box/sing-box-1.13.0-beta.1-reF1nd-linux-arm64"
            ;;
    esac
    
    if [ -z "$BASE_URL" ]; then
        echo -e "${RED}错误：无法根据架构 $SINGBOX_ARCH 匹配到下载 URL。请检查顶部配置。${NC}"
        exit 1
    fi

    # 3. 停止服务 (如果正在运行)，以避免 "Text file busy"
    if manage_svc is-active sing-box; then
        echo -e "${YELLOW}正在停止正在运行的 Sing-box 服务以更新核心...${NC}"
        manage_svc stop sing-box
    fi
    
    # 4. 下载核心
    echo -e "${YELLOW}正在下载 Sing-box 核心 ($SINGBOX_ARCH)...${NC}"
    mkdir -p $INSTALL_DIR
    rm -f "$SINGBOX_CORE_PATH" # Prevent Text file busy
    if ! safe_github_download "$BASE_URL" "$SINGBOX_CORE_PATH"; then
        echo -e "${RED}❌ Sing-box 核心下载失败！${NC}"
        exit 1
    fi
    chmod +x $SINGBOX_CORE_PATH
    echo -e "${GREEN}Sing-box 核心安装成功!${NC}"
    $SINGBOX_CORE_PATH version

    # 5. 下载配置
    mkdir -p $CONFIG_DIR
    CONFIG_JSON_URL="https://raw.githubusercontent.com/Scu9277/TProxy/refs/heads/main/sing-box/config.json"
    echo -e "${YELLOW}正在下载 Sing-box 配置文件...${NC}"
    if ! safe_github_download "$CONFIG_JSON_URL" "$CONFIG_DIR/config.json"; then
        echo -e "${RED}❌ Sing-box 配置文件下载失败！${NC}"
        exit 1
    fi
    echo -e "${GREEN}config.json 下载成功！${NC}"
    
    # 6. 创建并启动服务
    if [ "$OS_DIST" == "alpine" ]; then
        echo "正在创建 OpenRC 服务..."
        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="Sing-Box Service"
command="$SINGBOX_CORE_PATH"
command_args="run -c $CONFIG_DIR/config.json"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/sing-box
    else
        echo "正在创建 systemd 服务..."
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-Box Service
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
LimitNPROC=512
LimitNOFILE=1048576
ExecStart=$SINGBOX_CORE_PATH run -c $CONFIG_DIR/config.json
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    manage_svc enable sing-box
    echo -e "${YELLOW}正在启动 Sing-box 服务...${NC}"
    manage_svc restart sing-box
    sleep 2
    if manage_svc is-active sing-box; then
        echo -e "${GREEN}✅ Sing-box 服务已成功启动！${NC}"
    else
        echo -e "${RED}❌ Sing-box 服务启动失败！${NC}"
        echo -e "${YELLOW}显示最后 20 行日志用于调试:${NC}"
        view_logs sing-box
        exit 1
    fi
    echo "----------------------------------------------------------------"
    echo -e "🎉 ${GREEN}Sing-box 核心安装并配置完毕！${NC}"
    echo "----------------------------------------------------------------"
}


#=================================================================================
#   SECTION 2: 独立安装组件 (Modular Components)
#=================================================================================
# (此区域函数与 V12 完全相同，未作修改)

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ 错误：此脚本必须以 root 权限运行！${NC}"
        exit 1
    fi
}

# 检查并安装依赖
check_dependencies() {
    echo -e "🔍 正在检查系统依赖 (wget, curl, jq, unzip, iproute2)..."
    DEPS=("wget" "curl" "jq" "unzip" "grep")
    # Alpine 需要 iproute2 提供 ip 命令，hostname 可能需要安装
    if [ "$OS_DIST" == "alpine" ]; then
        DEPS+=("iproute2" "bash" "ca-certificates")
    else
        DEPS+=("hostname")
    fi
    
    MISSING_DEPS=()
    for dep in "${DEPS[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            MISSING_DEPS+=("$dep")
        fi
    done

    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
        echo -e "${YELLOW}🔧 检测到缺失的依赖: ${MISSING_DEPS[*]} ... 正在尝试自动安装...${NC}"
        install_pkg "${MISSING_DEPS[@]}"
        echo -e "${GREEN}✅ 核心依赖已安装完毕！${NC}"
    else
        echo -e "${GREEN}👍 依赖检查通过，全部已安装。${NC}"
    fi
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   组件 1: 更换系统源
# ----------------------------------------------------------------
install_change_source() {
    echo -e "${BLUE}--- 正在执行 [组件 1: 更换系统源] ---${NC}"
    echo -e "🔧 正在执行换源脚本 (linuxmirrors.cn/main.sh)..."
    bash <(curl -sSL https://linuxmirrors.cn/main.sh)
    echo -e "${GREEN}✅ 换源脚本执行完毕。${NC}"
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   组件 2: DNS 劫持
# ----------------------------------------------------------------
install_dns_hijack() {
    echo -e "${BLUE}--- 正在安装 [组件 2: DNS 劫持] ---${NC}"
    echo -e "📝 正在配置 /etc/hosts (本机劫持)..."
    if grep -q "scu.lan" /etc/hosts; then
        echo -e "${GREEN}👍 /etc/hosts 似乎已配置，跳过。${NC}"
        echo "----------------------------------------------------------------"
        return
    fi
    cat << 'EOF' | tee -a /etc/hosts > /dev/null

# --- Scu x Duang DNS Hijack (Local) ---
127.0.0.1   21.cn 21.com scu.cn scu.com shangkouyou.cn shangkouyou.com
127.0.0.1   21.icu scu.icu shangkouyou.icu
127.0.0.1   21.wifi scu.wifi shangkouyou.wifi
127.0.0.1   21.lan scu.lan shangkouyou.lan
EOF
    echo -e "${GREEN}✅ /etc/hosts 配置完毕。${NC}"
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   组件 3: Docker
# ----------------------------------------------------------------
install_docker() {
    echo -e "${BLUE}--- 正在安装 [组件 3: Docker] ---${NC}"
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}👍 Docker 已经安装，跳过此步骤。${NC}"
        echo "----------------------------------------------------------------"
        return
    fi
    
    # Alpine 系统使用专用安装方式
    if [ "$OS_DIST" == "alpine" ]; then
        echo -e "${YELLOW}🐳 检测到 Alpine 系统，使用 Alpine 专用 Docker 安装方式...${NC}"
        
        # 1. 开启社区软件源 (包含 Docker, nftables 等)
        echo -e "📦 正在开启社区软件源..."
        if grep -q "^#.*community" /etc/apk/repositories; then
            sed -i 's|^#\(.*community\)|\1|g' /etc/apk/repositories
            echo -e "${GREEN}✅ 社区软件源已开启${NC}"
        else
            echo -e "${GREEN}👍 社区软件源已启用${NC}"
        fi
        
        # 2. 更新系统索引并安装基础工具
        echo -e "🔄 正在更新系统索引..."
        apk update
        echo -e "📥 正在安装 Docker 及相关工具 (wget, unzip, ca-certificates, iptables, gcompat, docker, docker-compose)..."
        apk add --no-cache wget unzip ca-certificates iptables gcompat docker docker-compose
        
        # 3. 设置 Docker 开机自启并立即启动
        echo -e "🚀 正在设置 Docker 开机自启..."
        rc-update add docker default
        echo -e "▶️  正在启动 Docker 服务..."
        rc-service docker start
        sleep 2
        
        # 4. 开启内核 IPv4 转发 (路由转发基础)
        echo -e "🌐 正在开启内核 IPv4 转发..."
        if ! grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
            echo -e "${GREEN}✅ IPv4 转发已添加到 sysctl.conf${NC}"
        else
            echo -e "${GREEN}👍 IPv4 转发配置已存在${NC}"
        fi
        sysctl -p >/dev/null 2>&1
        
        # 验证安装
        if ! command -v docker &> /dev/null; then
            echo -e "${RED}❌ Docker 安装失败！ 'docker' 命令不可用。${NC}"
            exit 1
        fi
        
        # 等待 Docker 服务完全启动
        sleep 3
        if rc-service docker status >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Docker 服务已成功启动！${NC}"
        else
            echo -e "${YELLOW}⚠️  Docker 服务可能未完全启动，请稍后手动检查。${NC}"
        fi
        
        echo -e "${GREEN}✅ Docker 安装成功！${NC}"
    else
        # 其他系统使用原版脚本
        echo -e "🐳 正在执行 Docker 安装脚本 (linuxmirrors.cn/docker.sh)..."
        bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
        if ! command -v docker &> /dev/null; then
            echo -e "${RED}❌ Docker 安装失败！ 'docker' 命令不可用。${NC}"
            exit 1
        fi
        echo -e "${GREEN}✅ Docker 安装成功。${NC}"
    fi
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   组件 4: Sub-Store
# ----------------------------------------------------------------
install_substore() {
    echo -e "${BLUE}--- 正在安装 [组件 4: Sub-Store] ---${NC}"
    CONTAINER_NAME="sub-store"
    IMAGE_NAME="xream/sub-store:latest"

    if ! command -v docker &> /dev/null; then
        echo -e "${RED}❌ 错误：未找到 Docker！${NC}"
        echo -e "${YELLOW}请先从主菜单选择安装 Docker。${NC}"
        return
    fi

    if [ $(docker ps -q -f name=^/${CONTAINER_NAME}$) ]; then
        echo -e "${GREEN}👍 Sub-Store 容器 'sub-store' 已经在运行，跳过。${NC}"
        echo "----------------------------------------------------------------"
        return
    fi

    if [ $(docker ps -a -q -f name=^/${CONTAINER_NAME}$) ]; then
        echo -e "${YELLOW}🔄 发现已停止的 'sub-store' 容器，正在尝试启动...${NC}"
        docker start $CONTAINER_NAME
        sleep 3
        if [ $(docker ps -q -f name=^/${CONTAINER_NAME}$) ]; then
             echo -e "${GREEN}✅ Sub-Store 容器启动成功！${NC}"
             echo "----------------------------------------------------------------"
             return
        else
             echo -e "${RED}❌ 启动失败，正在移除旧容器并重新创建...${NC}"
             docker rm $CONTAINER_NAME
        fi
    fi

    if ! docker images -q $IMAGE_NAME | grep -q . ; then
        echo -e "${YELLOW}🔎 未找到 '$IMAGE_NAME' 镜像，正在下载...${NC}"
        echo -e "📦 正在下载 Sub-Store Docker 镜像包..."
        SUBSTORE_URL="https://github.com/Scu9277/TProxy/releases/download/1.0/sub-store.tar.gz"
        if ! safe_github_download "$SUBSTORE_URL" "/root/sub-store.tar.gz"; then
            echo -e "${RED}❌ Sub-Store 镜像包下载失败！${NC}"
            exit 1
        fi
        echo -e "🗜️ 正在解压并加载镜像..."
        tar -xzf "/root/sub-store.tar.gz" -C "/root/"
        docker load -i "/root/sub-store.tar"
        rm -f "/root/sub-store.tar.gz" "/root/sub-store.tar"
    else
        echo -e "${GREEN}👍 发现 '$IMAGE_NAME' 镜像，跳过下载。${NC}"
    fi

    echo -e "🚀 正在启动 Sub-Store 容器..."
    docker run -it -d --restart=always \
      -e "SUB_STORE_BACKEND_SYNC_CRON=55 23 * * *" \
      -e "SUB_STORE_FRONTEND_BACKEND_PATH=/21DEDINGZHI" \
      -p 0.0.0.0:9277:3001 \
      -v /root/sub-store-data:/opt/app/data \
      --name $CONTAINER_NAME \
      $IMAGE_NAME
    echo -e "⏳ 正在等待 Sub-Store 容器启动 (5秒)..."
    sleep 5
    if [ $(docker ps -q -f name=^/${CONTAINER_NAME}$) ]; then
        echo -e "${GREEN}✅ Sub-Store 容器已成功启动 (端口 9277)！${NC}"
    else
        echo -e "${RED}❌ Sub-Store 容器启动失败！${NC}"
    fi
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   组件 5: TProxy
# ----------------------------------------------------------------
install_tproxy() {
    echo -e "${BLUE}--- 正在安装 [组件 5: TProxy] ---${NC}"
    echo "请选择 TProxy 模式:"
    echo "  1) 传统 iptables TProxy 模式 (setup-tproxy-ipv4.sh)"
    echo "  2) 高性能 eBPF TC TProxy 模式 v2.0 (自动识别系统/推荐)"
    echo "  3) 旧版 eBPF TC TProxy 模式 (mihomo/deploy.sh)"
    echo
    read -p "请输入选项 [1-3]: " t_choice

    case $t_choice in
        1)
            echo -e "🔧 准备执行传统 iptables TProxy 脚本..."
            TPROXY_SCRIPT_URL="https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/Alpine/setup-tproxy-ipv4.sh"
            if safe_github_script_exec "$TPROXY_SCRIPT_URL"; then
                echo -e "${GREEN}✅ iptables TProxy 脚本执行完毕！${NC}"
            else
                echo -e "${RED}❌ iptables TProxy 脚本执行失败。${NC}"
            fi
            ;;
        2)
            echo -e "🚀 准备安装高性能 eBPF TC TProxy v2.0..."
            echo -e "${YELLOW}📋 特性：${NC}"
            echo -e "  - 自动识别系统类型 (Debian/Ubuntu/CentOS/Alpine)"
            echo -e "  - 自动安装所有依赖"
            echo -e "  - 自动检测并编译 eBPF 程序（如果支持）"
            echo -e "  - 性能比 iptables 提升 3-5 倍"
            echo -e "  - 如果 eBPF 不可用，自动回退到优化的 iptables 方案"
            echo ""
            EBPF_SCRIPT_URL="https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/Alpine/setup-ebpf-tc-tproxy.sh"
            echo -e "📥 正在下载并执行 eBPF TC TProxy 部署脚本..."
            if safe_github_script_exec "$EBPF_SCRIPT_URL"; then
                echo -e "${GREEN}✅ eBPF TC TProxy 部署完成！${NC}"
                echo ""
                echo -e "${YELLOW}💡 服务管理提示：${NC}"
                if [ "$OS_DIST" == "alpine" ]; then
                    echo -e "  启动: ${CYAN}rc-service ebpf-tproxy start${NC}"
                    echo -e "  停止: ${CYAN}rc-service ebpf-tproxy stop${NC}"
                    echo -e "  状态: ${CYAN}rc-service ebpf-tproxy status${NC}"
                    echo -e "  日志: ${CYAN}tail -f /var/log/ebpf-tproxy.log${NC}"
                else
                    echo -e "  启动: ${CYAN}systemctl start ebpf-tproxy${NC}"
                    echo -e "  停止: ${CYAN}systemctl stop ebpf-tproxy${NC}"
                    echo -e "  状态: ${CYAN}systemctl status ebpf-tproxy${NC}"
                    echo -e "  日志: ${CYAN}journalctl -u ebpf-tproxy -f${NC}"
                fi
            else
                echo -e "${RED}❌ eBPF TC TProxy 部署失败。${NC}"
                echo -e "${YELLOW}💡 提示：请检查网络连接或查看错误信息${NC}"
            fi
            ;;
        3)
            echo -e "🐝 准备安装旧版 eBPF TC TProxy..."
            echo -e "${YELLOW}📋 这是旧版本的 eBPF 部署脚本${NC}"
            echo ""
            EBPF_DEPLOY_URL="https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/mihomo/deploy.sh"
            echo -e "📥 正在下载并执行旧版 eBPF TC TProxy 部署脚本..."
            if safe_github_script_exec "$EBPF_DEPLOY_URL"; then
                echo -e "${GREEN}✅ 旧版 eBPF TC TProxy 部署脚本执行完毕！${NC}"
                echo -e "${YELLOW}💡 提示：你可以运行以下命令检查 TProxy 状态：${NC}"
                CHECK_URL="https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/mihomo/check_tproxy.sh"
                echo -e "   ${CYAN}bash <(curl -sSL $CHECK_URL)${NC}"
            else
                echo -e "${RED}❌ 旧版 eBPF TC TProxy 部署失败。${NC}"
            fi
            ;;
        *)
            echo -e "${RED}❌ 无效选项。${NC}"
            ;;
    esac
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   组件 6: 配置网卡IP
# ----------------------------------------------------------------
install_renetwork() {
    echo -e "${BLUE}--- 正在执行 [组件 6: 配置网卡IP] ---${NC}"
    echo -e "🚀 正在下载并执行 renetwork.sh 脚本..."
    
    RENETWORK_URL="https://raw.githubusercontent.com/Scu9277/eBPF/refs/heads/main/Alpine/renetwork.sh"
    if safe_github_script_exec "$RENETWORK_URL"; then
        echo -e "${GREEN}✅ 网卡配置脚本执行完毕。${NC}"
    else
        echo -e "${RED}❌ 网卡配置脚本执行失败。${NC}"
    fi
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   组件 7: 服务管理 (Service Manager)
# ----------------------------------------------------------------
manage_services() {
    while true; do
        echo -e "${CYAN}--- 服务管理面板 ---${NC}"
        echo "  1) Mihomo 服务"
        echo "  2) Sing-box 服务"
        echo "  3) eBPF TProxy Agent 服务"
        echo "  0) 返回主菜单"
        echo
        read -p "请选择要管理的服务 [1-3 或 0]: " s_svc
        
        SVC_NAME=""
        case $s_svc in
            1) SVC_NAME="mihomo" ;;
            2) SVC_NAME="sing-box" ;;
            3) SVC_NAME="tproxy-agent" ;;
            0) return ;;
            *) echo -e "${RED}无效选项${NC}"; continue ;;
        esac

        echo -e "${YELLOW}正在管理服务: $SVC_NAME${NC}"
        echo "  1) 启动 (Start)"
        echo "  2) 停止 (Stop)"
        echo "  3) 重启 (Restart)"
        echo "  4) 查看状态 (Status)"
        echo "  5) 查看日志 (Logs - Recent)"
        echo "  0) 返回上一级"
        read -p "请选择操作: " s_act

        case $s_act in
            1) manage_svc start $SVC_NAME; echo -e "${GREEN}已发送启动指令${NC}" ;;
            2) manage_svc stop $SVC_NAME; echo -e "${GREEN}已发送停止指令${NC}" ;;
            3) manage_svc restart $SVC_NAME; echo -e "${GREEN}已发送重启指令${NC}" ;;
            4) manage_svc status $SVC_NAME ;;
            5) view_logs $SVC_NAME ;;
            0) continue ;;
            *) echo -e "${RED}无无效操作${NC}" ;;
        esac
        echo "----------------------------------------------------------------"
    done
}

#=================================================================================
#   SECTION 3: 高级系统工具 (Advanced System Tools)
#=================================================================================
# (此区域函数与 V12 完全相同，未作修改)

# ----------------------------------------------------------------
#   高级 1: 更改主机名
# ----------------------------------------------------------------
install_change_hostname() {
    echo -e "${BLUE}--- 正在执行 [高级 1: 更改主机名] ---${NC}"
    read -p "请输入你的新主机名 (例如: MyServer): " NEW_HOSTNAME
    if [ -z "$NEW_HOSTNAME" ]; then
        echo -e "${RED}❌ 输入为空，操作已取消。${NC}"
        echo "----------------------------------------------------------------"
        return
    fi
    
    echo -e "${YELLOW}正在将主机名设置为: $NEW_HOSTNAME ...${NC}"
    set_hostname "$NEW_HOSTNAME"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 主机名已成功更改为: $NEW_HOSTNAME${NC}"
        echo -e "${YELLOW}注意：你可能需要重新登录 SSH 才能看到更改。${NC}"
    else
        echo -e "${RED}❌ 更改主机名失败！${NC}"
    fi
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   高级 2: 系统优化
# ----------------------------------------------------------------
install_kejilion_optimizer() {
    echo -e "${BLUE}--- 正在执行 [高级 2: 科技Lion系统优化脚本] ---${NC}"
    echo -e "🚀 正在下载并执行 kejilion.sh ..."
    echo -e "${YELLOW}这将启动一个交互式脚本，请根据其提示操作。${NC}"
    sleep 3
    bash <(curl -sL kejilion.sh)
    echo -e "${GREEN}✅ 科技Lion 脚本执行完毕。${NC}"
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   高级 3: 系统深度清理 (V12 版本)
# ----------------------------------------------------------------
install_system_cleanup() {
    echo -e "${BLUE}--- 正在执行 [高级 3: 系统深度清理] ---${NC}"
    echo -e "${YELLOW}警告：此操作将：${NC}"
    echo -e " 1. ${RED}完全卸载 Docker (包括容器、镜像和数据卷)！${NC}"
    echo -e " 2. 清理 apt 缓存。"
    echo -e " 3. 移除孤立的系统依赖。"
    echo -e " 4. 清理内存缓存 (drop_caches)。"
    echo -e "${RED}这是一个高风险操作，请确保你不再需要 Docker！${NC}"
    
    read -p "$(echo -e ${YELLOW}"是否确认执行? [y/N]: "${NC})" choice
    
    case "$choice" in
        y|Y )
            echo -e "${YELLOW}--- 1/4: 正在卸载 Docker... ---${NC}"
            if command -v docker &> /dev/null; then
                if manage_svc is-active docker; then
                    echo -e "  -> 正在停止运行中的 Docker 服务..."
                    manage_svc stop docker
                fi
                if manage_svc is-enabled docker; then
                    echo -e "  -> 正在禁用 Docker 开机自启..."
                    manage_svc disable docker
                fi
                echo -e "  -> 正在彻底清除 Docker 软件包和残留数据..."
                if [ "$OS_DIST" == "alpine" ]; then
                    apk del docker docker-cli containerd.io runc &> /dev/null
                else
                    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker-engine docker.io runc &> /dev/null
                fi
                rm -rf /var/lib/docker
                rm -rf /var/lib/containerd
                echo -e "${GREEN}✅ Docker 已彻底移除。${NC}"
            else
                echo -e "${GREEN}👍 Docker 未安装，跳过卸载。${NC}"
            fi

            echo -e "${YELLOW}--- 2/4: 正在清理缓存... ---${NC}"
            if [ "$OS_DIST" == "alpine" ]; then
                apk cache clean
            else
                apt-get clean
            fi
            echo -e "${GREEN}✅ 软件包缓存已清理。${NC}"

            echo -e "${YELLOW}--- 3/4: 正在移除不需要的依赖... ---${NC}"
            if [ "$OS_DIST" != "alpine" ]; then
                apt-get autoremove -y --purge
            fi
            echo -e "${GREEN}✅ 孤立依赖已处理。${NC}"

            echo -e "${YELLOW}--- 4/4: 正在释放内存缓存... ---${NC}"
            sync
            echo 3 > /proc/sys/vm/drop_caches
            echo -e "${GREEN}✅ 内存缓存 (PageCache, dentries, inodes) 已清理。${NC}"

            echo -e "${GREEN}🎉 系统深度清理完成！${NC}"
            ;;
        * )
            echo -e "${GREEN}👍 操作已取消。${NC}"
            ;;
    esac
    echo "----------------------------------------------------------------"
}

# ----------------------------------------------------------------
#   高级 4: 重装系统 (V12 版本)
# ----------------------------------------------------------------
install_reinstall_os() {
    echo -e "${RED}==================== 极度危险 ====================${NC}"
    echo -e "${YELLOW}警告：此操作将从网络下载脚本并重装当前操作系统！${NC}"
    echo -e "${YELLOW}你选择的版本是: ${GREEN}Debian 13${NC}"
    echo -e "${RED}所有数据将被永久删除！${NC}"
    echo -e "${RED}所有数据将被永久删除！${NC}"
    echo -e "${RED}所有数据将被永久删除！${NC}"
    echo -e "=================================================="
    
    read -p "$(echo -e ${YELLOW}"是否确认重装? (最后警告!) [y/N]: "${NC})" choice

    case "$choice" in
        y|Y )
            echo -e "${BLUE}🚀 正在开始重装系统... 你的 SSH 将会断开。${NC}"
            REINSTALL_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
            if safe_github_download "$REINSTALL_URL" "./reinstall.sh"; then
                bash reinstall.sh debian-13
            else
                echo -e "${RED}❌ 重装脚本下载失败！${NC}"
                echo -e "${RED}--- 如果你还看得到这条消息，说明脚本执行失败。---${NC}"
            fi
            ;;
        * )
            echo -e "${GREEN}👍 操作已取消。${NC}"
            ;;
    esac
    echo "----------------------------------------------------------------"
}


#=================================================================================
#   SECTION 4: 主菜单 (Main Menu)
#=================================================================================

# --- V13 变更: 修复 V12 菜单的笔误 ---
show_logo() {
    clear
    # "shangkouyou" - Scu 专属 Logo
    echo -e "${CYAN}"
    echo "                                                        "; 
    echo " ▗▄▄▖▗▖ ▗▖ ▗▄▖ ▗▖  ▗▖ ▗▄▄▖▗▖ ▗▖ ▗▄▖ ▗▖ ▗▖▗▖  ▗▖▗▄▖ ▗▖ ▗▖";
    echo "▐▌   ▐▌ ▐▌▐▌ ▐▌▐▛▚▖▐▌▐▌   ▐▌▗▞▘▐▌ ▐▌▐▌ ▐▌ ▝▚▞▘▐▌ ▐▌▐▌ ▐▌";
    echo " ▝▀▚▖▐▛▀▜▌▐▛▀▜▌▐▌ ▝▜▌▐▌▝▜▌▐▛▚▖ ▐▌ ▐▌▐▌ ▐▌  ▐▌ ▐▌ ▐▌▐▌ ▐▌";
    echo "▗▄▄▞▘▐▌ ▐▌▐▌ ▐▌▐▌  ▐▌▝▚▄▞▘▐▌ ▐▌▝▚▄▞▘▝▚▄▞▘  ▐▌ ▝▚▄▞▘▝▚▄▞▘";
    echo "                                                        ";   
    echo -e "${NC}"
    echo "=================================================="
    echo "     Mihomo / Sing-box 模块化安装脚本 (V14)"
    echo " "
    echo -e "     作者: ${GREEN}${AUTHOR_NAME}${NC}"
    echo -e "     微信: ${GREEN}${AUTHOR_WECHAT}${NC} | 邮箱: ${GREEN}${AUTHOR_EMAIL}${NC}"
    echo " "
    echo "=================================================="
    echo -e "     ${BLUE}服务器 AFF 推荐 (Scu 导航站):${NC}"
    echo -e "     ${YELLOW}${AFF_URL}${NC}"
    echo "=================================================="
}

# 主菜单 (V13 变更)
main_menu() {
    show_logo
    
    echo
    echo -e "--- ${BLUE}核心安装 (二选一) ${NC}---"
    echo "  1) 安装 Mihomo 核心 (带配置)"
    echo "  2) 安装 Sing-box 核心 (带配置)"
    echo
    echo -e "--- ${YELLOW}独立组件 (按需安装) ${NC}---"
    echo "  3) 更换系统源 (linuxmirrors.cn)"
    echo "  4) 安装 Docker (linuxmirrors.cn)"
    # V13 变更: 移除了 V12 中多余的 "S"
    echo "  5) 安装 Sub-Store (依赖 Docker)"
    echo "  6) 安装 TProxy (iptables/eBPF TC 可选)"
    echo "  7) 安装 DNS 劫持 (/etc/hosts)"
    echo "  8) 配置网卡IP (renetwork.sh)"
    echo "  9) 服务管理 (Start/Stop/Logs)"
    echo
    echo -e "--- ${RED}高级系统工具 ${NC}---"
    echo " 10) 更改主机名 (Hostname)"
    echo " 11) 运行 科技Lion 优化脚本 (kejilion.sh)"
    echo -e " 12) ${YELLOW}系统深度清理 (卸载Docker/清缓存/释内存)${NC}"
    echo -e " 13) ${RED}一键重装系统 (Debian 13 - 极度危险!)${NC}"
    echo "--------------------------------------------------"
    echo -e " ${MAGENTA}00) 退出脚本${NC}"
    echo
    echo -e " ${MAGENTA}00) 退出脚本${NC}"
    echo
    read -p "请输入选项 [1-13 或 00]: " choice

    case $choice in
        1) install_mihomo_core_and_config ;;
        2) install_singbox_core_and_config ;;
        3) install_change_source ;;
        4) install_docker ;;
        5) install_substore ;;
        6) install_tproxy ;;
        7) install_dns_hijack ;;
        8)
            install_renetwork
            NEW_IP=$(get_lan_ip)
            DISPLAY_IP=${NEW_IP:-"[您的新IP]"}
            echo -e "${GREEN}网卡配置完毕，请使用新 IP 重新连接 SSH: ${YELLOW}${DISPLAY_IP}${NC}"
            echo -e "${YELLOW}脚本将在 5 秒后退出，以便你重新连接...${NC}"
            sleep 5
            exit 0
            ;;
        9) manage_services ;;
        10) install_change_hostname ;;
        11) install_kejilion_optimizer ;;
        12) install_system_cleanup ;;
        13) install_reinstall_os ;;
        00)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请输入 1 到 13 或 00。${NC}"
            sleep 2
            ;;
    esac
    
    # 循环显示主菜单
    if [ "$choice" != "00" ] && [ "$choice" != "8" ] && [ "$choice" != "13" ]; then
        read -p "按任意键返回主菜单..."
        main_menu
    elif [ "$choice" == "13" ]; then
         # 如果重装被取消，返回菜单
        read -p "按任意键返回主菜单..."
        main_menu
    fi
}

# --- 脚本开始执行 ---
check_root
check_dependencies
select_github_proxy
main_menu
