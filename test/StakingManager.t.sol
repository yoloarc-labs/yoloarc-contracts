// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StakingManager} from "../src/core/StakingManager.sol";
import {IStakingManager} from "../src/interfaces/IStakingManager.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockYoloToken is IYoloToken {
    uint256 internal quotedPrice;

    constructor(uint256 _quotedPrice) {
        quotedPrice = _quotedPrice;
    }

    function burn(address, uint256) external pure {}

    function quote(uint256) external view returns (uint256) {
        return quotedPrice;
    }

    function setQuote(uint256 _quotedPrice) external {
        quotedPrice = _quotedPrice;
    }
}

contract MockUnderlyingToken is ERC20 {
    constructor() ERC20("Underlying", "UDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StakingManagerTest is Test {
    StakingManager internal stakingManager;
    MockYoloToken internal yoloToken;
    MockUnderlyingToken internal underlyingToken;
    address internal user = address(0x1234);

    function setUp() public {
        yoloToken = new MockYoloToken(1);
        underlyingToken = new MockUnderlyingToken();
        StakingManager implementation = new StakingManager();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                StakingManager.initialize,
                (address(this), address(this), address(underlyingToken), address(0x2), address(0x3), yoloToken)
            )
        );
        stakingManager = StakingManager(payable(address(proxy)));
    }

    function testDepositAndStakingTracksEachRoundSeparately() public {
        uint256 firstAmount = 200 ether;
        uint256 secondAmount = 350 ether;

        vm.startPrank(user);

        vm.warp(1_000);
        stakingManager.depositAndStaking(firstAmount);

        vm.warp(2_000);
        stakingManager.depositAndStaking(secondAmount);

        vm.stopPrank();

        assertEq(stakingManager.stakingRound(user), 2);
        assertEq(stakingManager.stakingAmount(user), firstAmount + secondAmount);

        (
            uint256 firstStakingAmount,
            uint256 firstStakingTime,
            uint256 firstStakingPrice,
            ,
            uint256 firstCreditLimit,
            ,
            uint256 firstFrozenCreditLimit,
            uint8 firstFreezeLevel,
            bool firstPlatformTakenOver
        ) = stakingManager.userStakingInfo(user, 1);
        assertEq(firstStakingAmount, firstAmount);
        assertEq(firstStakingTime, 1_000);
        assertEq(firstStakingPrice, 1);
        assertEq(firstCreditLimit, (firstAmount * 900) / 1000);
        assertEq(firstFrozenCreditLimit, 0);
        assertEq(firstFreezeLevel, 0);
        assertFalse(firstPlatformTakenOver);

        (
            uint256 secondStakingAmount,
            uint256 secondStakingTime,
            uint256 secondStakingPrice,
            ,
            uint256 secondCreditLimit,
            ,
            uint256 secondFrozenCreditLimit,
            uint8 secondFreezeLevel,
            bool secondPlatformTakenOver
        ) = stakingManager.userStakingInfo(user, 2);
        assertEq(secondStakingAmount, secondAmount);
        assertEq(secondStakingTime, 2_000);
        assertEq(secondStakingPrice, 1);
        assertEq(secondCreditLimit, (secondAmount * 900) / 1000);
        assertEq(secondFrozenCreditLimit, 0);
        assertEq(secondFreezeLevel, 0);
        assertFalse(secondPlatformTakenOver);
    }

    function testFreezeStakingAppliesTieredCreditFreezes() public {
        yoloToken.setQuote(100);

        vm.startPrank(user);
        for (uint256 i = 0; i < 5; i++) {
            stakingManager.depositAndStaking(2 ether);
        }

        yoloToken.setQuote(89);
        stakingManager.freezeStaking(1);

        yoloToken.setQuote(79);
        stakingManager.freezeStaking(2);

        yoloToken.setQuote(69);
        stakingManager.freezeStaking(3);

        yoloToken.setQuote(59);
        stakingManager.freezeStaking(4);

        yoloToken.setQuote(49);
        stakingManager.freezeStaking(5);
        vm.stopPrank();

        _assertFreezeState(1, 20, 1, false);
        _assertFreezeState(2, 30, 2, false);
        _assertFreezeState(3, 40, 3, false);
        _assertFreezeState(4, 50, 4, false);
        _assertFreezeState(5, 60, 5, true);
    }

    function testFreezeStakingDoesNotDowngradeExistingFreezeLevel() public {
        yoloToken.setQuote(100);

        vm.startPrank(user);
        stakingManager.depositAndStaking(2 ether);

        yoloToken.setQuote(49);
        stakingManager.freezeStaking(1);

        yoloToken.setQuote(79);
        stakingManager.freezeStaking(1);
        vm.stopPrank();

        _assertFreezeState(1, 60, 5, true);
    }

    function testUnfreezeStakingReleasesCreditAsPriceRecovers() public {
        yoloToken.setQuote(100);

        vm.startPrank(user);
        stakingManager.depositAndStaking(2 ether);

        yoloToken.setQuote(49);
        stakingManager.freezeStaking(1);
        _assertFreezeState(1, 60, 5, true);

        yoloToken.setQuote(59);
        stakingManager.unfreezeStaking(1);
        _assertFreezeState(1, 50, 4, false);

        yoloToken.setQuote(89);
        stakingManager.unfreezeStaking(1);
        _assertFreezeState(1, 20, 1, false);

        yoloToken.setQuote(100);
        stakingManager.unfreezeStaking(1);
        vm.stopPrank();

        _assertFreezeState(1, 0, 0, false);
    }

    function testRequestUnStakingAppliesEarlyRedeemSlippageAndCreatesQueue() public {
        uint256 stakingValue = 300 ether;

        vm.startPrank(user);
        vm.warp(1_000);
        stakingManager.depositAndStaking(stakingValue);

        uint256 withdrawRequestId = stakingManager.requestUnStaking(1, 100 ether);
        vm.stopPrank();

        assertEq(withdrawRequestId, 1);
        assertEq(stakingManager.withdrawRequestCount(user), 1);
        assertEq(stakingManager.stakingAmount(user), 200 ether);
        assertEq(stakingManager.queueWithdraws(user), 100 ether);

        (uint256 stakingRound_, uint256 requestAmount, uint256 payoutAmount, uint256 slippageAmount, uint256 requestTime, uint256 availableAt, bool claimed) =
            stakingManager.withdrawRequests(user, withdrawRequestId);
        assertEq(stakingRound_, 1);
        assertEq(requestAmount, 100 ether);
        assertEq(payoutAmount, 90 ether);
        assertEq(slippageAmount, 10 ether);
        assertEq(requestTime, 1_000);
        assertEq(availableAt, 1_000 + 3 hours);
        assertFalse(claimed);

        (, , , , uint256 creditLimit, , , , ) = stakingManager.userStakingInfo(user, 1);
        assertEq(creditLimit, (200 ether * 900) / 1000);
    }

    function testRequestUnStakingHasNoSlippageAfterCooldown() public {
        vm.startPrank(user);
        vm.warp(1_000);
        stakingManager.depositAndStaking(300 ether);

        vm.warp(1_000 + 7 days);
        uint256 withdrawRequestId = stakingManager.requestUnStaking(1, 100 ether);
        vm.stopPrank();

        (, , uint256 payoutAmount, uint256 slippageAmount, , uint256 availableAt, ) =
            stakingManager.withdrawRequests(user, withdrawRequestId);
        assertEq(payoutAmount, 100 ether);
        assertEq(slippageAmount, 0);
        assertEq(availableAt, 1_000 + 7 days + 3 hours);
    }

    function testStakingWithdrawTransfersQueuedAmountAfterDelay() public {
        underlyingToken.mint(address(stakingManager), 1_000 ether);

        vm.startPrank(user);
        vm.warp(1_000);
        stakingManager.depositAndStaking(300 ether);
        uint256 withdrawRequestId = stakingManager.requestUnStaking(1, 100 ether);

        vm.expectRevert("StakingManager: withdraw still pending");
        stakingManager.stakingWithdraw(withdrawRequestId);

        vm.warp(1_000 + 3 hours);
        stakingManager.stakingWithdraw(withdrawRequestId);

        vm.expectRevert("StakingManager: withdraw request already claimed");
        stakingManager.stakingWithdraw(withdrawRequestId);
        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(user), 90 ether);
        assertEq(stakingManager.queueWithdraws(user), 0);
        (, , , , , , bool claimed) = stakingManager.withdrawRequests(user, withdrawRequestId);
        assertTrue(claimed);
    }

    function testViewHelpersReturnPendingRequestsAndRedeemableAmount() public {
        underlyingToken.mint(address(stakingManager), 1_000 ether);

        vm.startPrank(user);
        vm.warp(1_000);
        stakingManager.depositAndStaking(300 ether);

        uint256 firstWithdrawRequestId = stakingManager.requestUnStaking(1, 100 ether);
        uint256 secondWithdrawRequestId = stakingManager.requestUnStaking(1, 50 ether);
        vm.warp(1_000 + 3 hours);
        stakingManager.stakingWithdraw(firstWithdrawRequestId);
        vm.stopPrank();

        assertEq(stakingManager.getUnstakeableAmount(user, 1), 150 ether);
        assertEq(stakingManager.getUnstakeableAmount(user, 99), 0);

        IStakingManager.WithdrawRequestView[] memory pendingRequests = stakingManager.getPendingWithdrawRequests(user);
        assertEq(pendingRequests.length, 1);
        assertEq(pendingRequests[0].withdrawRequestId, secondWithdrawRequestId);
        assertEq(pendingRequests[0].stakingRound, 1);
        assertEq(pendingRequests[0].requestAmount, 50 ether);
        assertEq(pendingRequests[0].payoutAmount, 45 ether);
        assertEq(pendingRequests[0].slippageAmount, 5 ether);
        assertEq(pendingRequests[0].availableAt, 1_000 + 3 hours);
        assertFalse(pendingRequests[0].claimed);
    }

    function _assertFreezeState(uint256 stakingRound_, uint256 frozenPercent, uint8 freezeLevel, bool platformTakenOver)
        internal
        view
    {
        (, , , , uint256 creditLimit, , uint256 frozenCreditLimit, uint8 actualFreezeLevel, bool actualPlatformTakenOver) =
            stakingManager.userStakingInfo(user, stakingRound_);
        assertEq(frozenCreditLimit, (creditLimit * frozenPercent) / 100);
        assertEq(actualFreezeLevel, freezeLevel);
        assertEq(actualPlatformTakenOver, platformTakenOver);
    }
}
