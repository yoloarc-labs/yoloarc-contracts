// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {InitContract} from "./InitContract.sol";
import {MockERC20} from "./MockERC20.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";
import {StakingManager} from "../src/core/StakingManager.sol";
import {EventManager} from "../src/core/EventManager.sol";
import {DaoRewardManager} from "../src/token/allocation/DaoRewardManager.sol";
import {FomoTreasureManager} from "../src/token/allocation/FomoTreasureManager.sol";
import {AirdropManager} from "../src/token/allocation/AirdropManager.sol";
import {MarketManager} from "../src/token/allocation/MarketManager.sol";
import {CapitalManager} from "../src/token/allocation/CapitalManager.sol";
import {EcosystemManager} from "../src/token/allocation/EcosystemManager.sol";
import {TechManager} from "../src/token/allocation/TechManager.sol";

contract DeployStakingScript is InitContract {
    struct DeployedContracts {
        address usdtTokenAddress;
        address proxyYoloToken;
        address proxyStakingManager;
        address proxyEventManager;
        address proxyDaoRewardManager;
        address proxyFomoTreasureManager;
        address proxyAirdropManager;
        address proxyMarketManager;
        address proxyEcosystemManager;
        address proxyCapitalManager;
        address proxyTechManager;
    }

    function run() external {
        deployAll();
    }

    function deployAll() public {
        uint256 deployerPrivateKey = getCurPrivateKey();
        address owner = getOwnerAddress();
        address manager = getManagerAddress();
        address feeVault = getFeeVaultAddress();
        address rewardSender = getRewardSenderAddress();
        address usdtAddress = getUsdtAddress();

        vm.startBroadcast(deployerPrivateKey);

        if (usdtAddress == address(0)) {
            MockERC20 mockUSDT = new MockERC20("Mock USDT", "USDT");
            usdtAddress = address(mockUSDT);
            mockUSDT.mint(owner, 100_000_000 ether);
        }

        DeployedContracts memory deployed;
        deployed.usdtTokenAddress = usdtAddress;

        YoloToken yoloTokenImplementation = new YoloToken();
        deployed.proxyYoloToken = _deployProxy(
            address(yoloTokenImplementation),
            owner,
            abi.encodeWithSelector(YoloToken.initialize.selector, owner, usdtAddress)
        );

        DaoRewardManager daoRewardManagerImplementation = new DaoRewardManager();
        deployed.proxyDaoRewardManager = _deployProxy(
            address(daoRewardManagerImplementation),
            owner,
            abi.encodeWithSelector(DaoRewardManager.initialize.selector, owner, deployed.proxyYoloToken)
        );

        FomoTreasureManager fomoTreasureManagerImplementation = new FomoTreasureManager();
        deployed.proxyFomoTreasureManager = _deployProxy(
            address(fomoTreasureManagerImplementation),
            owner,
            abi.encodeWithSelector(
                FomoTreasureManager.initialize.selector,
                owner,
                manager,
                usdtAddress,
                feeVault,
                rewardSender
            )
        );

        AirdropManager airdropManagerImplementation = new AirdropManager();
        deployed.proxyAirdropManager = _deployProxy(
            address(airdropManagerImplementation),
            owner,
            abi.encodeWithSelector(AirdropManager.initialize.selector, owner, manager, deployed.proxyYoloToken)
        );

        MarketManager marketManagerImplementation = new MarketManager();
        deployed.proxyMarketManager = _deployProxy(
            address(marketManagerImplementation),
            owner,
            abi.encodeWithSelector(MarketManager.initialize.selector, owner, manager, deployed.proxyYoloToken)
        );

        EcosystemManager ecosystemManagerImplementation = new EcosystemManager();
        deployed.proxyEcosystemManager = _deployProxy(
            address(ecosystemManagerImplementation),
            owner,
            abi.encodeWithSelector(EcosystemManager.initialize.selector, owner, manager, deployed.proxyYoloToken)
        );

        CapitalManager capitalManagerImplementation = new CapitalManager();
        deployed.proxyCapitalManager = _deployProxy(
            address(capitalManagerImplementation),
            owner,
            abi.encodeWithSelector(CapitalManager.initialize.selector, owner, manager, deployed.proxyYoloToken)
        );

        TechManager techManagerImplementation = new TechManager();
        deployed.proxyTechManager = _deployProxy(
            address(techManagerImplementation),
            owner,
            abi.encodeWithSelector(TechManager.initialize.selector, owner, manager, deployed.proxyYoloToken)
        );

        StakingManager stakingManagerImplementation = new StakingManager();
        deployed.proxyStakingManager = _deployProxy(
            address(stakingManagerImplementation),
            owner,
            abi.encodeWithSelector(
                StakingManager.initialize.selector,
                owner,
                manager,
                deployed.proxyYoloToken,
                usdtAddress,
                manager,
                IYoloToken(deployed.proxyYoloToken)
            )
        );

        EventManager eventManagerImplementation = new EventManager();
        deployed.proxyEventManager = _deployProxy(
            address(eventManagerImplementation),
            owner,
            abi.encodeWithSelector(
                EventManager.initialize.selector,
                owner,
                manager,
                deployed.proxyYoloToken,
                usdtAddress,
                IYoloToken(deployed.proxyYoloToken)
            )
        );

        EventManager(payable(deployed.proxyEventManager)).setStakingManager(deployed.proxyStakingManager);
        StakingManager(payable(deployed.proxyStakingManager)).setManager(deployed.proxyEventManager);

        _configureTokenPools(deployed);
        _configureAuthorizedCallers(deployed, manager);

        vm.stopBroadcast();

        _logDeployments(deployed);
        _writeDeployments(deployed);
    }

    function upgradeCore() public {
        uint256 deployerPrivateKey = getCurPrivateKey();
        initContracts();

        vm.startBroadcast(deployerPrivateKey);

        yoloTokenProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(yoloToken)),
            address(new YoloToken()),
            ""
        );
        stakingManagerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(stakingManager)),
            address(new StakingManager()),
            ""
        );
        eventManagerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(eventManager)),
            address(new EventManager()),
            ""
        );

        vm.stopBroadcast();
    }

    function upgradeAllocations() public {
        uint256 deployerPrivateKey = getCurPrivateKey();
        initContracts();

        vm.startBroadcast(deployerPrivateKey);

        daoRewardManagerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(daoRewardManager)),
            address(new DaoRewardManager()),
            ""
        );
        fomoTreasureManagerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(fomoTreasureManager)),
            address(new FomoTreasureManager()),
            ""
        );
        airdropManagerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(airdropManager)),
            address(new AirdropManager()),
            ""
        );
        marketManagerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(marketManager)),
            address(new MarketManager()),
            ""
        );
        ecosystemManagerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(ecosystemManager)),
            address(new EcosystemManager()),
            ""
        );
        capitalManagerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(capitalManager)),
            address(new CapitalManager()),
            ""
        );
        techManagerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(techManager)),
            address(new TechManager()),
            ""
        );

        vm.stopBroadcast();
    }

    function printAddresses() public {
        initContracts();

        console.log("usdtTokenAddress:", address(usdt));
        console.log("proxyYoloToken:", address(yoloToken));
        console.log("proxyStakingManager:", address(stakingManager));
        console.log("proxyEventManager:", address(eventManager));
        console.log("proxyDaoRewardManager:", address(daoRewardManager));
        console.log("proxyFomoTreasureManager:", address(fomoTreasureManager));
        console.log("proxyAirdropManager:", address(airdropManager));
        console.log("proxyMarketManager:", address(marketManager));
        console.log("proxyEcosystemManager:", address(ecosystemManager));
        console.log("proxyCapitalManager:", address(capitalManager));
        console.log("proxyTechManager:", address(techManager));
    }

    function printProxyAdmins() public {
        initContracts();

        console.log("yoloTokenProxyAdmin:", address(yoloTokenProxyAdmin));
        console.log("stakingManagerProxyAdmin:", address(stakingManagerProxyAdmin));
        console.log("eventManagerProxyAdmin:", address(eventManagerProxyAdmin));
        console.log("daoRewardManagerProxyAdmin:", address(daoRewardManagerProxyAdmin));
        console.log("fomoTreasureManagerProxyAdmin:", address(fomoTreasureManagerProxyAdmin));
        console.log("airdropManagerProxyAdmin:", address(airdropManagerProxyAdmin));
        console.log("marketManagerProxyAdmin:", address(marketManagerProxyAdmin));
        console.log("ecosystemManagerProxyAdmin:", address(ecosystemManagerProxyAdmin));
        console.log("capitalManagerProxyAdmin:", address(capitalManagerProxyAdmin));
        console.log("techManagerProxyAdmin:", address(techManagerProxyAdmin));
    }

    function initYoloTokenPools() public {
        uint256 deployerPrivateKey = getCurPrivateKey();
        initContracts();

        DeployedContracts memory deployed = DeployedContracts({
            usdtTokenAddress: address(usdt),
            proxyYoloToken: address(yoloToken),
            proxyStakingManager: address(stakingManager),
            proxyEventManager: address(eventManager),
            proxyDaoRewardManager: address(daoRewardManager),
            proxyFomoTreasureManager: address(fomoTreasureManager),
            proxyAirdropManager: address(airdropManager),
            proxyMarketManager: address(marketManager),
            proxyEcosystemManager: address(ecosystemManager),
            proxyCapitalManager: address(capitalManager),
            proxyTechManager: address(techManager)
        });

        vm.startBroadcast(deployerPrivateKey);
        _configureTokenPools(deployed);
        vm.stopBroadcast();
    }

    function _deployProxy(address implementation, address owner, bytes memory initData) internal returns (address) {
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(implementation, owner, initData);
        return address(proxy);
    }

    function _configureTokenPools(DeployedContracts memory deployed) internal {
        YoloToken yolo = YoloToken(payable(deployed.proxyYoloToken));
        if (yolo.balanceOf(deployed.proxyDaoRewardManager) > 0) {
            return;
        }

        IYoloToken.YoloPool memory pools = IYoloToken.YoloPool({
            nodePool: deployed.proxyStakingManager,
            daoRewardPool: deployed.proxyDaoRewardManager,
            airdropPool: deployed.proxyAirdropManager,
            techFeePool: deployed.proxyFomoTreasureManager,
            techPool: deployed.proxyTechManager,
            capitalPool: deployed.proxyCapitalManager,
            marketingFeePool: deployed.proxyMarketManager,
            subTokenPool: deployed.proxyEventManager,
            ecosystemPool: deployed.proxyEcosystemManager
        });

        address[] memory marketingPools = new address[](1);
        marketingPools[0] = deployed.proxyMarketManager;

        yolo.setPoolAddress(pools, marketingPools);
        yolo.poolAllocate();
    }

    function _configureAuthorizedCallers(DeployedContracts memory deployed, address manager) internal {
        DaoRewardManager(payable(deployed.proxyDaoRewardManager)).setAuthorizedCaller(manager, true);
        AirdropManager(payable(deployed.proxyAirdropManager)).addAuthorizedCaller(manager);
        MarketManager(payable(deployed.proxyMarketManager)).addAuthorizedCaller(manager);
        EcosystemManager(payable(deployed.proxyEcosystemManager)).addAuthorizedCaller(manager);
        CapitalManager(payable(deployed.proxyCapitalManager)).addAuthorizedCaller(manager);
        TechManager(payable(deployed.proxyTechManager)).addAuthorizedCaller(manager);
    }

    function _logDeployments(DeployedContracts memory deployed) internal pure {
        console.log("usdtTokenAddress:", deployed.usdtTokenAddress);
        console.log("proxyYoloToken:", deployed.proxyYoloToken);
        console.log("proxyStakingManager:", deployed.proxyStakingManager);
        console.log("proxyEventManager:", deployed.proxyEventManager);
        console.log("proxyDaoRewardManager:", deployed.proxyDaoRewardManager);
        console.log("proxyFomoTreasureManager:", deployed.proxyFomoTreasureManager);
        console.log("proxyAirdropManager:", deployed.proxyAirdropManager);
        console.log("proxyMarketManager:", deployed.proxyMarketManager);
        console.log("proxyEcosystemManager:", deployed.proxyEcosystemManager);
        console.log("proxyCapitalManager:", deployed.proxyCapitalManager);
        console.log("proxyTechManager:", deployed.proxyTechManager);
    }

    function _writeDeployments(DeployedContracts memory deployed) internal {
        string memory obj = "deployment";
        vm.serializeAddress(obj, "usdtTokenAddress", deployed.usdtTokenAddress);
        vm.serializeAddress(obj, "proxyYoloToken", deployed.proxyYoloToken);
        vm.serializeAddress(obj, "proxyStakingManager", deployed.proxyStakingManager);
        vm.serializeAddress(obj, "proxyEventManager", deployed.proxyEventManager);
        vm.serializeAddress(obj, "proxyDaoRewardManager", deployed.proxyDaoRewardManager);
        vm.serializeAddress(obj, "proxyFomoTreasureManager", deployed.proxyFomoTreasureManager);
        vm.serializeAddress(obj, "proxyAirdropManager", deployed.proxyAirdropManager);
        vm.serializeAddress(obj, "proxyMarketManager", deployed.proxyMarketManager);
        vm.serializeAddress(obj, "proxyEcosystemManager", deployed.proxyEcosystemManager);
        vm.serializeAddress(obj, "proxyCapitalManager", deployed.proxyCapitalManager);
        string memory finalJson = vm.serializeAddress(obj, "proxyTechManager", deployed.proxyTechManager);
        vm.writeJson(finalJson, getDeployPath());
    }
}
