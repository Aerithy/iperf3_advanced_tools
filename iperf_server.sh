#!/usr/bin/env bash
#
# 启动多个 iperf3 服务端，每个绑定不同端口与独立 CPU 核
#
# 用法:
#   ./iperf_server.sh -n <实例数量> [-b <基准端口>] [-d]
#
# 参数说明:
#   -n    启动的 iperf3 服务端数量（必须）
#   -b    基准端口，默认 5201；第 i 个实例使用端口 (base_port + i)
#   -d    后台运行（脚本不保持前台等待，直接退出）
#
# 示例:
#   ./iperf_server.sh -n 4
#   ./iperf_server.sh -n 8 -b 6000
#
set -euo pipefail

BASE_PORT=5201
COUNT=
DETACH=0
PIDS=()

usage() {
  sed -n '2,40p' "$0"
  exit 1
}

log() { echo "[SERVER] $*"; }

cleanup() {
  if [[ ${#PIDS[@]} -gt 0 ]]; then
    log "正在停止所有 iperf3 服务端实例..."
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

while getopts ":n:b:d" opt; do
  case $opt in
    n) COUNT=$OPTARG ;;
    b) BASE_PORT=$OPTARG ;;
    d) DETACH=1 ;;
    *) usage ;;
  esac
done

if [[ -z "${COUNT:-}" ]]; then
  log "错误: 必须指定 -n"
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

CORES=$(nproc --all)
if (( COUNT > CORES )); then
  log "错误: 请求的实例数 ($COUNT) 大于可用 CPU 核数 ($CORES)，无法保证唯一绑定。"
  exit 4
fi

log "启动 $COUNT 个 iperf3 服务端，从端口 $BASE_PORT 开始，绑定前 $COUNT 个 CPU 核。"

for (( i=0; i<COUNT; i++ )); do
  PORT=$((BASE_PORT + i))
  CORE=$i
  LOG_FILE="iperf_server_${PORT}.log"
  # 使用 taskset 绑定 CPU 核
  ( taskset -c "$CORE" iperf3 -s -p "$PORT" >/dev/null 2>"$LOG_FILE" & echo $! ) &
  PID=$!
  PIDS+=("$PID")
  printf "%-8s %-6s %-6s %s\n" "实例$i" "端口:$PORT" "CPU:$CORE" "PID:$PID"
done

log "所有实例已启动。日志文件格式: iperf_server_<端口>.log"

if (( DETACH == 1 )); then
  log "后台模式：脚本退出但进程继续运行。"
  trap - EXIT INT TERM
  exit 0
else
  log "按 Ctrl+C 结束并清理所有实例。"
  # 保持前台等待
  wait
fi
