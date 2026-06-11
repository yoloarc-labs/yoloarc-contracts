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
    function _proxyAdminOrZero(address proxy) internal view returns (ProxyAdmin) {
        if (proxy == address(0)) {
            return ProxyAdmin(address(0));
        }
        return ProxyAdmin(getProxyAdminAddress(proxy));
    }
}
