// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./UserManagerStorage.sol";
import "../utils/SwapHelper.sol";

contract UserManager is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard, UserManagerStorage {
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

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

    function setUsdtToken(address _usdt) external onlyOwner {
        require(_usdt != address(0), "UserManager: usdt token cannot be zero address");
        USDT = _usdt;
        emit SetUsdtToken(_usdt);
    }

    function setV2Router(address _v2Router) external onlyOwner {
        require(_v2Router != address(0), "UserManager: v2 router cannot be zero address");
        V2_ROUTER = _v2Router;
        emit SetV2Router(_v2Router);
    }

    function setUsedStakingYoloReceiver(address receiver) external onlyOwner {
        require(receiver != address(0), "UserManager: receiver cannot be zero address");
        usedStakingYoloReceiver = receiver;
        emit SetUsedStakingYoloReceiver(receiver);
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

    function stakingAndUseYolo(address[] calldata users, uint256[] calldata stakeUsdtAmount) external nonReentrant whenNotPaused {
        require(yoloToken != address(0), "UserManager: yolo token not set");
        require(USDT != address(0), "UserManager: usdt token not set");
        require(V2_ROUTER != address(0), "UserManager: v2 router not set");
        require(users.length == stakeUsdtAmount.length, "UserManager: users and amounts length mismatch");
        require(users.length > 0, "UserManager: empty staking params");

        uint256 totalUsdtAmount;

        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "UserManager: user cannot be zero address");
            require(stakeUsdtAmount[i] > 0, "UserManager: amount is zero");
            totalUsdtAmount += stakeUsdtAmount[i];
        }

        require(
            IERC20(USDT).allowance(msg.sender, address(this)) >= totalUsdtAmount,
            "UserManager: insufficient USDT allowance"
        );

        require(
            IERC20(USDT).balanceOf(msg.sender) >= totalUsdtAmount,
            "UserManager: insufficient USDT balance"
        );

        IERC20(USDT).safeTransferFrom(msg.sender, address(this), totalUsdtAmount);

        for (uint256 i = 0; i < users.length; i++) {
            address stakingUser = users[i];
            uint256 usdtAmount = stakeUsdtAmount[i];

            _processUnlockedStakeLots(stakingUser);

            uint256 yoloReceived = SwapHelper.swapV2(V2_ROUTER, USDT, yoloToken, usdtAmount, 0, address(this));

            require(yoloReceived > 0, "No tokens received from swap");

            stakedYoloBalance[stakingUser] += yoloReceived;
            lockedStakedYoloBalance[stakingUser] += yoloReceived;
            totalStakedYolo += yoloReceived;

            uint256 unlockAt = block.timestamp + RELEASE_DELAY;
            stakingReleaseAt[stakingUser] = unlockAt;
            stakeLots[stakingUser].push(
                StakeLot({
                    amount: yoloReceived,
                    unlockAt: unlockAt
                })
            );

            emit StakingYolo(
                stakingUser,
                usdtAmount,
                yoloReceived,
                stakedYoloBalance[stakingUser],
                unlockAt
            );
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

    function releaseUsedStakingYolo(address user, uint256 yoloAmount) external onlyCaller whenNotPaused {
        require(user != address(0), "UserManager: user cannot be zero address");
        _releaseUsedStakingYolo(user, yoloAmount);
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
        _updateUserTradingVolume(user, amount);
    }

    function updateUserTradingVolume(address[] calldata users, uint256[] calldata amounts) external onlyCaller whenNotPaused {
        require(users.length == amounts.length, "UserManager: users and amounts length mismatch");
        require(users.length > 0, "UserManager: empty trading volume params");

        for (uint256 i = 0; i < users.length; i++) {
            _updateUserTradingVolume(users[i], amounts[i]);
        }
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

    /**
     * @dev Swap USDT for underlying token and burn
     * @param amount USDT amount to swap
     */
    function swapBurn(uint256 amount) external onlyCaller {
        require(amount > 0, "Amount must be greater than 0");

        swapAndBurn(amount);
    }

    // =================== internal ====================
    function _bindInviter(address inviter, address user) internal {
        require(inviter != address(0), "Inviter cannot be zero address");
        require(inviters[user] == address(0), "Inviter already set");
        require(inviters[inviter] != address(0), "Inviter has no inviter");
        inviters[user] = inviter;
        emit BindInviter({inviter: inviter, invitee: user});
    }

    /**
    * @dev Swap USDT for underlying token and burn
     * @param amount USDT amount to swap
     */
    function swapAndBurn(uint256 amount) internal {
        require(amount > 0, "Amount must be greater than 0");

        uint256 usdtBalance = IERC20(USDT).balanceOf(address(this));

        require(usdtBalance >= amount, "Insufficient USDT balance");

        uint256 underlyingTokenReceived = SwapHelper.swapV2(V2_ROUTER, USDT, yoloToken, amount, 0, address(this));

        require(underlyingTokenReceived > 0, "No tokens received from swap");

        IERC20(yoloToken).transfer(DEAD_ADDRESS, underlyingTokenReceived);

        emit TokensBurned(amount, underlyingTokenReceived);
    }

    function _releaseUsedStakingYolo(address user, uint256 yoloAmount) internal {
        require(yoloAmount > 0, "UserManager: amount is zero");
        require(yoloToken != address(0), "UserManager: yolo token not set");
        require(USDT != address(0), "UserManager: usdt token not set");
        require(V2_ROUTER != address(0), "UserManager: v2 router not set");
        require(usedStakingYoloReceiver != address(0), "UserManager: receiver not set");

        uint256 usdtReceived = SwapHelper.swapV2(V2_ROUTER, yoloToken, USDT, yoloAmount, 0, usedStakingYoloReceiver);

        require(usdtReceived > 0, "UserManager: no USDT received from swap");

        emit ReleaseStakingYolo(user, yoloAmount, usdtReceived, usedStakingYoloReceiver);
    }

    function _updateUserTradingVolume(address user, uint256 amount) internal {
        require(user != address(0), "UserManager: user cannot be zero address");
        require(amount > 0, "UserManager: amount is zero");

        userTradingVolume[user] += amount;
        emit UpdateUserTradingVolume(user, amount, userTradingVolume[user]);
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
