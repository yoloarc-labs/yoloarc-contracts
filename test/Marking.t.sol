// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {YoloToken} from "../src/token/YoloToken.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";
import {Marking} from "../src/marketing/Marking.sol";
import {IPancakeRouter02} from "@pancake-v2-periphery/interfaces/IPancakeRouter02.sol";
import {IPancakePair} from "@pancake-v2-core/interfaces/IPancakePair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * Marking 做市合约测试
 * 运行命令: forge test --match-contract MarkingTest -vvv --fork-url bsc_mainnet
 * 网络: fork BSC 主网 (真实 PancakeV2 factory/router + 真实 USDT, 禁 mock)
 *
 * 覆盖:
 * - recycle 回流 (正向 / 1/3 上限 / 零值 / 权限拒绝 / fuzz 不变量)
 * - setMarking 权限 (零地址 / 非操作员)
 * - getUsdtTokenAmount STAKE_ROLE 代卖 (正向 / 非 STAKE 拒绝)
 * - autoFuck 掏池子 (正向, 验证底池 USDT 减少 + 本合约收到 USDT)
 * - adminWithdraw 提现 (正向 / 余额不足)
 * - healthcheck 健康检查
 */
contract MarkingTest is Test {
    // BSC 主网真实地址
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC; // Binance 热钱包 (约 200M USDT)

    YoloToken internal yolo;
    Marking internal marking;
    IERC20 internal usdt;
    IPancakeRouter02 internal router;
    address internal pair;

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal lpHolder = makeAddr("lpHolder");
    address internal cardHolder = makeAddr("cardHolder");
    address internal stakingManager = makeAddr("stakingManager");
    address internal fundingPod = makeAddr("fundingPod");
    address internal stakeCaller = makeAddr("stakeCaller"); // 被授予 STAKE_ROLE
    address internal recipient = makeAddr("recipient");

    // 测试合约自身 = owner / operator / marking admin (proxy 构造时 msg.sender)

    function setUp() public {
        // 1. fork BSC 主网
        vm.createSelectFork("bsc_mainnet");

        usdt = IERC20(USDT_ADDR);
        router = IPancakeRouter02(ROUTER);

        // 2. 部署 YoloToken 代理 (owner = address(this), 即测试合约)
        YoloToken yoloImpl = new YoloToken();
        bytes memory yoloData = abi.encodeCall(
            YoloToken.initialize,
            (address(this), stakingManager, USDT_ADDR, fundingPod, FACTORY, ROUTER)
        );
        TransparentUpgradeableProxy yoloProxy =
            new TransparentUpgradeableProxy(address(yoloImpl), proxyAdmin, yoloData);
        yolo = YoloToken(address(yoloProxy));
        pair = yolo.mainPair();

        // 3. 分配代币池 (40% lpPool / 60% cardPool), 由测试合约 (operator) 执行
        yolo.setPoolAddress(IYoloToken.YoloPool(lpHolder, cardHolder));
        yolo.poolAllocate();

        // 4. 给 lpHolder 注入真实 USDT (从 BSC 大户转), 再添加 YOLO-USDT 流动性
        vm.prank(USDT_WHALE);
        usdt.transfer(lpHolder, 10_000 ether); // 10000 USDT

        vm.startPrank(lpHolder);
        yolo.approve(ROUTER, type(uint256).max);
        usdt.approve(ROUTER, type(uint256).max);
        router.addLiquidity(
            address(yolo), USDT_ADDR, 1_000_000 * 1e6, 1_000 ether, 0, 0, lpHolder, block.timestamp + 300
        );
        vm.stopPrank();

        // 5. 部署 Marking 代理 (initialize 授予测试合约 DEFAULT_ADMIN_ROLE)
        Marking markingImpl = new Marking();
        bytes memory markingData = abi.encodeCall(Marking.initialize, ());
        TransparentUpgradeableProxy markingProxy =
            new TransparentUpgradeableProxy(address(markingImpl), proxyAdmin, markingData);
        marking = Marking(address(markingProxy));

        // 6. Marking 配置 + 在 YoloToken 上绑定 recycle 权限 + 白名单 (卖出绕过税费)
        marking.setConfig(address(yolo), USDT_ADDR, ROUTER, pair);
        yolo.setMarking(address(marking));
        address[] memory wl = new address[](1);
        wl[0] = address(marking);
        yolo.addWhitelist(wl);

        // 7. 给 Marking 注入 YOLO 弹药 (从 lpHolder 转), 用于做市卖出
        vm.prank(lpHolder);
        yolo.transfer(address(marking), 5_000_000 * 1e6); // 500 万 YOLO

        // 8. 授予 stakeCaller 代卖权限
        marking.grantRole(marking.STAKE_ROLE(), stakeCaller);

        // 9. lpHolder 加白名单 (价格控制测试需用 lpHolder 买卖操纵池价)
        address[] memory wl2 = new address[](1);
        wl2[0] = lpHolder;
        yolo.addWhitelist(wl2);
    }

    // ==================== 价格操纵辅助 (供价格控制测试) ====================

    /// @dev lpHolder 用 USDT 买 YOLO, 抬高池价
    function _pumpPrice(uint256 usdtIn) internal {
        vm.startPrank(lpHolder);
        usdt.approve(ROUTER, type(uint256).max);
        address[] memory p = new address[](2);
        p[0] = USDT_ADDR;
        p[1] = address(yolo);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(usdtIn, 0, p, lpHolder, block.timestamp + 300);
        vm.stopPrank();
    }

    /// @dev lpHolder 卖 YOLO 换 USDT, 压低池价
    function _dumpPrice(uint256 yoloIn) internal {
        vm.startPrank(lpHolder);
        yolo.approve(ROUTER, type(uint256).max);
        address[] memory p = new address[](2);
        p[0] = address(yolo);
        p[1] = USDT_ADDR;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(yoloIn, 0, p, lpHolder, block.timestamp + 300);
        vm.stopPrank();
    }

    // ==================== recycle 回流测试 ====================

    function testRecycle_Success() public {
        console.log(unicode"=== recycle 正向测试 ===");
        uint256 pairBefore = yolo.balanceOf(pair);
        uint256 markingBefore = yolo.balanceOf(address(marking));
        uint256 amount = pairBefore / 10; // 远低于 1/3 上限

        vm.prank(address(marking));
        yolo.recycle(amount);

        uint256 pairAfter = yolo.balanceOf(pair);
        uint256 markingAfter = yolo.balanceOf(address(marking));

        console.log(string.concat(unicode"  [pair YOLO]: ", _fmt(pairBefore, 6, unicode"个")));
        console.log(string.concat(unicode"  [回收请求]: ", _fmt(amount, 6, unicode"个")));
        console.log(string.concat(unicode"  [pair 减少]: ", _fmt(pairBefore - pairAfter, 6, unicode"个")));
        console.log(string.concat(unicode"  [marking 增加]: ", _fmt(markingAfter - markingBefore, 6, unicode"个")));

        assertEq(pairBefore - pairAfter, amount, "pair should decrease by amount");
        assertEq(markingAfter - markingBefore, amount, "marking should increase by amount");
        console.log(unicode"  [结果]: 通过");
    }

    function testRecycle_CapOneThird() public {
        console.log(unicode"=== recycle 1/3 上限测试 ===");
        uint256 pairBefore = yolo.balanceOf(pair);
        uint256 cap = pairBefore / 3;
        uint256 markingBefore = yolo.balanceOf(address(marking));

        // 请求远超上限, 应只回收 cap
        vm.prank(address(marking));
        yolo.recycle(pairBefore * 2);

        uint256 pairAfter = yolo.balanceOf(pair);
        uint256 markingAfter = yolo.balanceOf(address(marking));

        console.log(string.concat(unicode"  [pair 上限]: ", _fmt(cap, 6, unicode"个")));
        console.log(string.concat(unicode"  [实际回收]: ", _fmt(markingAfter - markingBefore, 6, unicode"个")));

        assertEq(pairBefore - pairAfter, cap, "should recycle exactly pairBalance/3");
        assertEq(markingAfter - markingBefore, cap, "marking should receive cap");
        console.log(unicode"  [结果]: 通过");
    }

    function testRecycle_ZeroIsNoop() public {
        console.log(unicode"=== recycle 零值测试 ===");
        uint256 pairBefore = yolo.balanceOf(pair);

        vm.prank(address(marking));
        yolo.recycle(0);

        assertEq(yolo.balanceOf(pair), pairBefore, "pair balance unchanged on recycle(0)");
        console.log(unicode"  [结果]: 通过");
    }

    function testRecycle_RevertNotMarking() public {
        console.log(unicode"=== recycle 权限拒绝 (非 marking 调用) ===");
        vm.prank(lpHolder);
        vm.expectRevert("YoloToken onlyMarking: Only Marking can call this function");
        yolo.recycle(100);
    }

    function testFuzz_RecycleCapInvariant(uint256 amount) public {
        vm.assume(amount > 0 && amount <= yolo.balanceOf(pair));
        uint256 pairYolo = yolo.balanceOf(pair);
        uint256 cap = pairYolo / 3;
        uint256 expected = amount >= cap ? cap : amount;
        uint256 markingBefore = yolo.balanceOf(address(marking));

        vm.prank(address(marking));
        yolo.recycle(amount);

        assertEq(yolo.balanceOf(address(marking)) - markingBefore, expected, "recycle cap invariant");
    }

    // ==================== setMarking 权限测试 ====================

    function testSetMarking_RevertZeroAddress() public {
        vm.expectRevert("YoloToken: marking cannot be zero address");
        yolo.setMarking(address(0));
    }

    function testSetMarking_RevertNotOperator() public {
        vm.prank(lpHolder);
        vm.expectRevert("YoloToken: caller is not the operator");
        yolo.setMarking(lpHolder);
    }

    // ==================== getUsdtTokenAmount STAKE_ROLE 代卖测试 ====================

    function testGetUsdtTokenAmount_Success() public {
        console.log(unicode"=== STAKE_ROLE 代卖 (YOLO -> USDT + recycle) ===");
        uint256 targetUsdt = 10 ether; // 10 USDT
        uint256 markingYoloBefore = yolo.balanceOf(address(marking));
        uint256 recipientUsdtBefore = usdt.balanceOf(recipient);

        vm.prank(stakeCaller);
        marking.getUsdtTokenAmount(targetUsdt, recipient);

        uint256 markingYoloAfter = yolo.balanceOf(address(marking));
        uint256 recipientUsdtAfter = usdt.balanceOf(recipient);

        console.log(string.concat(unicode"  [目标 USDT]: ", _fmt(targetUsdt, 18, unicode"USDT")));
        console.log(string.concat(unicode"  [recipient 实收]: ", _fmt(recipientUsdtAfter - recipientUsdtBefore, 18, unicode"USDT")));
        console.log(string.concat(unicode"  [marking YOLO 净消耗]: ", _fmt(markingYoloBefore - markingYoloAfter, 6, unicode"个")));

        // recipient 应收到不少于目标的 USDT
        assertGe(recipientUsdtAfter - recipientUsdtBefore, targetUsdt, "recipient should receive >= target USDT");
        // marking YOLO 不应增加 (卖出后 recycle 只回收已卖出的部分, 净额 <= 原值)
        assertLe(markingYoloAfter, markingYoloBefore, "marking yolo must not increase via sell");
        console.log(unicode"  [结果]: 通过");
    }

    function testGetUsdtTokenAmount_RevertNotStakeRole() public {
        vm.prank(lpHolder);
        // AccessControl 缺角色标准错误
        vm.expectRevert();
        marking.getUsdtTokenAmount(10 ether, recipient);
    }

    function testGetUsdtTokenAmount_RevertZeroAmount() public {
        vm.prank(stakeCaller);
        vm.expectRevert("Marking: usdtAmount zero");
        marking.getUsdtTokenAmount(0, recipient);
    }

    // ==================== autoFuck 掏池子测试 ====================

    function testAutoFuck_DrainPool() public {
        console.log(unicode"=== autoFuck 掏池子 (反复卖出 + 回收) ===");
        uint256 poolUsdtBefore = usdt.balanceOf(pair);
        uint256 markingUsdtBefore = usdt.balanceOf(address(marking));
        uint256 markingYoloBefore = yolo.balanceOf(address(marking));

        console.log(string.concat(unicode"  [掏前 pool USDT]: ", _fmt(poolUsdtBefore, 18, unicode"USDT")));

        // 目标 500 USDT 一轮, 金额递减直到掏干
        marking.autoFuck(500 ether);

        uint256 poolUsdtAfter = usdt.balanceOf(pair);
        uint256 markingUsdtAfter = usdt.balanceOf(address(marking));
        uint256 markingYoloAfter = yolo.balanceOf(address(marking));

        console.log(string.concat(unicode"  [掏后 pool USDT]: ", _fmt(poolUsdtAfter, 18, unicode"USDT")));
        console.log(string.concat(unicode"  [掏出 USDT]: ", _fmt(poolUsdtBefore - poolUsdtAfter, 18, unicode"USDT")));
        console.log(string.concat(unicode"  [marking 收到 USDT]: ", _fmt(markingUsdtAfter - markingUsdtBefore, 18, unicode"USDT")));
        console.log(string.concat(unicode"  [marking YOLO 变化]: ", _fmt(_diff(markingYoloBefore, markingYoloAfter), 6, unicode"个")));

        // 底池 USDT 应被显著掏出
        assertLt(poolUsdtAfter, poolUsdtBefore, "pool USDT must decrease");
        // marking 合约应累积到 USDT
        assertGt(markingUsdtAfter, markingUsdtBefore, "marking must accumulate USDT");
        console.log(unicode"  [结果]: 通过");
    }

    // ==================== 价格控制做市 (控制涨跌幅) 测试 ====================

    function testSetMarketControlPrice() public {
        uint256 p = marking.price();
        marking.setMarketControlPrice(p);
        assertEq(marking.marketControlPrice(), p, "baseline should be set");
    }

    function testSetMarketControlPrice_RevertNotAdmin() public {
        vm.prank(lpHolder);
        vm.expectRevert();
        marking.setMarketControlPrice(1e15);
    }

    function testMarketControlStatus() public {
        uint256 p = marking.price();
        marking.setMarketControlPrice(p);
        (uint256 base, uint256 cur, uint256 upper, uint256 lower) = marking.marketControlStatus();
        assertEq(base, p, "baseline");
        assertEq(cur, p, "current ~= baseline");
        assertEq(upper, p + (p * 200) / 10000, "upper = baseline+2%");
        assertEq(lower, p - (p * 200) / 10000, "lower = baseline-2%");
    }

    function testExecuteMarketControl_NoopInBand() public {
        console.log(unicode"=== 价格控制: 区间内不操作 ===");
        uint256 p = marking.price();
        marking.setMarketControlPrice(p); // 基准=当前, 在区间内
        uint256 markingYolo = yolo.balanceOf(address(marking));
        uint256 markingUsdt = usdt.balanceOf(address(marking));

        marking.executeMarketControl();

        assertEq(yolo.balanceOf(address(marking)), markingYolo, "yolo unchanged in band");
        assertEq(usdt.balanceOf(address(marking)), markingUsdt, "usdt unchanged in band");
        console.log(unicode"  [结果]: 通过");
    }

    function testExecuteMarketControl_SellWhenHigh() public {
        console.log(unicode"=== 价格控制: 价格偏高 -> 卖出压价 ===");
        uint256 baseline = marking.price();
        marking.setMarketControlPrice(baseline);

        // 抬高池价 (lpHolder 买 YOLO), 让价格突破 基准+2%
        _pumpPrice(100 ether);
        uint256 priceAfterPump = marking.price();
        assertGt(priceAfterPump, baseline + (baseline * 200) / 10000, "price must be above upper band");

        uint256 markingYoloBefore = yolo.balanceOf(address(marking));
        marking.executeMarketControl();
        uint256 markingYoloAfter = yolo.balanceOf(address(marking));
        uint256 priceAfterControl = marking.price();

        console.log(string.concat(unicode"  [基准]: ", _fmt(baseline, 18, unicode"USDT/YOLO")));
        console.log(string.concat(unicode"  [拉升后]: ", _fmt(priceAfterPump, 18, unicode"USDT/YOLO")));
        console.log(string.concat(unicode"  [控制后]: ", _fmt(priceAfterControl, 18, unicode"USDT/YOLO")));
        console.log(string.concat(unicode"  [marking 卖出 YOLO]: ", _fmt(markingYoloBefore - markingYoloAfter, 6, unicode"个")));

        // marking 卖出了 YOLO
        assertLt(markingYoloAfter, markingYoloBefore, "marking should sell YOLO");
        // 价格被压回 (低于拉升后)
        assertLt(priceAfterControl, priceAfterPump, "price should be pushed down");
        console.log(unicode"  [结果]: 通过");
    }

    function testExecuteMarketControl_BuyWhenLow() public {
        console.log(unicode"=== 价格控制: 价格偏低 -> 买入托价 ===");
        // 给 marking 注入 USDT (托价买入弹药)
        vm.prank(USDT_WHALE);
        usdt.transfer(address(marking), 1000 ether);

        uint256 baseline = marking.price();
        marking.setMarketControlPrice(baseline);

        // 压低池价 (lpHolder 卖 YOLO), 让价格跌破 基准-2%
        _dumpPrice(200_000 * 1e6);
        uint256 priceAfterDump = marking.price();
        assertLt(priceAfterDump, baseline - (baseline * 200) / 10000, "price must be below lower band");

        uint256 markingUsdtBefore = usdt.balanceOf(address(marking));
        uint256 markingYoloBefore = yolo.balanceOf(address(marking));
        marking.executeMarketControl();
        uint256 markingUsdtAfter = usdt.balanceOf(address(marking));
        uint256 markingYoloAfter = yolo.balanceOf(address(marking));
        uint256 priceAfterControl = marking.price();

        console.log(string.concat(unicode"  [基准]: ", _fmt(baseline, 18, unicode"USDT/YOLO")));
        console.log(string.concat(unicode"  [砸盘后]: ", _fmt(priceAfterDump, 18, unicode"USDT/YOLO")));
        console.log(string.concat(unicode"  [控制后]: ", _fmt(priceAfterControl, 18, unicode"USDT/YOLO")));
        console.log(string.concat(unicode"  [marking 花费 USDT]: ", _fmt(markingUsdtBefore - markingUsdtAfter, 18, unicode"USDT")));
        console.log(string.concat(unicode"  [marking 买入 YOLO]: ", _fmt(markingYoloAfter - markingYoloBefore, 6, unicode"个")));

        // marking 花了 USDT 买回 YOLO
        assertLt(markingUsdtAfter, markingUsdtBefore, "marking should spend USDT");
        assertGt(markingYoloAfter, markingYoloBefore, "marking should gain YOLO");
        // 价格被托回 (高于砸盘后)
        assertGt(priceAfterControl, priceAfterDump, "price should be pushed up");
        console.log(unicode"  [结果]: 通过");
    }

    function testExecuteMarketControl_DisabledWhenBaselineZero() public {
        // marketControlPrice 默认 0, 价格控制关闭, 不操作
        uint256 markingYolo = yolo.balanceOf(address(marking));
        marking.executeMarketControl();
        assertEq(yolo.balanceOf(address(marking)), markingYolo, "no action when baseline 0");
    }

    function testCalcAmounts_ZeroWhenBaselineZero() public {
        assertEq(marking.calculateSellAmount(), 0, "sell amount 0 when no baseline");
        assertEq(marking.calculateBuyAmount(), 0, "buy amount 0 when no baseline");
    }

    // ==================== adminWithdraw 提现测试 ====================

    function testAdminWithdraw_Success() public {
        console.log(unicode"=== adminWithdraw 提现 ===");
        // 先 autoFuck 让 marking 持有 USDT
        marking.autoFuck(500 ether);
        uint256 markingUsdt = usdt.balanceOf(address(marking));
        require(markingUsdt > 0, "setup: marking needs USDT");

        uint256 recipientBefore = usdt.balanceOf(recipient);
        marking.adminWithdraw(recipient, markingUsdt / 2);

        console.log(string.concat(unicode"  [提取 USDT]: ", _fmt(markingUsdt / 2, 18, unicode"USDT")));
        console.log(string.concat(unicode"  [recipient 收到]: ", _fmt(usdt.balanceOf(recipient) - recipientBefore, 18, unicode"USDT")));

        assertEq(usdt.balanceOf(recipient) - recipientBefore, markingUsdt / 2, "recipient should receive withdrawn");
        console.log(unicode"  [结果]: 通过");
    }

    function testAdminWithdraw_RevertInsufficient() public {
        uint256 over = usdt.balanceOf(address(marking)) + 1;
        vm.expectRevert("Marking: usdt balance insufficient");
        marking.adminWithdraw(recipient, over);
    }

    // ==================== 执行入口零地址拦截 (configured) ====================

    function testConfigured_RevertBeforeSetConfig() public {
        // 新部署一个未 setConfig 的 Marking, 执行入口应拦截零地址变量
        Marking freshImpl = new Marking();
        bytes memory data = abi.encodeCall(Marking.initialize, ());
        TransparentUpgradeableProxy freshProxy =
            new TransparentUpgradeableProxy(address(freshImpl), proxyAdmin, data);
        Marking fresh = Marking(address(freshProxy));

        // 未配置, getAmountsIn 应在 configured 处拦截
        vm.expectRevert("Marking: yoloToken not set");
        fresh.getAmountsIn(10 ether);
    }

    function testSetEnable() public {
        marking.setEnable(false);
        assertFalse(marking.enable(), "should be disabled");
        marking.setEnable(true);
        assertTrue(marking.enable(), "should be enabled");
    }

    // ==================== 格式化辅助 ====================

    function _fmt(uint256 val, uint8 dec, string memory unit) internal pure returns (string memory) {
        uint256 factor = 10 ** uint256(dec);
        return string.concat(vm.toString(val / factor), ".", _pad(val % factor, dec), " ", unit);
    }

    function _pad(uint256 x, uint8 width) internal pure returns (string memory) {
        string memory s = vm.toString(x);
        uint256 len = bytes(s).length;
        if (len >= width) return s;
        bytes memory z = new bytes(uint256(width) - len);
        for (uint256 i = 0; i < z.length; i++) {
            z[i] = "0";
        }
        return string.concat(string(z), s);
    }

    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }
}
