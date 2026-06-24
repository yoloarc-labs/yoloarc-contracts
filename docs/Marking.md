# Marking 做市合约交接文档

Marking 合约承担两类做市: (1) **掏池子** — 把底池 USDT 抽到 Marking (参考 svcc-web3/sol SvcMarking); (2) **价格控制** — 把池价钉在基准价 ±2% 区间, 控制涨跌幅 (参考 D3xai.executeMarketControl). 按 yoloarc 规则适配 (去 onlyEOA / 去 chainid 自适应 / mirror onlyStakingManager 权限).

## 两大做市模式

```
模式 A: 掏池子 (autoFuck / getUsdtTokenAmount)
  卖出 YOLO -> USDT 进 Marking, recycle 把卖进池子的 YOLO 抽回 (上限池子 1/3)
  金额递减循环, 直到底池 USDT 被掏干. 单向抽水.

模式 B: 价格控制 (executeMarketControl, keeper 触发)
  基准价 marketControlPrice (admin 设) + 2% 容差
  池价 > 基准*1.02 -> 卖 YOLO 压价回基准 (恒定乘积 sqrt 反推精确量)
  池价 < 基准*0.98 -> 用 USDT 买 YOLO 托价回基准
  双向稳价, 把涨跌幅钉在 ±2% 区间.
```

## 机制流程

```
                 YoloToken (代币)                PancakeV2 Pair (YOLO-USDT)            Marking (做市)
                      |                                   |                                  |
   1. setMarking(Marking) ─────────────────────────────────────────────────────授 recycle 权限
   2. addWhitelist([Marking]) ──────────────────────────────────────────────────卖出绕过税费/开关
   3. setConfig(yolo,USDT,router,pair) + approve(router, yolo+usdt) ───────────配置 + 双向授权
   4. transfer YOLO + USDT 弹药 ─────────────────────────────────────► 持有双向做市弹药
                      |                                   |                                  |
   [模式 A 掏池] autoFuck / getUsdtTokenAmount:                                               |
     卖 YOLO->USDT, recycle(amountIn) 抽回 YOLO (上限 1/3), 循环掏干                            |
                      |                                   |                                  |
   [模式 B 稳价] executeMarketControl() (keeper 调):                                          |
     读 price() vs 基准±2%                                                                     |
     偏高 -> calculateSellAmount (sqrt(k*1e6/基准)) -> 卖 YOLO 压价                            |
     偏低 -> calculateBuyAmount  (sqrt(k*基准/1e6)) -> 买 YOLO 托价                            |
                      |                                   |                                  |
   adminWithdraw      |                                   |   Marking USDT ──► 管理员地址       |
```

精度归一化: YoloToken 6 位, BSC USDT 18 位. 价格控制 sqrt 反推用 `TOKEN_UNIT=1e6` 归一化 (D3xai 用 1e18 因其代币 18 位, 不可照抄数值).

## YoloToken 新增接口

| 函数 | 权限 | 说明 |
|------|------|------|
| `setMarking(address _marking)` | onlyOperator | 设置做市合约地址 (持有 recycle 权限) |
| `recycle(uint256 amount)` | onlyMarking | 从 mainPair 抽 YOLO 到 marking, 上限 = `balanceOf(pair)/3`; 走 `super._update` 绕税费, 后 `pair.sync()` |

| 事件 | 参数 | 说明 |
|------|------|------|
| `SetMarking` | marking | 设置做市地址 |
| `Recycle` | pair, marking, amount | 实际回收 (已扣 1/3 上限) |

存储变更: `YoloTokenStorage` 新增 `address public marking;`, `__gap` 由 `98` 改为 `97` (升级安全, 消耗 1 槽).

## Marking 合约接口

`src/marketing/Marking.sol` (Initializable + AccessControlUpgradeable, 本地重入锁)

