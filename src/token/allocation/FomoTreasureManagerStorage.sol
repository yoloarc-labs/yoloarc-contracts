// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../../interfaces/IFomoTreasureManager.sol";

abstract contract FomoTreasureManagerStorage is IFomoTreasureManager {
    enum StakingRewardType {
        SixThousandType,
        FourteenThousandType
    }

    enum DepositReward {
        DepositType,
        RewardType
    }

    address public constant NativeTokenAddress = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    address public underlyingToken;
    address public manager;
    address public fundManager;

    address public adminFeeVault;
    address public rewardSender;

    mapping(address => uint256) public fundingBalance;
    mapping(uint8 => uint256) public stakingRewardBalance;
    mapping(address => mapping(address => uint256)) public awardWinnerBalance;

    mapping(address => mapping(address => uint256)) public predictionLossAirdrop;

    uint256[97] private __gap;
}
