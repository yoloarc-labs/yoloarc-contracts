// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IYoloToken.sol";

abstract contract YoloTokenStorage is IYoloToken {
    uint256 public constant MaxTotalSupply = 1_000_000_000 * 10 ** 6;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant SELL_FEE_BPS = 300;
    uint256 internal constant PRICE_DROP_3_BPS = 300;
    uint256 internal constant PRICE_DROP_6_BPS = 600;
    uint256 internal constant DOWN_TAX_3_BPS = 1_000;
    uint256 internal constant DOWN_TAX_6_BPS = 2_000;

    address public USDT;

    uint256 public _lpBurnedTokens;

    address public stakingManager;
    address public operator;

    address public currencyDistributor;

    bool internal isAllocation;

    YoloPool public cmPool;

    address public mainPair;

    bool internal slippageLock;

    mapping(address => uint256) public userCost;

    EnumerableSet.AddressSet whiteList;

    bool internal isOpenBuy;
    bool internal isOpenSell;

    uint256 public latestChoPrice;
    address public predictionContract;

    address public fundingPod;

    uint256 public downsideTax;

    address public fomoTreasureAddress;

    address public v2Router;
    address public v2Factory;

    uint256[98] private __gap;
}
