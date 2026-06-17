// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CardManager} from "../src/token/allocation/CardManager.sol";
import {ERC20Mock} from "../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract CardManagerTest is Test {
    CardManager internal cardManager;
    ERC20Mock internal underlyingToken;

    address internal constant OWNER = address(0x1);
    address internal constant MANAGER = address(0x2);
    address internal constant CONTRACT_CALLER = address(0x3);
    address internal constant USER = address(0x4);
    address internal constant RECEIVER = address(0x5);

    function setUp() public {
        underlyingToken = new ERC20Mock();
        CardManager implementation = new CardManager();
        bytes memory initData = abi.encodeCall(
            CardManager.initialize,
            (OWNER, MANAGER, CONTRACT_CALLER, address(underlyingToken), "ipfs://card")
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), OWNER, initData);
        cardManager = CardManager(payable(address(proxy)));

        underlyingToken.mint(USER, 10_000 ether);

        vm.startPrank(USER);
        underlyingToken.approve(address(cardManager), type(uint256).max);
        vm.stopPrank();
    }

    function testCannotTransferWhenHolderOwnsLessThan16NFTs() public {
        vm.prank(USER);
        cardManager.buyCards(15, 1_500 ether);

        vm.prank(USER);
        vm.expectRevert("CardManager: holder must own at least 16 NFTs to transfer");
        cardManager.transferFrom(USER, RECEIVER, 0);
    }

    function testCanTransferWhenHolderOwnsAtLeast16NFTs() public {
        vm.prank(USER);
        cardManager.buyCards(16, 1_600 ether);

        vm.prank(USER);
        cardManager.transferFrom(USER, RECEIVER, 0);

        assertEq(cardManager.ownerOf(0), RECEIVER);
        assertEq(cardManager.balanceOf(USER), 15);
        assertEq(cardManager.balanceOf(RECEIVER), 1);
    }
}