| 函数 | 权限 | 说明 |
|------|------|------|
| `initialize()` | initializer | 授予部署者 DEFAULT_ADMIN_ROLE, enable=true |
| `setEnable(bool)` | DEFAULT_ADMIN_ROLE | 系统开关 |
| `setConfig(yolo,usdt,router,pair)` | DEFAULT_ADMIN_ROLE | 配置四地址 + approve router (YOLO+USDT 双向 max) |
| `getAmountsIn(usdtAmount)` | view | 换出指定 USDT 需多少 YOLO |
| `getUsdtTokenAmount(usdtAmount, to)` | STAKE_ROLE+enable+nonReentrant | 代卖 YOLO->USDT 到 to, 并 recycle |
| `autoFuck(usdtAmount)` | DEFAULT_ADMIN_ROLE+enable+nonReentrant | 模式A 掏池子: 金额递减循环 + try-catch |
| `setMarketControlPrice(price)` | DEFAULT_ADMIN_ROLE | 模式B 设基准价 (0=关闭价格控制) |
| `price()` | view | 当前池价 (1 YOLO 换多少 USDT raw) |
| `executeMarketControl()` | 公开+enable+nonReentrant | 模式B keeper 触发稳价 (区间内 no-op) |
| `marketControlStatus()` | view | 返回 (基准/当前/上限/下限) 供 keeper 判断 |
| `calculateSellAmount()` | view | 价格偏高时需卖出的 YOLO 量 (恒定乘积反推) |
| `calculateBuyAmount()` | view | 价格偏低时需付出的 USDT 量 (恒定乘积反推) |
| `adminWithdraw(to, amount)` | DEFAULT_ADMIN_ROLE | 提取 Marking 持有的 USDT |

常量: `STAKE_ROLE`, 卖出缓冲 106%, 掏池阈值 100 USDT/每级 100 轮, 价格控制容差 2%, 滑点容忍 10% (防 MEV), PancakeV2 手续费因子 9975/10000 (0.25%).

> 不设集中式 healthcheck. 执行入口 (`getAmountsIn`/`getUsdtTokenAmount`/`autoFuck`/`price`/`executeMarketControl`) 用 `configured` 修饰器 require 四地址非零.

## 部署配置顺序

1. 升级 YoloToken (加 marking 字段 + recycle/setMarking)
2. 部署 Marking 逻辑合约 + 代理, 调 `initialize()`
3. YoloToken `setMarking(address(Marking))` (operator)
4. YoloToken `addWhitelist([address(Marking)])` (operator, 做市卖出绕税费/开关)
5. Marking `setConfig(yoloToken, USDT, v2Router, mainPair)` (DEFAULT_ADMIN)
6. 给 Marking 转 YOLO 弹药 (掏池+稳价卖出) 和 USDT 弹药 (稳价买入托价)
7. 按需 `grantRole(STAKE_ROLE, 上层质押/业务合约)` 调 getUsdtTokenAmount
8. 模式B: `setMarketControlPrice(当前池价)` 开启价格控制, keeper 周期调 `executeMarketControl()`

## 安全注意

- `recycle` 走 `super._update` 绕过税费/买卖开关, 仅 marking 可调, 单次 1/3 上限防崩价
- Marking 必须 whitelist, 否则做市卖出触发 sellFee/declineTax 稀释效率
- `autoFuck` 是池子抽水, 仅 DEFAULT_ADMIN 可调, 上线前多签/时间锁
- 价格控制 swap 设 10% 滑点下限 (`amountOutMin`), 防三明治/MEV; keeper 触发频率别太高避免被针对性夹
- 价格控制反推用 PancakeV2 手续费 0.25% (9975/10000), 非 Uniswap 的 0.3%
- 模式A(掏池)和模式B(稳价)方向相反, 不要同时跑; 稳价时关 autoFuck
- BSC USDT 18 位, YOLO 6 位; 价格控制 sqrt 用 1e6 归一化
- 去 onlyEOA (EIP-7702 可绕, 用 nonReentrant+角色), 去 chainid 自适应 (BSC 单链地址参数化)

## 测试

`test/Marking.t.sol` — fork BSC 主网, 真实 PancakeV2 + 真实 USDT (禁 mock), 23 用例全通过.

```bash
forge test --match-contract MarkingTest -vvv
```

覆盖: recycle 正向/1-3 上限/零值/权限/fuzz(256轮), setMarking 权限, getUsdtTokenAmount 正向/非STAKE/零额, autoFuck 掏池 (实测 1000->100 USDT), adminWithdraw, configured 零地址拦截, 价格控制 (区间no-op/偏高卖出压价/偏低买入托价/基准0关闭/状态查询). 价格控制实测: 偏高 0.001207 拉回 0.000995 (≈基准), 偏低 0.000693 托回 0.000995.