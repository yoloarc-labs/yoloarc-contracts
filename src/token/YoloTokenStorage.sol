// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IYoloToken.sol";

abstract contract YoloTokenStorage is IYoloToken {
    uint256 public constant MaxTotalSupply = 1_000_000_000 * 10 ** 6;

    address public USDT;
    address public constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    uint256 public _lpBurnedTokens;

    bool internal isAllocation;

    YoloPool public cmPool;

    address public mainPair;

    EnumerableSet.AddressSet marketingPools; // Marketing developments

    uint256[100] private __gap;
}
