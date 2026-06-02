// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../interfaces/IEventManager.sol";
import "../interfaces/IYoloToken.sol";

abstract contract EventManagerStorage is IEventManager  {
    address public manager;
    address public USDT;
    address public underlyingToken;

    IYoloToken public yoloTokenAddress;

    uint256[100] private __gap;
}
