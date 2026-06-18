#!/bin/sh
set -eu
G=$(printf '\033[0;32m')
Y=$(printf '\033[1;33m')
R=$(printf '\033[0;31m')
N=$(printf '\033[0m')
info() { echo "${G}[INFO]${N} $*" >&2; }
warn() { echo "${Y}[WARN]${N} $*" >&2; }
err()  { echo "${R}[ERR]${N} $*" >&2; }
MIRROR="${MIRROR:-https://ghfast.top}"
PORT="${PORT:-80}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"

detect_version() {
    # First try via mirror, then try direct GitHub API
    for _src in "${MIRROR}/api.github.com" "https://api.github.com"; do
        _api="${_src}/repos/daeuniverse/daed/releases?per_page=5"
        _ver=$(curl -sL --connect-timeout 8 "$_api" 2>/dev/null | \
            grep -o '"tag_name": *"v[0-9]*\.[0-9]*\.[0-9]*"' | \
            head -1 | sed 's/.*"v\(.*\)"/\1/')
        if [ -n "${_ver}" ]; then
            info "detected latest version: v${_ver}"
            echo "${_ver}"
            return 0
        fi
    done
    warn "cannot detect latest version, falling back to 1.27.0"
    echo 1.27.0
    return 0
}
VERSION="${VERSION:-$(detect_version)}"
case "$VERSION" in v*) VERSION="${VERSION#v}";; esac
URL="${MIRROR}/github.com/daeuniverse/daed/releases/download/v${VERSION}/daed-linux-x86_64.zip"
TMP=/tmp/daed_install_$$
[ "$(id -u)" -ne 0 ] && { err "please run as root"; exit 1; }
[ "$(uname -m)" != "x86_64" ] && { err "x86_64 only"; exit 1; }
info checking eBPF...
KR=$(uname -r); _ok=1
for o in BPF DEBUG_INFO_BTF KPROBES BPF_EVENTS; do
    F=0
    [ -f /proc/config.gz ] && zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_${o}=y" && F=1
    [ -f "/boot/config-${KR}" ] && grep -q "CONFIG_${o}=y" "/boot/config-${KR}" && F=1
    [ $F = 0 ] && { err "missing: $o"; _ok=0; }
done; [ $_ok = 0 ] && exit 1; info eBPF OK
info detecting network interface...
DEFAULT_IFACE=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}' | awk '{print $1}')
if [ -z "$DEFAULT_IFACE" ]; then
    err "no physical network interface found"
    exit 1
fi
info "detected interface: $DEFAULT_IFACE"
info installing deps...
apk update >/dev/null || { err "apk update failed, check network/mirrors"; exit 1; }
apk add --no-cache curl unzip ca-certificates nftables >/dev/null || { err "failed to install dependencies"; exit 1; }
rc-update show | grep -q cgroups || rc-update add cgroups boot
rc-service cgroups start 2>/dev/null || true
info "downloading daed v${VERSION}..."
mkdir -p "$TMP"
curl -fsSL -o "${TMP}/daed.zip" "$URL" || { err "download failed"; exit 1; }
unzip -qo "${TMP}/daed.zip" -d "${TMP}/x"
BIN=$(find "${TMP}/x" -type f \( -name daed -o -name "daed-*" \) | head -1)
[ -z "$BIN" ] && { err "binary not found in zip"; exit 1; }
install -m 755 "$BIN" /usr/local/bin/daed
mkdir -p /etc/daed
for f in geoip.dat geosite.dat; do
    S=$(find "${TMP}/x" -name "$f" | head -1)
    if [ -n "$S" ]; then
        cp "$S" "/etc/daed/$f"
    else
        warn "$f not found in zip, skipping"
    fi
done
rm -r "$TMP" 2>/dev/null || true
info binary installed
if [ ! -f /etc/sysctl.d/60-ip-forward.conf ]; then
    cat > /etc/sysctl.d/60-ip-forward.conf << EOFS
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOFS
    sysctl -p /etc/sysctl.d/60-ip-forward.conf >/dev/null 2>&1
    info IP forwarding enabled
fi

if [ ! -f /etc/daed/config.dae ]; then
    cat > /etc/daed/config.dae << DAEEOF
global {
  tproxy_port: 12345
  tproxy_port_protect: true
  lan_interface: ${DEFAULT_IFACE}
  wan_interface: auto
  auto_config_kernel_parameter: true
  log_level: info
}
dns {
  upstream { googledns: 'tcp+udp://8.8.8.8:53'; alidns: 'udp://223.5.5.5:53' }
  routing { request { match: qname(geosite:cn) -> alidns; fallback: googledns } }
}
group { proxy { filter: subtag(proxy) } }
routing { pbr { dns: alidns; lan: dip(geoip:private) -> direct; must_direct: dip(geoip:cn) -> direct; default: proxy } }
DAEEOF
    info default config written
fi

if [ ! -f /etc/init.d/daed ]; then
    cat > /etc/init.d/daed << SVC
#!/sbin/openrc-run
description="daed proxy service"
command="/usr/local/bin/daed"
command_args="run -c /etc/daed/ -l ${LISTEN_ADDR}:${PORT}"
command_user="root"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { need net; after cgroups; }
start_pre() {
    mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
    [ -d /sys/fs/bpf/daed ] || mkdir -p /sys/fs/bpf/daed
    mountpoint -q /sys/fs/cgroup/unified || {
        mkdir -p /sys/fs/cgroup/unified
        mount -t cgroup2 none /sys/fs/cgroup/unified 2>/dev/null || true
    }
    find /sys/fs/bpf/daed -mindepth 1 -delete 2>/dev/null || true
    return 0
}
stop_post() {
    find /sys/fs/bpf/daed -mindepth 1 -delete 2>/dev/null || true
    return 0
}
SVC
    chmod +x /etc/init.d/daed; info service created
fi

rc-update show | grep -q daed || rc-update add daed default
info starting daed...
rc-service daed restart 2>/dev/null || rc-service daed start
sleep 2
pgrep -f daed > /dev/null 2>&1 && info daed running || { err start failed; exit 1; }
C=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:${PORT}/" 2>/dev/null || echo 000)
echo
echo ==============================
echo daed v${VERSION} installed!
echo Web UI: http://${LISTEN_ADDR}:${PORT}/
echo Manage: rc-service daed
echo Clients: gateway=$(ip -4 addr show ${DEFAULT_IFACE} 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1) dns=8.8.8.8
echo ==============================
