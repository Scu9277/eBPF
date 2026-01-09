#!/bin/bash
set -e

# ==========================================
# eBPF TProxy Agent Installer
# Author: shangkouyou Duang Scu
# WeChat: shangkouyou
# Email:  shangkouyou@gmail.com
# ==========================================

# Configuration
# Set to 'true' to force using the proxy, 'false' to force direct connection, 
# or 'auto' to detect based on timezone/locale (simple heuristic).
USE_CN_PROXY="auto" 
CN_PROXY_URL="https://ghfast.tproxy"
BINARY_URL="https://github.com/Scu9277/eBPF/releases/download/0.1/tproxy-agent"
SERVICE_URL="https://github.com/Scu9277/eBPF/releases/download/0.1/tproxy-agent.service"
INSTALL_DIR="/etc/eBPF"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'

log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

print_header() {
    echo -e "${CYAN}"
    echo "============================================================"
    echo "        eBPF TProxy Agent Installer                         "
    echo "        Author:  shangkouyou Duang Scu                      "
    echo "        WeChat:  shangkouyou                                "
    echo "        Email:   shangkouyou@gmail.com                      "
    echo "============================================================"
    echo -e "${NC}"
}

# Check Root
if [ "$EUID" -ne 0 ]; then
  log_error "Please run as root"
  exit 1
fi

print_header

# Region Detection Logic
if [ "$USE_CN_PROXY" = "auto" ]; then
    log_info "Detecting network region..."
    if curl -s --connect-timeout 3 https://github.com > /dev/null; then
        USE_CN_PROXY="false"
        log_info "GitHub is accessible. Using direct connection."
    else
        USE_CN_PROXY="true"
        log_info "GitHub seems slow or inaccessible. Switching to CN Proxy."
    fi
fi

if [ "$USE_CN_PROXY" = "true" ]; then
    # Prepend Proxy URL
    BINARY_URL="${CN_PROXY_URL}/${BINARY_URL}"
    SERVICE_URL="${CN_PROXY_URL}/${SERVICE_URL}"
    log_info "Using Mirror: $CN_PROXY_URL"
fi

# 1. Install Dependencies
log_info "Step 1/7: Installing dependencies..."
if command -v apt-get >/dev/null; then
    apt-get update -y
    apt-get install -y wget curl ca-certificates procps iproute2
elif command -v yum >/dev/null; then
    yum install -y wget curl ca-certificates procps iproute
else
    log_warn "Package manager not found. Assuming dependencies are installed."
fi

# 2. Enable IP Forwarding (Permanent)
log_info "Step 2/7: Enabling IP Forwarding..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
else
    # Ensure it's not commented out
    sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
fi
# Apply immediately
sysctl -p >/dev/null 2>&1 || true
# Double check dynamic
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# 3. Create Install Directory
log_info "Step 3/7: Creating directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 4. Download Binary
log_info "Step 4/7: Downloading binary..."
log_info "Src: $BINARY_URL"
curl -L -o "$INSTALL_DIR/tproxy-agent" "$BINARY_URL"
chmod +x "$INSTALL_DIR/tproxy-agent"

# 5. Download Service
log_info "Step 5/7: Downloading service file..."
curl -L -o "/etc/systemd/system/tproxy-agent.service" "$SERVICE_URL"

# 6. Fix Service Path
log_info "Step 6/7: Configuring Service Path..."
sed -i "s|ExecStart=.*|ExecStart=$INSTALL_DIR/tproxy-agent|" /etc/systemd/system/tproxy-agent.service

# 7. Start Service
log_info "Step 7/7: Starting Service..."
systemctl daemon-reload
systemctl enable tproxy-agent
systemctl restart tproxy-agent

# 8. Status Check & Summary
log_info "Installation Complete. Checking Status..."
sleep 2

SERVICE_STATUS=$(systemctl is-active tproxy-agent)
SERVICE_LOGS=$(journalctl -u tproxy-agent -n 5 --no-pager)

echo -e "${CYAN}"
echo "============================================================"
echo "                INSTALLATION SUMMARY                        "
echo "============================================================"
echo " Service Name : tproxy-agent"
echo " Status       : $SERVICE_STATUS"
echo " Install Path : $INSTALL_DIR/tproxy-agent"
echo " Log Command  : journalctl -u tproxy-agent -f"
echo "------------------------------------------------------------"
echo " Recent Logs:"
echo "$SERVICE_LOGS"
echo "============================================================"
echo -e "${NC}"

if [ "$SERVICE_STATUS" != "active" ]; then
    log_error "Service is NOT active. Please check logs."
    exit 1
else
    log_info "eBPF TProxy Agent deployed successfully!"
fi
