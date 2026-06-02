// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {ITransparentUpgradeableProxy, ProxyAdmin, TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {InitContract} from "./InitContract.sol";
import {MockERC20} from "./MockERC20.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";
import {UserManager} from "../src/core/UserManager.sol";
import {FomoTreasureManager} from "../src/core/FomoTreasureManager.sol";
import {CardManager} from "../src/token/allocation/CardManager.sol";
import {LpManager} from "../src/token/allocation/LpManager.sol";

contract DeployStakingScript is InitContract {
    function run() external {
        deployAll();
    }

    function deployAll() public {
        uint256 deployerPrivateKey = getCurPrivateKey();
        address owner = getOwnerAddress();
        address manager = getManagerAddress();
        address contractCaller = getContractCallerAddress();
        address feeVault = getFeeVaultAddress();
        address usdtAddress = getUsdtAddress();
        address fundingPod = getFundingPodAddress();
        address eventManagerAddress = getEventManagerAddress();
        string memory nftJson = getCardNftJson();

        vm.startBroadcast(deployerPrivateKey);

        if (usdtAddress == address(0)) {
            MockERC20 mockUSDT = new MockERC20("Mock USDT", "USDT");
            usdtAddress = address(mockUSDT);
            mockUSDT.mint(owner, 100_000_000 ether);
        }

        CoreAddresses memory deployed;
        deployed.usdtTokenAddress = usdtAddress;
        deployed.proxyEventManager = eventManagerAddress;

        UserManager userManagerImplementation = new UserManager();
        deployed.proxyUserManager = _deployProxy(
            address(userManagerImplementation),
            owner,
            abi.encodeWithSelector(UserManager.initialize.selector, owner, manager, address(0), contractCaller)
        );

        YoloToken yoloTokenImplementation = new YoloToken();
        deployed.proxyYoloToken = _deployProxy(
            address(yoloTokenImplementation),
            owner,
            abi.encodeWithSelector(
                YoloToken.initialize.selector,
                owner,
                deployed.proxyUserManager,
                usdtAddress,
                fundingPod == address(0) ? manager : fundingPod
            )
        );

        FomoTreasureManager fomoTreasureManagerImplementation = new FomoTreasureManager();
        deployed.proxyFomoTreasureManager = _deployProxy(
            address(fomoTreasureManagerImplementation),
            owner,
            abi.encodeWithSelector(FomoTreasureManager.initialize.selector, owner, deployed.proxyYoloToken)
        );

        CardManager cardManagerImplementation = new CardManager();
        deployed.proxyCardManager = _deployProxy(
            address(cardManagerImplementation),
            owner,
            abi.encodeWithSelector(
                CardManager.initialize.selector,
                owner,
                manager,
                usdtAddress,
                feeVault,
                contractCaller,
                nftJson
            )
        );

        LpManager lpManagerImplementation = new LpManager();
        deployed.proxyLpManager = _deployProxy(
            address(lpManagerImplementation),
            owner,
            abi.encodeWithSelector(
                LpManager.initialize.selector,
                owner,
                owner,
                deployed.proxyYoloToken,
                usdtAddress
            )
        );

        UserManager(payable(deployed.proxyUserManager)).setYoloToken(deployed.proxyYoloToken);
        YoloToken(payable(deployed.proxyYoloToken)).setPlatformAddress(deployed.proxyFomoTreasureManager);
        CardManager(payable(deployed.proxyCardManager)).setFundManager(manager);

        _configureTokenPools(deployed);
        _configureAuthorizedCallers(deployed, owner, manager, contractCaller);

        vm.stopBroadcast();

        _logDeployments(deployed);
        _writeDeployments(deployed);
    }

    function upgradeCore() public {
        uint256 deployerPrivateKey = getCurPrivateKey();
        initContracts();

        vm.startBroadcast(deployerPrivateKey);

        _upgradeProxy(yoloTokenProxyAdmin, address(yoloToken), address(new YoloToken()));
        _upgradeProxy(userManagerProxyAdmin, address(userManager), address(new UserManager()));

        vm.stopBroadcast();
    }

    function upgradeAllocations() public {
        uint256 deployerPrivateKey = getCurPrivateKey();
        initContracts();

        vm.startBroadcast(deployerPrivateKey);

        _upgradeProxy(fomoTreasureManagerProxyAdmin, address(fomoTreasureManager), address(new FomoTreasureManager()));
        _upgradeProxy(cardManagerProxyAdmin, address(cardManager), address(new CardManager()));
        _upgradeProxy(lpManagerProxyAdmin, address(lpManager), address(new LpManager()));

        vm.stopBroadcast();
    }

    function printAddresses() public {
        initContracts();

        console.log("usdtTokenAddress:", address(usdt));
        console.log("proxyYoloToken:", address(yoloToken));
        console.log("proxyUserManager:", address(userManager));
        console.log("proxyEventManager:", eventManager);
        console.log("proxyFomoTreasureManager:", address(fomoTreasureManager));
        console.log("proxyCardManager:", address(cardManager));
        console.log("proxyLpManager:", address(lpManager));
    }

    function printProxyAdmins() public {
        initContracts();

        console.log("yoloTokenProxyAdmin:", address(yoloTokenProxyAdmin));
        console.log("userManagerProxyAdmin:", address(userManagerProxyAdmin));
        console.log("eventManagerProxyAdmin:", address(eventManagerProxyAdmin));
        console.log("fomoTreasureManagerProxyAdmin:", address(fomoTreasureManagerProxyAdmin));
        console.log("cardManagerProxyAdmin:", address(cardManagerProxyAdmin));
        console.log("lpManagerProxyAdmin:", address(lpManagerProxyAdmin));
    }

    function initYoloTokenPools() public {
        uint256 deployerPrivateKey = getCurPrivateKey();
        initContracts();

        CoreAddresses memory deployed = CoreAddresses({
            usdtTokenAddress: address(usdt),
            proxyYoloToken: address(yoloToken),
            proxyUserManager: address(userManager),
            proxyEventManager: eventManager,
            proxyFomoTreasureManager: address(fomoTreasureManager),
            proxyCardManager: address(cardManager),
            proxyLpManager: address(lpManager)
        });

        vm.startBroadcast(deployerPrivateKey);
        _configureTokenPools(deployed);
        vm.stopBroadcast();
    }

    function _deployProxy(address implementation, address owner, bytes memory initData) internal returns (address) {
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(implementation, owner, initData);
        return address(proxy);
    }

    function _configureTokenPools(CoreAddresses memory deployed) internal {
        if (deployed.proxyLpManager == address(0) || deployed.proxyCardManager == address(0)) {
            return;
        }

        YoloToken yolo = YoloToken(payable(deployed.proxyYoloToken));
        if (yolo.totalSupply() > 0) {
            return;
        }

        IYoloToken.YoloPool memory pools = IYoloToken.YoloPool({
            lpPool: deployed.proxyLpManager,
            cardPool: deployed.proxyCardManager
        });

        yolo.setPoolAddress(pools);
        yolo.poolAllocate();
    }

    function _configureAuthorizedCallers(
        CoreAddresses memory deployed,
        address owner,
        address manager,
        address contractCaller
    ) internal {
        FomoTreasureManager treasure = FomoTreasureManager(payable(deployed.proxyFomoTreasureManager));
        LpManager lp = LpManager(payable(deployed.proxyLpManager));

        treasure.setAuthorizedCaller(owner, true);
        lp.addAuthorizedCaller(owner);

        if (contractCaller != owner) {
            treasure.setAuthorizedCaller(contractCaller, true);
            lp.addAuthorizedCaller(contractCaller);
        }

        if (deployed.proxyEventManager != address(0) && deployed.proxyEventManager != owner && deployed.proxyEventManager != contractCaller) {
            treasure.setAuthorizedCaller(deployed.proxyEventManager, true);
            lp.addAuthorizedCaller(deployed.proxyEventManager);
        }

        if (manager != owner) {
            treasure.setManager(manager);
            lp.setManager(manager);
        }
    }

    function _upgradeProxy(ProxyAdmin admin, address proxy, address implementation) internal {
        if (proxy == address(0) || address(admin) == address(0)) {
            return;
        }
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, "");
    }

    function _logDeployments(CoreAddresses memory deployed) internal pure {
        console.log("usdtTokenAddress:", deployed.usdtTokenAddress);
        console.log("proxyYoloToken:", deployed.proxyYoloToken);
        console.log("proxyUserManager:", deployed.proxyUserManager);
        console.log("proxyEventManager:", deployed.proxyEventManager);
        console.log("proxyFomoTreasureManager:", deployed.proxyFomoTreasureManager);
        console.log("proxyCardManager:", deployed.proxyCardManager);
        console.log("proxyLpManager:", deployed.proxyLpManager);
    }

    function _writeDeployments(CoreAddresses memory deployed) internal {
        string memory obj = "deploy";
        vm.serializeAddress(obj, "usdtTokenAddress", deployed.usdtTokenAddress);
        vm.serializeAddress(obj, "proxyYoloToken", deployed.proxyYoloToken);
        vm.serializeAddress(obj, "proxyUserManager", deployed.proxyUserManager);
        vm.serializeAddress(obj, "proxyEventManager", deployed.proxyEventManager);
        vm.serializeAddress(obj, "proxyFomoTreasureManager", deployed.proxyFomoTreasureManager);
        vm.serializeAddress(obj, "proxyCardManager", deployed.proxyCardManager);
        string memory finalJson = vm.serializeAddress(obj, "proxyLpManager", deployed.proxyLpManager);
        vm.writeJson(finalJson, getDeployPath());
    }
}
