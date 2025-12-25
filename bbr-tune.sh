#!/usr/bin/env bash
# ==========================================================
# Sing-box Proxy VPS Network Stack & BBR Tuning Script
# Fixed Line Endings Version
# Target: Sing-box / QUIC / Hysteria2 / TUIC / 高并发代理
# ==========================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}❌ 请使用 root 用户运行该脚本${NC}"
  exit 1
fi

echo "================ Sing-box 代理 VPS BBR 调优 ================"
echo

MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_MB=$((MEM_KB / 1024))
CPU_CORES=$(nproc)

echo -e "${GREEN}系统信息探测：${NC}"
echo "  内存        : ${MEM_MB} MB"
echo "  CPU 核心    : ${CPU_CORES}"
echo

read -rp "请输入通过 iperf3 测得的【最大缓冲区】(字节，如 67108864): " MAX_BUF
if ! [[ "$MAX_BUF" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}❌ 输入必须为纯数字（单位：字节）${NC}"
  exit 1
fi

MAX_SAFE_BUF=$((MEM_MB * 1024 * 1024 / 4))
if (( MAX_BUF > MAX_SAFE_BUF )); then
  echo -e "${YELLOW}⚠ 最大缓冲区超过系统内存的 25%${NC}"
  echo -e "${YELLOW}⚠ 已自动限制为 ${MAX_SAFE_BUF} bytes${NC}"
  MAX_BUF=$MAX_SAFE_BUF
fi

echo
echo "VPS 主要用途："
echo "  [1] 短连接代理（常规翻墙、多用户共享）"
echo "  [2] 长连接代理（流媒体、WebSocket、游戏）"
read -rp "请选择 [1-2] (默认1): " PROXY_TYPE
PROXY_TYPE=${PROXY_TYPE:-1}

read -rp "是否使用 UDP 高速协议 (Hysteria2/TUIC/QUIC)? [y/N]: " USE_UDP_PROTO
USE_UDP_PROTO=${USE_UDP_PROTO:-N}

read -rp "VPS 出口带宽 (Mbps，如1000代表1Gbps，默认1000): " BANDWIDTH_MBPS
BANDWIDTH_MBPS=${BANDWIDTH_MBPS:-1000}

if (( MEM_MB <= 1024 )); then
  FILE_MAX=262144
elif (( MEM_MB <= 4096 )); then
  FILE_MAX=524288
else
  FILE_MAX=1000000
fi

if (( MEM_MB <= 512 )); then
  BUF_DEFAULT=65536
elif (( MEM_MB <= 2048 )); then
  BUF_DEFAULT=131072
else
  BUF_DEFAULT=262144
fi

SOMAXCONN=$((CPU_CORES * 8192))
[[ $SOMAXCONN -gt 65535 ]] && SOMAXCONN=65535

TCP_SYN_BACKLOG=$((CPU_CORES * 4096))
[[ $TCP_SYN_BACKLOG -gt 32768 ]] && TCP_SYN_BACKLOG=32768

NETDEV_BACKLOG=$((CPU_CORES * 4096))
[[ $NETDEV_BACKLOG -gt 32768 ]] && NETDEV_BACKLOG=32768

TCP_MAX_TW=$((MEM_MB * 80))
[[ $TCP_MAX_TW -gt 200000 ]] && TCP_MAX_TW=200000
[[ $TCP_MAX_TW -lt 10000 ]] && TCP_MAX_TW=10000

if [[ "$PROXY_TYPE" == "1" ]]; then
  TCP_FIN_TIMEOUT=15
  TCP_KEEPALIVE_TIME=300
else
  TCP_FIN_TIMEOUT=30
  TCP_KEEPALIVE_TIME=120
fi

if [[ "$USE_UDP_PROTO" =~ ^[Yy]$ ]]; then
  UDP_MIN_BUF=131072
else
  UDP_MIN_BUF=16384
fi

UDP_MEM_LOW=$((MEM_MB * 1024 / 4 / 6))
UDP_MEM_PRESSURE=$((MEM_MB * 1024 / 4 / 3))
UDP_MEM_HIGH=$((MEM_MB * 1024 / 4 / 2))

if (( BANDWIDTH_MBPS >= 10000 )); then
  NETDEV_BUDGET=600
  NETDEV_BUDGET_USECS=2000
elif (( BANDWIDTH_MBPS >= 1000 )); then
  NETDEV_BUDGET=600
  NETDEV_BUDGET_USECS=8000
else
  NETDEV_BUDGET=300
  NETDEV_BUDGET_USECS=20000
fi

if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr2; then
  BBR_ALGO=bbr2
  echo -e "${GREEN}✓ 检测到 BBR v2${NC}"
else
  BBR_ALGO=bbr
  echo -e "${YELLOW}⚠ 使用 BBR v1${NC}"
fi

echo
echo -e "${GREEN}==================== 配置预览 ====================${NC}"
echo "文件描述符      : ${FILE_MAX}"
echo "默认缓冲区      : ${BUF_DEFAULT} bytes"
echo "最大缓冲区      : ${MAX_BUF} bytes"
echo "Listen 队列     : ${SOMAXCONN}"
echo "SYN 队列        : ${TCP_SYN_BACKLOG}"
echo "FIN 超时        : ${TCP_FIN_TIMEOUT} 秒"
echo "Keepalive       : ${TCP_KEEPALIVE_TIME} 秒"
echo "UDP 最小缓冲    : ${UDP_MIN_BUF} bytes"
echo "TIME-WAIT 上限  : ${TCP_MAX_TW}"
echo "BBR 算法        : ${BBR_ALGO}"
echo -e "${GREEN}=================================================${NC}"
echo

read -rp "确认应用以上配置？[Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

[[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s)

cat > /etc/sysctl.conf << EOF
fs.file-max = ${FILE_MAX}

net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.conf.all.route_localnet = 1

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = ${TCP_FIN_TIMEOUT}

net.ipv4.tcp_keepalive_time = ${TCP_KEEPALIVE_TIME}
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 2

net.core.somaxconn = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.ipv4.tcp_max_syn_backlog = ${TCP_SYN_BACKLOG}

net.ipv4.ip_local_port_range = 1024 65535

net.core.rmem_default = ${BUF_DEFAULT}
net.core.wmem_default = ${BUF_DEFAULT}
net.core.rmem_max = ${MAX_BUF}
net.core.wmem_max = ${MAX_BUF}

net.ipv4.tcp_rmem = 4096 87380 ${MAX_BUF}
net.ipv4.tcp_wmem = 4096 65536 ${MAX_BUF}

net.ipv4.udp_rmem_min = ${UDP_MIN_BUF}
net.ipv4.udp_wmem_min = ${UDP_MIN_BUF}
net.ipv4.udp_mem = ${UDP_MEM_LOW} ${UDP_MEM_PRESSURE} ${UDP_MEM_HIGH}

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${BBR_ALGO}

net.core.netdev_budget = ${NETDEV_BUDGET}
net.core.netdev_budget_usecs = ${NETDEV_BUDGET_USECS}

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = ${TCP_MAX_TW}

net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
EOF

cat > /etc/security/limits.conf << EOF
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF

if [[ -f /etc/systemd/system.conf ]]; then
  sed -i 's/^#\?DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' /etc/systemd/system.conf
  grep -q '^DefaultLimitNOFILE=' /etc/systemd/system.conf || echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
fi

echo
echo -e "${YELLOW}正在应用 sysctl 配置...${NC}"
sysctl -p
sysctl --system

echo
RPS_MASK=$(printf '%x' $(( (1 << CPU_CORES) - 1 )))
for iface in $(ls /sys/class/net/ | grep -vE '^(lo|docker|veth|br-|tun|tap)'); do
  [[ -d "/sys/class/net/$iface/queues" ]] || continue
  for rxq in /sys/class/net/$iface/queues/rx-*/rps_cpus; do
    [[ -f "$rxq" ]] && echo "$RPS_MASK" > "$rxq" 2>/dev/null
  done
done

cat > /root/verify_tuning.sh << 'VEREOF'
#!/bin/bash
echo "============ 网络调优验证 ============"
echo "BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "文件描述符: $(ulimit -n)"
echo "TCP连接数: $(ss -s | grep 'TCP:' | awk '{print $2}')"
echo "TIME-WAIT: $(ss -tan | grep -c TIME-WAIT || echo 0)"
echo "====================================="
VEREOF
chmod +x /root/verify_tuning.sh

echo
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}✅ Sing-box 代理 VPS 网络栈调优完成${NC}"
echo -e "${GREEN}====================================================${NC}"
echo
echo -e "${YELLOW}建议操作：${NC}"
echo "  1. 重启 VPS: reboot"
echo "  2. 验证配置: /root/verify_tuning.sh"
echo