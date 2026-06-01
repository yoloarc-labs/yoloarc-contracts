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

        uint256 currentRound = stakingRound[msg.sender] + 1;
        stakingRound[msg.sender] = currentRound;

        UserStaking storage stakingInfo = userStakingInfo[msg.sender][currentRound];
        stakingInfo.stakingAmount = amount;
        stakingInfo.stakingPrice = yoloPrice;
        stakingInfo.stakingTime = block.timestamp;
        _updatePriceAndLimits(msg.sender, currentRound, stakingInfo, false);

        stakingAmount[msg.sender] += amount;
        IERC20(underlyingToken).safeTransferFrom(msg.sender, address(this), amount);

        emit DepositAndStaking(msg.sender, amount, stakingInfo.creditLimit, currentRound);
    }

    function requestUnStaking(uint256 _stakingRound, uint256 amount) external returns (uint256 withdrawRequestId) {
        UserStaking storage stakingInfo = _getUserStaking(msg.sender, _stakingRound);
        _updatePriceAndLimits(msg.sender, _stakingRound, stakingInfo, false);

        uint256 redeemableAmount = getUnstakeableAmount(msg.sender, _stakingRound);
        require(amount <= redeemableAmount, "StakingManager: amount is greater than redeemable amount");

        // creditLimit and frozenCreditLimit are both linear in stakingAmount
        // for a fixed price; scale them proportionally instead of re-quoting
        // and re-computing freeze state (price hasn't moved within the tx).
        uint256 previousStakingAmount = stakingInfo.stakingAmount;
        uint256 newStakingAmount = previousStakingAmount - amount;
        stakingInfo.creditLimit = (stakingInfo.creditLimit * newStakingAmount) / previousStakingAmount;
        stakingInfo.frozenCreditLimit = (stakingInfo.frozenCreditLimit * newStakingAmount) / previousStakingAmount;
        stakingInfo.stakingAmount = newStakingAmount;
        stakingAmount[msg.sender] -= amount;

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
            stakingInfo.stakingAmount,
            stakingInfo.currentPrice,
            stakingInfo.creditLimit,
            stakingInfo.usedCredit,
            stakingInfo.frozenCreditLimit,
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
        totalSlippageAmount += withdrawRequest.slippageAmount;

        IERC20(underlyingToken).safeTransfer(msg.sender, withdrawRequest.payoutAmount);

        emit StakingWithdraw(msg.sender, withdrawRequestId, withdrawRequest.payoutAmount);
    }

    function freezeStaking(uint256 _stakingRound) external {
        require(_stakingRound > 0 && _stakingRound <= stakingRound[msg.sender], "StakingManager: invalid staking round");

        UserStaking storage stakingInfo = userStakingInfo[msg.sender][_stakingRound];
        require(stakingInfo.stakingAmount > 0, "StakingManager: staking record not found");

        uint8 previousFreezeLevel = stakingInfo.freezeLevel;
        // Event is emitted from inside _updatePriceAndLimits when freezeLevel
        // changes; we pass byCall = true to mark this as an explicit trigger.
        _updatePriceAndLimits(msg.sender, _stakingRound, stakingInfo, true);
        require(stakingInfo.freezeLevel > previousFreezeLevel, "StakingManager: no new freeze applies");
    }

    function unfreezeStaking(uint256 _stakingRound) external {
        require(_stakingRound > 0 && _stakingRound <= stakingRound[msg.sender], "StakingManager: invalid staking round");

        UserStaking storage stakingInfo = userStakingInfo[msg.sender][_stakingRound];
        require(stakingInfo.stakingAmount > 0, "StakingManager: staking record not found");

        uint8 previousFreezeLevel = stakingInfo.freezeLevel;
        require(previousFreezeLevel > 0, "StakingManager: no frozen credit limit");

        _updatePriceAndLimits(msg.sender, _stakingRound, stakingInfo, true);
        require(stakingInfo.freezeLevel < previousFreezeLevel, "StakingManager: no unfreeze applies");
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

    function getUnstakeableAmount(address user, uint256 _stakingRound) public view returns (uint256) {
        if (_stakingRound == 0 || _stakingRound > stakingRound[user]) {
            return 0;
        }
        UserStaking storage stakingInfo = userStakingInfo[user][_stakingRound];

        // Both already-used credit and frozen reserve must stay collateralized
        // after withdrawal; otherwise the freeze becomes meaningless and a
        // bet in flight could end up under-collateralized.
        uint256 totalLocked = stakingInfo.usedCredit + stakingInfo.frozenCreditLimit;
        if (totalLocked == 0) {
            return stakingInfo.stakingAmount;
        }

        uint256 yoloPrice = yoloTokenAddress.quote(1000000);
        if (yoloPrice == 0) {
            return 0;
        }

        // YOLO collateral needed = ceil(totalLocked / (yoloPrice * 0.9))
        // (yoloPrice is scaled by 1e6 from quote(1000000))
        uint256 divisor = 9 * yoloPrice;
        uint256 lockedAmount = (totalLocked * 10 * 1e6 + divisor - 1) / divisor;
        if (lockedAmount >= stakingInfo.stakingAmount) {
            return 0;
        }

        return stakingInfo.stakingAmount - lockedAmount;
    }

    function useStakingCredit(address user, uint256 _stakingRound, uint256 amount) external onlyManager whenNotPaused {
        UserStaking storage stakingInfo = _getUserStaking(user, _stakingRound);
        require(amount > 0, "StakingManager: amount is zero");

        _updatePriceAndLimits(user, _stakingRound, stakingInfo, false);

        uint256 reserved = stakingInfo.usedCredit + stakingInfo.frozenCreditLimit;
        uint256 available = stakingInfo.creditLimit > reserved ? stakingInfo.creditLimit - reserved : 0;
        require(available >= amount, "StakingManager: credit limit not enough");

        stakingInfo.usedCredit += amount;
        emit StakingCreditUsed(user, _stakingRound, amount, stakingInfo.stakingAmount, stakingInfo.currentPrice, stakingInfo.creditLimit, stakingInfo.usedCredit, stakingInfo.frozenCreditLimit);
    }

    function releaseStakingCredit(address user, uint256 _stakingRound, uint256 amount) external onlyManager whenNotPaused {
        UserStaking storage stakingInfo = _getUserStaking(user, _stakingRound);
        require(amount > 0, "StakingManager: amount is zero");
        require(stakingInfo.usedCredit >= amount, "StakingManager: used credit not enough");

        _updatePriceAndLimits(user, _stakingRound, stakingInfo, false);
        stakingInfo.usedCredit -= amount;
        emit StakingCreditReleased(user, _stakingRound, amount, stakingInfo.stakingAmount, stakingInfo.currentPrice, stakingInfo.creditLimit, stakingInfo.usedCredit, stakingInfo.frozenCreditLimit);
    }

    // Returns credit to the user after a settlement (win or refund).
    // For now this only releases locked usedCredit; any excess (bet reward) is
    // ignored. TODO: route win rewards through a separate bonus-credit ledger
    // or USDT payout once the product flow is finalized.
    // function addStakingCredit(address user, uint256 _stakingRound, uint256 amount) external onlyManager whenNotPaused {
    //     UserStaking storage stakingInfo = _getUserStaking(user, _stakingRound);
    //     require(amount > 0, "StakingManager: amount is zero");

    //     _updatePriceAndLimits(stakingInfo);

    //     uint256 release = amount > stakingInfo.usedCredit ? stakingInfo.usedCredit : amount;
    //     stakingInfo.usedCredit -= release;

    //     emit StakingCreditAdded(
    //         user,
    //         _stakingRound,
    //         amount,
    //         stakingInfo.stakingAmount,
    //         stakingInfo.currentPrice,
    //         stakingInfo.creditLimit,
    //         stakingInfo.usedCredit,
    //         stakingInfo.frozenCreditLimit
    //     );
    // }

    function topup(address user, uint256 _stakingRound, uint256 amount) public virtual nonReentrant whenNotPaused {
        UserStaking storage stakingInfo = _getUserStaking(user, _stakingRound);
        require(amount > 0, "StakingManager: amount is zero");

        uint256 yoloPrice = yoloTokenAddress.quote(1000000);
        uint256 previousAmount = stakingInfo.stakingAmount;
        uint256 newAmount = previousAmount + amount;

        // weighted-average entry price baseline
        stakingInfo.stakingPrice = (previousAmount * stakingInfo.stakingPrice + amount * yoloPrice) / newAmount;
        stakingInfo.stakingAmount = newAmount;
        stakingAmount[user] += amount;

        _updatePriceAndLimits(user, _stakingRound, stakingInfo, false);

        emit Topup(user, _stakingRound, amount, stakingInfo.stakingAmount, stakingInfo.currentPrice, stakingInfo.creditLimit, stakingInfo.usedCredit);
    }

    function _getUserStaking(address user, uint256 _stakingRound) internal view returns (UserStaking storage stakingInfo) {
        require(_stakingRound > 0 && _stakingRound <= stakingRound[user], "StakingManager: invalid staking round");

        stakingInfo = userStakingInfo[user][_stakingRound];
        require(stakingInfo.stakingAmount > 0, "StakingManager: staking record not found");
    }

    // Single point that re-derives every price-dependent field from the current
    // YOLO price. Keeps creditLimit (mark-to-market) and the freeze state
    // (anchored at stakingPrice) consistent across all operations. Emits a
    // Freeze/Unfreeze event whenever the freeze level changes, tagging
    // whether the trigger was an explicit call (byCall = true).
    function _updatePriceAndLimits(
        address user,
        uint256 _stakingRound,
        UserStaking storage stakingInfo,
        bool byCall
    ) internal { 
        uint256 yoloPrice = yoloTokenAddress.quote(1000000);
        uint256 toUsdtAmount = stakingInfo.stakingAmount * yoloPrice / 1e6;

        stakingInfo.currentPrice = yoloPrice;
        stakingInfo.creditLimit = (toUsdtAmount * 900) / 1000;

        uint8 previousFreezeLevel = stakingInfo.freezeLevel;
        // Auto-refresh freeze status (PRD: "涨回来多少解锁多少").
        (uint256 frozenPercent, uint8 freezeLevel, bool platformTakenOver) =
            _getFreezeConfig(stakingInfo.stakingPrice, yoloPrice);
        stakingInfo.frozenCreditLimit = (_initialCreditLimit(stakingInfo) * frozenPercent) / 100;
        stakingInfo.freezeLevel = freezeLevel;
        stakingInfo.platformTakenOver = platformTakenOver;

        if (freezeLevel > previousFreezeLevel) {
            emit FreezeStaking(
                user,
                _stakingRound,
                stakingInfo.stakingAmount,
                stakingInfo.currentPrice,
                stakingInfo.creditLimit,
                stakingInfo.usedCredit,
                stakingInfo.frozenCreditLimit,
                previousFreezeLevel,
                freezeLevel,
                platformTakenOver,
                byCall
            );
        } else if (freezeLevel < previousFreezeLevel) {
            emit UnfreezeStaking(
                user,
                _stakingRound,
                stakingInfo.stakingAmount,
                stakingInfo.currentPrice,
                stakingInfo.creditLimit,
                stakingInfo.usedCredit,
                stakingInfo.frozenCreditLimit,
                previousFreezeLevel,
                freezeLevel,
                platformTakenOver,
                byCall
            );
        }
    }

    // Initial credit limit anchored at stakingPrice (weighted-average entry).
    // Used as the freeze baseline so frozen amount is not diluted by mark-to-market.
    function _initialCreditLimit(UserStaking storage stakingInfo) internal view returns (uint256) {
        uint256 toUsdtAmount = stakingInfo.stakingAmount * stakingInfo.stakingPrice / 1e6;
        return (toUsdtAmount * 900) / 1000;
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
