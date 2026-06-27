// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./NftTokenManagerStorage.sol";


contract NftTokenManager is
    Initializable,
    OwnableUpgradeable,
    IERC721Receiver,
    NftTokenManagerStorage
{
    using SafeERC20 for IERC20;

    constructor(){
        _disableInitializers();
    }

    modifier onlyWithdrawCaller() {
        require(msg.sender == withdrawCaller, "onlyWithdrawCaller");
        _;
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function initialize(
        address initialOwner,
        address initialWithdrawCaller
    ) public initializer {
        __Ownable_init(initialOwner);
        withdrawCaller = initialWithdrawCaller;
    }

    function setWithdrawCaller(address _withdrawCaller) external onlyOwner {
        address oldAddress = withdrawCaller;
        withdrawCaller = _withdrawCaller;
        emit SetWithdrawCaller(oldAddress, _withdrawCaller);
    }

    function withdrawToken(address tokenAddress, address recipient, uint256 amount) external onlyWithdrawCaller {
        require(amount <= IERC20(tokenAddress).balanceOf(address(this)), "NftTokenManager: withdrawErc20 amount more token balance in this contracts");
        IERC20(tokenAddress).safeTransfer(recipient, amount);
        emit Withdraw(tokenAddress, recipient, amount);
    }
}
