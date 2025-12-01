#!/usr/bin/env bash
#
# 启动多个 iperf3 客户端，每个连接对应端口的服务端并绑定独立 CPU 核，可选绑定本地源 IP。
#
# 用法:
#   ./iperf_client.sh -n <实例数量> -H <server_ip或域名> [-b <基准端口>] [-t <持续秒>] [-R] [-i <间隔>] [-B <bind_ip>] [--skip-ip-check]
#
# 参数说明:
#   -n                客户端实例数量（必须）
#   -H                服务器地址（必须）
#   -b                基准端口，默认 5201；第 i 个客户端连接端口 (base_port + i)
#   -t                测试持续时间（秒），默认 10
#   -R                反向测试 (server -> client)；添加 iperf3 -R
#   -i                统计输出间隔，默认 1
#   -B <bind_ip>      绑定本地源 IP（iperf3 -B），用于多网卡或特定路由选择
#   --skip-ip-check   跳过对 -B 指定 IP 是否存在于本机的校验
#
# 示例:
#   ./iperf_client.sh -n 4 -H 192.168.1.10
#   ./iperf_client.sh -n 8 -H server.example.com -b 6000 -t 30 -B 192.168.10.5
#
set -euo pipefail

BASE_PORT=5201
COUNT=
SERVER_HOST=
DURATION=10
REVERSE=0
INTERVAL=1
BIND_IP=
SKIP_CHECK=0
PIDS=()

usage() {
  sed -n '2,70p' "$0"
  exit 1
}

log() { echo "[CLIENT] $*"; }

cleanup() {
  if [[ ${#PIDS[@]} -gt 0 ]]; then
    log "正在结束所有 iperf3 客户端实例..."
    for pid in "${PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" || true
      fi
    done
    wait || true
    log "已清理完成。"
  fi
}

trap cleanup EXIT INT TERM

# 处理长选项 --skip-ip-check
LONG_OPTS=()
for arg in "$@"; do
  case "$arg" in
    --skip-ip-check) SKIP_CHECK=1 ;;
    *) LONG_OPTS+=("$arg") ;;
  esac
done
set -- "${LONG_OPTS[@]}"

while getopts ":n:H:b:t:Ri:B:" opt; do
  case $opt in
    n) COUNT=$OPTARG ;;
    H) SERVER_HOST=$OPTARG ;;
    b) BASE_PORT=$OPTARG ;;
    t) DURATION=$OPTARG ;;
    R) REVERSE=1 ;;
    i) INTERVAL=$OPTARG ;;
    B) BIND_IP=$OPTARG ;;
    *) usage ;;
  esac
done

if [[ -z "${COUNT:-}" || -z "${SERVER_HOST:-}" ]]; then
  log "错误: 必须指定 -n 和 -H"
  usage
fi

if ! command -v iperf3 >/dev/null 2>&1; then
  log "错误: 未找到 iperf3，请先安装。"
  exit 2
fi

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || (( COUNT <= 0 )); then
  log "错误: -n 必须为正整数"
  exit 3
fi

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || (( DURATION <= 0 )); then
  log "错误: -t 必须为正整数"
  exit 4
fi

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || (( INTERVAL <= 0 )); then
  log "错误: -i 必须为正整数"
  exit 5
fi

CORES=$(nproc --all)
if (( COUNT > CORES )); then
  log "错误: 请求的客户端数量 ($COUNT) 大于可用 CPU 核数 ($CORES)，无法保证唯一绑定。"
  exit 6
fi

if [[ -n "$BIND_IP" && $SKIP_CHECK -eq 0 ]]; then
  if ! ip addr show | grep -Eo 'inet ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)' | awk '{print $2}' | grep -Fx "$BIND_IP" >/dev/null; then
    log "错误: 指定的绑定 IP $BIND_IP 不存在于本机接口。可使用 --skip-ip-check 跳过。"
    exit 7
  fi
fi

EXTRA_OPTS=()
if (( REVERSE == 1 )); then
  EXTRA_OPTS+=("-R")
fi
EXTRA_OPTS+=("-i" "$INTERVAL")
[[ -n "$BIND_IP" ]] && EXTRA_OPTS+=(-B "$BIND_IP")

log "启动 $COUNT 个 iperf3 客户端，目标服务器: $SERVER_HOST，端口从 $BASE_PORT 开始，持续 $DURATION 秒。"
[[ -n "$BIND_IP" ]] && log "使用本地绑定 IP: $BIND_IP" || log "未指定本地绑定 IP，使用默认出接口。"

# 新增：根据实例数量创建日志目录，如 logs/cores_4
LOG_DIR="logs/cores_${COUNT}"
mkdir -p "$LOG_DIR"
log "日志目录: $LOG_DIR"

for (( i=0; i<COUNT; i++ )); do
  PORT=$((BASE_PORT + i))
  CORE=$i
  LOG_FILE="$LOG_DIR/iperf_client_${PORT}.log"
  CMD=(iperf3 -c "$SERVER_HOST" -p "$PORT" -t "$DURATION" "${EXTRA_OPTS[@]}")
  ( taskset -c "$CORE" "${CMD[@]}" >"$LOG_FILE" 2>&1 & echo $! ) &
  PID=$!
  PIDS+=("$PID")
  printf "%-8s %-12s %-8s %-6s %s\n" "实例$i" "端口:$PORT" "CPU:$CORE" "PID:$PID" "日志:$LOG_FILE"
done

log "所有客户端已启动，等待测试完成或按 Ctrl+C 停止。"
wait
log "测试结束，查看日志文件: $LOG_DIR/iperf_client_<端口>.log"