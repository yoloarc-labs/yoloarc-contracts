// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../interfaces/IStakingManager.sol";
import "../interfaces/IYoloToken.sol";



abstract contract StakingManagerStorage is IStakingManager {
    uint256 public MIN_STAKING_AMOUNT = 200000000000000000000;

    address public USDT;
    address public underlyingToken;
    address public manager;
    address public stakingOperatorManager;
    address public callerAddress;
    IYoloToken public yoloTokenAddress;

    mapping(address => uint256) public stakingRound;
    mapping(address => mapping(uint256 => UserStaking)) public userStakingInfo;
    mapping(address => uint256) public stakingAmount;

    mapping(address => uint256) public queueWithdraws;
    mapping(address => uint256) public withdrawRequestCount;
    mapping(address => mapping(uint256 => WithdrawRequest)) public withdrawRequests;

}
