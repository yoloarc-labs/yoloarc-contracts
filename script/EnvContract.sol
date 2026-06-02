// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract EnvContract is Script {
    struct CoreAddresses {
        address usdtTokenAddress;
        address proxyYoloToken;
        address proxyUserManager;
        address proxyEventManager;
        address proxyFomoTreasureManager;
        address proxyCardManager;
        address proxyLpManager;
    }

    function getAddresses() internal view returns (CoreAddresses memory addresses) {
        string memory json = _readDeployJson();
        addresses.usdtTokenAddress = _parseAddress(json, ".usdtTokenAddress");
        addresses.proxyYoloToken = _parseAddress(json, ".proxyYoloToken");
        addresses.proxyUserManager = _parseAddress(json, ".proxyUserManager");
        addresses.proxyEventManager = _parseAddress(json, ".proxyEventManager");
        addresses.proxyFomoTreasureManager = _parseAddress(json, ".proxyFomoTreasureManager");
        addresses.proxyCardManager = _parseAddress(json, ".proxyCardManager");
        addresses.proxyLpManager = _parseAddress(json, ".proxyLpManager");
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

    function getRewardSenderAddress() public view returns (address) {
        return _envAddressOr("REWARD_SENDER", getManagerAddress());
    }

    function getContractCallerAddress() public view returns (address) {
        return _envAddressOr("CONTRACT_CALLER", getManagerAddress());
    }

    function getCardNftJson() public view returns (string memory) {
        return _envStringOr("CARD_NFT_JSON", "");
    }

    function getProxyAdminAddress(address proxy) internal view returns (address) {
        address CHEATCODE_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
        Vm vm = Vm(CHEATCODE_ADDRESS);

        bytes32 adminSlot = vm.load(proxy, ERC1967Utils.ADMIN_SLOT);
        return address(uint160(uint256(adminSlot)));
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

    function _envStringOr(string memory key, string memory fallbackValue) internal view returns (string memory value) {
        try vm.envString(key) returns (string memory envValue) {
            value = envValue;
        } catch {
            value = fallbackValue;
        }
    }
}
