# Marking 做市功能发布说明

## 概述

为 YOLO 代币增加回流参数 (recycle) + 自动做市合约 (Marking). Marking 承担两类做市: (1) 掏池子 (参考 SvcMarking); (2) 价格控制稳价 (参考 D3xai.executeMarketControl, 控制涨跌幅). 按 yoloarc 项目规则适配.

## 两大做市模式

- 模式 A 掏池子: 卖出 YOLO->USDT, recycle 抽回 YOLO (上限池子 1/3), 循环掏干底池 USDT
- 模式 B 价格控制: 基准价 ±2% 容差, 偏高卖出压价 / 偏低买入托价 (恒定乘积 sqrt 精确反推), 把涨跌幅钉在区间

## 变更清单

- YoloToken: 新增 marking 字段 / onlyMarking 修饰器 / setMarking / recycle
- Marking 合约:
  - 掏池: getUsdtTokenAmount (STAKE_ROLE 代卖) / autoFuck (DEFAULT_ADMIN 掏池子) / recycle 回收 / adminWithdraw
  - 稳价: setMarketControlPrice / price / executeMarketControl (keeper) / marketControlStatus / calculateSellAmount / calculateBuyAmount
- IYoloToken: recycle 接口 + Recycle/SetMarking 事件
- Storage: __gap 98 -> 97 (升级安全)
- foundry.toml: bsc rpc_endpoints; foundry.lock: pancake-swap-periphery

## 规则合规适配

- 去 onlyEOA (EIP-7702 可绕过, 改 nonReentrant + 角色)
- 去 chainid 自适应 (BSC 单链, 地址参数化 setConfig)
- recycle 权限 mirror onlyStakingManager 模式 (onlyMarking 修饰器, 不改继承体系)
- 不设集中 healthcheck, 用 configured 修饰器执行入口拦截零地址

## 安全修复 (审计后)

- 价格控制 swap 设 10% 滑点下限 (amountOutMin), 防三明治/MEV (原 amountOutMin=0 漏洞)
- 手续费因子 9975/10000 (PancakeV2 0.25%), 非 Uniswap 997/1000 (0.3%)
- executeMarketControl 池子单边空时优雅返回 (不 revert)

## 测试

test/Marking.t.sol fork BSC 主网 (真实 PancakeV2 Router + 真实 USDT, 禁 mock), 23 用例全通过.

实测:
- autoFuck 把底池 1000 USDT 掏到 100 USDT, marking 收 899.9 USDT
- recycle 1/3 上限精确 (1M 池余额请求超量只回收 333333)
- 价格控制卖出: 偏高 0.001207 拉回 0.000995 (≈基准 0.000997)
- 价格控制买入: 偏低 0.000693 托回 0.000995, 花 165 USDT 买回 198538 YOLO
- fuzz 256 轮 recycle 上限不变量全部成立

## 部署配置顺序

1. 升级 YoloToken (加 marking 字段 + recycle/setMarking)
2. 部署 Marking 代理 + initialize()
3. YoloToken.setMarking(Marking) + addWhitelist([Marking])
4. Marking.setConfig(yolo, USDT, router, mainPair)
5. 给 Marking 转 YOLO 弹药 (掏池+稳价卖出) + USDT 弹药 (稳价买入托价)
6. grantRole(STAKE_ROLE, 上层业务合约)
7. 模式B: setMarketControlPrice(当前池价) 开启价格控制, keeper 周期调 executeMarketControl()
