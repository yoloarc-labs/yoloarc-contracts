// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IUserManager {
    event BindInviter(address indexed inviter, address indexed invitee);
    event SetYoloToken(address indexed yoloToken);
    event SetUsdtToken(address indexed usdtToken);
    event SetV2Router(address indexed v2Router);
    event SetUsedStakingYoloReceiver(address indexed receiver);
    event StakingYolo(address indexed user, uint256 usdtAmount, uint256 amount, uint256 totalStaked, uint256 releaseAt);
    event UseStakingYolo(address indexed user, uint256 usedAmount, uint256 totalUsed, uint256 releaseAt);
    event WithdrawStakingYolo(address indexed user, uint256 amount, uint256 remainingStaked);
    event ReleaseStakingYolo(address indexed user, uint256 releasedUsedAmount, uint256 usdtReceived, address indexed receiver);
    event AddRefundingAmount(address indexed user, uint256 amount, uint256 totalRefundingAmount, uint256 requiredTradingVolume);
    event UpdateUserTradingVolume(address indexed user, uint256 amount, uint256 totalTradingVolume);
    event ClaimRefundingAmount(address indexed user, uint256 amount);
    event TokensBurned(uint256 usdtAmount, uint256 tokensBurned);

    function stakingAndUseYolo(address[] calldata users, uint256[] calldata stakeUsdtAmount) external;
    function withdrawStakingYolo(uint256 amount) external;
    function releaseUsedStakingYolo(address user, uint256 yoloAmount) external;
    function setUsdtToken(address usdtToken) external;
    function setV2Router(address v2Router) external;
    function setUsedStakingYoloReceiver(address receiver) external;

    function addRefundingAmount(address user, uint256 amount) external;
    function updateUserTradingVolume(address user, uint256 amount) external;
    function updateUserTradingVolume(address[] calldata users, uint256[] calldata amounts) external;
    function claimRefundingAmount(uint256 amount) external;
}
