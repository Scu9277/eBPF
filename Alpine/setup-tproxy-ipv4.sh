#!/bin/bash
# ==========================================
# 🧠 Sing-box IPv4 TProxy 一键配置脚本 (优化版)
# 
# 作者: shangkouyou Duang Scu
# 微信: shangkouyou
# 邮箱: shangkouyou@gmail.com
# 版本: v1.5 (Gateway Mode Fixed)
#
# 更新日志:
# - v1.5: 修复网关模式流量豁免逻辑，添加智能等待，完整验证
# - v1.4: 完整支持 Alpine Linux 系统 (OpenRC)
# - v1.3: 修复 TPROXY 链名称冲突
# ==========================================

# 检查是否为 bash，如果不是则尝试安装并重新执行
if [ -z "$BASH_VERSION" ]; then
    echo "⚠️  此脚本需要 bash 环境。正在尝试安装 bash..."
    if [ -f /etc/alpine-release ]; then
        if ! command -v bash > /dev/null 2>&1; then
            echo "📦 正在安装 bash..."
            apk update > /dev/null 2>&1
            apk add --no-cache bash > /dev/null 2>&1
        fi
        if command -v bash > /dev/null 2>&1; then
            echo "✅ bash 已就绪，正在使用 bash 重新执行脚本..."
            exec bash "$0" "$@"
        else
            echo "❌ 无法安装 bash，请手动执行: apk add bash && bash $0"
            exit 1
        fi
    elif command -v apt-get > /dev/null 2>&1; then
        if ! command -v bash > /dev/null 2>&1; then
            apt-get update -y > /dev/null 2>&1 && apt-get install -y bash > /dev/null 2>&1
        fi
        exec bash "$0" "$@"
    else
        echo "❌ 请安装 bash 后再运行此脚本，或使用 'bash $0' 执行"
        exit 1
    fi
fi

set -e
LOG_FILE="/var/log/tproxy-setup.log"
TPROXY_DIR="/etc/tproxy"
TPROXY_SCRIPT="$TPROXY_DIR/tproxy.sh"
TPROXY_PORT=9420
# 默认 mark 值，如果检测到 mihomo 配置会自动使用其 routing-mark
TPROXY_MARK=0x2333
TABLE_ID=100
DOCKER_PORT=9277

# 检测并同步 mihomo 的 routing-mark
detect_mihomo_routing_mark() {
    local mihomo_config="/etc/mihomo/config.yaml"
    if [ -f "$mihomo_config" ]; then
        local routing_mark=$(grep -E "^routing-mark:" "$mihomo_config" 2>/dev/null | awk '{print $2}' | tr -d ' ' | head -n1)
        if [ -n "$routing_mark" ] && [[ "$routing_mark" =~ ^[0-9]+$ ]]; then
            # 转换为十六进制
            local mark_hex=$(printf "0x%X" "$routing_mark" 2>/dev/null)
            if [ -n "$mark_hex" ]; then
                echo "$mark_hex"
                return 0
            fi
        fi
    fi
    # 如果检测失败，返回默认值
    echo "0x2333"
    return 1
}

# --- 作者信息 ---
AUTHOR_NAME="shangkouyou Duang Scu"
AUTHOR_WECHAT="shangkouyou"
AUTHOR_EMAIL="shangkouyou@gmail.com"
AFF_URL="https://aff.scu.indevs.in/"

# 自定义链名称
CUSTOM_CHAIN="TPROXY_CHAIN"

# 展示作者信息
show_author_info() {
    echo "=================================================="
    echo "     Sing-box IPv4 TProxy 一键配置脚本"
    echo ""
    echo "     作者: $AUTHOR_NAME"
    echo "     微信: $AUTHOR_WECHAT | 邮箱: $AUTHOR_EMAIL"
    echo "     服务器 AFF 推荐 (Scu 导航站): $AFF_URL"
    echo "=================================================="
    echo ""
}

# ---- 检测系统类型 ----
OS_DIST="unknown"
if [ -f /etc/alpine-release ]; then
    OS_DIST="alpine"
    SERVICE_FILE="/etc/init.d/tproxy"
