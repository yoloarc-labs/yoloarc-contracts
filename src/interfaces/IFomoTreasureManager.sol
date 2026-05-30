// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IFomoTreasureManager {
    event Deposit(
        address indexed tokenAddress,
        address indexed sender,
        uint256 amount
    );

    event DepositRewards(
        address indexed tokenAddress,
        address indexed sender,
        address feePayer,
        uint256 amount,
        uint256 reward14,
        uint256 reward6,
        uint256 fee
    );

    event Withdraw(
        address indexed tokenAddress,
        address sender,
        address withdrawAddress,
        uint256 amount
    );

    event DistributeReward(
        address indexed tokenAddress,
        address recipient,
        uint256 amount
    );

    event ClaimReward (
        address indexed tokenAddress,
        address recipient,
        uint256 amount
    );

    event LossAirdropEvent (
        address indexed tokenAddress,
        address receiver,
        uint256 lossAmount,
        uint8 dropType
    );

    event ClaimAirdropEvent (
        address indexed tokenAddress,
        address receiver,
        uint256 airdropAmount,
        uint8 dropType
    );

    function deposit() external payable returns (bool);
    function depositRewardErc20(address tokenAddress, address feePayer, uint256 amount, uint8 depositType) external returns (bool);
    function lossAndAirdrop(address tokenAddress, address[] calldata receiver,  uint256[] calldata lossAmount, uint8[] calldata dropType) external;
    function withdraw(address payable withdrawAddress, uint256 amount) external payable returns (bool);
    function withdrawErc20(address recipient, uint256 amount) external returns (bool);
    function distributeReward(address tokenAddress, address[]  memory recipient, uint256[] memory amount) external;
    function claimReward(address tokenAddress, uint256 amount) external;
    function claimAirdrop(address tokenAddress, uint256 amount, uint8 dropType) external;
}
