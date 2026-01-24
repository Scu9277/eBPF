#!/bin/bash
# ==========================================
# 🧠 Sing-box IPv4 TProxy 一键配置脚本
# 
# 作者: shangkouyou Duang Scu
# 微信: shangkouyou
# 邮箱: shangkouyou@gmail.com
# 版本: v1.4 (Alpine Support)
#
# 更新日志:
# - v1.4: 完整支持 Alpine Linux 系统 (OpenRC)
# - v1.3: 修复 TPROXY 链名称冲突
# ==========================================

# 检查是否为 bash，如果不是则尝试安装并重新执行
if [ -z "$BASH_VERSION" ]; then
    echo "⚠️  此脚本需要 bash 环境。正在尝试安装 bash..."
    if [ -f /etc/alpine-release ]; then
        # Alpine 系统
        if ! command -v bash >/dev/null 2>&1; then
            echo "📦 正在安装 bash..."
            apk update >/dev/null 2>&1
            apk add --no-cache bash >/dev/null 2>&1
        fi
        if command -v bash >/dev/null 2>&1; then
            echo "✅ bash 已就绪，正在使用 bash 重新执行脚本..."
            exec bash "$0" "$@"
        else
            echo "❌ 无法安装 bash，请手动执行: apk add bash && bash $0"
            exit 1
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu 系统
        if ! command -v bash >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y bash >/dev/null 2>&1
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
TPROXY_MARK=0x2333
TABLE_ID=100
DOCKER_PORT=9277

# --- 作者信息 ---
AUTHOR_NAME="shangkouyou Duang Scu"
AUTHOR_WECHAT="shangkouyou"
AUTHOR_EMAIL="shangkouyou@gmail.com"
AFF_URL="https://aff.scu.indevs.in/"

# !! 修复点：定义一个不与内核目标冲突的自定义链名称
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
if command -v apt >/dev/null 2>&1; then
  PKG_INSTALL="apt install -y"
  PKG_UPDATE="apt update -y"
elif command -v apk >/dev/null 2>&1; then
  PKG_INSTALL="apk add"
  PKG_UPDATE="apk update"
elif command -v dnf >/dev/null 2>&1; then
  PKG_INSTALL="dnf install -y"
  PKG_UPDATE="dnf makecache"
elif command -v yum >/dev/null 2>&1; then
  PKG_INSTALL="yum install -y"
  PKG_UPDATE="yum makecache"
else
  echo "❌ 无法识别包管理器，请手动安装 iptables/iproute2/systemd" | tee -a "$LOG_FILE"
  exit 1
fi

# ---- 检查并安装依赖 ----
# Alpine 不需要 systemd，使用 OpenRC
MISSING_PKGS=()

# 检查 iptables
if ! command -v iptables >/dev/null 2>&1; then
  MISSING_PKGS+=("iptables")
fi

# 检查 iproute2 (通过 ip 命令)
if ! command -v ip >/dev/null 2>&1; then
  if [ "$OS_DIST" == "alpine" ]; then
    MISSING_PKGS+=("iproute2")
  else
    MISSING_PKGS+=("iproute2")
  fi
fi

# 对于非 Alpine 系统，检查 systemctl（但不强制安装 systemd，因为通常是系统核心组件）
if [ "$OS_DIST" != "alpine" ] && ! command -v systemctl >/dev/null 2>&1; then
  echo "[$(date '+%F %T')] ⚠️  警告：未检测到 systemctl，但 systemd 通常是系统核心组件，请手动安装" | tee -a "$LOG_FILE"
  echo "[$(date '+%F %T')] 💡 提示：如果确实需要安装 systemd，请根据您的发行版手动安装" | tee -a "$LOG_FILE"
fi

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  echo "[$(date '+%F %T')] 📦 检测到缺失依赖: ${MISSING_PKGS[*]}" | tee -a "$LOG_FILE"
  $PKG_UPDATE && $PKG_INSTALL "${MISSING_PKGS[@]}"
else
  echo "[$(date '+%F %T')] ✅ 所有依赖已安装" | tee -a "$LOG_FILE"
fi

