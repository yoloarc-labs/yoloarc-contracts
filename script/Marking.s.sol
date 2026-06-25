// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPancakeRouter02} from "@pancake-v2-periphery/interfaces/IPancakeRouter02.sol";

import {YoloToken} from "../src/token/YoloToken.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";
import {Marking} from "../src/marketing/Marking.sol";

/**
 * YoloToken + Marking 做市体系部署/运维脚本 (BSC 主网)
 * deployer = 0x6FD105357f893Dc85C4bf58a23C66B0A45A77777 (keystore: yoloarc), 各命令 --sender 用此地址
 *
 * 方法与运行命令 (每个 --sig 一行, 直接复制运行, 加 --broadcast 上链):
 *
 * 1. 一键部署 (代币+做市+建池+权限+开启控制):
 *    forge script script/Marking.s.sol:MarkingScript --rpc-url bsc_mainnet --account yoloarc --sender 0x6FD105357f893Dc85C4bf58a23C66B0A45A77777 --broadcast
 *
 * 2. 读取链上状态 (不上链, 不用 --broadcast):
 *    forge script script/Marking.s.sol:MarkingScript --rpc-url bsc_mainnet --account yoloarc --sender 0x6FD105357f893Dc85C4bf58a23C66B0A45A77777 --sig "read()"
 *
 * 3. 开放交易 (让其他地址能买卖; 默认 isOpenBuy/isOpenSell=false 只白名单能交易):
 *    forge script script/Marking.s.sol:MarkingScript --rpc-url bsc_mainnet --account yoloarc --sender 0x6FD105357f893Dc85C4bf58a23C66B0A45A77777 --sig "openTrading()" --broadcast
 *
 * 4. 调整基准价 (开启/改价格控制, 0=关闭):
 *    forge script script/Marking.s.sol:MarkingScript --rpc-url bsc_mainnet --account yoloarc --sender 0x6FD105357f893Dc85C4bf58a23C66B0A45A77777 --sig "setControlPrice(uint256)" 498749502497 --broadcast
 *
 * 5. 手动触发做市 (需 sender 有 KEEPER_ROLE):
 *    forge script script/Marking.s.sol:MarkingScript --rpc-url bsc_mainnet --account yoloarc --sender 0x6FD105357f893Dc85C4bf58a23C66B0A45A77777 --sig "executeControl()" --broadcast
 *
 * 6. 授 keeper 角色:
 *    forge script script/Marking.s.sol:MarkingScript --rpc-url bsc_mainnet --account yoloarc --sender 0x6FD105357f893Dc85C4bf58a23C66B0A45A77777 --sig "grantKeeper(address)" <地址> --broadcast
 *
 * 7. 升级 Marking (自动部署新 impl + 升级, 无需手填地址):
 *    forge script script/Marking.s.sol:MarkingScript --rpc-url bsc_mainnet --account yoloarc --sender 0x6FD105357f893Dc85C4bf58a23C66B0A45A77777 --sig "upgradeMarking()" --broadcast
 *
 * 8. 升级 YoloToken (自动部署新 impl + 升级):
 *    forge script script/Marking.s.sol:MarkingScript --rpc-url bsc_mainnet --account yoloarc --sender 0x6FD105357f893Dc85C4bf58a23C66B0A45A77777 --sig "upgradeYolo()" --broadcast
 */
