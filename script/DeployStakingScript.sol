// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";

import {
    ITransparentUpgradeableProxy,
    ProxyAdmin,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {InitContract} from "./InitContract.sol";
import {MockERC20} from "./MockERC20.sol";

import {FomoTreasureManager} from "../src/core/FomoTreasureManager.sol";
import {UserManager} from "../src/core/UserManager.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {CardManager} from "../src/token/allocation/CardManager.sol";
import {LpManager} from "../src/token/allocation/LpManager.sol";
import {EmptyContract} from "../src/utils/EmptyContract.sol";

// MODE=1 forge script script/DeployStakingScript.sol:DeployStakingScript --sig "deployAll()" --slow --multi --rpc-url https://shared.ap-southeast-1.getblock.io/8e87ac495a5941ae9dfb9ea6ed9ae7d2 --broadcast --verify --etherscan-api-key I4C1AKJT8J9KJVCXHZKK317T3XV8IVASRX
// MODE=1 forge script script/DeployStakingScript.sol:DeployStakingScript --sig "upgradeAll()" --slow --multi --rpc-url https://shared.ap-southeast-1.getblock.io/8e87ac495a5941ae9dfb9ea6ed9ae7d2 --broadcast --verify --etherscan-api-key I4C1AKJT8J9KJVCXHZKK317T3XV8IVASRX
contract DeployStakingScript is InitContract {
    struct DeployEnv {
        address deployerAddress;
        address distributeRewardAddress;
        address chooseMeMultiSign;
        address chooseMeMultiSign2;
        address usdtTokenAddress;
        address pancakeV2Factory;
        address pancakeV2Router;
    }

    EmptyContract public emptyContract;

    ProxyAdmin public yoloTokenProxyAdmin;
    ProxyAdmin public userManagerProxyAdmin;
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

    FomoTreasureManager public fomoTreasureManagerImplementation;
    FomoTreasureManager public fomoTreasureManager;

    uint256 deployerPrivateKey;

    function deployAll() public {
        DeployEnv memory env = _getENVAddress();

        vm.startBroadcast(deployerPrivateKey);

        emptyContract = new EmptyContract();
        _deployEmptyProxies(env.chooseMeMultiSign);
        _deployImplementations();
        _upgradeAndInitializeAll(env);

        vm.stopBroadcast();

        _writeDeployAddresses(env.usdtTokenAddress);
        _logAll();
    }

    function deployCard() public {
        DeployEnv memory env = _getENVAddress();

        vm.startBroadcast(deployerPrivateKey);

        cardManagerImplementation = new CardManager();
        bytes memory initData = abi.encodeCall(
            CardManager.initialize,
            (
                env.chooseMeMultiSign,
                env.chooseMeMultiSign,
                env.chooseMeMultiSign2,
                env.usdtTokenAddress,
                getCardNftJson()
            )
        );
        TransparentUpgradeableProxy proxyCardManager =
            new TransparentUpgradeableProxy(address(cardManagerImplementation), env.chooseMeMultiSign, initData);
        cardManager = CardManager(payable(address(proxyCardManager)));
        cardManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(proxyCardManager)));

        vm.stopBroadcast();

        _writeDeployAddress("usdtTokenAddress", env.usdtTokenAddress);
        _writeDeployAddress("proxyCardManager", address(cardManager));
        _logContract(
            "CardManager", address(cardManager), address(cardManagerImplementation), address(cardManagerProxyAdmin)
        );
    }

    function upgradeAll() public {
        _getCurPrivateKey();
        _initContracts();

        vm.startBroadcast(deployerPrivateKey);

        yoloTokenImplementation = new YoloToken();
        userManagerImplementation = new UserManager();
        fomoTreasureManagerImplementation = new FomoTreasureManager();
        cardManagerImplementation = new CardManager();
        lpManagerImplementation = new LpManager();

//        _upgrade(yoloTokenProxyAdmin, address(yoloToken), address(yoloTokenImplementation));
//        _upgrade(userManagerProxyAdmin, address(userManager), address(userManagerImplementation));
//        _upgrade(
//            fomoTreasureManagerProxyAdmin, address(fomoTreasureManager), address(fomoTreasureManagerImplementation)
//        );
         _upgrade(cardManagerProxyAdmin, address(cardManager), address(cardManagerImplementation));
        // _upgrade(lpManagerProxyAdmin, address(lpManager), address(lpManagerImplementation));

        vm.stopBroadcast();

        _logAll();
    }

    function _deployEmptyProxies(address proxyAdminOwner) internal {
        bytes memory emptyInitData = abi.encodeCall(EmptyContract.foo, ());

        TransparentUpgradeableProxy proxyYoloToken =
            new TransparentUpgradeableProxy(address(emptyContract), proxyAdminOwner, emptyInitData);
        yoloToken = YoloToken(payable(address(proxyYoloToken)));
        yoloTokenProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(proxyYoloToken)));

        TransparentUpgradeableProxy proxyUserManager =
            new TransparentUpgradeableProxy(address(emptyContract), proxyAdminOwner, emptyInitData);
        userManager = UserManager(payable(address(proxyUserManager)));
        userManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(proxyUserManager)));

        TransparentUpgradeableProxy proxyFomoTreasureManager =
            new TransparentUpgradeableProxy(address(emptyContract), proxyAdminOwner, emptyInitData);
        fomoTreasureManager = FomoTreasureManager(payable(address(proxyFomoTreasureManager)));
        fomoTreasureManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(proxyFomoTreasureManager)));

        TransparentUpgradeableProxy proxyCardManager =
            new TransparentUpgradeableProxy(address(emptyContract), proxyAdminOwner, emptyInitData);
        cardManager = CardManager(payable(address(proxyCardManager)));
        cardManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(proxyCardManager)));

        TransparentUpgradeableProxy proxyLpManager =
            new TransparentUpgradeableProxy(address(emptyContract), proxyAdminOwner, emptyInitData);
        lpManager = LpManager(payable(address(proxyLpManager)));
        lpManagerProxyAdmin = ProxyAdmin(getProxyAdminAddress(address(proxyLpManager)));
    }

    function _deployImplementations() internal {
        yoloTokenImplementation = new YoloToken();
        userManagerImplementation = new UserManager();
        fomoTreasureManagerImplementation = new FomoTreasureManager();
        cardManagerImplementation = new CardManager();
        lpManagerImplementation = new LpManager();
    }

    function _upgradeAndInitializeAll(DeployEnv memory env) internal {
        _upgradeAndCall(
            yoloTokenProxyAdmin,
            address(yoloToken),
            address(yoloTokenImplementation),
            abi.encodeCall(
                YoloToken.initialize,
                (
                    env.chooseMeMultiSign,
                    address(userManager),
                    env.usdtTokenAddress,
                    address(fomoTreasureManager),
                    env.pancakeV2Factory,
                    env.pancakeV2Router
                )
            )
        );
        _upgradeAndCall(
            userManagerProxyAdmin,
            address(userManager),
            address(userManagerImplementation),
            abi.encodeCall(
                UserManager.initialize,
                (env.chooseMeMultiSign, env.distributeRewardAddress, address(yoloToken), env.chooseMeMultiSign2)
            )
        );
        _upgradeAndCall(
            fomoTreasureManagerProxyAdmin,
            address(fomoTreasureManager),
            address(fomoTreasureManagerImplementation),
            abi.encodeCall(FomoTreasureManager.initialize, (env.chooseMeMultiSign, env.usdtTokenAddress))
        );
        _upgradeAndCall(
            cardManagerProxyAdmin,
            address(cardManager),
            address(cardManagerImplementation),
            abi.encodeCall(
                CardManager.initialize,
                (
                    env.chooseMeMultiSign,
                    env.chooseMeMultiSign,
                    env.chooseMeMultiSign2,
                    env.usdtTokenAddress,
                    getCardNftJson()
                )
            )
        );
        _upgradeAndCall(
            lpManagerProxyAdmin,
            address(lpManager),
            address(lpManagerImplementation),
            abi.encodeCall(
                LpManager.initialize,
                (
                    env.chooseMeMultiSign,
                    env.chooseMeMultiSign,
                    address(yoloToken),
                    env.usdtTokenAddress,
                    env.pancakeV2Router
                )
            )
        );
    }

    function _initContracts() internal {
        CoreAddresses memory addresses = getAddresses();

        yoloToken = YoloToken(payable(addresses.proxyYoloToken));
        userManager = UserManager(payable(addresses.proxyUserManager));
        fomoTreasureManager = FomoTreasureManager(payable(addresses.proxyFomoTreasureManager));
        cardManager = CardManager(payable(addresses.proxyCardManager));
        lpManager = LpManager(payable(addresses.proxyLpManager));

        yoloTokenProxyAdmin = _proxyAdminOrZero(address(yoloToken));
        userManagerProxyAdmin = _proxyAdminOrZero(address(userManager));
        fomoTreasureManagerProxyAdmin = _proxyAdminOrZero(address(fomoTreasureManager));
        cardManagerProxyAdmin = _proxyAdminOrZero(address(cardManager));
        lpManagerProxyAdmin = _proxyAdminOrZero(address(lpManager));

        _requireProxy(address(yoloToken), "YoloToken");
        _requireProxy(address(userManager), "UserManager");
        _requireProxy(address(fomoTreasureManager), "FomoTreasureManager");
        _requireProxy(address(cardManager), "CardManager");
        _requireProxy(address(lpManager), "LpManager");
    }

    function _upgrade(ProxyAdmin proxyAdmin, address proxy, address implementation) internal {
        _upgradeAndCall(proxyAdmin, proxy, implementation, "");
    }

    function _upgradeAndCall(ProxyAdmin proxyAdmin, address proxy, address implementation, bytes memory data) internal {
        require(proxyAdmin != ProxyAdmin(address(0)), "DeployStakingScript: proxy admin not found");
        require(proxy != address(0), "DeployStakingScript: proxy not found");
        require(implementation != address(0), "DeployStakingScript: implementation not found");

        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, data);
    }

    function _requireProxy(address proxy, string memory name) internal pure {
        require(proxy != address(0), string.concat("DeployStakingScript: missing proxy ", name));
    }

    function _getCurPrivateKey() public {
        deployerPrivateKey = super.getCurPrivateKey();
    }

    function getENVAddress()
        public
        returns (
            address deployerAddress,
            address distributeRewardAddress,
            address chooseMeMultiSign,
            address chooseMeMultiSign2,
            address usdtTokenAddress
        )
    {
        DeployEnv memory env = _getENVAddress();
        return (
            env.deployerAddress,
            env.distributeRewardAddress,
            env.chooseMeMultiSign,
            env.chooseMeMultiSign2,
            env.usdtTokenAddress
        );
    }

    function _getENVAddress() internal returns (DeployEnv memory env) {
        _getCurPrivateKey();

        uint256 mode = vm.envUint("MODE");
        console.log("mode:", mode == 0 ? "development" : "production");

        env.deployerAddress = vm.addr(deployerPrivateKey);
        (env.pancakeV2Factory, env.pancakeV2Router) = _getPancakeV2Addresses();
        if (mode == 0) {
            vm.startBroadcast(deployerPrivateKey);
            MockERC20 usdtToken = new MockERC20("Test USDT", "USDT");
            env.usdtTokenAddress = address(usdtToken);
            vm.stopBroadcast();

            env.distributeRewardAddress = env.deployerAddress;
            env.chooseMeMultiSign = env.deployerAddress;
            env.chooseMeMultiSign2 = env.deployerAddress;
        } else {
            env.distributeRewardAddress = vm.envAddress("DR_ADDRESS");
            env.chooseMeMultiSign = vm.envAddress("MULTI_SIGNER");
            env.chooseMeMultiSign2 = vm.envAddress("MULTI_SIGNER_2");
            env.usdtTokenAddress = vm.envAddress("USDT_TOKEN_ADDRESS");
        }
    }

    function _getPancakeV2Addresses() internal view returns (address factory, address router) {
        if (block.chainid == 97) {
            factory = _envAddressOr("PANCAKE_V2_FACTORY", 0x6725F303b657a9451d8BA641348b6761A6CC7a17);
            router = _envAddressOr("PANCAKE_V2_ROUTER", 0xD99D1c33F9fC3444f8101754aBC46c52416550D1);
        } else {
            factory = _envAddressOr("PANCAKE_V2_FACTORY", 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
            router = _envAddressOr("PANCAKE_V2_ROUTER", 0x10ED43C718714eb63d5aA57B78B54704E256024E);
        }
    }

    function _writeDeployAddresses(address usdtTokenAddress) internal {
        string memory path = getDeployPath();
        string memory root = "deployed";

        vm.serializeAddress(root, "usdtTokenAddress", usdtTokenAddress);
        vm.serializeAddress(root, "proxyYoloToken", address(yoloToken));
        vm.serializeAddress(root, "proxyUserManager", address(userManager));
        vm.serializeAddress(root, "proxyFomoTreasureManager", address(fomoTreasureManager));
        vm.serializeAddress(root, "proxyCardManager", address(cardManager));
        string memory json = vm.serializeAddress(root, "proxyLpManager", address(lpManager));

        vm.writeJson(json, path);
    }

    function _writeDeployAddress(string memory key, address value) internal {
        string memory path = getDeployPath();
        string memory root = "deployed";
        string memory json = _readDeployJson();

        string memory serialized = vm.serializeAddress(root, key, value);
        if (bytes(json).length == 0 || keccak256(bytes(json)) == keccak256(bytes("{}"))) {
            vm.writeJson(serialized, path);
        } else {
            vm.writeJson(serialized, path, string.concat(".", key));
        }
    }

    function _logAll() internal view {
        console.log("Deploy Path:", getDeployPath());
        _logContract("YoloToken", address(yoloToken), address(yoloTokenImplementation), address(yoloTokenProxyAdmin));
        _logContract(
            "UserManager", address(userManager), address(userManagerImplementation), address(userManagerProxyAdmin)
        );
        _logContract(
            "FomoTreasureManager",
            address(fomoTreasureManager),
            address(fomoTreasureManagerImplementation),
            address(fomoTreasureManagerProxyAdmin)
        );
        _logContract(
            "CardManager", address(cardManager), address(cardManagerImplementation), address(cardManagerProxyAdmin)
        );
        _logContract("LpManager", address(lpManager), address(lpManagerImplementation), address(lpManagerProxyAdmin));
    }

    function _logContract(string memory name, address proxy, address implementation, address proxyAdmin) internal pure {
        console.log(string.concat(name, " Proxy:"), proxy);
        console.log(string.concat(name, " Implementation:"), implementation);
        console.log(string.concat(name, " ProxyAdmin:"), proxyAdmin);
    }
}
