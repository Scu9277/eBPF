cat << 'EOF' > pve-nic-fix.sh
#!/bin/bash

# 1. 自动获取物理网卡名称 (排除 lo, wlan 和 虚拟网桥)
NIC_NAME=$(ip -o link show | awk -F': ' '$2 !~ /lo|vmbr|wlp|tap|fwbr/ {print $2; exit}')

if [ -z "$NIC_NAME" ]; then
    echo "错误: 未能自动识别到物理网卡，请检查网络设置。"
    exit 1
fi

echo "检测到物理网卡: $NIC_NAME"

# 2. 安装必要工具
echo "正在安装 ethtool..."
apt-get update && apt-get install -y ethtool

# 3. 立即应用 ethtool 优化 (不重启立即生效)
echo "正在应用 ethtool 优化参数..."
ethtool -K $NIC_NAME gso off gro off tso off
ethtool --set-eee $NIC_NAME eee off

# 4. 修改 /etc/network/interfaces 实现持久化
# 检查是否已经存在配置，避免重复添加
if ! grep -q "ethtool -K $NIC_NAME" /etc/network/interfaces; then
    echo "正在将配置写入 /etc/network/interfaces..."
    # 在网卡定义下方插入 post-up 脚本
    sed -i "/iface $NIC_NAME inet manual/a \    post-up /usr/sbin/ethtool -K $NIC_NAME gso off gro off tso off\n    post-up /usr/sbin/ethtool --set-eee $NIC_NAME eee off" /etc/network/interfaces
fi

# 5. 修改 GRUB 优化内核参数
echo "正在优化内核 GRUB 参数..."
GRUB_FILE="/etc/default/grub"
# 注入针对 Intel 网卡的稳定参数
OPT_PARAMS="intel_idle.max_cstate=1 pcie_aspm=off e1000e.IntMode=1,1 e1000e.SmartPowerDownEnable=0"

if ! grep -q "pcie_aspm=off" "$GRUB_FILE"; then
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$OPT_PARAMS /" "$GRUB_FILE"
    update-grub
    echo "GRUB 配置已更新。"
else
    echo "GRUB 配置似乎已存在，跳过修改。"
fi

echo "------------------------------------------------"
echo "全部优化已完成！"
echo "物理网卡: $NIC_NAME 已关闭 Offload 和 EEE 节能。"
echo "内核参数已禁用 ASPM 节能。建议重启系统以确保所有更改生效。"
echo "------------------------------------------------"
EOF

# 给脚本执行权限
chmod +x pve-nic-fix.sh
