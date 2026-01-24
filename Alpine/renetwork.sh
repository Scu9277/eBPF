#!/bin/bash

# ==============================
# 网络配置助手（支持 Debian/Ubuntu/Alpine）
# 功能: DHCP -> 静态IP交互式配置 + IP检查 + 自动应用检测
# 作者: shangkouyou Duang Scu
# 版本: v1.1 (Alpine Support)
# ==============================

# 检查是否为 bash
if [ -z "$BASH_VERSION" ]; then
    if [ -f /etc/alpine-release ]; then
        apk add --no-cache bash >/dev/null 2>&1
        exec bash "$0" "$@"
    else
        echo "此脚本需要 bash 环境，请使用 'bash $0' 执行"
        exit 1
    fi
fi

# --- 颜色定义 ---
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
NC="\033[0m"

# --- 作者信息 ---
AUTHOR_NAME="shangkouyou Duang Scu"
AUTHOR_WECHAT="shangkouyou"
AUTHOR_EMAIL="shangkouyou@gmail.com"
AFF_URL="https://aff.scu.indevs.in/"
PROJECT_NAME="网络配置助手"

# 展示 Logo
show_logo() {
    clear
    echo -e "${CYAN}"
    echo " ▗▄▄▖▗▖ ▗▖ ▗▄▖ ▗▖  ▗▖ ▗▄▄▖▗▖ ▗▖ ▗▄▖ ▗▖ ▗▖▗▖  ▗▖▗▄▖ ▗▖ ▗▖"
    echo "▐▌   ▐▌ ▐▌▐▌ ▐▌▐▛▚▖▐▌▐▌   ▐▌▗▞▘▐▌ ▐▌▐▌ ▐▌ ▝▚▞▘▐▌ ▐▌▐▌ ▐▌"
    echo " ▝▀▚▖▐▛▀▜▌▐▛▀▜▌▐▌ ▝▜▌▐▌▝▜▌▐▛▚▖ ▐▌ ▐▌▐▌ ▐▌  ▐▌ ▐▌ ▐▌▐▌ ▐▌"
    echo "▗▄▄▞▘▐▌ ▐▌▐▌ ▐▌▐▌  ▐▌▝▚▄▞▘▐▌ ▐▌▝▚▄▞▘▝▚▄▞▘  ▐▌ ▝▚▄▞▘▝▚▄▞▘"
    echo -e "${NC}"
    echo "=================================================="
    echo -e "     项目: ${BLUE}${PROJECT_NAME}${NC}"
    echo -e "     作者: ${GREEN}${AUTHOR_NAME}${NC}"
    echo -e "     微信: ${GREEN}${AUTHOR_WECHAT}${NC} | 邮箱: ${GREEN}${AUTHOR_EMAIL}${NC}"
    echo -e "     服务器 AFF 推荐 (Scu 导航站): ${YELLOW}${AFF_URL}${NC}"
    echo "=================================================="
    echo ""
}

# 检测系统类型
OS_DIST="unknown"
if [ -f /etc/alpine-release ]; then
    OS_DIST="alpine"
elif [ -f /etc/debian_version ]; then
    OS_DIST="debian"
elif [ -f /etc/redhat-release ]; then
    OS_DIST="redhat"
fi

NETPLAN_FILE="/etc/network/interfaces"

# 显示 Logo 和系统信息
show_logo
echo -e "${GREEN}检测到系统类型: ${BLUE}${OS_DIST}${NC}"
echo ""

# 检测活跃网卡
echo -e "${GREEN}检测当前活跃网络接口...${NC}"
interfaces=($(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo))
active_interfaces=()
for iface in "${interfaces[@]}"; do
    if ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
        active_interfaces+=("$iface")
    fi
done

