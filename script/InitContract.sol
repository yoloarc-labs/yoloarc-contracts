// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {EnvContract} from "./EnvContract.sol";
import {MockERC20} from "./MockERC20.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {StakingManager} from "../src/core/StakingManager.sol";
import {EventManager} from "../src/core/EventManager.sol";
import {DaoRewardManager} from "../src/token/allocation/DaoRewardManager.sol";
import {FomoTreasureManager} from "../src/token/allocation/FomoTreasureManager.sol";
import {AirdropManager} from "../src/token/allocation/AirdropManager.sol";
import {MarketManager} from "../src/token/allocation/MarketManager.sol";
import {CapitalManager} from "../src/token/allocation/CapitalManager.sol";
import {EcosystemManager} from "../src/token/allocation/EcosystemManager.sol";
import {TechManager} from "../src/token/allocation/TechManager.sol";

contract InitContract is EnvContract {
    YoloToken public yoloToken;
    StakingManager public stakingManager;
    EventManager public eventManager;
    DaoRewardManager public daoRewardManager;
    FomoTreasureManager public fomoTreasureManager;
    AirdropManager public airdropManager;
    MarketManager public marketManager;
    CapitalManager public capitalManager;
    EcosystemManager public ecosystemManager;
    TechManager public techManager;
    MockERC20 public usdt;

    ProxyAdmin public yoloTokenProxyAdmin;
    ProxyAdmin public stakingManagerProxyAdmin;
    ProxyAdmin public eventManagerProxyAdmin;
    ProxyAdmin public daoRewardManagerProxyAdmin;
    ProxyAdmin public fomoTreasureManagerProxyAdmin;
    ProxyAdmin public airdropManagerProxyAdmin;
    ProxyAdmin public marketManagerProxyAdmin;
    ProxyAdmin public capitalManagerProxyAdmin;
    ProxyAdmin public ecosystemManagerProxyAdmin;
    ProxyAdmin public techManagerProxyAdmin;

    function initContracts() internal {
        CoreAddresses memory addresses = getAddresses();

        usdt = MockERC20(payable(addresses.usdtTokenAddress));
        yoloToken = YoloToken(payable(addresses.proxyYoloToken));
        stakingManager = StakingManager(payable(addresses.proxyStakingManager));
        eventManager = EventManager(payable(addresses.proxyEventManager));
        daoRewardManager = DaoRewardManager(payable(addresses.proxyDaoRewardManager));
        fomoTreasureManager = FomoTreasureManager(payable(addresses.proxyFomoTreasureManager));
        airdropManager = AirdropManager(payable(addresses.proxyAirdropManager));
        marketManager = MarketManager(payable(addresses.proxyMarketManager));
        capitalManager = CapitalManager(payable(addresses.proxyCapitalManager));
        ecosystemManager = EcosystemManager(payable(addresses.proxyEcosystemManager));
        techManager = TechManager(payable(addresses.proxyTechManager));

        yoloTokenProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(yoloToken)));
        stakingManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(stakingManager)));
        eventManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(eventManager)));
        daoRewardManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(daoRewardManager)));
        fomoTreasureManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(fomoTreasureManager)));
        airdropManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(airdropManager)));
        marketManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(marketManager)));
        capitalManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(capitalManager)));
        ecosystemManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(ecosystemManager)));
        techManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(techManager)));
    }
}
