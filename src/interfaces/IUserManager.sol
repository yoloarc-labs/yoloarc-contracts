// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IUserManager {
    event BindInviter(address indexed inviter, address indexed invitee);
    event SetYoloToken(address indexed yoloToken);
    event StakingYolo(address indexed user, uint256 amount, uint256 totalStaked, uint256 releaseAt);
    event UseStakingYolo(address indexed user, uint256 usedAmount, uint256 totalUsed, uint256 releaseAt);
    event WithdrawStakingYolo(address indexed user, uint256 amount, uint256 remainingStaked);
    event ReleaseStakingYolo(address indexed user, uint256 releasedUsedAmount);
    event AddRefundingAmount(address indexed user, uint256 amount, uint256 totalRefundingAmount, uint256 requiredTradingVolume);
    event UpdateUserTradingVolume(address indexed user, uint256 amount, uint256 totalTradingVolume);
    event ClaimRefundingAmount(address indexed user, uint256 amount);

    function stakingAndUseYolo(uint256 stakeAmount, uint256 betAmount) external;
    function withdrawStakingYolo(uint256 amount) external;
    function releaseUsedStakingYolo(address user) external;

    function addRefundingAmount(address user, uint256 amount) external;
    function updateUserTradingVolume(address user, uint256 amount) external;
    function claimRefundingAmount(uint256 amount) external;
}