if [ ${#active_interfaces[@]} -eq 0 ]; then
    echo -e "${RED}未检测到活跃网络接口，退出.${NC}"
    exit 1
fi

echo -e "${YELLOW}活跃网络接口列表:${NC}"
for i in "${!active_interfaces[@]}"; do
    echo "$i) ${active_interfaces[$i]}"
done

read -rp "请选择要修改的网卡编号: " iface_index
iface="${active_interfaces[$iface_index]}"
echo -e "${GREEN}您选择的网卡是: $iface${NC}"

# 交互式输入 IP
while true; do
    read -rp "请输入静态IP地址 (例如 192.168.1.100): " static_ip
    [[ -z "$static_ip" ]] && echo -e "${RED}IP不能为空${NC}" && continue

    # IP 格式验证
    function validate_ip() {
        local ip=$1
        if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            for i in $(echo $ip | tr '.' ' '); do
                if ((i < 0 || i > 255)); then
                    return 1
                fi
            done
            return 0
        else
            return 1
        fi
    }

    if ! validate_ip "$static_ip"; then
        echo -e "${RED}IP格式不正确${NC}"
        continue
    fi

    # 检测 IP 是否被占用（兼容不同系统的 ping 参数）
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 1 "$static_ip" &> /dev/null 2>&1 || ping -c 1 -w 1 "$static_ip" &> /dev/null 2>&1; then
            echo -e "${RED}IP $static_ip 已被占用，请选择其他 IP${NC}"
            continue
        fi
    fi
    break
done

read -rp "请输入子网掩码位数 [默认24]: " netmask
netmask=${netmask:-24}
read -rp "请输入网关地址 (可选，强烈建议填写): " gateway
if [ -n "$gateway" ]; then
    if ! validate_ip "$gateway"; then
        echo -e "${RED}网关格式不正确，忽略网关设置${NC}"
        gateway=""
    else
        # 验证网关是否可达（使用当前网络）
        echo -e "${YELLOW}正在验证网关 $gateway 是否可达...${NC}"
        if command -v ping >/dev/null 2>&1; then
            if ! (ping -c 1 -W 2 "$gateway" &> /dev/null 2>&1 || ping -c 1 -w 2 "$gateway" &> /dev/null 2>&1); then
                echo -e "${YELLOW}⚠️  警告：无法 ping 通网关 $gateway${NC}"
                echo -e "${YELLOW}这可能是正常的（网关可能禁 ping），但请确认网关地址正确${NC}"
                read -rp "是否继续使用此网关？[y/N]: " gateway_confirm
                if [[ ! "$gateway_confirm" =~ ^[Yy]$ ]]; then
                    gateway=""
                    echo -e "${YELLOW}已取消网关设置${NC}"
                fi
            else
                echo -e "${GREEN}✅ 网关 $gateway 可达${NC}"
            fi
        fi
    fi
fi

# 如果没有提供网关，尝试自动检测
if [ -z "$gateway" ]; then
    echo -e "${YELLOW}未提供网关，尝试自动检测...${NC}"
    current_gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1)
    if [ -n "$current_gateway" ]; then
        echo -e "${GREEN}检测到当前网关: $current_gateway${NC}"
        read -rp "是否使用此网关？[Y/n]: " use_current_gateway
        if [[ ! "$use_current_gateway" =~ ^[Nn]$ ]]; then
            gateway="$current_gateway"
            echo -e "${GREEN}✅ 将使用网关: $gateway${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  无法自动检测网关，建议手动输入${NC}"
        echo -e "${YELLOW}提示：网关通常是路由器的 IP 地址（如 192.168.1.1）${NC}"
    fi
fi
read -rp "请输入首选DNS [默认 119.29.29.29]: " dns1
dns1=${dns1:-119.29.29.29}
read -rp "请输入备用DNS [默认 8.8.8.8]: " dns2
dns2=${dns2:-8.8.8.8}

# 显示配置预览
echo -e "${YELLOW}配置预览:${NC}"
echo "网卡: $iface"
echo "IP: $static_ip/$netmask"
echo "网关: $gateway"
echo "DNS: $dns1 $dns2"

read -rp "确认无误后才应用配置，是否继续？[y/N]: " confirm
[[ ! "$confirm" =~ ^[Yy]$ ]] && echo "取消操作" && exit 0

# 备份原始配置和网络状态
backup_file="${NETPLAN_FILE}.bak.$(date +%F_%T)"
backup_dir="/root/network_backup_$(date +%F_%T)"
mkdir -p "$backup_dir"

if [ -f "$NETPLAN_FILE" ]; then
    cp "$NETPLAN_FILE" "$backup_file"
    echo -e "${GREEN}✅ 已备份原配置: $backup_file${NC}"
else
    echo -e "${YELLOW}原配置文件不存在，将创建新配置${NC}"
    # 确保目录存在
    mkdir -p "$(dirname "$NETPLAN_FILE")"
fi

# 备份当前网络状态（Alpine 特殊处理）
if [ "$OS_DIST" == "alpine" ]; then
    echo -e "${YELLOW}正在备份当前网络状态...${NC}"
    {
        echo "# 当前 IP 配置"
        ip -4 addr show "$iface" 2>/dev/null | grep "inet " || echo "# 无 IP 配置"
        echo ""
        echo "# 当前路由"
        ip route show 2>/dev/null || echo "# 无路由"
        echo ""
        echo "# 当前网关"
        ip route show default 2>/dev/null || echo "# 无默认网关"
    } > "$backup_dir/network_state.txt" 2>/dev/null
    echo -e "${GREEN}✅ 网络状态已备份至: $backup_dir/network_state.txt${NC}"
fi

# 生成新配置
cat > "$NETPLAN_FILE" <<EOL
# Loopback interface
auto lo
iface lo inet loopback

# Static IP configuration for $iface
# Generated by renetwork.sh on $(date '+%F %T')
auto $iface
iface $iface inet static
    address $static_ip/$netmask
EOL

# 添加网关（如果提供）
if [ -n "$gateway" ]; then
    echo "    gateway $gateway" >> "$NETPLAN_FILE"
fi

# 添加 DNS
echo "    dns-nameservers $dns1 $dns2" >> "$NETPLAN_FILE"

# IPv6 配置（可选）
echo "" >> "$NETPLAN_FILE"
echo "# IPv6 configuration (optional)" >> "$NETPLAN_FILE"
echo "iface $iface inet6 auto" >> "$NETPLAN_FILE"

echo -e "${GREEN}✅ 配置文件已生成: $NETPLAN_FILE${NC}"

# 同时更新 /etc/resolv.conf（Alpine 和部分系统需要）
if [ "$OS_DIST" == "alpine" ] || [ ! -f /etc/resolv.conf.head ]; then
    # 备份 resolv.conf
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%F_%T) 2>/dev/null || true
    fi
    # 更新 DNS（如果 networking 服务没有自动处理）
    echo "# Generated by renetwork.sh" > /etc/resolv.conf
    echo "nameserver $dns1" >> /etc/resolv.conf
    echo "nameserver $dns2" >> /etc/resolv.conf
    echo -e "${GREEN}已更新 DNS 配置${NC}"