# ---- 切换到 iptables-legacy (若存在) ----
# Debian 13 (Trixie) 默认使用 nftables，TProxy 必须用 legacy
# Alpine 默认使用 iptables-legacy，无需切换
if [ "$OS_DIST" != "alpine" ]; then
  if command -v update-alternatives >/dev/null 2>&1; then
    if command -v iptables-legacy >/dev/null 2>&1; then
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
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf && sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
echo "[$(date '+%F %T')] 🔧 已启用 IPv4 转发" | tee -a "$LOG_FILE"

# ---- 写入 IPv4 TProxy 脚本 ----
cat > "$TPROXY_SCRIPT" <<EOF
#!/bin/bash
# IPv4-only TProxy for sing-box (Gateway/PREROUTING Only)
# ** 修复：使用 $CUSTOM_CHAIN 代替 TPROXY 作为链名称 **
LOG_FILE="/var/log/tproxy.log"
TPROXY_PORT=$TPROXY_PORT
TPROXY_MARK=$TPROXY_MARK
TABLE_ID=$TABLE_ID
DOCKER_PORT=$DOCKER_PORT
CHAIN_NAME="$CUSTOM_CHAIN"

echo "[$(date '+%F %T')] 开始加载 IPv4 TProxy 规则 (链: \$CHAIN_NAME)..." | tee -a "\$LOG_FILE"

# 检测主网卡（兼容 BusyBox，不使用 -P 选项）
MAIN_IF=\$(ip -4 route show default 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print \$2}' | head -n1)
if [ -z "\$MAIN_IF" ]; then
    # 备用方法：获取第一个非 lo 的网卡
    MAIN_IF=\$(ip -4 link show | grep -E '^[0-9]+:' | grep -v 'lo:' | head -n1 | awk -F': ' '{print \$2}' | awk '{print \$1}')
fi

# 检测主网卡 IP
if [ -n "\$MAIN_IF" ]; then
    MAIN_IP=\$(ip -4 addr show "\$MAIN_IF" 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1 | head -n1)
else
    MAIN_IP=""
fi

if [ -n "\$MAIN_IF" ] && [ -n "\$MAIN_IP" ]; then
    echo "检测到主网卡: \$MAIN_IF (\$MAIN_IP)" | tee -a "\$LOG_FILE"
else
    echo "⚠️  未能检测到主网卡，将跳过服务器 IP 豁免规则" | tee -a "\$LOG_FILE"
fi

# ---- 安全清理旧规则 ----
# 清理跳转规则
iptables -t mangle -D PREROUTING -j \$CHAIN_NAME 2>/dev/null || true
# 清空并删除旧链
iptables -t mangle -F \$CHAIN_NAME 2>/dev/null || true
iptables -t mangle -X \$CHAIN_NAME 2>/dev/null || true
# 清理策略路由
ip rule del fwmark \$TPROXY_MARK table \$TABLE_ID 2>/dev/null || true
ip route flush table \$TABLE_ID 2>/dev/null || true

# ---- 创建新链 ----
iptables -t mangle -N \$CHAIN_NAME

# ---- 规则详情 ----

# 1. 豁免本地、局域网、Docker 订阅端口 9277
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 255.255.255.255; do
  iptables -t mangle -A \$CHAIN_NAME -d \$net -j RETURN
done
# 豁免服务器本身的 IP，防止来自局域网的回环
#iptables -t mangle -A \$CHAIN_NAME -d \$MAIN_IP -j RETURN

iptables -t mangle -A \$CHAIN_NAME -p tcp --dport \$DOCKER_PORT -j RETURN
iptables -t mangle -A \$CHAIN_NAME -p udp --dport \$DOCKER_PORT -j RETURN

# 2. 添加 TProxy 转发 (!! 重点：-j TPROXY 是指内核的 *目标* !!)
# 注意：mangle 表不支持 REJECT，如果需要阻止 UDP 443，应该在 filter 表中处理
# 这里直接转发所有 TCP 和 UDP 流量到 TProxy
iptables -t mangle -A \$CHAIN_NAME -p tcp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$TPROXY_MARK
iptables -t mangle -A \$CHAIN_NAME -p udp -j TPROXY --on-port \$TPROXY_PORT --tproxy-mark \$TPROXY_MARK

