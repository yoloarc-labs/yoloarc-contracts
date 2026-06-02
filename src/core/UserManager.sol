// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./UserManagerStorage.sol";

contract UserManager is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard, UserManagerStorage {
    using SafeERC20 for IERC20;

    modifier onlyCaller() {
        require(msg.sender == contractCaller, "onlyCaller");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address, address initialYoloToken, address _contractCaller) public initializer {
        __Ownable_init(initialOwner);
        yoloToken = initialYoloToken;
        contractCaller = _contractCaller;
    }

    function bindInviter(address inviter) public {
        _bindInviter(inviter, msg.sender);
    }

    function setContractCaller(address _contractCaller) external onlyOwner {
        contractCaller = _contractCaller;
    }

    function setYoloToken(address _yoloToken) external onlyOwner {
        require(_yoloToken != address(0), "UserManager: yolo token cannot be zero address");
        yoloToken = _yoloToken;
        emit SetYoloToken(_yoloToken);
    }

    function bindRootInviter(address rootInviter, address user) external onlyCaller {
        require(rootInviter != address(0) && user != address(0), "Root inviter and user cannot be zero address");
        require(inviters[user] == address(0), "Root inviter already set");

        inviters[user] = rootInviter;
        emit BindInviter({inviter: rootInviter, invitee: user});
    }

    function bindInviterBatch(address[] calldata inviters, address[] calldata invitees) external onlyCaller {
        require(inviters.length == invitees.length, "UserManager: inviters and invitees length mismatch");
        for (uint256 i = 0; i < inviters.length; i++) {
            _bindInviter(inviters[i], invitees[i]);
        }
    }

    function stakingAndUseYolo(uint256 stakeAmount, uint256 betAmount) external nonReentrant whenNotPaused {
        require(yoloToken != address(0), "UserManager: yolo token not set");
        require(stakeAmount > 0 || betAmount > 0, "UserManager: invalid staking params");

        _processUnlockedStakeLots(msg.sender);

        if (stakeAmount > 0) {
            IERC20(yoloToken).safeTransferFrom(msg.sender, address(this), stakeAmount);
            stakedYoloBalance[msg.sender] += stakeAmount;
            lockedStakedYoloBalance[msg.sender] += stakeAmount;
            totalStakedYolo += stakeAmount;

            uint256 unlockAt = block.timestamp + RELEASE_DELAY;
            stakingReleaseAt[msg.sender] = unlockAt;
            stakeLots[msg.sender].push(StakeLot({amount: stakeAmount, unlockAt: unlockAt}));

            emit StakingYolo(msg.sender, stakeAmount, stakedYoloBalance[msg.sender], unlockAt);
        }

        if (betAmount > 0) {
            uint256 requiredUsage = (betAmount * SPORTS_USAGE_BPS) / BPS_DENOMINATOR;
            require(requiredUsage > 0, "UserManager: bet amount too small");
            require(usedStakedYoloBalance[msg.sender] == 0, "UserManager: staking yolo already in use");
            require(stakedYoloBalance[msg.sender] >= requiredUsage, "UserManager: insufficient staked yolo");

            _consumeStakeForUsage(msg.sender, requiredUsage);

            usedStakedYoloBalance[msg.sender] = requiredUsage;
            emit UseStakingYolo(msg.sender, requiredUsage, usedStakedYoloBalance[msg.sender], 0);
        }
    }

    function withdrawStakingYolo(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "UserManager: amount is zero");

        _processUnlockedStakeLots(msg.sender);

        uint256 availableAmount = unlockedStakedYoloBalance[msg.sender];

        require(availableAmount >= amount, "UserManager: insufficient available staked yolo");

        unlockedStakedYoloBalance[msg.sender] -= amount;
        stakedYoloBalance[msg.sender] -= amount;
        totalStakedYolo -= amount;
        IERC20(yoloToken).safeTransfer(msg.sender, amount);

        emit WithdrawStakingYolo(msg.sender, amount, stakedYoloBalance[msg.sender]);
    }

    function releaseUsedStakingYolo(address user) external onlyCaller whenNotPaused {
        require(user != address(0), "UserManager: user cannot be zero address");
        _releaseUsedStakingYolo(user);
    }

    function addRefundingAmount(address user, uint256 amount) external onlyCaller whenNotPaused {
        require(user != address(0), "UserManager: user cannot be zero address");
        require(amount > 0, "UserManager: amount is zero");
        require(_availableRefundLiquidity() >= amount, "UserManager: insufficient refund liquidity");

        refundingAmount[user] += amount;
        totalRefundReserved += amount;

        emit AddRefundingAmount(
            user,
            amount,
            refundingAmount[user],
            refundingAmount[user] * REFUND_CLAIM_MULTIPLIER
        );
    }

    function updateUserTradingVolume(address user, uint256 amount) external onlyCaller whenNotPaused {
        require(user != address(0), "UserManager: user cannot be zero address");
        require(amount > 0, "UserManager: amount is zero");

        userTradingVolume[user] += amount;
        emit UpdateUserTradingVolume(user, amount, userTradingVolume[user]);
    }

    function claimRefundingAmount(uint256 amount) external nonReentrant whenNotPaused {
        uint256 refundAmount = refundingAmount[msg.sender];
        require(refundAmount >= amount, "UserManager: refunding amount less than claim amount");
        require(
            userTradingVolume[msg.sender] >= amount * REFUND_CLAIM_MULTIPLIER,
            "UserManager: insufficient trading volume"
        );

        refundingAmount[msg.sender] -= amount;
        totalRefundReserved -= amount;

        IERC20(yoloToken).safeTransfer(msg.sender, amount);

        emit ClaimRefundingAmount(msg.sender, amount);
    }

    // =================== internal ====================
    function _bindInviter(address inviter, address user) internal {
        require(inviter != address(0), "Inviter cannot be zero address");
        require(inviters[user] == address(0), "Inviter already set");
        require(inviters[inviter] != address(0), "Inviter has no inviter");
        inviters[user] = inviter;
        emit BindInviter({inviter: inviter, invitee: user});
    }

    function _releaseUsedStakingYolo(address user) internal {
        uint256 releasedAmount = usedStakedYoloBalance[user];
        require(releasedAmount > 0, "UserManager: no used staking yolo");
        _clearUsedStakingYolo(user, releasedAmount);
    }

    function _clearUsedStakingYolo(address user, uint256 releasedAmount) internal {
        usedStakedYoloBalance[user] = 0;
        unlockedStakedYoloBalance[user] += releasedAmount;
        emit ReleaseStakingYolo(user, releasedAmount);
    }

    function _processUnlockedStakeLots(address user) internal {
        uint256 index = nextStakeLotIndex[user];
        uint256 lotsLength = stakeLots[user].length;

        while (index < lotsLength) {
            StakeLot storage lot = stakeLots[user][index];
            if (lot.amount == 0) {
                unchecked {
                    ++index;
                }
                continue;
            }

            if (lot.unlockAt > block.timestamp) {
                break;
            }

            uint256 releasedAmount = lot.amount;
            lot.amount = 0;
            lockedStakedYoloBalance[user] -= releasedAmount;
            unlockedStakedYoloBalance[user] += releasedAmount;

            unchecked {
                ++index;
            }
        }

        nextStakeLotIndex[user] = index;
    }

    function _consumeStakeForUsage(address user, uint256 amount) internal {
        uint256 unlockedAmount = unlockedStakedYoloBalance[user];
        if (unlockedAmount >= amount) {
            unlockedStakedYoloBalance[user] = unlockedAmount - amount;
            return;
        }

        if (unlockedAmount > 0) {
            unlockedStakedYoloBalance[user] = 0;
            amount -= unlockedAmount;
        }

        require(lockedStakedYoloBalance[user] >= amount, "UserManager: insufficient locked staked yolo");

        uint256 index = nextStakeLotIndex[user];
        uint256 lotsLength = stakeLots[user].length;

        while (amount > 0 && index < lotsLength) {
            StakeLot storage lot = stakeLots[user][index];
            uint256 lotAmount = lot.amount;

            if (lotAmount == 0) {
                unchecked {
                    ++index;
                }
                continue;
            }

            if (lotAmount > amount) {
                lot.amount = lotAmount - amount;
                lockedStakedYoloBalance[user] -= amount;
                amount = 0;
                break;
            }

            lot.amount = 0;
            lockedStakedYoloBalance[user] -= lotAmount;
            amount -= lotAmount;

            unchecked {
                ++index;
            }
        }

        nextStakeLotIndex[user] = index;
        require(amount == 0, "UserManager: failed to consume stake");
    }

    function _availableRefundLiquidity() internal view returns (uint256) {
        uint256 balance = IERC20(yoloToken).balanceOf(address(this));
        if (balance <= totalStakedYolo + totalRefundReserved) {
            return 0;
        }
        return balance - totalStakedYolo - totalRefundReserved;
    }
}
