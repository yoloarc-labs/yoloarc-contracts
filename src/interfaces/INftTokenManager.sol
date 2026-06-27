// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface INftTokenManager {
    event SetWithdrawCaller(address oldAddress, address newAddress);
    event Withdraw(address indexed tokenAddress, address recipient, uint256 amount);


    function withdrawToken(address tokenAddress, address recipient, uint256 amount) external;
    function setWithdrawCaller(address _withdrawCaller) external;
}