elif [ -f /etc/debian_version ]; then
    OS_DIST="debian"
    SERVICE_FILE="/etc/systemd/system/tproxy.service"
elif [ -f /etc/redhat-release ]; then
    OS_DIST="redhat"
    SERVICE_FILE="/etc/systemd/system/tproxy.service"
else
    OS_DIST="other"
    SERVICE_FILE="/etc/systemd/system/tproxy.service"
fi

show_author_info
echo "[$(date '+%F %T')] 🚀 开始配置 IPv4 TProxy 环境 (仅网关模式)..." | tee -a "$LOG_FILE"
echo "[$(date '+%F %T')] 📋 检测到系统类型: $OS_DIST" | tee -a "$LOG_FILE"

# ---- 创建目录 ----
mkdir -p "$TPROXY_DIR"

# ---- 检查包管理器 ----
if command -v apt > /dev/null 2>&1; then
  PKG_INSTALL="apt install -y"
  PKG_UPDATE="apt update -y"
elif command -v apk > /dev/null 2>&1; then
  PKG_INSTALL="apk add"
  PKG_UPDATE="apk update"
elif command -v dnf > /dev/null 2>&1; then
  PKG_INSTALL="dnf install -y"
  PKG_UPDATE="dnf makecache"
elif command -v yum > /dev/null 2>&1; then
  PKG_INSTALL="yum install -y"
  PKG_UPDATE="yum makecache"
else
  echo "❌ 无法识别包管理器，请手动安装 iptables/iproute2" | tee -a "$LOG_FILE"
  exit 1
fi

# ---- 检查并安装依赖 ----
MISSING_PKGS=()

# 检查 iptables
if ! command -v iptables > /dev/null 2>&1; then
  MISSING_PKGS+=("iptables")
fi

# 检查 iproute2 (通过 ip 命令)
if ! command -v ip > /dev/null 2>&1; then
  MISSING_PKGS+=("iproute2")
fi

# 检查 net-tools (netstat)
if ! command -v netstat > /dev/null 2>&1; then
  if [ "$OS_DIST" == "alpine" ]; then
    MISSING_PKGS+=("net-tools")
  else
    MISSING_PKGS+=("net-tools")
  fi
fi

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  echo "[$(date '+%F %T')] 📦 检测到缺失依赖: ${MISSING_PKGS[*]}" | tee -a "$LOG_FILE"
  $PKG_UPDATE && $PKG_INSTALL "${MISSING_PKGS[@]}"
else
  echo "[$(date '+%F %T')] ✅ 所有依赖已安装" | tee -a "$LOG_FILE"
fi

# ---- 切换到 iptables-legacy (若存在) ----
if [ "$OS_DIST" != "alpine" ]; then
  if command -v update-alternatives > /dev/null 2>&1; then
    if command -v iptables-legacy > /dev/null 2>&1; then
      update-alternatives --set iptables /usr/sbin/iptables-legacy || true
      update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true
      echo "[$(date '+%F %T')] 🔁 已强制切换到 iptables-legacy 模式" | tee -a "$LOG_FILE"
    else
       echo "[$(date '+%F %T')] ⚠️ 未找到 iptables-legacy，TProxy 可能会失败" | tee -a "$LOG_FILE"
    fi
  else
      echo "[$(date '+%F %T')] ⚠️ 非 Debian/Ubuntu 系统，请手动确保使用 iptables-legacy" | tee -a "$LOG_FILE"
  fi
else
  echo "[$(date '+%F %T')] ✅ Alpine 系统默认使用 iptables-legacy，无需切换" | tee -a "$LOG_FILE"
fi

# ---- 加载内核模块 ----
for mod in xt_TPROXY nf_tproxy_ipv4; do
  modprobe $mod 2>/dev/null && echo "[$(date '+%F %T')] ✅ 加载模块: $mod" | tee -a "$LOG_FILE"
done

# ---- 启用 IPv4 转发 ----
sysctl -w net.ipv4.ip_forward=1 > /dev/null
grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf && sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
echo "[$(date '+%F %T')] 🔧 已启用 IPv4 转发" | tee -a "$LOG_FILE"

