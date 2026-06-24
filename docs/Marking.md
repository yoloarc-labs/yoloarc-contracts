# Marking 做市合约交接文档

YOLO 代币自动做市 + 掏池子机制. 参考实现 `svcc-web3/sol` 的 SvcToken.recycle + SvcMarking 模式, 按 yoloarc 项目规则适配 (去 onlyEOA / 去 chainid 自适应 / mirror onlyStakingManager 权限).

## 机制流程

```
                 YoloToken (代币)                PancakeV2 Pair (YOLO-USDT)            Marking (做市)
                      |                                   |                                  |
   1. setMarking(Marking) ─────────────────────────────────────────────────────授 recycle 权限
   2. addWhitelist([Marking]) ──────────────────────────────────────────────────卖出绕过税费/开关
   3. setConfig(yolo,USDT,router,pair) + approve(router) ─────────────────────────配置 + 授权 router
   4. transfer YOLO 弹药 ──────────────────────────────────────────────► 持有 YOLO (做市弹药)
                      |                                   |                                  |
   autoFuck / getUsdtTokenAmount 触发:                                                        |
                      |   swapExactTokensForTokens (卖 YOLO -> USDT)                          |
                      |   Marking ──YOLO──► Router ──► Pair ◄──注入 YOLO                       |
                      |                                   |   ──USDT──► recipient / Marking    |
                      |                                   |                                  |
   recycle(amountIn)  |   ◄──super._update(pair, marking, min(amountIn, pairYolo/3))── 抽回 YOLO|
                      |   pair.sync() (按真实余额重置 reserve)                              |
                      |                                   |                                  |
   循环: 金额减半直到 pool USDT < 100, 或 swap 失败 break                                       |
                      |                                   |                                  |
   adminWithdraw      |                                   |   Marking USDT ──► 管理员地址       |
```

核心: 每轮卖出把池子 USDT 抽到 Marking, recycle 把卖进池子的 YOLO 抽回 Marking (单次上限池子 YOLO 余额 1/3, 防一次抽干崩价), 金额递减循环掏干底池 USDT.

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
| `setConfig(yolo,usdt,router,pair)` | DEFAULT_ADMIN_ROLE | 配置四地址 + approve router max |
| `getAmountsIn(usdtAmount)` | view | 换出指定 USDT 需多少 YOLO |
| `getUsdtTokenAmount(usdtAmount, to)` | STAKE_ROLE + enable + nonReentrant | 代卖 YOLO->USDT 到 to, 并 recycle |
| `autoFuck(usdtAmount)` | DEFAULT_ADMIN_ROLE + enable + nonReentrant | 掏池子: 金额递减循环 + try-catch 容错 |
| `_autoFuckExternal(usdtAmount)` | 仅本合约自调用 | autoFuck 内部 try-catch 包装 |
| `adminWithdraw(to, amount)` | DEFAULT_ADMIN_ROLE | 提取 Marking 持有的 USDT |

常量: `STAKE_ROLE = keccak256("STAKE_ROLE")`, 卖出滑点缓冲 106%, 掏池子最小阈值 100 USDT, 每级最大 100 轮.

> 不设集中式 healthcheck. `getAmountsIn`/`getUsdtTokenAmount`/`autoFuck` 用 `configured` 修饰器在执行入口直接 require 四地址非零, 未配置即 revert.

## 部署配置顺序 (关键)

1. 部署 YoloToken 代理 (已存在, 本次为升级: 加 marking 字段 + recycle/setMarking)
2. 部署 Marking 逻辑合约 + 代理, 调 `initialize()`
3. YoloToken `setMarking(address(Marking))` (operator 执行)
4. YoloToken `addWhitelist([address(Marking)])` (operator, 让做市卖出绕税费/买卖开关)
5. Marking `setConfig(yoloToken, USDT, v2Router, mainPair)` (DEFAULT_ADMIN)
6. 给 Marking 转入 YOLO 弹药 (做市卖出用)
7. 按需 `grantRole(STAKE_ROLE, 上层质押/业务合约)` 让其调用 getUsdtTokenAmount

## 安全注意

- `recycle` 走 `super._update` 绕过 `_update` override 的税费/买卖开关限制, 仅 marking 可调用, 单次 1/3 上限防崩价
- Marking 必须 whitelist, 否则卖出会触发 sellFee/declineTax 稀释掏池效率
- `autoFuck` 是池子抽水操作, 仅 DEFAULT_ADMIN 可调用, 上线前确认调用者多签/时间锁
- BSC USDT 18 位精度, YOLO 6 位精度; 金额均为 raw 单位, getAmountsIn 自动换算
- 去掉了参考合约的 onlyEOA (EIP-7702 可绕过, 改用 nonReentrant + 角色) 和 chainid 自适应 (单链 BSC, 地址参数化)

## 测试

`test/Marking.t.sol` — fork BSC 主网, 真实 PancakeV2 + 真实 USDT (禁 mock), 15 个用例全通过.

```bash
forge test --match-contract MarkingTest -vvv
```

覆盖: recycle 正向/1-3 上限/零值/权限拒绝/fuzz(256 轮)不变量, setMarking 零地址/非 operator, getUsdtTokenAmount 正向/非 STAKE/零额, autoFuck 掏池子 (实测 1000 USDT 掏到 100), adminWithdraw 正向/余额不足, healthcheck, setEnable.