fi

# 应用配置
echo -e "${YELLOW}应用配置并重启网卡...${NC}"

# 根据系统类型使用不同的方式重启网络
if [ "$OS_DIST" == "alpine" ]; then
    # Alpine 系统：使用 ifup/ifdown 或直接配置
    echo -e "${YELLOW}正在配置网卡 $iface...${NC}"
    
    # 检查并安装 ifupdown-ng（如果需要）
    if ! command -v ifup >/dev/null 2>&1 || ! command -v ifdown >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到缺少 ifup/ifdown，正在安装 ifupdown-ng...${NC}"
        apk add --no-cache ifupdown-ng >/dev/null 2>&1 || {
            echo -e "${YELLOW}⚠️  无法安装 ifupdown-ng，将使用 ip 命令直接配置${NC}"
        }
    fi
    
    # 确保网卡是 UP 状态
    if ! ip link show "$iface" | grep -q "state UP"; then
        echo -e "${YELLOW}正在启动网卡 $iface...${NC}"
        ip link set "$iface" up 2>/dev/null || true
        sleep 1
    fi
    
    # 优先使用 ifup/ifdown（如果可用，更安全）
    if command -v ifdown >/dev/null 2>&1 && command -v ifup >/dev/null 2>&1; then
        echo -e "${YELLOW}使用 ifup/ifdown 配置网卡...${NC}"
        # 先停止网卡
        ifdown "$iface" 2>/dev/null || true
        sleep 1
        # 启动网卡（会读取 /etc/network/interfaces）
        ifup "$iface" 2>/dev/null || true
    else
        # 如果没有 ifup/ifdown，使用 ip 命令直接配置
        echo -e "${YELLOW}使用 ip 命令直接配置网卡...${NC}"
        
        # 先删除现有 IP（如果存在）
        current_ip_info=$(ip -4 addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}')
        if [ -n "$current_ip_info" ]; then
            echo -e "${YELLOW}删除现有 IP: $current_ip_info${NC}"
            ip addr del "$current_ip_info" dev "$iface" 2>/dev/null || true
            sleep 1
        fi
        
        # 确保网卡是 UP 状态
        ip link set "$iface" up 2>/dev/null || true
        sleep 1
        
        # 添加新 IP
        echo -e "${YELLOW}添加新 IP: $static_ip/$netmask${NC}"
        ip addr add "$static_ip/$netmask" dev "$iface" 2>/dev/null || {
            echo -e "${RED}❌ 添加 IP 失败，可能 IP 已存在或网卡有问题${NC}"
            echo -e "${YELLOW}尝试继续配置...${NC}"
        }
        
        # 配置网关（如果提供）- 使用更安全的方式
        if [ -n "$gateway" ]; then
            echo -e "${YELLOW}配置网关: $gateway${NC}"
            
            # 先备份当前网关
            current_gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1)
            if [ -n "$current_gateway" ]; then
                echo "$current_gateway" > "$backup_dir/old_gateway.txt" 2>/dev/null || true
            fi
            
            # 先尝试添加新网关（如果成功，再删除旧的）
            if ip route add default via "$gateway" dev "$iface" 2>/dev/null; then
                echo -e "${GREEN}✅ 新网关已添加${NC}"
                # 删除旧的默认路由（只删除一个，避免全部删除）
                if [ -n "$current_gateway" ] && [ "$current_gateway" != "$gateway" ]; then
                    ip route del default via "$current_gateway" 2>/dev/null || true
                fi
                echo -e "${GREEN}✅ 网关配置成功: $gateway${NC}"
            else
                echo -e "${RED}❌ 添加新网关失败${NC}"
                # 如果添加失败，保留原网关
                if [ -n "$current_gateway" ]; then
                    echo -e "${YELLOW}保留原网关: $current_gateway${NC}"
                else
                    echo -e "${YELLOW}⚠️  警告：当前无默认网关，网络可能无法访问外网${NC}"
                fi
            fi
        fi
    fi
    
    # 尝试重启 networking 服务（如果存在）
    if command -v rc-service >/dev/null 2>&1; then
        if rc-service networking status >/dev/null 2>&1; then
            echo -e "${YELLOW}重启 networking 服务...${NC}"
            rc-service networking restart 2>/dev/null || true
        fi
    elif command -v service >/dev/null 2>&1; then
        if service networking status >/dev/null 2>&1; then
            echo -e "${YELLOW}重启 networking 服务...${NC}"
            service networking restart 2>/dev/null || true
        fi
    fi
    
    # 验证配置是否生效
    echo -e "${YELLOW}验证网络配置...${NC}"
    
    # 检查 IP
    if ip addr show "$iface" 2>/dev/null | grep -q "$static_ip"; then
        echo -e "${GREEN}✅ IP 配置已生效${NC}"
    else
        echo -e "${RED}❌ IP 配置未生效${NC}"
    fi
    
    # 检查网关
    if [ -n "$gateway" ]; then
        current_default=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1)
        if [ "$current_default" == "$gateway" ]; then
            echo -e "${GREEN}✅ 网关配置已生效: $gateway${NC}"
        else
            echo -e "${YELLOW}⚠️  网关可能未生效（当前: ${current_default:-"无"}，期望: $gateway）${NC}"
        fi
    fi
    
    # 检查是否有默认路由（至少一个）
    if ! ip route show default 2>/dev/null | grep -q "default"; then
        echo -e "${RED}❌ 警告：没有默认路由，网络可能无法访问外网！${NC}"
        if [ -n "$gateway" ]; then
            echo -e "${YELLOW}尝试重新添加网关...${NC}"
            ip route add default via "$gateway" dev "$iface" 2>/dev/null || {
                echo -e "${RED}❌ 无法添加网关，请检查网关地址是否正确${NC}"
            }
        fi
    fi
    
    sleep 2
