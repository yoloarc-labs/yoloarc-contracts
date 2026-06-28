# yoloarc-contracts


## 目录结构

```
src/
├── token/
│   ├── YoloToken.sol              主代币 (销毁税/下跌税/白名单/Fomo)
│   ├── YoloTokenStorage.sol       代币存储布局 (__gap[98] 兼容升级)
│   └── allocation/
│       ├── CardManager.sol        卡牌分配管理器 (可升级)
│       ├── CardManagerStorage.sol
│       ├── LpManager.sol          LP 分配管理器 (可升级)
│       └── LpManagerStorage.sol
├── core/
│   ├── UserManager.sol            用户邀请/推荐关系 (onlyCaller)
│   ├── UserManagerStorage.sol
│   ├── FomoTreasureManager.sol    Fomo 奖池分发
│   └── FomoTreasureManagerStorage.sol
├── utils/
│   ├── SwapHelper.sol             PancakeSwap V2/V3 swap 封装
│   └── TradeSlippage.sol          滑点控制/价格影响防护
└── interfaces/                    各合约接口 + PancakeSwap 接口
    └── pancake/                   IPancakeV2/V3 Factory/Router/Pair/Pool

script/
├── EnvContract.sol                集中管理各 proxy 地址 (ERC1967Utils)
├── InitContract.sol               ProxyAdmin 工具
├── DeployStakingScript.sol        主部署脚本 (TransparentUpgradeableProxy)
└── MockERC20.sol                  测试用 USDT mock

test/
└── CardManager.t.sol              CardManager 单元测试
```

## 架构

```
                 ┌─────────── contractCaller (yolo-contracts-caller 链下调用层) ───────────┐
                 │                                                                       │
                 ▼                                                                       ▼
  YoloToken ──► mainPair (PancakeV2) ──► SwapHelper ──► PancakeV2/V3 Router
  (销毁税/下跌税/白名单/        │
   Fomo 奖池/价格影响)          ├─► UserManager           (邀请绑定/推荐关系)
                               ├─► CardManager           (卡牌分配)
                               ├─► LpManager             (LP 分配)
                               └─► FomoTreasureManager   (Fomo 奖池分发)
```

- 所有核心合约走可升级代理, 实现合约用 `Initializable` + 独立 Storage 合约分离存储布局, 以 `__gap` 数组预留升级插槽.
- `contractCaller` 角色地址是核心业务函数的唯一合法调用方, 由 `setContractCaller` (onlyOwner) 配置, 对应链下 `yolo-contracts-caller` 服务.
- `YoloToken` 持有 `operator` / `stakingManager` / `currencyDistributor` / `fomoTreasureAddress` / `predictionContract` / `fundingPod` 等角色地址.

## 代币机制

- 总量上限: `200_000_000 * 1e6`.
- 卖单手续费: 300 bps.
- 下跌税阶梯 (按价格跌幅触发): 跌幅 >= 3% (300 bps) 触发 1000 bps 税, 跌幅 >= 6% (600 bps) 触发 2000 bps 税.
- 白名单 (`whiteList`) 地址免手续费.
- `slippageLock` 防重入, `_lpBurnedTokens` 累计 LP 销毁, `userCost` 记录用户成本.

## 构建 / 测试 / 部署

```shell
forge build                                              # 构建 (via_ir 规避 stack too deep)
forge test                                               # 全部测试
forge test --match-test <TestName> -vvv                  # 单测 + trace
forge snapshot                                           # Gas 快照
forge fmt                                                # 格式化
forge script script/DeployStakingScript.sol:DeployStakingScript --rpc-url <rpc> --private-key <key>
```

## 依赖

通过 git submodule 管理 (见 `.gitmodules`):

- `forge-std` - Foundry 标准库
- `openzeppelin-contracts` / `openzeppelin-contracts-upgradeable` - OpenZeppelin 合约 (含可升级版本)
- `pancake-swap-core` / `pancake-swap-periphery` - PancakeSwap V2 核心与外设
- `openzeppelin-foundry-upgrades` - Foundry 升级工具 (remappings 引用)
- `solmate` - solmate 工具库 (remappings 引用)

克隆后需初始化子模块: `git submodule update --init --recursive`.

