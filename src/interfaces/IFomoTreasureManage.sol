// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IFomoTreasureManage {
    enum RewardType {
        User,
        Agent
    }

    event DistributeReward(address indexed tokenAddress, address recipient, uint256 amount, uint8 rewardType);

    event ClaimReward(address indexed tokenAddress, address recipient, uint256 amount, uint8 rewardType);

    function withdrawErc20(address tokenAddress, address recipient, uint256 amount) external;

    function distributeReward(
        address tokenAddress,
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint8[] calldata rewardTypes
    ) external;

    function claimReward(address tokenAddress, uint256 amount, uint8 rewardType) external;
}
