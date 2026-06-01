// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EventManager} from "../src/core/EventManager.sol";
import {IEventManager} from "../src/interfaces/IEventManager.sol";
import {IStakingManager} from "../src/interfaces/IStakingManager.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";

contract MockBetToken is ERC20 {
    constructor() ERC20("Bet Token", "U") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockYoloToken is IYoloToken {
    function burn(address, uint256) external pure {}

    function quote(uint256) external pure returns (uint256) {
        return 1;
    }
}

contract MockStakingManager is IStakingManager {
    mapping(address => mapping(uint256 => uint256)) public credits;

    function useStakingCredit(address user, uint256 stakingRound, uint256 amount) external {
        require(credits[user][stakingRound] >= amount, "MockStakingManager: credit not enough");
        credits[user][stakingRound] -= amount;
    }

    function releaseStakingCredit(address user, uint256 stakingRound, uint256 amount) external {
        credits[user][stakingRound] += amount;
    }

    function addStakingCredit(address user, uint256 stakingRound, uint256 amount) external {
        credits[user][stakingRound] += amount;
    }

    function setCredit(address user, uint256 stakingRound, uint256 amount) external {
        credits[user][stakingRound] = amount;
    }

    function setUnderlyingToken(address) external {}
    function depositAndStaking(uint256) external payable {}
    function requestUnStaking(uint256, uint256) external returns (uint256) { return 0; }
    function stakingWithdraw(uint256) external {}
    function freezeStaking(uint256) external {}
    function unfreezeStaking(uint256) external {}
    function getPendingWithdrawRequests(address) external pure returns (WithdrawRequestView[] memory pendingRequests) { return pendingRequests; }
    function getUnstakeableAmount(address, uint256) external pure returns (uint256) { return 0; }
    function topup(address user, uint256 stakingRound, uint256 amount) external {
        credits[user][stakingRound] += amount;
    }
    function createReward(address, uint256, uint256, uint256, uint8) external {}
    function claimReward() external {}
}

contract EventManagerTest is Test {
    EventManager internal eventManager;
    MockBetToken internal betToken;
    MockYoloToken internal yoloToken;
    MockStakingManager internal stakingManager;

    address internal manager = address(this);
    address internal owner = address(this);
    address internal user = address(0x1234);
    address internal winner = address(0x1111);
    address internal loser = address(0x2222);

    function setUp() public {
        betToken = new MockBetToken();
        yoloToken = new MockYoloToken();
        stakingManager = new MockStakingManager();

        EventManager implementation = new EventManager();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                EventManager.initialize,
                (owner, manager, address(0x1), address(0x2), IYoloToken(address(yoloToken)))
            )
        );
        eventManager = EventManager(payable(address(proxy)));
        eventManager.setStakingManager(address(stakingManager));
    }

    function testBetEventTransfersTokenAndRecordsBet() public {
        eventManager.createEvent(1, block.timestamp, block.timestamp + 1 days, 100, address(betToken));
        betToken.mint(user, 1000 ether);

        vm.startPrank(user);
        betToken.approve(address(eventManager), 250 ether);
        eventManager.betEvent(1, 250 ether, IEventManager.EventResult.YES);
        vm.stopPrank();

        assertEq(betToken.balanceOf(address(eventManager)), 250 ether);
        assertEq(eventManager.nextBetId(), 2);
        assertEq(eventManager.eventYesAmount(1), 250 ether);
        assertEq(eventManager.eventNoAmount(1), 0);
        assertEq(eventManager.getEventBetIds(1).length, 1);
        assertEq(eventManager.getUserBetIds(user).length, 1);

        (
            uint256 betId,
            uint256 eventId,
            address bettor,
            IEventManager.EventResult selectedResult,
            uint256 amount,
            IEventManager.BetPaymentType paymentType,
            uint256 stakingRound,
            uint256 createdAt
        ) = eventManager.betRecords(1);
        assertEq(betId, 1);
        assertEq(eventId, 1);
        assertEq(bettor, user);
        assertEq(uint256(selectedResult), uint256(IEventManager.EventResult.YES));
        assertEq(amount, 250 ether);
        assertEq(uint256(paymentType), uint256(IEventManager.BetPaymentType.TOKEN));
        assertEq(stakingRound, 0);
        assertEq(createdAt, block.timestamp);
    }

    function testBetEventWithStakingConsumesCreditAndRecordsBet() public {
        eventManager.createEvent(2, block.timestamp, block.timestamp + 1 days, 100, address(betToken));
        stakingManager.setCredit(user, 3, 500 ether);

        vm.prank(user);
        eventManager.betEventWithStaking(2, 3, 200 ether, IEventManager.EventResult.NO);

        assertEq(eventManager.nextBetId(), 2);
        assertEq(eventManager.eventYesAmount(2), 0);
        assertEq(eventManager.eventNoAmount(2), 200 ether);
        assertEq(stakingManager.credits(user, 3), 300 ether);
        assertEq(eventManager.getEventBetIds(2).length, 1);

        (
            ,
            uint256 eventId,
            address bettor,
            IEventManager.EventResult selectedResult,
            uint256 amount,
            IEventManager.BetPaymentType paymentType,
            uint256 stakingRound,

        ) = eventManager.betRecords(1);
        assertEq(eventId, 2);
        assertEq(bettor, user);
        assertEq(uint256(selectedResult), uint256(IEventManager.EventResult.NO));
        assertEq(amount, 200 ether);
        assertEq(uint256(paymentType), uint256(IEventManager.BetPaymentType.STAKING_CREDIT));
        assertEq(stakingRound, 3);
    }

    function testFinishEventDistributesRewardsForTokenAndStakingWinners() public {
        uint256 expectedStartTime = block.timestamp;
        uint256 expectedEndTime = expectedStartTime + 1 days;
        eventManager.createEvent(3, expectedStartTime, expectedEndTime, 1000, address(betToken));
        betToken.mint(winner, 1_000 ether);
        betToken.mint(loser, 1_000 ether);
        stakingManager.setCredit(winner, 1, 500 ether);
        stakingManager.setCredit(loser, 1, 500 ether);

        vm.startPrank(winner);
        betToken.approve(address(eventManager), 200 ether);
        eventManager.betEvent(3, 200 ether, IEventManager.EventResult.YES);
        eventManager.betEventWithStaking(3, 1, 100 ether, IEventManager.EventResult.YES);
        vm.stopPrank();

        vm.startPrank(loser);
        betToken.approve(address(eventManager), 300 ether);
        eventManager.betEvent(3, 300 ether, IEventManager.EventResult.NO);
        eventManager.betEventWithStaking(3, 1, 200 ether, IEventManager.EventResult.NO);
        vm.stopPrank();

        (
            uint256 eventIdBefore,
            uint256 storedStartTimeBefore,
            uint256 storedEndTimeBefore,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 createdAtBefore,
            uint256 settledAtBefore
        ) = eventManager.events(3);
        assertEq(eventIdBefore, 3);
        assertEq(storedStartTimeBefore, expectedStartTime, "stored start time");
        assertEq(storedEndTimeBefore, expectedEndTime, "stored end time");
        assertEq(createdAtBefore, expectedStartTime, "created at");
        assertEq(settledAtBefore, 0);

        uint256 settledAt = expectedStartTime + 2 days;
        vm.warp(settledAt);
        eventManager.setEventResult(3, IEventManager.EventResult.YES);
        eventManager.finishEvent(3);

        assertEq(betToken.balanceOf(winner), 1_270 ether);
        assertEq(betToken.balanceOf(address(eventManager)), 30 ether);
        assertEq(stakingManager.credits(winner, 1), 680 ether);
        assertEq(stakingManager.credits(loser, 1), 300 ether);

        (
            uint256 eventId,
            ,
            ,
            IEventManager.EventStatus status,
            IEventManager.EventResult result,
            address betTokenAddress,
            uint256 totalAmount,
            uint256 winAmount,
            uint256 lossAmount,
            uint256 settlementFeeRate,
            ,
            uint256 storedSettledAt
        ) = eventManager.events(3);
        assertEq(eventId, 3);
        assertEq(uint256(status), uint256(IEventManager.EventStatus.SETTLED));
        assertEq(uint256(result), uint256(IEventManager.EventResult.YES));
        assertEq(betTokenAddress, address(betToken));
        assertEq(totalAmount, 800 ether);
        assertEq(winAmount, 300 ether);
        assertEq(lossAmount, 500 ether);
        assertEq(settlementFeeRate, 1000);
        assertEq(storedSettledAt, settledAt, "settled at");
    }
}
