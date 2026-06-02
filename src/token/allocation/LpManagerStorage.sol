// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../../interfaces/ILpManager.sol";

abstract contract LpManagerStorage is ILpManager {
    address public constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    address public USDT;

    address public underlyingToken;

    address public manager;

    EnumerableSet.AddressSet internal authorizedCallers;

    uint256[100] private __gap;
}

