// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract EnvContract is Script {
    struct CoreAddresses {
        address usdtTokenAddress;
        address proxyYoloToken;
        address proxyEventManager;
        address proxyDaoRewardManager;
        address proxyFomoTreasureManager;
        address proxyAirdropManager;
        address proxyMarketManager;
        address proxyEcosystemManager;
        address proxyCapitalManager;
        address proxyTechManager;
    }

    function getAddresses() internal returns (CoreAddresses memory addresses) {
        string memory json = _readDeployJson();

        addresses.usdtTokenAddress = _parseAddress(json, ".usdtTokenAddress");
        addresses.proxyYoloToken = _parseAddress(json, ".proxyYoloToken");
        addresses.proxyEventManager = _parseAddress(json, ".proxyEventManager");
        addresses.proxyDaoRewardManager = _parseAddress(json, ".proxyDaoRewardManager");
        addresses.proxyFomoTreasureManager = _parseAddress(json, ".proxyFomoTreasureManager");
        addresses.proxyAirdropManager = _parseAddress(json, ".proxyAirdropManager");
        addresses.proxyMarketManager = _parseAddress(json, ".proxyMarketManager");
        addresses.proxyEcosystemManager = _parseAddress(json, ".proxyEcosystemManager");
        addresses.proxyCapitalManager = _parseAddress(json, ".proxyCapitalManager");
        addresses.proxyTechManager = _parseAddress(json, ".proxyTechManager");
    }

    function getDeployPath() public view returns (string memory) {
        uint256 mode = _envUintOr("MODE", 0);
        if (mode == 0) {
            return "./cache/__deployed_addresses_dev.json";
        }
        return "./cache/__deployed_addresses_prod.json";
    }

    function getCurPrivateKey() public view returns (uint256) {
        uint256 mode = _envUintOr("MODE", 0);
        if (mode == 0) {
            return vm.envUint("DEV_PRIVATE_KEY");
        }
        return vm.envUint("PROD_PRIVATE_KEY");
    }

    function getOwnerAddress() public view returns (address) {
        return _envAddressOr("OWNER", vm.addr(getCurPrivateKey()));
    }

    function getManagerAddress() public view returns (address) {
        return _envAddressOr("MANAGER", getOwnerAddress());
    }

    function getUsdtAddress() public view returns (address) {
        return _envAddressOr("USDT_ADDRESS", address(0));
    }

    function getFeeVaultAddress() public view returns (address) {
        return _envAddressOr("FEE_VAULT", getOwnerAddress());
    }

    function getRewardSenderAddress() public view returns (address) {
        return _envAddressOr("REWARD_SENDER", getManagerAddress());
    }

    function getProxyAdminAddress(address proxy) internal view returns (address) {
        bytes32 adminSlot = vm.load(proxy, ERC1967Utils.ADMIN_SLOT);
        return address(uint160(uint256(adminSlot)));
    }

    function getImplementationAddress(address proxy) internal view returns (address) {
        bytes32 implementationSlot = vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        return address(uint160(uint256(implementationSlot)));
    }

    function _readDeployJson() internal view returns (string memory json) {
        string memory path = getDeployPath();
        try vm.readFile(path) returns (string memory fileJson) {
            json = fileJson;
        } catch {
            json = "{}";
        }
    }

    function _parseAddress(string memory json, string memory key) internal pure returns (address parsed) {
        try vm.parseJsonAddress(json, key) returns (address value) {
            parsed = value;
        } catch {
            parsed = address(0);
        }
    }

    function _envUintOr(string memory key, uint256 fallbackValue) internal view returns (uint256 value) {
        try vm.envUint(key) returns (uint256 envValue) {
            value = envValue;
        } catch {
            value = fallbackValue;
        }
    }

    function _envAddressOr(string memory key, address fallbackValue) internal view returns (address value) {
        try vm.envAddress(key) returns (address envValue) {
            value = envValue;
        } catch {
            value = fallbackValue;
        }
    }
}
