// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FomoTreasureManagerStorage} from "./FomoTreasureManagerStorage.sol";

contract FomoTreasureManager is Initializable, OwnableUpgradeable, PausableUpgradeable, FomoTreasureManagerStorage {
    using SafeERC20 for IERC20;

    constructor() {
        _disableInitializers();
    }

    modifier onlyManager() {
        require(msg.sender == manager, "onlyManager");
        _;
    }

    modifier onlyFundManager() {
        require(msg.sender == fundManager, "onlyFundManager");
        _;
    }

    modifier onlyRewardSender() {
        require(msg.sender == rewardSender, "onlyRewardSender");
        _;
    }

    /**
     * @dev Receive native tokens (BNB) and record to funding balance
     */
    receive() external payable {
        require(!paused(), "Pausable: paused");
        fundingBalance[NativeTokenAddress] += msg.value;
        emit Deposit(NativeTokenAddress, msg.sender, msg.value);
    }

    /**
     * @dev Initialize the FOMO Treasure Manager contract
     * @param initialOwner Initial owner address
     * @param _manager Initial manager address
     * @param _underlyingToken Underlying token address (USDT)
     */
    function initialize(address initialOwner, address _manager, address _underlyingToken, address _adminFeeVault, address _rewardSender) public initializer {
        __Ownable_init(initialOwner);
        manager = _manager;
        underlyingToken = _underlyingToken;
        adminFeeVault = _adminFeeVault;
        rewardSender = _rewardSender;
    }

    /**
     * @dev Pause the contract (only operator can call)
     */
    function pause() external onlyManager {
        _pause();
    }

    /**
     * @dev Unpause the contract (only operator can call)
     */
    function unpause() external onlyManager {
        _unpause();
    }

    /**
     * @dev Set the manager address (only owner can call)
     * @param _manager New manager address
     */
    function setManager(address _manager) external onlyOwner {
        require(_manager != address(0), "FomoTreasureManager: manager cannot be zero address");
        manager = _manager;
    }

    /**
     * @dev Set the reward sender address (only owner can call)
     * @param _rewardSender New reward sender address
     */
    function setRewardSender(address _rewardSender) external onlyOwner {
        require(_rewardSender != address(0), "FomoTreasureManager: manager cannot be zero address");
        rewardSender = _rewardSender;
    }

    /**
     * @dev Set the fund manager address (only owner can call)
     * @param _fundManager New fund manager address
     */
    function setFundManager(address _fundManager) external onlyOwner {
        require(_fundManager != address(0), "FomoTreasureManager: fund manager cannot be zero address");
        fundManager = _fundManager;
    }

    /**
    * @dev update funding balance (only owner can call)
     * @param tokenAddress update token address
     * @param amount update token amount
     */
    function updateFundingBalance(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(0), "FomoTreasureManager: token address cannot be zero address");
        fundingBalance[tokenAddress] += amount;
    }

    /**
     * @dev Deposit native tokens (BNB) to FOMO Treasury
     * @return Whether the operation was successful
     */
    function deposit() external payable whenNotPaused returns (bool) {
        fundingBalance[NativeTokenAddress] += msg.value;
        emit Deposit(NativeTokenAddress, msg.sender, msg.value);
        return true;
    }

    /**
     * @dev Deposit ERC20 tokens (USDT) to FOMO Treasury
     * @param amount Amount of tokens to deposit
     * @return Whether the operation was successful
     */
    function depositRewardErc20(address tokenAddress, address feePayer, uint256 amount, uint8 depositType) external whenNotPaused returns (bool) {
        require(amount > 0, "Invalid amount");
        IERC20 token = IERC20(tokenAddress);

        token.safeTransferFrom(msg.sender, address(this), amount);

        if (depositType == uint8(DepositReward.RewardType)) {
            uint256 reward14 = (amount * 50) / 100;
            uint256 reward6 = (amount * 30) / 100;
            uint256 fee = (amount * 20) / 100;

            stakingRewardBalance[uint8(StakingRewardType.FourteenThousandType)] += reward14;
            stakingRewardBalance[uint8(StakingRewardType.SixThousandType)] += reward6;

            fundingBalance[tokenAddress] += (reward14 + reward6);

            token.safeTransfer(adminFeeVault, fee);

            emit DepositRewards(msg.sender, tokenAddress, feePayer, amount, reward14, reward6, fee);
        } else {
            fundingBalance[tokenAddress] += amount;
            emit Deposit(msg.sender, tokenAddress, amount);
        }
        return true;
    }

    /**
     * @dev Airdrop tokens to users who lost in the prediction
     * @param tokenAddress Token contract address to airdrop
     * @param receiver Array of recipient addresses
     * @param lossAmount Array of airdrop amounts corresponding to each receiver
     */
    function lossAndAirdrop(address tokenAddress, address[] calldata receiver,  uint256[] calldata lossAmount, uint8[] calldata dropType) external whenNotPaused onlyRewardSender {
        require(receiver.length > 0, "FomoTreasureManager: receiver length is zero");
        require(lossAmount.length > 0, "FomoTreasureManager: lossAmount length is zero");
        require(receiver.length == lossAmount.length, "FomoTreasureManager: receiver and lossAmount length mismatch");

        for(uint256 i = 0; i < receiver.length; i++) {
            require(lossAmount[i] > 0, "FomoTreasureManager: lossAmount is zero");
            require(receiver[i] != address(0), "FomoTreasureManager: receiver is zero address");

            predictionLossAirdrop[tokenAddress][receiver[i]] += lossAmount[i];

            fundingBalance[tokenAddress] += lossAmount[i];

            emit LossAirdropEvent(tokenAddress, receiver[i], lossAmount[i], dropType[i]);
        }
    }

    /**
     * @dev Withdraw native tokens (BNB)
     * @param withdrawAddress Receiving address
     * @param amount Withdrawal amount
     * @return Whether the operation was successful
     */
    function withdraw(address payable withdrawAddress, uint256 amount)
        external
        payable
        whenNotPaused
        onlyFundManager
        returns (bool)
    {
        require(
            address(this).balance >= amount,
            "FomoTreasureManager withdraw: insufficient native token balance in contract"
        );
        fundingBalance[NativeTokenAddress] -= amount;
        (bool success,) = withdrawAddress.call{value: amount}("");
        if (!success) {
            return false;
        }
        emit Withdraw(NativeTokenAddress, msg.sender, withdrawAddress, amount);
        return true;
    }

    /**
     * @dev Withdraw ERC20 tokens (USDT)
     * @param recipient Recipient address
     * @param amount Withdrawal amount
     * @return Whether the operation was successful
     */
    function withdrawErc20(address recipient, uint256 amount) external whenNotPaused onlyFundManager returns (bool) {
        require(
            amount <= _tokenBalance(), "FomoTreasureManager: withdraw erc20 amount more token balance in this contracts"
        );
        fundingBalance[underlyingToken] -= amount;

        IERC20(underlyingToken).safeTransfer(recipient, amount);

        emit Withdraw(underlyingToken, msg.sender, recipient, amount);
        return true;
    }

    /**
     * @dev distributeReward tokens to winner
     * @param tokenAddress token contract address
     * @param recipient token recipient address
     * @param amount reward amount
     */
    function distributeReward(address tokenAddress, address[] memory recipient, uint256[] memory amount) external whenNotPaused onlyRewardSender {

        require(recipient.length > 0, "FomoTreasureManager: recipient length is zero");
        require(amount.length > 0, "FomoTreasureManager: amount length is zero");

        for(uint256 i = 0; i < recipient.length; i++) {
            require(amount[i] > 0, "FomoTreasureManager: distributeReward amount is zero");
            require(recipient[i] != address(0), "FomoTreasureManager: distributeReward recipient is zero address");
            awardWinnerBalance[tokenAddress][recipient[i]] += amount[i];

            fundingBalance[tokenAddress] += amount[i];

            emit DistributeReward(tokenAddress, recipient[i], amount[i]);
        }
    }

    /**
     * @dev claimReward winner claim token from fomo contract
     * @param tokenAddress token contract address
     * @param amount claim reward amount
     */
    function claimReward(address tokenAddress, uint256 amount) external {
        require(awardWinnerBalance[tokenAddress][msg.sender] >= amount, "FomoTreasureManager: claimReward balance is not enough");

        awardWinnerBalance[tokenAddress][msg.sender] -= amount;
        fundingBalance[tokenAddress] -= amount;

        IERC20(tokenAddress).transfer(msg.sender, amount);

        emit ClaimReward(tokenAddress, msg.sender, amount);
    }

    /**
    * @dev claimAirdrop loser claim token from fomo contract
     * @param tokenAddress token contract address
     * @param amount claim reward amount
     */
    function claimAirdrop(address tokenAddress, uint256 amount, uint8 dropType) external {
        require(predictionLossAirdrop[tokenAddress][msg.sender] >= amount, "FomoTreasureManager: claimAirdrop balance is not enough");

        predictionLossAirdrop[tokenAddress][msg.sender] -= amount;
        fundingBalance[tokenAddress] -= amount;

        IERC20(tokenAddress).transfer(msg.sender, amount);

        emit ClaimAirdropEvent(tokenAddress, msg.sender, amount, dropType);
    }


    // ========= internal =========
    /**
     * @dev Get the ERC20 token balance in the contract
     * @return Token balance in the contract
     */
    function _tokenBalance() internal view virtual returns (uint256) {
        return IERC20(underlyingToken).balanceOf(address(this));
    }
}
