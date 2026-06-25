// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {YoloToken} from "../src/token/YoloToken.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";
import {Marking} from "../src/marketing/Marking.sol";
import {IPancakeRouter02} from "@pancake-v2-periphery/interfaces/IPancakeRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * 做市控制端到端流程测试 (只测这一条流程, 验证做市能否真正控制涨跌)
 *
 * 流程: 部署代币 -> 创建交易对 -> 给做市合约放币 -> 制造涨跌 -> 执行做市 -> 验证控制
 * 运行: forge test --match-contract MarkingFlowTest -vvv --fork-url bsc_mainnet
 */
contract MarkingFlowTest is Test {
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    YoloToken internal yolo;
    Marking internal marking;
    IERC20 internal usdt;
    IPancakeRouter02 internal router;
    address internal pair;

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal lpHolder = makeAddr("lpHolder"); // 模拟用户, 用来买卖制造涨跌
    address internal cardHolder = makeAddr("cardHolder");

    function setUp() public {
        // ── 1. 部署代币 (YoloToken 代理) ──
        vm.createSelectFork("bsc_mainnet");
        usdt = IERC20(USDT_ADDR);
        router = IPancakeRouter02(ROUTER);

        YoloToken yoloImpl = new YoloToken();
        bytes memory yoloData = abi.encodeCall(
            YoloToken.initialize,
            (address(this), address(this), USDT_ADDR, address(this), FACTORY, ROUTER)
        );
        yolo = YoloToken(address(new TransparentUpgradeableProxy(address(yoloImpl), proxyAdmin, yoloData)));
        pair = yolo.mainPair(); // initialize 内自动 createPair

        // ── 2. 发行代币 (poolAllocate 铸造到 lpPool/cardPool) ──
        yolo.setPoolAddress(IYoloToken.YoloPool(lpHolder, cardHolder));
        yolo.poolAllocate();

        // 给 lpHolder 注入 USDT 并添加初始流动性 (建池子, 设初始币价)
        vm.prank(USDT_WHALE);
        usdt.transfer(lpHolder, 10_000 ether);
        vm.startPrank(lpHolder);
        yolo.approve(ROUTER, type(uint256).max);
        usdt.approve(ROUTER, type(uint256).max);
        router.addLiquidity(address(yolo), USDT_ADDR, 1_000_000 * 1e6, 1_000 ether, 0, 0, lpHolder, block.timestamp + 300);
        vm.stopPrank();

        // ── 3. 部署做市合约 + 给它放币 ──
        Marking markingImpl = new Marking();
        bytes memory mData = abi.encodeCall(Marking.initialize, ());
        marking = Marking(address(new TransparentUpgradeableProxy(address(markingImpl), proxyAdmin, mData)));
        marking.setConfig(address(yolo), USDT_ADDR, ROUTER, pair);

        // 做市合约绑回收权限 + 白名单 (卖出绕税费)
        yolo.setMarking(address(marking));
        address[] memory wl = new address[](2);
        wl[0] = address(marking);
        wl[1] = lpHolder;
        yolo.addWhitelist(wl);

        // 给做市合约放币: YOLO (卖出压价弹药) + USDT (买入托价弹药)
        vm.prank(lpHolder);
        yolo.transfer(address(marking), 5_000_000 * 1e6);
        vm.prank(USDT_WHALE);
        usdt.transfer(address(marking), 5_000 ether);

        // 授 keeper 角色 (本测试合约代调 executeMarketControl)
        marking.grantRole(marking.KEEPER_ROLE(), address(this));
    }

    // ── 唯一流程测试: 制造涨跌 -> 执行做市 -> 验证控制 ──
    function test_MarkingControlFlow() public {
        // 开启价格控制 (基准价 = 当前池价)
        uint256 baseline = marking.price();
        marking.setMarketControlPrice(baseline);

        console.log(unicode"\n========== 做市控制流程 ==========");
        _logPrice(unicode"初始基准价", baseline);

        // === 涨: 用户买入制造上涨 -> 做市卖出压价 ===
        console.log(unicode"\n--- [涨] 用户用 150 USDT 买入 YOLO 制造上涨 ---");
        _userBuy(150 ether);
        uint256 priceAfterPump = marking.price();
        _logPrice(unicode"拉升后池价", priceAfterPump);
        assertTrue(priceAfterPump > baseline, "pump should raise price");

        console.log(unicode"--- [做市] keeper 触发 executeMarketControl (应卖出压价) ---");
        marking.executeMarketControl();
        uint256 priceAfterControlDown = marking.price();
        _logPrice(unicode"做市后池价", priceAfterControlDown);
        // 做市把价格压回基准方向 (低于拉升后)
        assertLt(priceAfterControlDown, priceAfterPump, "control should press price down");

        // === 跌: 用户卖出制造下跌 -> 做市买入托价 ===
        console.log(unicode"\n--- [跌] 用户卖出 300000 YOLO 制造下跌 ---");
        _userSell(300_000 * 1e6);
        uint256 priceAfterDump = marking.price();
        _logPrice(unicode"砸盘后池价", priceAfterDump);
        assertTrue(priceAfterDump < baseline, "dump should drop price");

        console.log(unicode"--- [做市] keeper 触发 executeMarketControl (应买入托价) ---");
        marking.executeMarketControl();
        uint256 priceAfterControlUp = marking.price();
        _logPrice(unicode"做市后池价", priceAfterControlUp);
        // 做市把价格托回基准方向 (高于砸盘后)
        assertGt(priceAfterControlUp, priceAfterDump, "control should push price up");

        console.log(unicode"\n========== 结论 ==========");
        console.log(unicode"  涨 -> 做市卖出压价: 生效");
        console.log(unicode"  跌 -> 做市买入托价: 生效");
        console.log(unicode"  做市控制涨跌幅: 正常");
    }

    // ── 辅助: 用户买 YOLO (USDT->YOLO), 抬价 ──
    function _userBuy(uint256 usdtIn) internal {
        vm.startPrank(lpHolder);
        usdt.approve(ROUTER, type(uint256).max);
        address[] memory p = new address[](2);
        p[0] = USDT_ADDR;
        p[1] = address(yolo);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(usdtIn, 0, p, lpHolder, block.timestamp + 300);
        vm.stopPrank();
    }

    // ── 辅助: 用户卖 YOLO (YOLO->USDT), 砸价 ──
    function _userSell(uint256 yoloIn) internal {
        vm.startPrank(lpHolder);
        yolo.approve(ROUTER, type(uint256).max);
        address[] memory p = new address[](2);
        p[0] = address(yolo);
        p[1] = USDT_ADDR;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(yoloIn, 0, p, lpHolder, block.timestamp + 300);
        vm.stopPrank();
    }

    function _logPrice(string memory label, uint256 price) internal view {
        // price = 每 1 YOLO (1e6 raw) 的 USDT raw (18 位), 换算成可读 USDT/YOLO
        // 显示: price / 1e18 = 每 YOLO 多少 USDT
        uint256 whole = price / 1e18;
        uint256 frac = (price % 1e18) / 1e12; // 保留 6 位小数
        console.log(string.concat(label, unicode": ", vm.toString(whole), ".", _pad6(frac), unicode" USDT/YOLO  (raw ", vm.toString(price), unicode")"));
    }

    function _pad6(uint256 x) internal pure returns (string memory) {
        string memory s = vm.toString(x);
        uint256 len = bytes(s).length;
        if (len >= 6) return s;
        bytes memory z = new bytes(6 - len);
        for (uint256 i = 0; i < z.length; i++) z[i] = "0";
        return string.concat(string(z), s);
    }
}
