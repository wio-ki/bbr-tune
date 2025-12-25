#!/usr/bin/env bash
# ==========================================================
# Sing-box Proxy VPS Network Stack & BBR Tuning Script
# Final Version with Safety Guards
# Target: Sing-box / QUIC / Hysteria2 / TUIC / 高并发代理
# ==========================================================

set -e

# ===================== 颜色定义 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ===================== 0. Root 检查 =====================
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}❌ 请使用 root 用户运行该脚本${NC}"
  exit 1
fi

echo "================ Sing-box 代理 VPS BBR 调优 ================"
echo

# ===================== 1. 系统能力探测 =====================
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_MB=$((MEM_KB / 1024))
CPU_CORES=$(nproc)

echo -e "${GREEN}系统信息探测：${NC}"
echo "  内存        : ${MEM_MB} MB"
echo "  CPU 核心    : ${CPU_CORES}"
echo

# ===================== 2. 用户交互式输入 =====================
read -rp "请输入通过 iperf3 测得的【最大缓冲区】(字节，如 67108864): " MAX_BUF
if ! [[ "$MAX_BUF" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}❌ 输入必须为纯数字（单位：字节）${NC}"
  exit 1
fi

# ---------- 内存保护阀（防 OOM） ----------
MAX_SAFE_BUF=$((MEM_MB * 1024 * 1024 / 4))   # ≤ 总内存 25%
if (( MAX_BUF > MAX_SAFE_BUF )); then
  echo -e "${YELLOW}⚠ 最大缓冲区超过系统内存的 25%${NC}"
  echo -e "${YELLOW}⚠ 已自动限制为 ${MAX_SAFE_BUF} bytes${NC}"
  MAX_BUF=$MAX_SAFE_BUF
fi

# ===================== 代理类型 =====================
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

# ===================== 3. 参数自动推导 =====================
# 文件描述符
if (( MEM_MB <= 1024 )); then
  FILE_MAX=262144
elif (( MEM_MB <= 4096 )); then
  FILE_MAX=524288
else
  FILE_MAX=1000000
fi

# 默认缓冲
if (( MEM_MB <= 512 )); then
  BUF_DEFAULT=65536
elif (( MEM_MB <= 2048 )); then
  BUF_DEFAULT=131072
else
  BUF_DEFAULT=262144
fi

# 队列
SOMAXCONN=$((CPU_CORES * 8192))
[[ $SOMAXCONN -gt 65535 ]] && SOMAXCONN=65535

TCP_SYN_BACKLOG=$((CPU_CORES * 4096))
[[ $TCP_SYN_BACKLOG -gt 32768 ]] && TCP_SYN_BACKLOG=32768

NETDEV_BACKLOG=$((CPU_CORES * 4096))
[[ $NETDEV_BACKLOG -gt 32768 ]] && NETDEV_BACKLOG=32768

# TIME-WAIT
TCP_MAX_TW=$((MEM_MB * 80))
[[ $TCP_MAX_TW -gt 200000 ]] && TCP_MAX_TW=200000
[[ $TCP_MAX_TW -lt 10000 ]] && TCP_MAX_TW=10000

# FIN / keepalive
if [[ "$PROXY_TYPE" == "1" ]]; then
  TCP_FIN_TIMEOUT=15
  TCP_KEEPALIVE_TIME=300
else
  TCP_FIN_TIMEOUT=30
  TCP_KEEPALIVE_TIME=120
fi

# UDP
if [[ "$USE_UDP_PROTO" =~ ^[Yy]$ ]]; then
  UDP_MIN_BUF=131072
else
  UDP_MIN_BUF=16384
fi

UDP_MEM_LOW=$((MEM_MB * 1024 / 4 / 6))
UDP_MEM_PRESSURE=$((MEM_MB * 1024 / 4 / 3))
UDP_MEM_HIGH=$((MEM_MB * 1024 / 4 / 2))

# netdev budget
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

# ===================== 4. BBR 探测 =====================
if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr2; then
  BBR_ALGO=bbr2
else
  BBR_ALGO=bbr
fi

# ===================== 5. 备份配置 =====================
[[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%F_%T)

# ===================== 6. 写入 sysctl =====================
cat > /etc/sysctl.conf << EOF
fs.file-max = ${FILE_MAX}

net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
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

# ---------- 关键修改点 ----------
# loose mode，代理 / TProxy / 多出口友好
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# 安全基础
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF

# ===================== 7. 应用 =====================
sysctl -p
sysctl --system

echo
echo -e "${GREEN}✅ Sing-box 代理 VPS BBR 调优完成${NC}"
echo -e "${YELLOW}建议立即重启 VPS 以确保完全生效${NC}"
