#!/bin/sh
# keeper 单次执行:
# 1. 读 marketControlPrice, 为 0 (价格控制未开启) 直接跳过, 省一次发交易
# 2. 否则 cast send executeMarketControl() (合约内自带 ±2% 区间判断, 区间内 no-op)
# 签名用 ENV 明文私钥; keeper 地址在 Marking 上授了 KEEPER_ROLE (最小权限, 只能触发做市)
set -eu

: "${RPC_URL:?keeper: RPC_URL required}"
: "${MARKING_ADDRESS:?keeper: MARKING_ADDRESS required}"
: "${PRIVATE_KEY:?keeper: PRIVATE_KEY required}"
CHAIN_ID="${CHAIN_ID:-56}"
GAS_LIMIT="${GAS_LIMIT:-300000}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# 1. 价格控制开关: marketControlPrice == 0 表示未开启, 跳过
baseline=$(cast call "$MARKING_ADDRESS" "marketControlPrice()(uint256)" --rpc-url "$RPC_URL" | tr -d '[:space:]')
if [ -z "$baseline" ] || [ "$baseline" = "0" ]; then
    echo "[$(ts)] [keeper] marketControlPrice=0, 价格控制未开启, 跳过"
    exit 0
fi

# 2. 读当前价 / 区间, 仅日志 (大整数不 Shell 比较, 区间判断交给合约)
status=$(cast call "$MARKING_ADDRESS" "marketControlStatus()(uint256,uint256,uint256,uint256)" --rpc-url "$RPC_URL")
echo "[$(ts)] [keeper] baseline/current/upper/lower = $(echo "$status" | tr '\n' '/')"

# 3. 触发 executeMarketControl (合约内: 偏高卖出压价 / 偏低买入托价 / 区间内 no-op)
echo "[$(ts)] [keeper] 发送 executeMarketControl ..."
cast send "$MARKING_ADDRESS" "executeMarketControl()" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --chain "$CHAIN_ID" \
    --gas-limit "$GAS_LIMIT"

echo "[$(ts)] [keeper] 本轮完成"