else
    # Debian/Ubuntu 系统：使用 ifup/ifdown
    if command -v ifdown >/dev/null 2>&1 && command -v ifup >/dev/null 2>&1; then
        if ip link show "$iface" | grep -q "state UP"; then
            ifdown "$iface" 2>/dev/null || true
        fi
        ifup "$iface" 2>/dev/null || true
    else
        # 如果没有 ifup/ifdown，使用 ip 命令
        current_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        if [ -n "$current_ip" ]; then
            ip addr del "$current_ip/$(ip -4 addr show "$iface" | grep "inet " | awk '{print $2}' | cut -d/ -f2)" dev "$iface" 2>/dev/null || true
        fi
        ip addr add "$static_ip/$netmask" dev "$iface" 2>/dev/null || true
        if [ -n "$gateway" ]; then
            ip route del default 2>/dev/null || true
            ip route add default via "$gateway" dev "$iface" 2>/dev/null || true
        fi
    fi
    
    # 检查 IP 是否生效
    if ! ip addr show "$iface" | grep -q "$static_ip"; then
        echo -e "${YELLOW}尝试重启 networking 服务...${NC}"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart networking 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true
        elif command -v service >/dev/null 2>&1; then
            service networking restart 2>/dev/null || true
        fi
        sleep 2
    fi
