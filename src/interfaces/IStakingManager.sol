// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;


interface IStakingManager {
    struct UserStaking {
        uint256 stakingAmount;
        uint256 stakingTime;
        uint256 stakingPrice;   //首次deposit 和后续topup的加权价格
        uint256 currentPrice;   //最新价格
        uint256 creditLimit;    //stakingAmount * currentPrice / 1e6 * 0.9
        uint256 usedCredit;    //已使用信用额度
        uint256 frozenCreditLimit; //冻结的信用额度
        uint8 freezeLevel; //冻结等级
        bool platformTakenOver; //平台是否接管
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

    event DepositAndStaking(address indexed stakingAddress, uint256 stakingAmount, uint256 stakingCredit, uint256 stakingRound);
    event RequestUnStakingWithdraw(
        address indexed stakingAddress,
        uint256 indexed withdrawRequestId,
        uint256 indexed stakingRound,
        uint256 requestAmount,
        uint256 payoutAmount,
        uint256 slippageAmount,
        uint256 stakingAmount,
        uint256 currentPrice,
        uint256 creditLimit,
        uint256 usedCredit,
        uint256 frozenCreditLimit,
        uint256 availableAt
    );
    event StakingWithdraw(address indexed stakingAddress, uint256 indexed withdrawRequestId, uint256 payoutAmount);
    event FreezeStaking(
        address indexed stakingAddress,
        uint256 indexed stakingRound,
        uint256 stakingAmount,
        uint256 currentPrice,
        uint256 creditLimit,
        uint256 usedCredit,
        uint256 frozenCreditLimit,
        uint8 previousFreezeLevel,
        uint8 freezeLevel,
        bool platformTakenOver,
        bool byCall   // true: 由 freezeStaking 显式触发；false: 由 _updatePriceAndLimits 自动触发
    );
    event UnfreezeStaking(
        address indexed stakingAddress,
        uint256 indexed stakingRound,
        uint256 stakingAmount,
        uint256 currentPrice,
        uint256 creditLimit,
        uint256 usedCredit,
        uint256 frozenCreditLimit,
        uint8 previousFreezeLevel,
        uint8 freezeLevel,
        bool platformTakenOver,
        bool byCall   // true: 由 unfreezeStaking 显式触发；false: 由 _updatePriceAndLimits 自动触发
    );

    event StakingCreditUsed(
        address indexed stakingAddress,
        uint256 indexed stakingRound,
        uint256 amount,
        uint256 stakingAmount,
        uint256 currentPrice,
        uint256 creditLimit,
        uint256 usedCredit,
        uint256 frozenCreditLimit
    );
    event StakingCreditReleased(
        address indexed stakingAddress,
        uint256 indexed stakingRound,
        uint256 amount,
        uint256 stakingAmount,
        uint256 currentPrice,
        uint256 creditLimit,
        uint256 usedCredit,
        uint256 frozenCreditLimit
    );
    event Topup(
        address indexed stakingAddress,
        uint256 indexed stakingRound,
        uint256 amount,
        uint256 stakingAmount,
        uint256 currentPrice,
        uint256 creditLimit,
        uint256 usedCredit
    );
    function setUnderlyingToken(address _underlyingToken) external;
    function depositAndStaking(uint256 amount) external payable;
    function requestUnStaking(uint256 stakingRound, uint256 amount) external returns (uint256 withdrawRequestId);
    function stakingWithdraw(uint256 withdrawRequestId) external;
    function freezeStaking(uint256 stakingRound) external;
    function unfreezeStaking(uint256 stakingRound) external;
    function getPendingWithdrawRequests(address user) external view returns (WithdrawRequestView[] memory pendingRequests);
    function getUnstakeableAmount(address user, uint256 stakingRound) external view returns (uint256);
    function useStakingCredit(address user, uint256 stakingRound, uint256 amount) external;
    function releaseStakingCredit(address user, uint256 stakingRound, uint256 amount) external;
    function topup(address user, uint256 stakingRound, uint256 amount) external;
}
