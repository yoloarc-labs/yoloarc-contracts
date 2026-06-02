// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {EnvContract} from "./EnvContract.sol";
import {MockERC20} from "./MockERC20.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {UserManager} from "../src/core/UserManager.sol";
import {FomoTreasureManager} from "../src/core/FomoTreasureManager.sol";
import {CardManager} from "../src/token/allocation/CardManager.sol";
import {LpManager} from "../src/token/allocation/LpManager.sol";

contract InitContract is EnvContract {
    YoloToken public yoloToken;
    UserManager public userManager;
    address public eventManager;
    FomoTreasureManager public fomoTreasureManager;
    CardManager public cardManager;
    LpManager public lpManager;
    MockERC20 public usdt;

    ProxyAdmin public yoloTokenProxyAdmin;
    ProxyAdmin public userManagerProxyAdmin;
    ProxyAdmin public eventManagerProxyAdmin;
    ProxyAdmin public fomoTreasureManagerProxyAdmin;
    ProxyAdmin public cardManagerProxyAdmin;
    ProxyAdmin public lpManagerProxyAdmin;

    function initContracts() internal {
        CoreAddresses memory addresses = getAddresses();

        usdt = MockERC20(payable(addresses.usdtTokenAddress));
        yoloToken = YoloToken(payable(addresses.proxyYoloToken));
        userManager = UserManager(payable(addresses.proxyUserManager));
        eventManager = addresses.proxyEventManager;
        fomoTreasureManager = FomoTreasureManager(payable(addresses.proxyFomoTreasureManager));
        cardManager = CardManager(payable(addresses.proxyCardManager));
        lpManager = LpManager(payable(addresses.proxyLpManager));

        yoloTokenProxyAdmin = _proxyAdminOrZero(address(yoloToken));
        userManagerProxyAdmin = _proxyAdminOrZero(address(userManager));
        eventManagerProxyAdmin = _proxyAdminOrZero(eventManager);
        fomoTreasureManagerProxyAdmin = _proxyAdminOrZero(address(fomoTreasureManager));
        cardManagerProxyAdmin = _proxyAdminOrZero(address(cardManager));
        lpManagerProxyAdmin = _proxyAdminOrZero(address(lpManager));
    }

    function _proxyAdminOrZero(address proxy) internal view returns (ProxyAdmin) {
        if (proxy == address(0)) {
            return ProxyAdmin(address(0));
        }
        return ProxyAdmin(getProxyAdminAddress(proxy));
    }
}