# ---- 检测并同步 mihomo 的 routing-mark ----
echo "[$(date '+%F %T')] 🔍 正在检测 mihomo 配置中的 routing-mark..." | tee -a "$LOG_FILE"
detected_mark=$(detect_mihomo_routing_mark)
if [ "$detected_mark" != "0x2333" ]; then
    TPROXY_MARK="$detected_mark"
    echo "[$(date '+%F %T')] ✅ 检测到 mihomo routing-mark，使用: $TPROXY_MARK" | tee -a "$LOG_FILE"
else
    echo "[$(date '+%F %T')] ℹ️  使用默认 TProxy mark: $TPROXY_MARK" | tee -a "$LOG_FILE"
    echo "[$(date '+%F %T')] 💡 提示：如果 mihomo 使用不同的 routing-mark，请确保配置匹配" | tee -a "$LOG_FILE"
fi

# ---- 写入 IPv4 TProxy 脚本 ----
cat > "$TPROXY_SCRIPT" <<'EOF'
#!/bin/bash
# IPv4 TProxy for Mihomo (Gateway Mode - 优化版)
# 修复网关模式流量豁免逻辑，添加智能等待和完整验证

EOF

# 添加配置变量
cat >> "$TPROXY_SCRIPT" <<EOF
LOG_FILE="/var/log/tproxy.log"
TPROXY_PORT=$TPROXY_PORT
TPROXY_MARK=$TPROXY_MARK
TABLE_ID=$TABLE_ID
DOCKER_PORT=$DOCKER_PORT
CHAIN_NAME="$CUSTOM_CHAIN"

EOF

# 添加脚本主体
cat >> "$TPROXY_SCRIPT" <<'EOF'
log() {
    echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"
}

# 智能等待 Mihomo 启动函数
wait_for_mihomo() {
    local max_wait=60
    local waited=0
    local check_interval=2
    
    log "⏳ 正在等待 Mihomo 服务就绪..."
    
    while [ $waited -lt $max_wait ]; do
        # 检查服务状态
        local service_running=false
        if command -v systemctl > /dev/null 2>&1; then
            if systemctl is-active --quiet mihomo.service 2>/dev/null; then
                service_running=true
            fi
        elif command -v rc-service > /dev/null 2>&1; then
            if rc-service mihomo status > /dev/null 2>&1; then
                service_running=true
            fi
        fi
        
        if [ "$service_running" = true ]; then
            # 服务运行中，检查端口是否监听
            sleep 2
            
            if command -v netstat > /dev/null 2>&1; then
                if netstat -tuln 2>/dev/null | grep -q ":$TPROXY_PORT "; then
                    log "✅ Mihomo 服务已就绪 (等待时间: ${waited}s)"
                    return 0
                fi
            elif command -v ss > /dev/null 2>&1; then
                if ss -tuln 2>/dev/null | grep -q ":$TPROXY_PORT "; then
                    log "✅ Mihomo 服务已就绪 (等待时间: ${waited}s)"
                    return 0
                fi
            else
                log "✅ Mihomo 服务已启动 (等待时间: ${waited}s)"
                return 0
            fi
        fi
        
        sleep $check_interval
        waited=$((waited + check_interval))
        
        if [ $((waited % 10)) -eq 0 ]; then
            log "   仍在等待 Mihomo... (已等待 ${waited}s)"
        fi
    done
    
    log "❌ 等待 Mihomo 超时 (${max_wait}s)"
    return 1
}

log "🚀 开始配置 IPv4 TProxy..."

# ⚠️ 智能等待 Mihomo 启动
if ! wait_for_mihomo; then
    log "❌ Mihomo 服务未就绪，无法继续配置 TProxy"
    exit 1
fi

# 检测主网卡
MAIN_IF=$(ip -4 route show default 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}' | head -n1)
if [ -z "$MAIN_IF" ]; then
    MAIN_IF=$(ip -4 link show | grep -E '^[0-9]+:' | grep -v 'lo:' | head -n1 | awk -F': ' '{print $2}' | awk '{print $1}')
fi

