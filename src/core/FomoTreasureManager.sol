// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { FomoTreasureManagerStorage } from "./FomoTreasureManagerStorage.sol";

contract FomoTreasureManager is Initializable, OwnableUpgradeable, PausableUpgradeable, FomoTreasureManagerStorage {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor() {
        _disableInitializers();
    }

    modifier onlyAuthorizedCaller() {
        require(authorizedCallers.contains(msg.sender), "onlyAuthorizedCaller");
        _;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "onlyManager");
        _;
    }

    receive() external payable {}

    function initialize(address initialOwner, address _rewardTokenAddress) public initializer {
        __Ownable_init(initialOwner);
        manager = initialOwner;
        rewardTokenAddress = _rewardTokenAddress;
    }

    function setManager(address _manager) external onlyOwner {
        require(_manager != address(0), "DaoRewardManager: manager cannot be zero address");
        manager = _manager;
    }

    function setRewardTokenAddress(address _rewardTokenAddress) external onlyOwner {
        require(_rewardTokenAddress != address(0), "DaoRewardManager: _rewardTokenAddress cannot be zero address");
        rewardTokenAddress = _rewardTokenAddress;
    }

    function setAuthorizedCaller(address caller, bool authorized) external onlyManager {
        if (authorized) {
            authorizedCallers.add(caller);
        } else {
            authorizedCallers.remove(caller);
        }
    }

    function getAuthorizedCallers() external view returns (address[] memory) {
        return EnumerableSet.values(authorizedCallers);
    }

    function withdrawErc20(address tokenAddress, address recipient, uint256 amount) external onlyAuthorizedCaller {
        require(amount <= IERC20(tokenAddress).balanceOf(address(this)), "DaoRewardManager: withdrawErc20 amount more token balance in this contracts");
        IERC20(tokenAddress).safeTransfer(recipient, amount);
    }

    function distributeReward(
        address tokenAddress,
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint8[] calldata rewardTypes
    ) external whenNotPaused onlyAuthorizedCaller {
        _validateDistributionInputs(recipients, amounts, rewardTypes);

        for (uint256 i = 0; i < recipients.length; i++) {
            _distributeSingleReward(tokenAddress, recipients[i], amounts[i], rewardTypes[i]);
        }
    }

    function claimReward(address tokenAddress, uint256 amount, uint8 rewardType) external {
        require(_rewardBalance(tokenAddress, msg.sender, rewardType) >= amount, "DaoRewardManager: claimReward balance is not enough");

        _decreaseRewardBalance(tokenAddress, msg.sender, amount, rewardType);
        fundingBalance[tokenAddress] -= amount;

        IERC20(tokenAddress).transfer(msg.sender, amount);

        emit ClaimReward(tokenAddress, msg.sender, amount, rewardType);
    }

    function _tokenBalance() internal view virtual returns (uint256) {
        return IERC20(rewardTokenAddress).balanceOf(address(this));
    }

    function _validateDistributionInputs(
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint8[] calldata rewardTypes
    ) internal pure {
        require(recipients.length > 0, "DaoRewardManager: recipient length is zero");
        require(amounts.length > 0, "DaoRewardManager: amount length is zero");
        require(rewardTypes.length > 0, "DaoRewardManager: rewardType length is zero ");
        require(recipients.length == amounts.length, "DaoRewardManager: recipient and amount length mismatch");
        require(recipients.length == rewardTypes.length, "DaoRewardManager: recipient and rewardType length mismatch");
    }

    function _distributeSingleReward(
        address tokenAddress,
        address recipient,
        uint256 amount,
        uint8 rewardType
    ) internal {
        require(amount > 0, "DaoRewardManager: distributeReward amount is zero");
        require(recipient != address(0), "DaoRewardManager: distributeReward recipient is zero address");

        _increaseRewardBalance(tokenAddress, recipient, amount, rewardType);
        fundingBalance[tokenAddress] += amount;

        emit DistributeReward(tokenAddress, recipient, amount, rewardType);
    }

    function _increaseRewardBalance(address tokenAddress, address recipient, uint256 amount, uint8 rewardType) internal {
        if (rewardType == uint8(RewardType.User)) {
            userRewardBalance[tokenAddress][recipient] += amount;
            return;
        }
        if (rewardType == uint8(RewardType.Agent)) {
            agentRewardBalance[tokenAddress][recipient] += amount;
            return;
        }
        revert("DaoRewardManager: invalid rewardType");
    }

    function _decreaseRewardBalance(address tokenAddress, address recipient, uint256 amount, uint8 rewardType) internal {
        if (rewardType == uint8(RewardType.User)) {
            userRewardBalance[tokenAddress][recipient] -= amount;
            return;
        }
        if (rewardType == uint8(RewardType.Agent)) {
            agentRewardBalance[tokenAddress][recipient] -= amount;
            return;
        }
        revert("DaoRewardManager: invalid rewardType");
    }

    function _rewardBalance(address tokenAddress, address recipient, uint8 rewardType) internal view returns (uint256) {
        if (rewardType == uint8(RewardType.User)) {
            return userRewardBalance[tokenAddress][recipient];
        }
        if (rewardType == uint8(RewardType.Agent)) {
            return agentRewardBalance[tokenAddress][recipient];
        }
        revert("DaoRewardManager: invalid rewardType");
    }
}
