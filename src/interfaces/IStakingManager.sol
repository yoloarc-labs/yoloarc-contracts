// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;


interface IStakingManager {
    struct UserStaking {
        uint256 stakingAmount;
        uint256 stakingTime;
        uint256 stakingPrice;
        uint256 creditLimit;
        uint256 frozenCreditLimit;
        uint8 freezeLevel;
        bool platformTakenOver;
    }

    struct WithdrawRequest {
        uint256 stakingRound;
        uint256 requestAmount;
        uint256 payoutAmount;
        uint256 slippageAmount;
        uint256 requestTime;
        uint256 availableAt;
        bool claimed;
    }

    struct WithdrawRequestView {
        uint256 withdrawRequestId;
        uint256 stakingRound;
        uint256 requestAmount;
        uint256 payoutAmount;
        uint256 slippageAmount;
        uint256 requestTime;
        uint256 availableAt;
        bool claimed;
    }

    event DepositAndStaking(address indexed stakingAddress, uint256 stakingAmount, uint256 stakingCredit);
    event RequestUnStakingWithdraw(
        address indexed stakingAddress,
        uint256 indexed withdrawRequestId,
        uint256 indexed stakingRound,
        uint256 requestAmount,
        uint256 payoutAmount,
        uint256 slippageAmount,
        uint256 availableAt
    );
    event StakingWithdraw(address indexed stakingAddress, uint256 indexed withdrawRequestId, uint256 payoutAmount);
    event FreezeStaking(
        address indexed stakingAddress,
        uint256 indexed stakingRound,
        uint256 currentPrice,
        uint256 frozenCreditLimit,
        uint8 freezeLevel,
        bool platformTakenOver
    );
    event UnfreezeStaking(
        address indexed stakingAddress,
        uint256 indexed stakingRound,
        uint256 currentPrice,
        uint256 frozenCreditLimit,
        uint8 freezeLevel,
        bool platformTakenOver
    );
    event StakingCreditUsed(address indexed stakingAddress, uint256 indexed stakingRound, uint256 amount, uint256 remainingCreditLimit);
    event StakingCreditReleased(address indexed stakingAddress, uint256 indexed stakingRound, uint256 amount, uint256 remainingCreditLimit);
    event StakingCreditAdded(address indexed stakingAddress, uint256 indexed stakingRound, uint256 amount, uint256 remainingCreditLimit);

    function setUnderlyingToken(address _underlyingToken) external;
    function depositAndStaking(uint256 amount) external payable;
    function requestUnStaking(uint256 stakingRound, uint256 amount) external returns (uint256 withdrawRequestId);
    function stakingWithdraw(uint256 withdrawRequestId) external;
    function freezeStaking(uint256 stakingRound) external;
    function unfreezeStaking(uint256 stakingRound) external;
    function getPendingWithdrawRequests(address user) external view returns (WithdrawRequestView[] memory pendingRequests);
    function getRedeemableAmount(address user, uint256 stakingRound) external view returns (uint256);
    function createReward(address lpAddress, uint256 round, uint256 tokenAmount, uint256 usdtAmount, uint8 incomeType) external;
    function claimReward() external;
    function useStakingCredit(address user, uint256 stakingRound, uint256 amount) external;
    function releaseStakingCredit(address user, uint256 stakingRound, uint256 amount) external;
    function addStakingCredit(address user, uint256 stakingRound, uint256 amount) external;
}
