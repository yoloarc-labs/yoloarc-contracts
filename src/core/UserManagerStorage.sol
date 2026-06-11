// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../interfaces/IUserManager.sol";

abstract contract UserManagerStorage is IUserManager {
    struct StakeLot {
        uint256 amount;
        uint256 unlockAt;
    }

    uint256 internal constant RELEASE_DELAY = 10 days;
    uint256 internal constant SPORTS_USAGE_BPS = 2_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant REFUND_CLAIM_MULTIPLIER = 20;

    address public contractCaller;
    address public yoloToken;

    mapping(address => address) public inviters;
    mapping(address => uint256) public stakedYoloBalance;
    mapping(address => uint256) public unlockedStakedYoloBalance;
    mapping(address => uint256) public lockedStakedYoloBalance;
    mapping(address => uint256) public usedStakedYoloBalance;
    mapping(address => uint256) public stakingReleaseAt;
    mapping(address => StakeLot[]) internal stakeLots;
    mapping(address => uint256) internal nextStakeLotIndex;

    mapping(address => uint256) public refundingAmount;
    mapping(address => uint256) public userTradingVolume;

    uint256 public totalStakedYolo;
    uint256 public totalRefundReserved;

    address public USDT;
    address public V2_ROUTER;

    uint256[98] private __gap;
}
