# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 仓库定位

`yoloarc-contracts` 是 yoloarc 体育博彩业务线的链上合约仓库 (Foundry / Solidity 0.8.20, evm_version=prague, via_ir + optimizer). 与父目录 `dapplink-external/CLAUDE.md` 描述的仓库群审计约束一致: 本仓库为从 GitHub clone 的第三方代码, 默认审计只读模式, 禁运行 / 构建 / 部署 / 安装依赖, 禁启动任何服务. 需运行 `forge build` / `forge test` / `forge script` 前必须 AskUserQuestion 确认. 仓库群级的安全硬约束以父级 CLAUDE.md 为准, 本文不重复.

## 常用命令 (仅理解项目用, 审计只读模式禁运行)

- 构建: `forge build` (via_ir + optimizer, 用于规避 Stack too deep)
- 测试: `forge test` / 单测 `forge test --match-test <TestName> -vvv`
- Gas 快照: `forge snapshot`
- 格式化: `forge fmt`
- 部署脚本: `forge script script/DeployStakingScript.sol:DeployStakingScript --rpc-url <rpc> --private-key <key>` (需用户确认)
- 链上查询: `cast call` / `cast storage` / `cast interface` (审计验证用)

## 架构概览

代币 + 分配管理器双层架构, 全部走可升级代理 (TransparentUpgradeableProxy). 每个核心合约配独立 Storage 合约分离存储布局, 用 `uint256[<n>] private __gap` 预留升级插槽, 这是合约升级时存储兼容的关键, 改字段必须同步改对应 Storage 合约.

```
                 ┌─────────────── contractCaller (yolo-contracts-caller 链下调用层) ───────────────┐
                 │                                                                          │
                 ▼                                                                          ▼
  YoloToken ──► mainPair (PancakeV2) ──► SwapHelper ──► PancakeV2/V3 Router
  (销毁税/下跌税/白名单/      │
   Fomo 奖池/价格影响)        ├─► UserManager      (绑定邀请人 / 推荐关系, onlyCaller)
                             ├─► CardManager      (卡牌分配, 可升级)
                             ├─► LpManager        (LP 分配, 可升级)
                             └─► FomoTreasureManager (Fomo 奖池分发, 可升级)
```

### 核心合约 (src/)

| 合约 | 行数 | 职责 | Storage |
|------|------|------|---------|
| `token/YoloToken.sol` | 277 | 主代币, 卖单 300bps fee, 下跌税 3%/6% 阶梯, 白名单, Fomo 奖池地址, 价格预言 (latestChoPrice) | `YoloTokenStorage` (含 __gap[98]) |
| `core/UserManager.sol` | 272 | 绑定邀请人 / 推荐关系, `onlyCaller` 限制只有 contractCaller 能调, Initializable+Pausable | `UserManagerStorage` |
| `token/allocation/CardManager.sol` | 268 | 卡牌分配管理, 可升级 | `CardManagerStorage` |
| `core/FomoTreasureManager.sol` | 154 | Fomo 奖池资金分发 | `FomoTreasureManagerStorage` |
| `token/allocation/LpManager.sol` | 89 | LP 分配管理 | `LpManagerStorage` |
| `utils/SwapHelper.sol` | 57 | PancakeSwap V2/V3 swap 封装 | - |
| `utils/TradeSlippage.sol` | 156 | 交易滑点控制 / 价格影响防护 (slippageLock) | - |

### 跨合约通信模型

- `UserManager.onlyCaller` / 各 Manager 的权限修饰符限制只有 `contractCaller` (即 yolo-contracts-caller 后端服务地址) 能调用核心业务函数. `setContractCaller` 仅 owner.
- `YoloToken` 持有 `operator` / `stakingManager` / `currencyDistributor` / `fomoTreasureAddress` / `predictionContract` / `fundingPod` 等角色地址, 通过 `setXxx` (onlyOwner) 配置, 业务调用由这些角色发起.
- 修改任一 Manager 的接口 (函数签名 / 事件 / storage 布局) 必须同步: 链下 caller (yolo-contracts-caller) + Storage 合约 + 接口定义 (src/interfaces/).

### 代币机制要点 (YoloToken)

- 总量上限 `MaxTotalSupply = 1e9 * 1e6`, BPS 分母 10_000.
- 卖单 fee 300bps, 下跌税按价格跌幅阶梯: PRICE_DROP_3_BPS=300 / PRICE_DROP_6_BPS=600 触发 DOWN_TAX_3_BPS=1000 / DOWN_TAX_6_BPS=2000.
- `slippageLock` 防重入, `_lpBurnedTokens` LP 销毁累计, `userCost` 用户成本映射.
- `isOpenBuy` / `isOpenSell` 开关, `whiteList` (EnumerableSet) 白名单绕 fee.

### 可升级代理部署 (script/)

- `script/EnvContract.sol`: 集中管理 CoreAddresses (各 proxy 地址), 用 ERC1967Utils 读取代理实现槽.
- `script/InitContract.sol`: ProxyAdmin 工具, `_proxyAdminOrZero` 处理空地址.
- `script/DeployStakingScript.sol`: 主部署脚本, 用 TransparentUpgradeableProxy + ProxyAdmin 部署各合约代理.
- `script/MockERC20.sol`: 测试用 USDT mock.
- 部署脚本里各代理的 initData 必须与合约 `initialize(...)` 签名完全一致, 否则部署回滚.

## 审计要点 (本仓库特有)

- **代理初始化**: 各 Manager constructor 调 `_disableInitializers()` 防止实现合约被直接初始化; 部署脚本必须经代理调 initialize, 验证链上 implementation 槽非零.
- **存储布局**: Storage 合约的 `__gap` 大小决定可新增字段数, 改 Storage 字段顺序/类型/位置会破坏代理升级兼容性, 必须只在末尾追加并同步缩减 `__gap`.
- **onlyCaller 越权**: UserManager 等核心业务函数仅 contractCaller 可调, 审计需对照每个 public/external 函数的修饰符是否一致, 找出漏加 onlyCaller 的入口 (参考父级 CLAUDE.md 跨链 Gateway 审计方法).
- **PancakeSwap 集成**: SwapHelper / TradeSlippage 走 V2/V3 router, 关注 swap callback 重入面 (V3 swapCallback) 和滑点校验绕过; 0xdead 销毁地址对 AMM 价格的影响 (父级 security_scope 规则).
- **代币税机制**: 卖单 fee / 下跌税 / 白名单绕税, 审计需验证白名单地址是否可绕税套利, 0xdead 大量流入对 AMM 价格的操纵面.
- **预言机依赖**: `latestChoPrice` 作为下跌税触发依据, 审计其更新路径与操纵面 (谁来 set, 是否可被 sandwich).