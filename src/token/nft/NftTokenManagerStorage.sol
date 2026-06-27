// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../../interfaces/INftTokenManager.sol";

abstract contract NftTokenManagerStorage is INftTokenManager{
    address public withdrawCaller;

}
