# Marking 做市 Keeper (Docker 自包含)

不依赖 yoloarc-services / yolo-contracts-caller, 直接在 yoloarc-contracts 里用 Foundry 官方镜像跑 keeper, 每 5 分钟 cast 调 `Marking.executeMarketControl()` 做价格控制.

## 安全模型

```
  keeper 账户 (私钥明文入 ENV, 牺牲了"加密"换部署简单)
     │
     │  Marking.grantRole(KEEPER_ROLE, keeper地址)  <- admin 授权
     ▼
  KEEPER_ROLE 最小权限: 只能调 executeMarketControl() (触发稳价 swap)
     - 卖出/买入资金始终留 Marking 合约, 无提现权 (adminWithdraw 是 DEFAULT_ADMIN)
     - 私钥泄露也只能触发做市, 不能盗资; 做市有 10% 滑点保护限损失
     - keeper 地址公开可知, 不影响安全 (权限受限)
```

## 工作原理

```
  Docker 容器 (ghcr.io/foundry-rs/foundry:latest, 含 cast)
   ├─ entrypoint.sh: sleep-loop 每 300s 跑 keeper.sh (sleep-loop 比 cron 稳, 继承容器 ENV)
   └─ keeper.sh 单次:
        1. cast call marketControlPrice() -> 为 0 (未开启) 跳过
        2. cast send executeMarketControl() (ENV 私钥签名)
           合约内: 偏高卖出压价 / 偏低买入托价 / 区间内 no-op (需 KEEPER_ROLE)
```

## 目录

```
docker/keeper/
├── Dockerfile          基于 Foundry 官方镜像
├── entrypoint.sh       sleep-loop 入口
├── keeper.sh           单次 keeper (cast call + cast send)
├── docker-compose.yml  一键部署
└── env.example         环境变量样例 (复制为 .env 填写)
```

## 部署步骤 (服务器)

1. 生成/准备 keeper 账户:

   ```bash
   cast wallet new                  # 生成新私钥 + 地址 (或用已有的)
   # 记下私钥和地址
   ```

2. 给 keeper 地址授权 + 充 gas (admin 操作):

   ```bash
   KEEPER_ROLE=$(cast keccak "KEEPER_ROLE")
   # Marking 上授 KEEPER_ROLE 给 keeper 地址
   cast send <Marking代理> "grantRole(bytes32,address)" "$KEEPER_ROLE" <keeper地址> \
     --rpc-url <rpc> --private-key <admin私钥>
   # 给 keeper 地址转 BNB 付 gas
   ```

3. 配置 `.env`:

   ```bash
   cd docker/keeper
   cp env.example .env
   # 编辑 .env: 填 MARKING_ADDRESS (Marking 代理), PRIVATE_KEY (keeper 私钥)
   ```

4. 启动:

   ```bash
   docker compose up -d --build
   docker compose logs -f
   ```

5. 确认做市已开启: Marking 上 `setMarketControlPrice(当前池价)` (admin 设基准价, 0=关闭). keeper 读到非 0 才会发交易.

## 配置项 (.env)

| 变量 | 说明 | 默认 |
|------|------|------|
| RPC_URL | BSC 主网 RPC | https://bsc-dataseed.binance.org |
| CHAIN_ID | 链 ID | 56 |
| MARKING_ADDRESS | Marking 代理地址 | 必填 |
| PRIVATE_KEY | keeper 私钥 (明文, 带/不带 0x 均可) | 必填 |
| INTERVAL_SECONDS | 执行间隔 | 300 (5 分钟) |
| GAS_LIMIT | 单笔 gas 上限 | 300000 |

## 安全

- keeper 私钥明文入 ENV, 不进镜像, 不提交 (.env 在 .gitignore)
- KEEPER_ROLE 最小权限: 只能触发 executeMarketControl, 不能提现/掏池 (autoFuck 是 DEFAULT_ADMIN)
- 私钥泄露的损失上限: 被恶意触发做市 (有 10% 滑点保护), 不能直接盗资; 可随时 admin 撤销角色 `revokeRole`
- 容器 `restart: unless-stopped` 自动拉起

## 注意

- 区间内每 5 分钟发一次 no-op 交易会持续消耗少量 BNB gas, 确保 keeper 地址 gas 充足
- 撤销 keeper: `cast send <Marking> "revokeRole(bytes32,address)" <KEEPER_ROLE> <addr> ...`
- 价格控制开启前确认 Marking 持有 YOLO 弹药 (卖出压价) + USDT 弹药 (买入托价), 否则单边失效
- ARM 主机 (Apple Silicon) 构建加 `platform: linux/amd64` (compose 里已注释, 服务器 x86 不需要)
