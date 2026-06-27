// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Vm.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import { CardManager } from "../src/token/allocation/CardManager.sol";
import { NftTokenManager } from "../src/token/nft/NftTokenManager.sol";
import { console, Script } from "forge-std/Script.sol";

// forge script script/DeployNftTokenScript.sol:DeployNftTokenScript --sig "deployNFT()" --slow --multi --rpc-url https://shared.ap-southeast-1.getblock.io/8e87ac495a5941ae9dfb9ea6ed9ae7d2 --broadcast --verify --etherscan-api-key I4C1AKJT8J9KJVCXHZKK317T3XV8IVASRX
// forge script script/DeployNftTokenScript.sol:DeployNftTokenScript --sig "freeMintCardsToNftTokenManagers()" --slow --multi --rpc-url https://shared.ap-southeast-1.getblock.io/8e87ac495a5941ae9dfb9ea6ed9ae7d2 --broadcast
// forge script script/DeployNftTokenScript.sol:DeployNftTokenScript --sig "upgradeNftTokenManagers()" --slow --multi --rpc-url https://shared.ap-southeast-1.getblock.io/8e87ac495a5941ae9dfb9ea6ed9ae7d2 --broadcast
contract DeployNftTokenScript is Script {
    uint256 public constant NFT_TOKEN_MANAGER_COUNT = 30;
    uint256 public constant FREE_MINT_TOTAL = 3_000;
    uint256 public constant FREE_MINT_BASE_QUANTITY = 90;
    uint256 public constant FREE_MINT_MAX_EXTRA_PER_MANAGER = 20;
    string public constant OUTPUT_PATH = "cache/DeployNftTokenScript/deployed-addresses.json";

    ProxyAdmin[NFT_TOKEN_MANAGER_COUNT] public nftTokenManagerAdmins;

    NftTokenManager[NFT_TOKEN_MANAGER_COUNT] public nftTokenManagers;
    NftTokenManager public nftTokenManagerImplementation;


    function deployNFT() public {
        uint256 deployerPrivateKey = vm.envUint("PROD_PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address[] memory proxyAddresses = new address[](NFT_TOKEN_MANAGER_COUNT);
        address[] memory adminAddresses = new address[](NFT_TOKEN_MANAGER_COUNT);

        vm.startBroadcast(deployerPrivateKey);

        nftTokenManagerImplementation = new NftTokenManager();
        console.log("deploy nftTokenManagerImplementation:", address(nftTokenManagerImplementation));

        for (uint256 i = 0; i < NFT_TOKEN_MANAGER_COUNT; i++) {
            TransparentUpgradeableProxy proxyNftTokenManager =
                new TransparentUpgradeableProxy(
                    address(nftTokenManagerImplementation),
                    deployerAddress,
                    abi.encodeWithSelector(NftTokenManager.initialize.selector, deployerAddress, deployerAddress)
                );
            NftTokenManager nftTokenManager = NftTokenManager(payable(address(proxyNftTokenManager)));
            ProxyAdmin nftTokenManagerAdmin = ProxyAdmin(getProxyAdminAddress(address(proxyNftTokenManager)));

            nftTokenManagers[i] = nftTokenManager;
            nftTokenManagerAdmins[i] = nftTokenManagerAdmin;
            proxyAddresses[i] = address(proxyNftTokenManager);
            adminAddresses[i] = address(nftTokenManagerAdmin);

            console.log("deploy proxyNftTokenManager index:", i);
            console.log("deploy proxyNftTokenManager:", address(proxyNftTokenManager));
            console.log("deploy nftTokenManagerAdmin:", address(nftTokenManagerAdmin));
        }

        vm.stopBroadcast();

        _writeDeployAddresses(deployerAddress, proxyAddresses, adminAddresses);
    }

    function freeMintCardsToNftTokenManagers() public {
        uint256 deployerPrivateKey = vm.envUint("PROD_PRIVATE_KEY");
        address cardManagerAddress = address(0xEa33a0db2356501aFe2eFC7CA124f9E437F0C4Ca);
        address[] memory receivers = _readNftTokenManagerAddresses();
        uint256[] memory quantities = _buildBalancedRandomQuantities(receivers);

        vm.startBroadcast(deployerPrivateKey);

        CardManager cardManager = CardManager(payable(cardManagerAddress));
        for (uint256 i = 0; i < receivers.length; i++) {
            cardManager.freeMintCards(receivers[i], quantities[i]);

            console.log("free mint receiver index:", i);
            console.log("free mint receiver:", receivers[i]);
            console.log("free mint quantity:", quantities[i]);
        }

        vm.stopBroadcast();
    }

    function upgradeNftTokenManagers() public {
        uint256 deployerPrivateKey = vm.envUint("PROD_PRIVATE_KEY");
        address[] memory proxyAddresses = _readNftTokenManagerAddresses();
        address[] memory adminAddresses = _readNftTokenManagerAdminAddresses();

        vm.startBroadcast(deployerPrivateKey);

        nftTokenManagerImplementation = new NftTokenManager();
        console.log("deploy nftTokenManagerImplementation:", address(nftTokenManagerImplementation));

        for (uint256 i = 0; i < proxyAddresses.length; i++) {
            ProxyAdmin(adminAddresses[i]).upgradeAndCall(
                ITransparentUpgradeableProxy(payable(proxyAddresses[i])),
                address(nftTokenManagerImplementation),
                ""
            );

            console.log("upgrade proxyNftTokenManager index:", i);
            console.log("upgrade proxyNftTokenManager:", proxyAddresses[i]);
            console.log("upgrade nftTokenManagerAdmin:", adminAddresses[i]);
        }

        vm.stopBroadcast();

        _writeDeployAddresses(vm.addr(deployerPrivateKey), proxyAddresses, adminAddresses);
    }

    function _writeDeployAddresses(address deployerAddress, address[] memory proxyAddresses, address[] memory adminAddresses)
        internal
    {
        vm.createDir("cache/DeployNftTokenScript", true);

        string memory root = "deployNftTokenScript";
        vm.serializeAddress(root, "deployer", deployerAddress);
        vm.serializeAddress(root, "nftTokenManagerImplementation", address(nftTokenManagerImplementation));
        vm.serializeAddress(root, "nftTokenManagers", proxyAddresses);
        string memory json = vm.serializeAddress(root, "nftTokenManagerAdmins", adminAddresses);

        vm.writeJson(json, OUTPUT_PATH);
        console.log("write deployed addresses:", OUTPUT_PATH);
    }

    function _readNftTokenManagerAddresses() internal view returns (address[] memory) {
        string memory json = vm.readFile(OUTPUT_PATH);
        address[] memory receivers = vm.parseJsonAddressArray(json, ".nftTokenManagers");

        require(receivers.length == NFT_TOKEN_MANAGER_COUNT, "DeployNftTokenScript: invalid receiver count");
        for (uint256 i = 0; i < receivers.length; i++) {
            require(receivers[i] != address(0), "DeployNftTokenScript: receiver zero address");
        }

        return receivers;
    }

    function _readNftTokenManagerAdminAddresses() internal view returns (address[] memory) {
        string memory json = vm.readFile(OUTPUT_PATH);
        address[] memory admins = vm.parseJsonAddressArray(json, ".nftTokenManagerAdmins");

        require(admins.length == NFT_TOKEN_MANAGER_COUNT, "DeployNftTokenScript: invalid admin count");
        for (uint256 i = 0; i < admins.length; i++) {
            require(admins[i] != address(0), "DeployNftTokenScript: admin zero address");
        }

        return admins;
    }

    function _buildBalancedRandomQuantities(address[] memory receivers) internal view returns (uint256[] memory quantities) {
        quantities = new uint256[](receivers.length);

        uint256 remaining = FREE_MINT_TOTAL;
        for (uint256 i = 0; i < receivers.length; i++) {
            quantities[i] = FREE_MINT_BASE_QUANTITY;
            remaining -= FREE_MINT_BASE_QUANTITY;
        }

        uint256 nonce;
        while (remaining > 0) {
            uint256 index = uint256(keccak256(abi.encode(block.chainid, block.timestamp, block.prevrandao, receivers, nonce)))
                % receivers.length;
            if (quantities[index] < FREE_MINT_BASE_QUANTITY + FREE_MINT_MAX_EXTRA_PER_MANAGER) {
                quantities[index]++;
                remaining--;
            }
            nonce++;
        }

        uint256 total;
        bool hasDifferentQuantity;
        for (uint256 i = 0; i < quantities.length; i++) {
            total += quantities[i];
            if (quantities[i] != FREE_MINT_TOTAL / NFT_TOKEN_MANAGER_COUNT) {
                hasDifferentQuantity = true;
            }
        }

        require(total == FREE_MINT_TOTAL, "DeployNftTokenScript: invalid mint total");
        require(hasDifferentQuantity, "DeployNftTokenScript: quantities must not be average");
    }

    function getProxyAdminAddress(address proxy) internal view returns (address) {
        address CHEATCODE_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
        Vm vm = Vm(CHEATCODE_ADDRESS);

        bytes32 adminSlot = vm.load(proxy, ERC1967Utils.ADMIN_SLOT);
        return address(uint160(uint256(adminSlot)));
    }
}