# 3. Hook 链 (!! 重点：跳转到我们的 *自定义链* !!)
iptables -t mangle -I PREROUTING -j \$CHAIN_NAME

# 4. 策略路由
ip rule add fwmark \$TPROXY_MARK table \$TABLE_ID
ip route add local default dev lo table \$TABLE_ID

echo "[$(date '+%F %T')] ✅ IPv4 TProxy 规则加载完成 (链: \$CHAIN_NAME)" | tee -a "\$LOG_FILE"
EOF

chmod +x "$TPROXY_SCRIPT"
echo "[$(date '+%F %T')] ✅ 写入转发脚本到 $TPROXY_SCRIPT" | tee -a "$LOG_FILE"

# ---- 创建服务（根据系统类型） ----
if [ "$OS_DIST" == "alpine" ]; then
  # Alpine 使用 OpenRC
  echo "[$(date '+%F %T')] 🔧 正在创建 OpenRC 服务..." | tee -a "$LOG_FILE"
  cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
# Sing-box IPv4 TProxy Redirect Service (Gateway Mode)
description="Sing-box IPv4 TProxy Redirect Service"
command="$TPROXY_SCRIPT"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/tproxy-service.log"
error_log="/var/log/tproxy-service.log"

depend() {
    need net
    after firewall
    before local
}

start() {
    ebegin "Starting TProxy service"
    # 等待网络就绪
    sleep 30
    if \$command; then
        eend 0
    else
        eend 1
    fi
}

stop() {
    ebegin "Stopping TProxy service"
    # TProxy 是 oneshot 类型，无需停止操作
    eend 0
}
EOF
  chmod +x "$SERVICE_FILE"
  echo "[$(date '+%F %T')] ✅ 已创建 OpenRC 服务文件: $SERVICE_FILE" | tee -a "$LOG_FILE"
  
  # 启用并启动服务
  rc-update add tproxy default 2>/dev/null || true
  rc-service tproxy start
  
  # 检查服务状态
  sleep 2
  if rc-service tproxy status >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] ✅ 已创建并成功启动 OpenRC 服务 tproxy" | tee -a "$LOG_FILE"
  else
    echo "[$(date '+%F %T')] ⚠️  服务 tproxy 可能未完全启动，请检查日志: /var/log/tproxy-service.log" | tee -a "$LOG_FILE"
    echo "[$(date '+%F %T')] 💡 提示：可以手动执行 'rc-service tproxy start' 启动服务" | tee -a "$LOG_FILE"
  fi
else
  # 其他系统使用 systemd
  echo "[$(date '+%F %T')] 🔧 正在创建 systemd 服务..." | tee -a "$LOG_FILE"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box IPv4 TProxy Redirect Service (Gateway Mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 30
ExecStart=$TPROXY_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

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
# !! 修复点：验证我们正确的自定义链
iptables -t mangle -L $CUSTOM_CHAIN -v -n | tee -a "$LOG_FILE"
ip rule show | tee -a "$LOG_FILE"
ip route show table 100 | tee -a "$LOG_FILE"

echo "[$(date '+%F %T')] 🎉 IPv4 TProxy 已配置完成 (仅网关模式)！" | tee -a "$LOG_FILE"
echo "日志文件: $LOG_FILE 和 /var/log/tproxy.log"
if [ "$OS_DIST" == "alpine" ]; then
  echo "✅ 服务管理命令:"
  echo "   - 启动: rc-service tproxy start"
  echo "   - 停止: rc-service tproxy stop"
  echo "   - 状态: rc-service tproxy status"
  echo "   - 日志: tail -f /var/log/tproxy-service.log"
else
  echo "✅ 服务管理命令:"
  echo "   - 启动: systemctl start tproxy.service"
  echo "   - 停止: systemctl stop tproxy.service"
  echo "   - 状态: systemctl status tproxy.service"
  echo "   - 日志: journalctl -u tproxy.service"
fi
echo "✅ 执行过程中遇到的任何问题都可以联系我。"
echo "✅ 宿主机流量不会被代理。"
