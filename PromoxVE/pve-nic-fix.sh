cat << 'EOF' > pve_nic_auto_fix.sh
#!/bin/bash

###########################################################
#  项目: PVE 物理网卡稳定性全自动加固脚本
#  作者: shangkouyou Duang Scu
#  微信: shangkouyou
#  邮箱: shangkouyou@gmail.com
#  功能: 解决联想/各类小主机 PVE 网卡频繁断连、需拔插恢复的问题
###########################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}====================================================${NC}"
echo -e "${GREEN}    PVE Network Fixer - By Scu (shangkouyou)${NC}"
echo -e "${BLUE}====================================================${NC}"

# 1. 权限与环境检查
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请以 root 权限运行此脚本。${NC}"
    exit 1
fi

# 2. 自动安装依赖
echo -e "${BLUE}[1/5] 检查依赖工具...${NC}"
if ! command -v ethtool &> /dev/null; then
    echo "正在安装 ethtool..."
    apt-get update && apt-get install -y ethtool
else
    echo "ethtool 已安装。"
fi

# 3. 自动识别物理网卡
echo -e "${BLUE}[2/5] 正在扫描物理网卡...${NC}"
# 排除虚拟接口、无线网卡
PHYSICAL_NICS=$(ls /sys/class/net | grep -vE 'lo|vmbr|tap|fwbr|veth|wlp|wlan|docker')

if [ -z "$PHYSICAL_NICS" ]; then
    echo -e "${RED}错误: 未能识别到物理网卡，请检查硬件连接。${NC}"
    exit 1
fi

# 4. 循环处理每个物理网卡
echo -e "${BLUE}[3/5] 正在配置网卡参数...${NC}"
IFACE_FILE="/etc/network/interfaces"
cp $IFACE_FILE "${IFACE_FILE}.bak_$(date +%F_%T)"

for NIC in $PHYSICAL_NICS; do
    echo -e "发现目标网卡: ${GREEN}$NIC${NC}"
    
    # 立即应用优化
    ethtool -K $NIC gso off gro off tso off &> /dev/null
    ethtool --set-eee $NIC eee off &> /dev/null
    
    # 写入配置文件 (防止重复写入)
    if grep -q "iface $NIC" "$IFACE_FILE"; then
        if ! grep -q "ethtool -K $NIC" "$IFACE_FILE"; then
            echo "写入持久化配置到 $IFACE_FILE..."
            # 在网卡定义行后插入
            sed -i "/iface $NIC inet manual/a \    # 稳定性加固: 禁用Offload和EEE\n    post-up /usr/sbin/ethtool -K $NIC gso off gro off tso off\n    post-up /usr/sbin/ethtool --set-eee $NIC eee off" "$IFACE_FILE"
        else
            echo "持久化配置已存在，跳过。"
        fi
    fi
done

# 5. 优化内核 GRUB 参数
echo -e "${BLUE}[4/5] 正在优化内核 GRUB 参数...${NC}"
GRUB_FILE="/etc/default/grub"
# 判断是否为 Intel 网卡，如果是，额外增加 e1000e 参数
EXTRA_PARAMS="pcie_aspm=off intel_idle.max_cstate=1"
if lspci | grep -qi "Ethernet.*Intel"; then
    echo "检测到 Intel 物理网卡，注入专有驱动优化参数。"
    EXTRA_PARAMS="$EXTRA_PARAMS e1000e.IntMode=1,1 e1000e.SmartPowerDownEnable=0"
fi

if ! grep -q "pcie_aspm=off" "$GRUB_FILE"; then
    cp "$GRUB_FILE" "${GRUB_FILE}.bak"
    # 在 quiet 后面追加参数
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet $EXTRA_PARAMS/" "$GRUB_FILE"
    update-grub
    echo -e "${GREEN}GRUB 内核参数更新完毕。${NC}"
else
    echo "GRUB 配置似乎已经优化过，无需重复执行。"
fi

# 6. 完成提示
echo -e "${BLUE}[5/5] 任务完成！${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "网卡稳定性优化已成功应用。"
echo -e "作者: ${BLUE}Scu 联合x Duang${NC}"
echo -e "联系: ${BLUE}WeChat: shangkouyou / Email: shangkouyou@gmail.com${NC}"
echo -e "请运行 ${RED}reboot${NC} 命令重启系统使所有配置生效。"
echo -e "${GREEN}====================================================${NC}"
EOF

chmod +x pve_nic_auto_fix.sh
