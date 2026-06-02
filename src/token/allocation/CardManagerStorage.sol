// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../../interfaces/ICardManager.sol";

abstract contract CardManagerStorage is ICardManager {
    // Base card price: 100 U, increased by 20% for every 10,000 cards sold.
    uint256 public constant minAmount = 100 * 10 ** 18;

    enum StakingRewardType {
        SixThousandType,
        FourteenThousandType
    }

    enum DepositReward {
        DepositType,
        RewardType
    }

    address public constant NativeTokenAddress = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    address public underlyingToken;
    address public manager;
    address public fundManager;

    address public adminFeeVault;
    address public contractCaller;

    uint256 public _nextTokenId;

    string public nftJson;

    mapping(address => uint256) public fundingBalance;

    mapping(address => mapping(address => uint256)) public validatorBalance;

    uint256[100] private __gap;
}