contract MarkingScript is Script {
    // ========== BSC 主网固定地址 ==========
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955; // BSC USDT
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73; // PancakeV2 Factory
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeV2 Router

    // ========== 已部署地址 (部署后回填; 重新部署需更新) ==========
    address constant PROXY_ADMIN = 0x7cAC360fC2f519e63A177ABcfbA5f3aC89D1B56a;
    address constant YOLO = 0xccB5d487d45b991206Bad3F00682EC37dB5c5911;
    address constant MARKING = 0x211256fdD03675bB32Ba41cb54E0766e5d893709;
    address constant PAIR = 0xc6441b689122b99c1AC81ea8224078a4DFe39043;

    // ========== 部署默认量 (deploy 用) ==========
    uint256 constant LP_YOLO = 1_000_000 * 1e6; // 100 万 YOLO
    uint256 constant LP_USDT = 0.5 ether; // 0.5 USDT
    uint256 constant MARKING_YOLO_AMMO = 100_000 * 1e6; // 10 万 YOLO
    uint256 constant MARKING_USDT_AMMO = 0.5 ether; // 0.5 USDT

    // ============================================================
    // 1. 一键部署
    // ============================================================
    function deploy() public {
        address deployer = msg.sender;

        ProxyAdmin admin = new ProxyAdmin(deployer);
        YoloToken yoloImpl = new YoloToken();
        bytes memory yoloData =
            abi.encodeCall(YoloToken.initialize, (deployer, deployer, USDT, deployer, FACTORY, ROUTER));
        TransparentUpgradeableProxy yoloProxy =
            new TransparentUpgradeableProxy(address(yoloImpl), address(admin), yoloData);
        YoloToken yolo = YoloToken(address(yoloProxy));
        address pair = yolo.mainPair();

        yolo.setPoolAddress(IYoloToken.YoloPool(deployer, deployer));
        yolo.poolAllocate();

        Marking markingImpl = new Marking();
        bytes memory mData = abi.encodeCall(Marking.initialize, ());
        TransparentUpgradeableProxy markingProxy =
            new TransparentUpgradeableProxy(address(markingImpl), address(admin), mData);
        Marking marking = Marking(address(markingProxy));

        yolo.setMarking(address(marking));
        address[] memory wl = new address[](2);
        wl[0] = address(marking);
        wl[1] = deployer;
        yolo.addWhitelist(wl);
        yolo.setPlatformAddress(deployer); // 设卖税接收地址 (fomoTreasureAddress), 不设非白名单卖出会 revert
        marking.setConfig(address(yolo), USDT, ROUTER, pair);

        yolo.approve(ROUTER, type(uint256).max);
        IERC20(USDT).approve(ROUTER, type(uint256).max);
        IPancakeRouter02(ROUTER).addLiquidity(
            address(yolo), USDT, LP_YOLO, LP_USDT, 0, 0, deployer, block.timestamp + 600
        );

        yolo.transfer(address(marking), MARKING_YOLO_AMMO);
        IERC20(USDT).transfer(address(marking), MARKING_USDT_AMMO);

        marking.grantRole(marking.KEEPER_ROLE(), deployer);
        marking.setMarketControlPrice(marking.price());

        console.log(unicode"=== 部署完成 ===");
        console.log(unicode"ProxyAdmin(代理管理员):", address(admin));
        console.log(unicode"YoloToken impl(代币实现):", address(yoloImpl));
        console.log(unicode"YoloToken(代币代理):", address(yolo));
        console.log(unicode"Marking impl(做市实现):", address(markingImpl));
        console.log(unicode"Marking(做市代理):", address(marking));
        console.log(unicode"Pair(交易对):", pair);
        console.log(unicode"ControlPrice(基准价 raw):", marking.marketControlPrice());
    }

    // ============================================================
    // 2. 读取链上状态
    // ============================================================
    function read() public view {
        YoloToken yolo = YoloToken(YOLO);
        Marking marking = Marking(MARKING);
        (uint256 base, uint256 cur, uint256 upper, uint256 lower) = marking.marketControlStatus();
        console.log(unicode"=== 链上状态 ===");
        console.log(unicode"YoloToken(代币代理):", YOLO);
        console.log(unicode"Marking(做市代理):", MARKING);
        console.log(unicode"Pair(交易对):", PAIR);
        console.log(unicode"operator(操作员):", yolo.operator());
        console.log(unicode"marking(代币绑定做市):", yolo.marking());
        console.log(unicode"whitelist marking(做市是否白名单):", yolo.isWhitelisted(MARKING, MARKING));
        console.log(unicode"Marking enable(做市开关):", marking.enable());
        console.log(unicode"--- 价格控制 ---");
        console.log(string.concat(unicode"基准价(baseline): ", _fmt(base, 18, unicode"USDT/YOLO"), unicode"  (raw ", vm.toString(base), unicode")"));
        console.log(string.concat(unicode"当前价(current): ", _fmt(cur, 18, unicode"USDT/YOLO"), unicode"  (raw ", vm.toString(cur), unicode")"));
        console.log(string.concat(unicode"涨跌幅(vs基准): ", _pct(cur, base)));
        console.log(string.concat(unicode"上限(upper,超此卖出压价): ", _fmt(upper, 18, unicode"USDT/YOLO")));
        console.log(string.concat(unicode"下限(lower,低此买入托价): ", _fmt(lower, 18, unicode"USDT/YOLO")));
        console.log(unicode"--- 做市弹药 ---");
        console.log(string.concat(unicode"YOLO 弹药: ", _fmt(IERC20(YOLO).balanceOf(MARKING), 6, unicode"YOLO")));
        console.log(string.concat(unicode"USDT 弹药: ", _fmt(IERC20(USDT).balanceOf(MARKING), 18, unicode"USDT")));
    }

    // ============================================================
    // 格式化辅助: raw -> "整数.小数 单位"
    // ============================================================
    function _fmt(uint256 raw, uint8 dec, string memory unit) internal pure returns (string memory) {
        uint256 factor = 10 ** uint256(dec);
        uint256 whole = raw / factor;
        uint256 frac = raw % factor;
        return string.concat(vm.toString(whole), unicode".", _pad(frac, dec), unicode" ", unit);
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

    // 涨跌幅: (current - baseline) / baseline, 显示为 "x.xx%" (基点换算)
    function _pct(uint256 current, uint256 base) internal pure returns (string memory) {
        if (base == 0) return unicode"n/a";
        bool neg = current < base;
        uint256 diff = neg ? base - current : current - base;
        // bps = diff * 10000 / base; 显示 bps/100 = 百分比, 两位小数
        uint256 bps = (diff * 10000) / base;
        uint256 whole = bps / 100;
        uint256 frac = bps % 100;
        string memory sign = neg ? unicode"-" : unicode"+";
        return string.concat(sign, vm.toString(whole), unicode".", _pad(frac, 2), unicode"%  (区间 ±2%)");
    }

    // ============================================================
    // 3. 开放交易 (其他地址能买卖)
    // ============================================================
    function openTrading() public {
        YoloToken yolo = YoloToken(YOLO);
        yolo.openBuy(true);
        yolo.openSell(true);
        console.log(unicode"=== 已开放交易 ===");
        console.log(unicode"isOpenBuy/isOpenSell(买入卖出): 已对非白名单开放");
    }

    // ============================================================
    // 4. 调整基准价 (0 = 关闭价格控制)
    // ============================================================
    function setControlPrice(uint256 price) public {
        Marking marking = Marking(MARKING);
        marking.setMarketControlPrice(price);
        console.log(unicode"=== 基准价已设 ===");
        console.log(unicode"marketControlPrice(基准价 raw):", marking.marketControlPrice());
    }

    // ============================================================
    // 5. 手动触发做市
    // ============================================================
    function executeControl() public {
        Marking marking = Marking(MARKING);
        uint256 before = marking.price();
        marking.executeMarketControl();
        uint256 afterPrice = marking.price();
        console.log(unicode"=== 做市已触发 ===");
        console.log(unicode"price before(执行前 raw):", before);
        console.log(unicode"price after(执行后 raw):", afterPrice);
    }

    // ============================================================
    // 6. 授 keeper 角色
    // ============================================================
    function grantKeeper(address addr) public {
        Marking marking = Marking(MARKING);
        marking.grantRole(marking.KEEPER_ROLE(), addr);
        console.log(unicode"=== KEEPER_ROLE 已授 ===");
        console.log(unicode"keeper(做市触发地址):", addr);
        console.log(unicode"hasRole(是否已授权):", marking.hasRole(marking.KEEPER_ROLE(), addr) ? 1 : 0);
    }

    // ============================================================
    // 7. 升级 Marking (自动部署新 impl + 升级代理, 无需手填地址)
    // ============================================================
    function upgradeMarking() public {
        ProxyAdmin admin = ProxyAdmin(PROXY_ADMIN);
        Marking newImpl = new Marking();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(MARKING), address(newImpl), "");
        console.log(unicode"=== Marking 已升级 ===");
        console.log(unicode"Marking(做市代理):", MARKING);
        console.log(unicode"new impl(新实现):", address(newImpl));
    }

    // ============================================================
    // 8. 升级 YoloToken (自动部署新 impl + 升级代理)
    // ============================================================
    function upgradeYolo() public {
        ProxyAdmin admin = ProxyAdmin(PROXY_ADMIN);
        YoloToken newImpl = new YoloToken();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(YOLO), address(newImpl), "");
        console.log(unicode"=== YoloToken 已升级 ===");
        console.log(unicode"YoloToken(代币代理):", YOLO);
        console.log(unicode"new impl(新实现):", address(newImpl));
    }

    // ============================================================
    // 默认入口 = 部署
    // ============================================================
    function run() external {
        vm.startBroadcast();
        deploy();
        vm.stopBroadcast();
    }
}