# 检测主网卡 IP
if [ -n "$MAIN_IF" ]; then
    MAIN_IP=$(ip -4 addr show "$MAIN_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
else
    MAIN_IP=""
fi

if [ -n "$MAIN_IF" ] && [ -n "$MAIN_IP" ]; then
    log "✅ 检测到主网卡: $MAIN_IF ($MAIN_IP)"
else
    log "⚠️  未能检测到主网卡 IP"
fi

# ---- 安全清理旧规则 ----
log "🧹 正在清理旧规则..."
iptables -t mangle -D PREROUTING -j $CHAIN_NAME 2>/dev/null || true
iptables -t mangle -F $CHAIN_NAME 2>/dev/null || true
iptables -t mangle -X $CHAIN_NAME 2>/dev/null || true
ip rule del fwmark $TPROXY_MARK table $TABLE_ID 2>/dev/null || true
ip route flush table $TABLE_ID 2>/dev/null || true

# ---- 创建新链 ----
iptables -t mangle -N $CHAIN_NAME

# !! 关键修复：防止回环 (如果包已经带了标记，直接跳过)
iptables -t mangle -A $CHAIN_NAME -m mark --mark $TPROXY_MARK -j RETURN
log "✅ 已开启防回环保护 (Mark: $TPROXY_MARK)"

# ⚠️ 关键修复：优化规则顺序，正确处理网关模式
log "🔗 配置 iptables TProxy 规则..."

# 规则优先级：本地回环 > 宿主机自身流量 > 服务端口 > 局域网 > TProxy

# 1. 豁免本地回环（最高优先级）
iptables -t mangle -A $CHAIN_NAME -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A $CHAIN_NAME -s 127.0.0.0/8 -j RETURN

# 2. ⚠️ 关键：豁免宿主机自身流量 (双向)
if [ -n "$MAIN_IP" ]; then
    iptables -t mangle -A $CHAIN_NAME -s $MAIN_IP -j RETURN
    iptables -t mangle -A $CHAIN_NAME -d $MAIN_IP -j RETURN
    log "✅ 已豁免宿主机自身流量 (IP: $MAIN_IP)"
fi

# 3. 豁免宿主机服务端口 (22, 123, 80, 443, 9090, 9420)
iptables -t mangle -A $CHAIN_NAME -p tcp --dport 22 -j RETURN    # SSH
iptables -t mangle -A $CHAIN_NAME -p udp --dport 123 -j RETURN   # NTP
iptables -t mangle -A $CHAIN_NAME -p tcp --dport 80 -j RETURN    # HTTP
# iptables -t mangle -A $CHAIN_NAME -p tcp --dport 443 -j RETURN  # ⚠️ 不要豁免 443，那是主要加密流量
iptables -t mangle -A $CHAIN_NAME -p tcp --dport 9090 -j RETURN  # Mihomo UI
iptables -t mangle -A $CHAIN_NAME -p tcp --dport $TPROXY_PORT -j RETURN  # TProxy 端口
log "✅ 已豁免宿主机服务端口 (22, 123, 80, 9090, $TPROXY_PORT)"

# !! 关键修复：拦截 QUIC (UDP 443) !!
# 这会迫使浏览器回退到 TCP，从而能被稳定的代理。你的原始脚本里有这一条，这是成功的关键！
iptables -t mangle -A $CHAIN_NAME -p udp --dport 443 -j REJECT
log "✅ 已强行拦截 QUIC (UDP 443) 流量以启用 TCP 回退"

# 4. 豁免 Docker 订阅端口
iptables -t mangle -A $CHAIN_NAME -p tcp --dport $DOCKER_PORT -j RETURN
iptables -t mangle -A $CHAIN_NAME -p udp --dport $DOCKER_PORT -j RETURN

# 5. 豁免局域网、内网地址块 (恢复原始版本最稳逻辑)
log "🔗 正在配置局域网豁免规则..."
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 255.255.255.255; do
  iptables -t mangle -A $CHAIN_NAME -d $net -j RETURN
done

# 如果有检测到额外网段，补充豁免
      iptables -t mangle -A $CHAIN_NAME -d $LAN_SUBNET -j RETURN
fi
log "✅ 局域网豁免配置完成"

# 6. TProxy 转发规则 (⚠️ 最终防御：仅处理来自局域网的合法客户端流量)
# 这防止了来自互联网的随机流量误入 TProxy，解决了连接数爆表的问题。
log "🔗 正在配置 TProxy 转发逻辑 (仅限局域网来源)..."
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
  iptables -t mangle -A $CHAIN_NAME -s $net -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $TPROXY_MARK
  iptables -t mangle -A $CHAIN_NAME -s $net -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $TPROXY_MARK
done
log "✅ TProxy 转发规则配置完成"

# Hook 到 PREROUTING
iptables -t mangle -I PREROUTING -j $CHAIN_NAME

# 配置策略路由
log "🛣️  正在配置策略路由..."
if ip rule add fwmark $TPROXY_MARK table $TABLE_ID 2>&1; then
    log "✅ 策略路由规则添加成功"
else
    log "❌ 错误：策略路由规则添加失败！"
    exit 1
fi

if ip route add local default dev lo table $TABLE_ID 2>&1; then
    log "✅ 路由表 $TABLE_ID 配置成功"
else
    log "❌ 错误：路由表 $TABLE_ID 配置失败！"
    ip route del local default dev lo table $TABLE_ID 2>/dev/null || true
    sleep 1
    if ip route add local default dev lo table $TABLE_ID 2>&1; then
        log "✅ 路由表 $TABLE_ID 配置成功（修复后）"
    else
        log "❌ 错误：路由表 $TABLE_ID 配置仍然失败！"
        exit 1
    fi
fi

log "✅ IPv4 TProxy 配置完成"

# ========================================
# 配置验证
# ========================================
log "🔍 正在验证配置..."

verify_config() {
    local errors=0
    
    echo "=================================================="
    echo "🔍 TProxy 配置验证报告"
    echo "=================================================="
    
    # 1. 检查 Mihomo 服务
    if command -v systemctl > /dev/null 2>&1; then
        if systemctl is-active --quiet mihomo.service 2>/dev/null; then
            echo "✅ Mihomo 服务运行正常"
        else
            echo "❌ Mihomo 服务未运行"
            errors=$((errors + 1))
        fi
    elif command -v rc-service > /dev/null 2>&1; then
        if rc-service mihomo status > /dev/null 2>&1; then
            echo "✅ Mihomo 服务运行正常"
        else
            echo "❌ Mihomo 服务未运行"
            errors=$((errors + 1))
        fi
    fi
    
    # 2. 检查 TProxy 端口监听
    if command -v netstat > /dev/null 2>&1; then
        if netstat -tuln 2>/dev/null | grep -q ":$TPROXY_PORT "; then
            echo "✅ TProxy 端口 $TPROXY_PORT 正在监听"
        else
            echo "❌ TProxy 端口 $TPROXY_PORT 未监听"
            errors=$((errors + 1))
        fi
    elif command -v ss > /dev/null 2>&1; then
        if ss -tuln 2>/dev/null | grep -q ":$TPROXY_PORT "; then
            echo "✅ TProxy 端口 $TPROXY_PORT 正在监听"
        else
            echo "❌ TProxy 端口 $TPROXY_PORT 未监听"
            errors=$((errors + 1))
        fi
    fi
    
    # 3. 检查 iptables 规则
    if iptables -t mangle -L $CHAIN_NAME -n 2>/dev/null | grep -q "TPROXY"; then
        echo "✅ iptables TPROXY 规则已加载"
        local rule_count=$(iptables -t mangle -L $CHAIN_NAME -n 2>/dev/null | grep -c "TPROXY" || echo 0)
        echo "   (共 $rule_count 条 TPROXY 规则)"
    else
        echo "❌ iptables TPROXY 规则未找到"
        errors=$((errors + 1))
    fi
    
    # 4. 检查策略路由 (不区分大小写)
    if ip rule show | grep -qi "$TPROXY_MARK"; then
        echo "✅ 策略路由规则已配置 (mark: $TPROXY_MARK)"
    else
        echo "❌ 策略路由规则未找到"
        errors=$((errors + 1))
    fi
    
    if ip route show table $TABLE_ID 2>/dev/null | grep -q "local default"; then
        echo "✅ 路由表 $TABLE_ID 已配置"
    else
        echo "❌ 路由表 $TABLE_ID 未配置"
        errors=$((errors + 1))
    fi
    
    # 5. 检查 IP 转发
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        echo "✅ IPv4 转发已启用"
    else
        echo "❌ IPv4 转发未启用"
        errors=$((errors + 1))
    fi
    
    echo "=================================================="
    if [ $errors -eq 0 ]; then
        echo "✅ 所有检查通过！TProxy 配置正常"
        echo ""
        echo "📱 客户端设备配置指南："
        echo "   1. 设置网关: $MAIN_IP"
        echo "   2. 设置 DNS: $MAIN_IP (或 8.8.8.8)"
        echo ""
        echo "🧪 测试命令（在客户端设备上执行）："
        echo "   curl -I https://www.google.com"
        echo "   curl https://ipinfo.io"
        return 0
    else
        echo "❌ 发现 $errors 个问题，请检查日志"
        echo ""
        echo "📋 故障排除："
        echo "   1. 查看日志: tail -f $LOG_FILE"
        echo "   2. 检查 Mihomo: systemctl status mihomo 或 rc-service mihomo status"
        echo "   3. 检查规则: iptables -t mangle -L $CHAIN_NAME -n -v"
        echo "   4. 检查路由: ip rule show && ip route show table $TABLE_ID"
        return 1
    fi
}

# 执行验证
verify_config | tee -a "$LOG_FILE"
EOF

chmod +x "$TPROXY_SCRIPT"
echo "[$(date '+%F %T')] ✅ 写入转发脚本到 $TPROXY_SCRIPT" | tee -a "$LOG_FILE"

# ---- 创建服务（根据系统类型） ----
if [ "$OS_DIST" == "alpine" ]; then
  # Alpine 使用 OpenRC
  echo "[$(date '+%F %T')] 🔧 正在创建 OpenRC 服务..." | tee -a "$LOG_FILE"
  cat > "$SERVICE_FILE" <<EOFRC
#!/sbin/openrc-run
description="Sing-box IPv4 TProxy Service (Gateway Mode)"
command="$TPROXY_SCRIPT"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/tproxy-service.log"
error_log="/var/log/tproxy-service.log"

depend() {
    need net
    need mihomo
    after firewall mihomo
    before local
}

start() {
    ebegin "Starting TProxy service"
    
    # 1. 检查 mihomo 服务是否运行
    if ! rc-service mihomo status > /dev/null 2>&1; then
        eend 1 "Mihomo service is not running. Please start mihomo first."
        return 1
    fi
    
    # 2. 等待网络就绪
    sleep 2
    
    # 3. 执行配置脚本（脚本内部会智能等待 Mihomo）
    if \$command; then
        eend 0
    else
        eend 1
        return 1
    fi
}

stop() {
    ebegin "Stopping TProxy service"
    # 清理规则
    iptables -t mangle -D PREROUTING -j $CUSTOM_CHAIN 2>/dev/null || true
    iptables -t mangle -F $CUSTOM_CHAIN 2>/dev/null || true
    iptables -t mangle -X $CUSTOM_CHAIN 2>/dev/null || true
    ip rule del fwmark $TPROXY_MARK table $TABLE_ID 2>/dev/null || true
    ip route flush table $TABLE_ID 2>/dev/null || true
    eend 0
}
EOFRC
  chmod +x "$SERVICE_FILE"
  echo "[$(date '+%F %T')] ✅ 已创建 OpenRC 服务文件: $SERVICE_FILE" | tee -a "$LOG_FILE"
  
  # 启用并启动服务
  rc-update add tproxy default 2>/dev/null || true
  rc-service tproxy start
  
  # 检查服务状态
  sleep 2
  if rc-service tproxy status > /dev/null 2>&1; then
    echo "[$(date '+%F %T')] ✅ 已创建并成功启动 OpenRC 服务 tproxy" | tee -a "$LOG_FILE"
  else
    echo "[$(date '+%F %T')] ⚠️  服务 tproxy 可能未完全启动，请检查日志: /var/log/tproxy-service.log" | tee -a "$LOG_FILE"
    echo "[$(date '+%F %T')] 💡 提示：可以手动执行 'rc-service tproxy start' 启动服务" | tee -a "$LOG_FILE"
  fi
else
  # 其他系统使用 systemd
  echo "[$(date '+%F %T')] 🔧 正在创建 systemd 服务..." | tee -a "$LOG_FILE"
  cat > "$SERVICE_FILE" <<EOFSD
[Unit]
Description=Sing-box IPv4 TProxy Service (Gateway Mode)
After=network-online.target mihomo.service
Wants=network-online.target
Requires=mihomo.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 检查 mihomo 是否运行
ExecStartPre=/bin/bash -c 'systemctl is-active --quiet mihomo.service || exit 1'
# 执行配置脚本（脚本内部会智能等待 Mihomo）
ExecStart=$TPROXY_SCRIPT
StandardOutput=journal
StandardError=journal
# 停止时清理规则
ExecStop=/bin/bash -c 'iptables -t mangle -D PREROUTING -j $CUSTOM_CHAIN 2>/dev/null || true'
ExecStop=/bin/bash -c 'iptables -t mangle -F $CUSTOM_CHAIN 2>/dev/null || true'
ExecStop=/bin/bash -c 'iptables -t mangle -X $CUSTOM_CHAIN 2>/dev/null || true'
ExecStop=/bin/bash -c 'ip rule del fwmark $TPROXY_MARK table $TABLE_ID 2>/dev/null || true'
ExecStop=/bin/bash -c 'ip route flush table $TABLE_ID 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOFSD

  systemctl daemon-reload
  systemctl enable tproxy.service
  systemctl restart tproxy.service

  # ---- 检查服务状态 ----
  if systemctl is-active --quiet tproxy.service; then
    echo "[$(date '+%F %T')] ✅ 已创建并成功启动 systemd 服务 tproxy.service" | tee -a "$LOG_FILE"
  else
    echo "[$(date '+%F %T')] ❌ 服务 tproxy.service 启动失败！" | tee -a "$LOG_FILE"
    echo "请手动执行 'journalctl -xeu tproxy.service' 检查错误。" | tee -a "$LOG_FILE"
    exit 1
  fi
fi

# ---- 验证结果 ----
echo "[$(date '+%F %T')] 🔍 当前 TProxy 状态:" | tee -a "$LOG_FILE"
iptables -t mangle -L PREROUTING -v -n | tee -a "$LOG_FILE"
iptables -t mangle -L $CUSTOM_CHAIN -v -n | tee -a "$LOG_FILE"
ip rule show | tee -a "$LOG_FILE"
ip route show table 100 | tee -a "$LOG_FILE"

echo "[$(date '+%F %T')] 🎉 IPv4 TProxy 已配置完成 (仅网关模式)！" | tee -a "$LOG_FILE"
echo ""
echo "=================================================="
echo "📊 性能说明："
echo "  - 当前方案：iptables-legacy TPROXY"
echo "  - 性能等级：中等（适合大多数场景 < 1Gbps）"
echo "  - 规则已优化：常用规则优先匹配"
echo ""
echo "💡 如需更高性能（> 1Gbps），推荐："
echo "  - eBPF TC 模式（性能提升 3-5 倍，CPU 占用更低）"
echo "  - 使用 setup-ebpf-tc-tproxy.sh 脚本"
echo "=================================================="
echo ""
echo "日志文件: $LOG_FILE 和 /var/log/tproxy.log"
if [ "$OS_DIST" == "alpine" ]; then
  echo "✅ 服务管理命令:"
  echo "   - 启动: rc-service tproxy start"
  echo "   - 停止: rc-service tproxy stop"
  echo "   - 重启: rc-service tproxy restart"
  echo "   - 状态: rc-service tproxy status"
  echo "   - 日志: tail -f /var/log/tproxy-service.log"
else
  echo "✅ 服务管理命令:"
  echo "   - 启动: systemctl start tproxy.service"
  echo "   - 停止: systemctl stop tproxy.service"
  echo "   - 重启: systemctl restart tproxy.service"
  echo "   - 状态: systemctl status tproxy.service"
  echo "   - 日志: journalctl -u tproxy.service"
fi
echo ""
echo "✅ 配置已自动验证，请查看上方验证报告"
echo "✅ 客户端设备请设置网关为宿主机 IP"
