// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";

import {ITransparentUpgradeableProxy, ProxyAdmin, TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EmptyContract} from "../src/utils/EmptyContract.sol";

import {InitContract} from "./InitContract.sol";
import {EventManager} from "../src/core/EventManager.sol";
import {MockERC20} from "./MockERC20.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";
import {UserManager} from "../src/core/UserManager.sol";
import {FomoTreasureManager} from "../src/core/FomoTreasureManager.sol";
import {CardManager} from "../src/token/allocation/CardManager.sol";
import {LpManager} from "../src/token/allocation/LpManager.sol";

// MODE=0 forge script DeployStakingScript --sig "deployCard()" --slow --multi --rpc-url https://go.getblock.io/00384bdf2ed44f53956c987b6866009e --broadcast
contract DeployStakingScript is InitContract {
    EmptyContract public emptyContract;

    ProxyAdmin public yoloTokenProxyAdmin;
    ProxyAdmin public userManagerProxyAdmin;
    ProxyAdmin public eventManagerProxyAdmin;
    ProxyAdmin public fomoTreasureManagerProxyAdmin;
    ProxyAdmin public cardManagerProxyAdmin;
    ProxyAdmin public lpManagerProxyAdmin;

    CardManager public cardManagerImplementation;
    CardManager public cardManager;

    LpManager public lpManagerImplementation;
    LpManager public lpManager;

    YoloToken public yoloTokenImplementation;
    YoloToken public yoloToken;

    UserManager public userManagerImplementation;
    UserManager public userManager;

    EventManager public eventManagerImplementation;
    EventManager public eventManager;

    FomoTreasureManager public  fomoTreasureManagerImplementation;
    FomoTreasureManager public fomoTreasureManager;


    uint256 deployerPrivateKey;

    function deployCard() public {
        (
            address deployerAddress,
            address distributeRewardAddress,
            address chooseMeMultiSign,
            address chooseMeMultiSign2,
            address usdtTokenAddress
        ) = getENVAddress();

        deployerAddress;

        vm.startBroadcast(deployerPrivateKey);

        // =============== CardManager ================
        cardManagerImplementation = new CardManager();
        bytes memory initData = abi.encodeCall(CardManager.initialize, (
            chooseMeMultiSign,      // initialOwner
            chooseMeMultiSign,      // _manager
            chooseMeMultiSign2,     // _contractCaller
            usdtTokenAddress,       // _underlyingToken
            getCardNftJson()        // _nftJson
        ));
        TransparentUpgradeableProxy proxyCardManager = new TransparentUpgradeableProxy(
            address(cardManagerImplementation),
            chooseMeMultiSign,
            initData
        );
        cardManager = CardManager(payable(address(proxyCardManager)));
        cardManagerProxyAdmin = ProxyAdmin(
            getProxyAdminAddress(address(proxyCardManager))
        );



        console.log("CardManager Proxy:", address(cardManager));
        console.log("CardManager Implementation:", address(cardManagerImplementation));
        console.log("CardManager ProxyAdmin:", address(cardManagerProxyAdmin));

        vm.stopBroadcast();
    }

    function upgradeAll() public {

    }

    function _getCurPrivateKey() public  {
        deployerPrivateKey = super.getCurPrivateKey();
    }

    function getENVAddress() public returns (
        address deployerAddress,
        address distributeRewardAddress,
        address chooseMeMultiSign,
        address chooseMeMultiSign2,
        address usdtTokenAddress
    )
    {
        _getCurPrivateKey();

        uint256 mode = vm.envUint("MODE");
        console.log("mode:", mode == 0 ? "development" : "production");
        if (mode == 0) {
            vm.startBroadcast(deployerPrivateKey);
            deployerAddress = vm.addr(deployerPrivateKey);
            distributeRewardAddress = deployerAddress;
            chooseMeMultiSign = deployerAddress;
            chooseMeMultiSign2 = deployerAddress;
            ERC20 usdtToken = new TestUSDT();
            usdtTokenAddress = address(usdtToken);
            vm.stopBroadcast();
        } else {
            deployerAddress = vm.addr(deployerPrivateKey);
            distributeRewardAddress = vm.envAddress("DR_ADDRESS");
            chooseMeMultiSign = vm.envAddress("MULTI_SIGNER");
            chooseMeMultiSign2 = vm.envAddress("MULTI_SIGNER_2");
            usdtTokenAddress = vm.envAddress("USDT_TOKEN_ADDRESS");
        }
    }


}
