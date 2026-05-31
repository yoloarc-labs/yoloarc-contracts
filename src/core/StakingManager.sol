// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;


import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./StakingManagerStorage.sol";
import "../interfaces/IYoloToken.sol";


contract StakingManager is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard, StakingManagerStorage {
    using SafeERC20 for IERC20;

    uint256 public constant REDEEM_COOLDOWN = 7 days;
    uint256 public constant WITHDRAW_DELAY = 3 hours;
    uint256 public constant EARLY_REDEEM_SLIPPAGE_BPS = 1000;
    uint256 internal constant BPS_DENOMINATOR = 10000;

    constructor() {
        _disableInitializers();
    }

    modifier onlyManager() {
        require(msg.sender == manager, "StakingManager: onlyManager caller is not the manager");
        _;
    }

    modifier onlyStakingOperatorManager() {
        require(msg.sender == address(stakingOperatorManager), "StakingManager: onlyRewardDistributionManager caller is not the manager");
        _;
    }

    receive() external payable {}


    function initialize(
        address initialOwner,
        address initialManager,
        address _underlyingToken,
        address _usdt,
        address _stakingOperatorManager,
        IYoloToken _yoloTokenAddress
    ) public initializer {
        __Ownable_init(initialOwner);
        manager = initialManager;
        underlyingToken = _underlyingToken;
        USDT = _usdt;
        yoloTokenAddress = _yoloTokenAddress;
        stakingOperatorManager = _stakingOperatorManager;
    }

    function setUnderlyingToken(address _underlyingToken) external onlyOwner {
        underlyingToken = _underlyingToken;
    }

    function setManager(address _manager) external onlyOwner {
        require(_manager != address(0), "StakingManager: manager cannot be zero address");
        manager = _manager;
    }

    function setStakingOperatorManager(address _stakingOperatorManager) external onlyManager {
        require(_stakingOperatorManager != address(0), "StakingManager: _stakingOperatorManager cannot be zero address");
        stakingOperatorManager = _stakingOperatorManager;
    }

    function setCallerAddress(address _callerAddress) external onlyOwner {
        require(_callerAddress != address(0), "StakingManager: _callerAddress cannot be zero address");
        callerAddress = _callerAddress;
    }

    function depositAndStaking(uint256 amount) external payable {
        uint256 yoloPrice = yoloTokenAddress.quote(1000000);

        uint256 toUsdtAmount = amount * yoloPrice / 1e6;

        require(toUsdtAmount >= MIN_STAKING_AMOUNT, "StakingManager: depositAndStaking staking amount less min staking amount");
        uint256 creditLimit = (toUsdtAmount * 900) / 1000;
        uint256 currentRound = stakingRound[msg.sender] + 1;
        stakingRound[msg.sender] = currentRound;

        UserStaking storage stakingInfo = userStakingInfo[msg.sender][currentRound];
        stakingInfo.stakingAmount = amount;
        stakingInfo.stakingPrice = yoloPrice;
        stakingInfo.creditLimit = creditLimit;
        stakingInfo.stakingTime = block.timestamp;
        stakingAmount[msg.sender] += amount;

        IERC20(underlyingToken).safeTransferFrom(msg.sender, address(this), amount);

        emit DepositAndStaking(msg.sender, amount, creditLimit, currentRound);
    }

    function requestUnStaking(uint256 _stakingRound, uint256 amount) external returns (uint256 withdrawRequestId) {
        UserStaking storage stakingInfo = _getUserStaking(msg.sender, _stakingRound);
        _reduceStakingPosition(msg.sender, stakingInfo, amount);

        (uint256 payoutAmount, uint256 slippageAmount) = _getWithdrawSettlement(stakingInfo.stakingTime, amount);
        uint256 availableAt = block.timestamp + WITHDRAW_DELAY;

        withdrawRequestId = ++withdrawRequestCount[msg.sender];
        withdrawRequests[msg.sender][withdrawRequestId] = WithdrawRequest({
            stakingRound: _stakingRound,
            requestAmount: amount,
            payoutAmount: payoutAmount,
            slippageAmount: slippageAmount,
            requestTime: block.timestamp,
            availableAt: availableAt,
            claimed: false
        });

        queueWithdraws[msg.sender] += amount;

        emit RequestUnStakingWithdraw(
            msg.sender,
            withdrawRequestId,
            _stakingRound,
            amount,
            payoutAmount,
            slippageAmount,
            availableAt
        );
    }

    function stakingWithdraw(uint256 withdrawRequestId) external nonReentrant {
        WithdrawRequest storage withdrawRequest = withdrawRequests[msg.sender][withdrawRequestId];
        require(withdrawRequest.requestAmount > 0, "StakingManager: withdraw request not found");
        require(!withdrawRequest.claimed, "StakingManager: withdraw request already claimed");
        require(block.timestamp >= withdrawRequest.availableAt, "StakingManager: withdraw still pending");

        withdrawRequest.claimed = true;
        queueWithdraws[msg.sender] -= withdrawRequest.requestAmount;

        IERC20(underlyingToken).safeTransfer(msg.sender, withdrawRequest.payoutAmount);

        emit StakingWithdraw(msg.sender, withdrawRequestId, withdrawRequest.payoutAmount);
    }

    function freezeStaking(uint256 _stakingRound) external {
        require(_stakingRound > 0 && _stakingRound <= stakingRound[msg.sender], "StakingManager: invalid staking round");

        UserStaking storage stakingInfo = userStakingInfo[msg.sender][_stakingRound];
        require(stakingInfo.stakingAmount > 0, "StakingManager: staking record not found");

        uint256 currentPrice = yoloTokenAddress.quote(1000000);
        require(currentPrice < stakingInfo.stakingPrice, "StakingManager: current price not below staking price");

        (uint256 targetFrozenPercent, uint8 targetFreezeLevel, bool targetPlatformTakenOver) =
            _getFreezeConfig(stakingInfo.stakingPrice, currentPrice);
        require(targetFrozenPercent > 0, "StakingManager: price drop threshold not reached");

        uint256 currentFrozenPercent = (stakingInfo.frozenCreditLimit * 100) / stakingInfo.creditLimit;
        if (targetFrozenPercent < currentFrozenPercent) {
            targetFrozenPercent = currentFrozenPercent;
            targetFreezeLevel = stakingInfo.freezeLevel;
            targetPlatformTakenOver = stakingInfo.platformTakenOver;
        }

        stakingInfo.frozenCreditLimit = (stakingInfo.creditLimit * targetFrozenPercent) / 100;
        stakingInfo.freezeLevel = targetFreezeLevel;
        stakingInfo.platformTakenOver = targetPlatformTakenOver;

        emit FreezeStaking(
            msg.sender,
            _stakingRound,
            currentPrice,
            stakingInfo.frozenCreditLimit,
            stakingInfo.freezeLevel,
            stakingInfo.platformTakenOver
        );
    }

    function unfreezeStaking(uint256 _stakingRound) external {
        require(_stakingRound > 0 && _stakingRound <= stakingRound[msg.sender], "StakingManager: invalid staking round");

        UserStaking storage stakingInfo = userStakingInfo[msg.sender][_stakingRound];
        require(stakingInfo.stakingAmount > 0, "StakingManager: staking record not found");
        require(stakingInfo.frozenCreditLimit > 0, "StakingManager: no frozen credit limit");

        uint256 currentPrice = yoloTokenAddress.quote(1000000);
        (uint256 targetFrozenPercent, uint8 targetFreezeLevel, bool targetPlatformTakenOver) =
            _getFreezeConfig(stakingInfo.stakingPrice, currentPrice);
        uint256 currentFrozenPercent = (stakingInfo.frozenCreditLimit * 100) / stakingInfo.creditLimit;

        if (targetFrozenPercent >= currentFrozenPercent) {
            return;
        }

        stakingInfo.frozenCreditLimit = (stakingInfo.creditLimit * targetFrozenPercent) / 100;
        stakingInfo.freezeLevel = targetFreezeLevel;
        stakingInfo.platformTakenOver = targetPlatformTakenOver;

        emit UnfreezeStaking(
            msg.sender,
            _stakingRound,
            currentPrice,
            stakingInfo.frozenCreditLimit,
            stakingInfo.freezeLevel,
            stakingInfo.platformTakenOver
        );
    }

    function getPendingWithdrawRequests(address user) external view returns (WithdrawRequestView[] memory pendingRequests) {
        uint256 requestCount = withdrawRequestCount[user];
        uint256 pendingCount;

        for (uint256 i = 1; i <= requestCount; i++) {
            if (!withdrawRequests[user][i].claimed) {
                pendingCount++;
            }
        }

        pendingRequests = new WithdrawRequestView[](pendingCount);
        uint256 pendingIndex;

        for (uint256 i = 1; i <= requestCount; i++) {
            WithdrawRequest storage withdrawRequest = withdrawRequests[user][i];
            if (withdrawRequest.claimed) {
                continue;
            }

            pendingRequests[pendingIndex] = WithdrawRequestView({
                withdrawRequestId: i,
                stakingRound: withdrawRequest.stakingRound,
                requestAmount: withdrawRequest.requestAmount,
                payoutAmount: withdrawRequest.payoutAmount,
                slippageAmount: withdrawRequest.slippageAmount,
                requestTime: withdrawRequest.requestTime,
                availableAt: withdrawRequest.availableAt,
                claimed: withdrawRequest.claimed
            });
            pendingIndex++;
        }
    }

    function getRedeemableAmount(address user, uint256 _stakingRound) external view returns (uint256) {
        if (_stakingRound == 0 || _stakingRound > stakingRound[user]) {
            return 0;
        }

        return userStakingInfo[user][_stakingRound].stakingAmount;
    }

    function useStakingCredit(address user, uint256 _stakingRound, uint256 amount) external onlyManager whenNotPaused {
        UserStaking storage stakingInfo = _getUserStaking(user, _stakingRound);
        require(amount > 0, "StakingManager: amount is zero");
        require(stakingInfo.creditLimit >= amount, "StakingManager: credit limit not enough");
        stakingInfo.creditLimit -= amount;
        emit StakingCreditUsed(user, _stakingRound, amount, stakingInfo.creditLimit);
    }

    function releaseStakingCredit(address user, uint256 _stakingRound, uint256 amount) external onlyManager whenNotPaused {
        UserStaking storage stakingInfo = _getUserStaking(user, _stakingRound);
        require(amount > 0, "StakingManager: amount is zero");
        stakingInfo.creditLimit += amount;
        emit StakingCreditReleased(user, _stakingRound, amount, stakingInfo.creditLimit);
    }

    function addStakingCredit(address user, uint256 _stakingRound, uint256 amount) external onlyManager whenNotPaused {
        UserStaking storage stakingInfo = _getUserStaking(user, _stakingRound);
        require(amount > 0, "StakingManager: amount is zero");
        stakingInfo.creditLimit += amount;
        emit StakingCreditAdded(user, _stakingRound, amount, stakingInfo.creditLimit);
    }

    function _getUserStaking(address user, uint256 _stakingRound) internal view returns (UserStaking storage stakingInfo) {
        require(_stakingRound > 0 && _stakingRound <= stakingRound[user], "StakingManager: invalid staking round");

        stakingInfo = userStakingInfo[user][_stakingRound];
        require(stakingInfo.stakingAmount > 0, "StakingManager: staking record not found");
    }

    function _reduceStakingPosition(address user, UserStaking storage stakingInfo, uint256 amount) internal {
        require(amount > 0, "StakingManager: withdraw amount is zero");
        require(stakingInfo.stakingAmount >= amount, "StakingManager: user amount is not enough for request withdraw");

        uint256 previousStakingAmount = stakingInfo.stakingAmount;
        uint256 creditReduction = (stakingInfo.creditLimit * amount) / previousStakingAmount;
        uint256 frozenReduction = (stakingInfo.frozenCreditLimit * amount) / previousStakingAmount;

        stakingInfo.stakingAmount = previousStakingAmount - amount;
        stakingInfo.creditLimit -= creditReduction;
        stakingInfo.frozenCreditLimit -= frozenReduction;
        stakingAmount[user] -= amount;

        if (stakingInfo.stakingAmount == 0 || stakingInfo.frozenCreditLimit == 0) {
            stakingInfo.freezeLevel = 0;
            stakingInfo.platformTakenOver = false;
        }
    }

    function _getWithdrawSettlement(uint256 stakingTime, uint256 amount) internal view returns (uint256 payoutAmount, uint256 slippageAmount) {
        uint256 slippageAmountInternal = 0;
        if (block.timestamp < stakingTime + REDEEM_COOLDOWN) {
            slippageAmountInternal = (amount * EARLY_REDEEM_SLIPPAGE_BPS) / BPS_DENOMINATOR;
        }

        slippageAmount = slippageAmountInternal;
        payoutAmount = amount - slippageAmount;
    }

    function _getFreezeConfig(uint256 stakingPrice, uint256 currentPrice) internal pure returns (uint256 frozenPercent, uint8 freezeLevel, bool platformTakenOver) {
        if (currentPrice >= stakingPrice) {
            return (0, 0, false);
        }

        uint256 priceDropBps = ((stakingPrice - currentPrice) * 10000) / stakingPrice;

        if (priceDropBps > 5000) {
            return (60, 5, true);
        }
        if (priceDropBps > 4000) {
            return (50, 4, false);
        }
        if (priceDropBps > 3000) {
            return (40, 3, false);
        }
        if (priceDropBps > 2000) {
            return (30, 2, false);
        }
        if (priceDropBps > 1000) {
            return (20, 1, false);
        }

        return (0, 0, false);
    }
}
