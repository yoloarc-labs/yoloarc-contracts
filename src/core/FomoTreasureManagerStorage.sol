// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IFomoTreasureManage.sol";


abstract contract FomoTreasureManagerStorage is IFomoTreasureManage {
    address public rewardTokenAddress;
    address public manager;

    EnumerableSet.AddressSet internal authorizedCallers;

    mapping(address => uint256) public fundingBalance;

    mapping(address => mapping(address => uint256)) public userRewardBalance;
    mapping(address => mapping(address => uint256)) public agentRewardBalance;

    uint256[100] private __gap;
}