fi

# 检查 IP 是否生效
ip_applied=false
if ip addr show "$iface" 2>/dev/null | grep -q "$static_ip"; then
    echo -e "${GREEN}✅ 网卡 $iface 已成功应用新 IP: $static_ip${NC}"
    ip_applied=true
else
    echo -e "${YELLOW}⚠️  IP 配置可能尚未生效，正在验证...${NC}"
    # 再次尝试应用配置（Alpine 特殊处理）
    if [ "$OS_DIST" == "alpine" ]; then
        if command -v ifup >/dev/null 2>&1; then
            echo -e "${YELLOW}尝试使用 ifup 重新应用配置...${NC}"
            ifup "$iface" 2>/dev/null || true
            sleep 2
        else
            # 直接使用 ip 命令
            ip addr add "$static_ip/$netmask" dev "$iface" 2>/dev/null || true
            if [ -n "$gateway" ]; then
                ip route add default via "$gateway" dev "$iface" 2>/dev/null || true
            fi
            sleep 1
        fi
        
        # 再次检查
        if ip addr show "$iface" 2>/dev/null | grep -q "$static_ip"; then
            echo -e "${GREEN}✅ IP 配置已生效: $static_ip${NC}"
            ip_applied=true
        fi
    fi
    
    if [ "$ip_applied" = false ]; then
        echo -e "${RED}❌ IP 配置未生效！${NC}"
        if [ "$OS_DIST" == "alpine" ]; then
            echo -e "${YELLOW}Alpine 系统故障排除：${NC}"
            echo -e "  1. 检查配置文件: ${GREEN}cat $NETPLAN_FILE${NC}"
            echo -e "  2. 手动重启网络: ${GREEN}rc-service networking restart${NC}"
            echo -e "  3. 或使用 ifup: ${GREEN}ifup $iface${NC}"
            echo -e "  4. 检查网卡状态: ${GREEN}ip addr show $iface${NC}"
            echo -e "  5. 如果仍无法解决，请重启系统"
        else
            echo -e "${YELLOW}提示：您可能需要手动重启网络服务或重启系统${NC}"
        fi
    fi
fi

# 网络连通性检测
echo ""
echo -e "${YELLOW}正在检测网络连通性...${NC}"

