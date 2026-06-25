#!/bin/sh
# keeper 入口: 校验必填 ENV, 然后 sleep-loop 每 INTERVAL_SECONDS 秒跑一次 keeper.sh
# 用 sleep-loop 而非 cron: cron 任务不继承容器 ENV (会把 PRIVATE_KEY 丢掉), sleep-loop 直接继承, 更稳
set -eu

: "${RPC_URL:?entrypoint: RPC_URL required}"
: "${MARKING_ADDRESS:?entrypoint: MARKING_ADDRESS required}"
: "${PRIVATE_KEY:?entrypoint: PRIVATE_KEY required}"

INTERVAL="${INTERVAL_SECONDS:-300}"

# 私钥带 0x 前缀容错
case "$PRIVATE_KEY" in
    0x*) : ;;
    *) PRIVATE_KEY="0x$PRIVATE_KEY" ;;
esac
export PRIVATE_KEY

echo "[entrypoint] keeper 启动 interval=${INTERVAL}s marking=${MARKING_ADDRESS}"

while true; do
    /app/keeper.sh || echo "[entrypoint] 本轮失败, 下个间隔重试"
    sleep "$INTERVAL"
done