# 先检查 IP 是否已配置
if ! ip addr show "$iface" 2>/dev/null | grep -q "$static_ip"; then
    echo -e "${RED}❌ 警告：IP $static_ip 未在网卡 $iface 上生效！${NC}"
    echo -e "${YELLOW}这可能导致网络中断。${NC}"
    read -rp "是否继续检测网络？[y/N]: " continue_check
    if [[ ! "$continue_check" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}跳过网络检测${NC}"
    fi
fi

ping_target=${gateway:-"8.8.8.8"}
network_ok=false

if command -v ping >/dev/null 2>&1; then
    echo -e "${YELLOW}测试连接: $ping_target${NC}"
    if ping -c 2 -W 3 "$ping_target" &> /dev/null 2>&1 || ping -c 2 -w 3 "$ping_target" &> /dev/null 2>&1; then
        echo -e "${GREEN}✅ 网络通畅: $ping_target 可达${NC}"
        network_ok=true
    else
        echo -e "${RED}❌ 网络不通: $ping_target 不可达${NC}"
        echo ""
        echo -e "${YELLOW}故障诊断信息：${NC}"
        echo -e "  当前 IP: $(ip -4 addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "未配置")"
        echo -e "  网关: $(ip route show default 2>/dev/null | awk '/default/ {print $3}' || echo "未配置")"
        echo -e "  路由表:"
        ip route show 2>/dev/null | head -5 || true
    fi
else
    echo -e "${YELLOW}未找到 ping 命令，跳过网络连通性检测${NC}"
    network_ok=true  # 如果没有 ping，假设网络正常
fi

if [ "$network_ok" = false ]; then
    echo ""
    echo -e "${RED}=================================================="
    echo -e "⚠️  网络配置可能有问题！${NC}"
    echo -e "${RED}==================================================${NC}"
    echo ""
    echo -e "${YELLOW}建议操作：${NC}"
    echo -e "  1. 检查 IP 地址是否正确"
    echo -e "  2. 检查网关地址是否正确"
    echo -e "  3. 检查网线/网络连接"
    echo -e "  4. 查看配置文件: ${GREEN}cat $NETPLAN_FILE${NC}"
    echo ""
    read -rp "是否回滚到原配置？[y/N]: " rollback
    if [[ "$rollback" =~ ^[Yy]$ ]]; then
        if [ -f "$backup_file" ]; then
            echo -e "${YELLOW}正在回滚配置...${NC}"
            cp "$backup_file" "$NETPLAN_FILE"
            echo -e "${GREEN}✅ 已恢复配置文件${NC}"
            
            # 恢复 resolv.conf（如果备份存在）
            if [ -f /etc/resolv.conf.bak.* ]; then
                resolv_backup=$(ls -t /etc/resolv.conf.bak.* 2>/dev/null | head -n1)
                if [ -n "$resolv_backup" ]; then
                    cp "$resolv_backup" /etc/resolv.conf 2>/dev/null || true
                    echo -e "${GREEN}✅ 已恢复 DNS 配置${NC}"
                fi
            fi
            
            # Alpine 特殊处理：尝试恢复网络状态
            if [ "$OS_DIST" == "alpine" ] && [ -d "$backup_dir" ]; then
                echo -e "${YELLOW}尝试恢复网络状态...${NC}"
                # 这里可以添加更详细的恢复逻辑，但为了安全，主要依赖配置文件恢复
            fi
            
            # 重启网络服务
            if [ "$OS_DIST" == "alpine" ]; then
                if command -v ifdown >/dev/null 2>&1 && command -v ifup >/dev/null 2>&1; then
                    ifdown "$iface" 2>/dev/null || true
                    sleep 1
                    ifup "$iface" 2>/dev/null || true
                elif command -v rc-service >/dev/null 2>&1; then
                    rc-service networking restart 2>/dev/null || true
                elif command -v service >/dev/null 2>&1; then
                    service networking restart 2>/dev/null || true
                fi
            else
                if command -v ifdown >/dev/null 2>&1 && command -v ifup >/dev/null 2>&1; then
                    ifdown "$iface" 2>/dev/null || true
                    ifup "$iface" 2>/dev/null || true
                elif command -v systemctl >/dev/null 2>&1; then
                    systemctl restart networking 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true
                fi
            fi
            sleep 2
            echo -e "${GREEN}✅ 已回滚原配置，请检查网络连接${NC}"
        else
            echo -e "${RED}❌ 备份文件不存在，无法回滚${NC}"
            echo -e "${YELLOW}请手动检查网络配置或联系技术支持${NC}"
        fi
    else
        echo -e "${YELLOW}未回滚配置，请手动检查网络设置${NC}"
        if [ "$OS_DIST" == "alpine" ]; then
            echo -e "${YELLOW}Alpine 故障排除命令：${NC}"
            echo -e "  - 查看配置: ${GREEN}cat $NETPLAN_FILE${NC}"
            echo -e "  - 重启网络: ${GREEN}rc-service networking restart${NC}"
            echo -e "  - 手动配置: ${GREEN}ifup $iface${NC}"
            echo -e "  - 查看状态: ${GREEN}ip addr show $iface${NC}"
        fi
    fi
fi

# 显示最终网络状态
echo ""
echo -e "${GREEN}=================================================="
echo -e "网络配置完成${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "${YELLOW}当前网络状态：${NC}"
echo -e "  网卡: ${BLUE}$iface${NC}"
echo -e "  IP 地址: ${BLUE}$(ip -4 addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "未配置")${NC}"
echo -e "  网关: ${BLUE}$(ip route show default 2>/dev/null | awk '/default/ {print $3}' || echo "未配置")${NC}"
echo -e "  DNS: ${BLUE}$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' || echo "未配置")${NC}"
echo ""
if [ "$OS_DIST" == "alpine" ]; then
    echo -e "${YELLOW}Alpine 系统提示：${NC}"
    echo -e "  - 如果网络有问题，备份文件: ${GREEN}$backup_file${NC}"
    echo -e "  - 网络状态备份: ${GREEN}$backup_dir/network_state.txt${NC}"
    echo -e "  - 手动重启网络: ${GREEN}rc-service networking restart${NC}"
fi
echo ""
echo -e "${GREEN}操作完成${NC}"
