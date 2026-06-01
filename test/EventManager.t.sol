// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EventManager} from "../src/core/EventManager.sol";
import {IEventManager} from "../src/interfaces/IEventManager.sol";
import {IYoloToken} from "../src/interfaces/IYoloToken.sol";

contract MockBetToken is ERC20 {
    constructor() ERC20("Bet Token", "U") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock YOLO: ERC20-compatible (6 decimals) + IYoloToken hooks.
/// quote(amount) reports how much USDT (18 decimals) you get for `amount` raw YOLO.
/// Hard-coded price: 1 YOLO = 0.5 USDT.
contract MockYoloToken is ERC20, IYoloToken {
    constructor() ERC20("Yolo", "YOLO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address user, uint256 amount) external override {
        _burn(user, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// 1 YOLO (1e6) -> 0.5 USDT-18 (5e17)
    function quote(uint256 amount) external pure returns (uint256) {
        return (amount * 5e17) / 1e6;
    }
}

contract EventManagerTest is Test {
    EventManager internal eventManager;
    MockBetToken internal betToken;
    MockYoloToken internal yoloToken;

    address internal manager = address(this);
    address internal owner = address(this);
    address internal user = address(0x1234);

    function setUp() public {
        betToken = new MockBetToken();
        yoloToken = new MockYoloToken();

        EventManager implementation = new EventManager();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                EventManager.initialize,
                (owner, manager, address(0x1), IYoloToken(address(yoloToken)))
            )
        );
        eventManager = EventManager(payable(address(proxy)));
    }

    function testBetEventTransfersTokenAndYoloCollateral() public {
        eventManager.createEvent(1, block.timestamp, block.timestamp + 1 days, 100, address(betToken), 18000, 25000);

        // bet 250 USDT-18  =>  yolo collateral = 250 * 0.2 / 0.5 = 100 YOLO (1e8 raw)
        betToken.mint(user, 1000 ether);
        yoloToken.mint(user, 100 * 1e6);

        vm.startPrank(user);
        betToken.approve(address(eventManager), 250 ether);
        yoloToken.approve(address(eventManager), 100 * 1e6);
        eventManager.betEvent(1, 250 ether, IEventManager.EventResult.YES);
        vm.stopPrank();

        assertEq(betToken.balanceOf(address(eventManager)), 250 ether, "usdt locked in contract");
        assertEq(yoloToken.balanceOf(address(eventManager)), 100 * 1e6, "yolo collateral locked");
        assertEq(eventManager.nextBetId(), 2);
        assertEq(eventManager.eventYesAmount(1), 250 ether);
        (, , , , , , , uint256 totalYoloAmount, , , , , , , , , ) = eventManager.events(1);
        (, , , , , , uint256 betYoloAmount, ) = eventManager.betRecords(1);
        assertEq(totalYoloAmount, 100 * 1e6, "event yolo amount");
        assertEq(betYoloAmount, 100 * 1e6, "bet yolo amount");
        assertEq(eventManager.eventNoAmount(1), 0);
        assertEq(eventManager.getEventBetIds(1).length, 1);
        assertEq(eventManager.getUserBetIds(user).length, 1);
    }

    /// 7 YES bettors (stake 100 USDT each) vs 3 NO bettors (stake 1000 USDT each).
    /// yesOdds=1.8 (18000), noOdds=2.5 (25000), settlementFeeRate=0.01 (100 bps).
    /// Result: YES.
    /// After settle, YOLO is NOT returned: it enters 10-day vesting per user.
    function testFinishEventDistributesRewardsAndVestsYolo() public {
        uint256 yesOdds = 18000; // 1.8x
        uint256 noOdds  = 25000; // 2.5x
        uint256 feeRate = 100;   // 1%

        uint256 yesStake = 100 ether;
        uint256 noStake  = 1000 ether;
        uint256 yesCollateral = 40 * 1e6;   // 40 YOLO
        uint256 noCollateral  = 400 * 1e6;  // 400 YOLO

        eventManager.createEvent(
            1,
            block.timestamp,
            block.timestamp + 1 days,
            feeRate,
            address(betToken),
            yesOdds,
            noOdds
        );

        address[7] memory yesUsers;
        for (uint256 i = 0; i < 7; i++) {
            yesUsers[i] = address(uint160(0xA000 + i));
            _bet(1, yesUsers[i], yesStake, yesCollateral, IEventManager.EventResult.YES);
        }

        address[3] memory noUsers;
        for (uint256 i = 0; i < 3; i++) {
            noUsers[i] = address(uint160(0xB000 + i));
            _bet(1, noUsers[i], noStake, noCollateral, IEventManager.EventResult.NO);
        }

        uint256 poolUsdt = 7 * yesStake + 3 * noStake;       // 3700
        uint256 poolYolo = 7 * yesCollateral + 3 * noCollateral; // 1480 YOLO (1.48e9 raw)
        assertEq(betToken.balanceOf(address(eventManager)), poolUsdt, "pool usdt before finish");
        assertEq(yoloToken.balanceOf(address(eventManager)), poolYolo, "pool yolo before finish");

        vm.warp(block.timestamp + 2 days);
        eventManager.setEventResult(1, IEventManager.EventResult.YES);
        eventManager.finishEvent(1);

        // Expected per YES winner: reward=180, fee=1.8, payout=278.2
        uint256 reward = yesStake * yesOdds / 10000;
        uint256 feePer = reward * feeRate / 10000;
        uint256 payoutPer = yesStake + reward - feePer;
        assertEq(payoutPer, 278.2 ether, "sanity payout");
        assertEq(feePer, 1.8 ether, "sanity fee");

        // YES winners: got USDT payout, YOLO is now in vesting (wallet still 0)
        for (uint256 i = 0; i < 7; i++) {
            assertEq(betToken.balanceOf(yesUsers[i]), payoutPer, "yes winner usdt");
            assertEq(yoloToken.balanceOf(yesUsers[i]), 0, "yes winner yolo wallet 0");
            assertEq(eventManager.getActiveYoloVesting(yesUsers[i]), yesCollateral, "yes vesting active");
            assertEq(eventManager.getClaimableYolo(yesUsers[i]), 0, "no claim on settle day");
        }

        // NO losers: lost USDT, YOLO in vesting
        for (uint256 i = 0; i < 3; i++) {
            assertEq(betToken.balanceOf(noUsers[i]), 0, "no loser usdt");
            assertEq(yoloToken.balanceOf(noUsers[i]), 0, "no loser yolo wallet 0");
            assertEq(eventManager.getActiveYoloVesting(noUsers[i]), noCollateral, "no vesting active");
        }

        // Contract still holds ALL YOLO (vesting), USDT residual = pool - winner payouts
        uint256 totalPayouts = 7 * payoutPer;
        uint256 totalFees    = 7 * feePer;
        assertEq(betToken.balanceOf(address(eventManager)), poolUsdt - totalPayouts, "usdt residual");
        assertEq(yoloToken.balanceOf(address(eventManager)), poolYolo, "yolo fully retained (vesting)");
        assertEq(eventManager.feeBalances(), totalFees, "fee balances tracked");
    }

    /// 用户场景：Day 10 结算 400 YOLO → Day 11 提走 40 → 同日再下 800 抵押的新单（复用 360 + 钱包 440）
    /// Cliff 释放下的 reuse 场景：
    ///   Day 10 结算 400 YOLO -> cliff 落在 day 20
    ///   Day 11 想 claim 但 cliff 未到 -> 0
    ///   Day 11 新下注需 800 YOLO -> 复用 400 (含未到期) + 钱包补 400
    ///   后续 cliff 到达，老 vesting 已全部消费，无可领
    function testYoloVestingReuseBeforeCliff() public {
        // Event 1: NO bettor pledges 400 YOLO; loses; YOLO vests
        eventManager.createEvent(1, block.timestamp, block.timestamp + 1 days, 100, address(betToken), 18000, 25000);

        address userA = address(0xA1A1);
        uint256 stake1 = 1000 ether;
        uint256 col1   = 400 * 1e6;
        _bet(1, userA, stake1, col1, IEventManager.EventResult.NO);

        // 跳到 day 10 结算
        uint256 day10 = 10 * 1 days;
        vm.warp(day10);
        eventManager.setEventResult(1, IEventManager.EventResult.YES);
        eventManager.finishEvent(1);

        assertEq(eventManager.getActiveYoloVesting(userA), col1, "active vesting = 400 YOLO");
        assertEq(eventManager.getClaimableYolo(userA), 0, "no claim on settle day");

        // Day 11: cliff 在 day 20，未到 -> 0 可领；claim 静默
        vm.warp(11 * 1 days);
        assertEq(eventManager.getClaimableYolo(userA), 0, "cliff not hit");
        vm.prank(userA);
        eventManager.claimYolo();
        assertEq(yoloToken.balanceOf(userA), 0, "claim no-op");
        assertEq(eventManager.getActiveYoloVesting(userA), col1, "vesting unchanged");

        // 新事件：押 2000U -> 需 800 YOLO 抵押。复用 400 + 钱包 400。
        _createSimpleEvent(2);

        uint256 stake2 = 2000 ether;
        uint256 col2   = 800 * 1e6;

        betToken.mint(userA, stake2);
        yoloToken.mint(userA, 400 * 1e6); // 仅给需要从钱包出的部分

        uint256 contractYoloBefore = yoloToken.balanceOf(address(eventManager));
        uint256 userYoloBefore     = yoloToken.balanceOf(userA);

        vm.startPrank(userA);
        betToken.approve(address(eventManager), stake2);
        yoloToken.approve(address(eventManager), 400 * 1e6);
        eventManager.betEvent(2, stake2, IEventManager.EventResult.YES);
        vm.stopPrank();

        assertEq(eventManager.getActiveYoloVesting(userA), 0, "vesting fully consumed");
        assertEq(yoloToken.balanceOf(userA), userYoloBefore - 400 * 1e6, "wallet -= 400");
        assertEq(yoloToken.balanceOf(address(eventManager)), contractYoloBefore + 400 * 1e6, "contract += 400");
    
        IEventManager.YoloVesting[] memory list = eventManager.getUserVestings(userA);
        assertEq(list.length, 0, "no active vesting after full consume");
        (, , , , , , uint256 bet2Yolo, ) = eventManager.betRecords(2);
        assertEq(bet2Yolo, col2, "bet2 collateral = 800 YOLO");

        //检查vestingHead == tail 
        assertEq(eventManager.userVestingHead(userA), eventManager.userVestingTail(userA), "vestingHead == tail");
        
        // Cliff 到达后：老 tranche 早已被 reuse 全部消费，无可领
        vm.warp(20 * 1 days);
        assertEq(eventManager.getClaimableYolo(userA), 0, "old tranche fully drained, nothing to claim");
    }

    /// Cliff 释放：day [0, 10) 都是 0；day 10 一次性 100%；之后保持。
    function testYoloCliffVestingAtDay10() public {
        eventManager.createEvent(1, block.timestamp, block.timestamp + 1 days, 100, address(betToken), 18000, 25000);
        address u = address(0xCAFE);
        uint256 col = 400 * 1e6;
        _bet(1, u, 1000 ether, col, IEventManager.EventResult.NO);

        uint256 dStart = 100 * 1 days;
        vm.warp(dStart);
        eventManager.setEventResult(1, IEventManager.EventResult.YES);
        eventManager.finishEvent(1);

        assertEq(eventManager.getClaimableYolo(u), 0, "day 0 -> 0");
        for (uint256 k = 1; k < 10; k++) {
            vm.warp(dStart + k * 1 days);
            assertEq(eventManager.getClaimableYolo(u), 0, "before cliff -> 0");
        }
        vm.warp(dStart + 10 * 1 days);
        assertEq(eventManager.getClaimableYolo(u), col, "cliff hit -> 100%");
        vm.warp(dStart + 30 * 1 days);
        assertEq(eventManager.getClaimableYolo(u), col, "still 100% past cliff");

        // 实际 claim
        vm.prank(u);
        eventManager.claimYolo();
        assertEq(yoloToken.balanceOf(u), col, "claimed full amount");
        assertEq(eventManager.getActiveYoloVesting(u), 0, "vesting cleared");
    }

    /// Multiple tranches drained FIFO on a single new bet.
    function testYoloMultiTrancheFifoConsume() public {
        eventManager.createEvent(1, block.timestamp, block.timestamp + 1 days, 100, address(betToken), 18000, 25000);

        address u = address(0xDEAD);
        // Two bets that will both lose, each creating a vesting tranche.
        _bet(1, u, 500 ether, 200 * 1e6, IEventManager.EventResult.NO); // tranche A: 200 YOLO
        _bet(1, u, 750 ether, 300 * 1e6, IEventManager.EventResult.NO); // tranche B: 300 YOLO

        vm.warp(block.timestamp + 2 days);
        eventManager.setEventResult(1, IEventManager.EventResult.YES);
        eventManager.finishEvent(1);

        assertEq(eventManager.getActiveYoloVesting(u), 500 * 1e6, "two tranches active");

        // New event: bet needing 250 YOLO collateral.
        // 250 USDT * 0.2 / 0.5 = 100 YOLO? No -> we want 250 YOLO needed: stake = 250 * 5/2 *... Easier:
        // pick stake such that yoloAmount = stake * 0.2 / 0.5 / 1e12 (units) = needed.
        // Use stake = 625 USDT -> yoloAmount = 625 * 0.2 / 0.5 = 250 YOLO ✓
        _createSimpleEvent(2);
        uint256 stake2 = 625 ether;

        betToken.mint(u, stake2);
        // no wallet YOLO needed: 500 vesting > 250 needed; nothing to top up.
        uint256 walletYoloBefore = yoloToken.balanceOf(u);

        vm.startPrank(u);
        betToken.approve(address(eventManager), stake2);
        eventManager.betEvent(2, stake2, IEventManager.EventResult.YES);
        vm.stopPrank();

        assertEq(yoloToken.balanceOf(u), walletYoloBefore, "no wallet movement");
        assertEq(eventManager.getActiveYoloVesting(u), 500 * 1e6 - 250 * 1e6, "250 reused");

        // Verify FIFO: tranche A should be fully drained, B partially.
        // After A (200) drained + 50 from B, A.withdrawn=200, B.withdrawn=50.
        // A is exhausted; _compactHead should have advanced head past A.
        IEventManager.YoloVesting[] memory list = eventManager.getUserVestings(u);
        assertEq(list.length, 1, "only B remains active");
        assertEq(list[0].totalAmount, 300 * 1e6, "remaining tranche is B");
        assertEq(list[0].withdrawn, 50 * 1e6, "B drained by 50");
    }

    /// Invalid events refund USDT + YOLO immediately, bypassing vesting.
    function testInvalidEventRefundsImmediately() public {
        eventManager.createEvent(1, block.timestamp, block.timestamp + 1 days, 100, address(betToken), 18000, 25000);

        address u = address(0xFEED);
        uint256 stake = 250 ether;
        uint256 col   = 100 * 1e6;
        _bet(1, u, stake, col, IEventManager.EventResult.YES);

        vm.warp(block.timestamp + 2 days);
        eventManager.setEventResult(1, IEventManager.EventResult.INVALID);
        eventManager.finishEvent(1);

        assertEq(betToken.balanceOf(u), stake, "usdt refunded");
        assertEq(yoloToken.balanceOf(u), col, "yolo refunded immediately");
        assertEq(eventManager.getActiveYoloVesting(u), 0, "no vesting for invalid");
    }

    function testClaimYoloIsSilentWhenNothing() public {
        vm.prank(user);
        eventManager.claimYolo();
        assertEq(yoloToken.balanceOf(user), 0);
    }

    // -------- addVesting --------

    /// 单次结算后 addVesting 应：
    ///   - 把 betRecord.yoloAmount 写入新的 YoloVesting
    ///   - vestingId = 当前 userVestingTail（首次为 0）
    ///   - startDay = block.timestamp / 1 days
    ///   - 发出 YoloVestingStarted 事件
    function testAddVestingFromSettledBetStoresFieldsAndEmits() public {
        _createSimpleEvent(1);

        address u = address(0xADD1);
        uint256 stake = 1000 ether;
        uint256 col = 400 * 1e6; // 1000U * 0.2 / 0.5 = 400 YOLO
        _bet(1, u, stake, col, IEventManager.EventResult.NO);

        // 推进到结算日
        vm.warp(block.timestamp + 3 days);
        uint256 expectedStartDay = block.timestamp / 1 days;

        eventManager.setEventResult(1, IEventManager.EventResult.YES);

        // finishEvent 内部会 _addYoloVesting(u, eventId=1, vestingId=0, amount=col, startDay=expectedStartDay)
        vm.expectEmit(true, true, true, true);
        emit IEventManager.YoloVestingStarted(u, 1, 0, col, expectedStartDay);
        eventManager.finishEvent(1);

        assertEq(eventManager.userVestingHead(u), 0, "head still at 0");
        assertEq(eventManager.userVestingTail(u), 1, "tail advanced to 1");

        IEventManager.YoloVesting memory v = eventManager.getYoloVesting(u, 0);
        assertEq(v.totalAmount, col, "totalAmount");
        assertEq(v.withdrawn, 0, "withdrawn = 0 on creation");
        assertEq(v.startDay, expectedStartDay, "startDay = settle day");

        // 视图函数和聚合一致
        assertEq(eventManager.getActiveYoloVesting(u), col, "active vesting matches");
        IEventManager.YoloVesting[] memory list = eventManager.getUserVestings(u);
        assertEq(list.length, 1);
        assertEq(list[0].totalAmount, col);
    }

    /// 同一用户多笔下注（多笔结算）会在队列尾部依次追加 vestingId = 0,1,2,...
    function testAddVestingMultipleSettlesAppendInOrder() public {
        _createSimpleEvent(1);

        address u = address(0xADD2);
        _bet(1, u, 500 ether, 200 * 1e6, IEventManager.EventResult.NO);
        _bet(1, u, 750 ether, 300 * 1e6, IEventManager.EventResult.NO);
        _bet(1, u, 250 ether, 100 * 1e6, IEventManager.EventResult.NO);

        vm.warp(block.timestamp + 2 days);
        eventManager.setEventResult(1, IEventManager.EventResult.YES);
        eventManager.finishEvent(1);

        assertEq(eventManager.userVestingHead(u), 0, "head = 0");
        assertEq(eventManager.userVestingTail(u), 3, "tail = 3 after 3 settles");

        assertEq(eventManager.getYoloVesting(u, 0).totalAmount, 200 * 1e6);
        assertEq(eventManager.getYoloVesting(u, 1).totalAmount, 300 * 1e6);
        assertEq(eventManager.getYoloVesting(u, 2).totalAmount, 100 * 1e6);
        assertEq(eventManager.getActiveYoloVesting(u), 600 * 1e6, "sum across tranches");
    }

    // -------- reuseVesting --------

    /// 部分复用：needed < vesting[0] 余额；只扣队首，钱包不动，head/tail 不变，emit YoloReused。
    function testReuseVestingPartialFromSingleTranche() public {
        _createSimpleEvent(1);

        address u = address(0xBEEF);
        _bet(1, u, 1000 ether, 400 * 1e6, IEventManager.EventResult.NO);

        vm.warp(block.timestamp + 2 days);
        eventManager.setEventResult(1, IEventManager.EventResult.YES);
        eventManager.finishEvent(1);

        assertEq(eventManager.getActiveYoloVesting(u), 400 * 1e6, "pre-reuse vesting");

        // 新事件：押 625U -> 需要 250 YOLO（400 vesting 完全够）
        _createSimpleEvent(2);
        uint256 stake2 = 625 ether;

        betToken.mint(u, stake2);
        uint256 walletYoloBefore = yoloToken.balanceOf(u);

        vm.startPrank(u);
        betToken.approve(address(eventManager), stake2);
        vm.expectEmit(true, true, false, true);
        emit IEventManager.YoloReused(u, 2, 250 * 1e6);
        eventManager.betEvent(2, stake2, IEventManager.EventResult.YES);
        vm.stopPrank();

        assertEq(yoloToken.balanceOf(u), walletYoloBefore, "wallet untouched");
        assertEq(eventManager.getActiveYoloVesting(u), 400 * 1e6 - 250 * 1e6, "150 left");

        IEventManager.YoloVesting memory v0 = eventManager.getYoloVesting(u, 0);
        assertEq(v0.totalAmount, 400 * 1e6, "tranche total unchanged");
        assertEq(v0.withdrawn, 250 * 1e6, "tranche withdrawn += 250");

        // 队首未空，_compactHead 不会推进 head
        assertEq(eventManager.userVestingHead(u), 0, "head still 0");
        assertEq(eventManager.userVestingTail(u), 1, "tail still 1");
    }

    /// 复用不足时从钱包补：reused = 全部 vesting，钱包补差额；vesting 队列被 _compactHead 完全清空。
    function testReuseVestingFallsBackToWalletWhenInsufficient() public {
        _createSimpleEvent(1);

        address u = address(0xBEE2);
        _bet(1, u, 500 ether, 200 * 1e6, IEventManager.EventResult.NO);

        vm.warp(block.timestamp + 2 days);
        eventManager.setEventResult(1, IEventManager.EventResult.YES);
        eventManager.finishEvent(1);

        // 新事件：需要 400 YOLO（vesting 只有 200，钱包要补 200）
        _createSimpleEvent(2);
        uint256 stake2 = 1000 ether;
        uint256 walletTopUp = 200 * 1e6;

        betToken.mint(u, stake2);
        yoloToken.mint(u, walletTopUp);

        uint256 walletYoloBefore = yoloToken.balanceOf(u);

        vm.startPrank(u);
        betToken.approve(address(eventManager), stake2);
        yoloToken.approve(address(eventManager), walletTopUp);
        vm.expectEmit(true, true, false, true);
        emit IEventManager.YoloReused(u, 2, 200 * 1e6);
        eventManager.betEvent(2, stake2, IEventManager.EventResult.YES);
        vm.stopPrank();

        assertEq(yoloToken.balanceOf(u), walletYoloBefore - walletTopUp, "wallet -= 200");
        assertEq(eventManager.getActiveYoloVesting(u), 0, "vesting drained");

        // _compactHead 应推进 head 到 tail（队列空），getUserVestings 返回空
        assertEq(eventManager.userVestingHead(u), 1, "head advanced past exhausted");
        assertEq(eventManager.userVestingTail(u), 1, "tail unchanged");

        IEventManager.YoloVesting[] memory list = eventManager.getUserVestings(u);
        assertEq(list.length, 0, "no active vesting after full consume");
    }

    /// 没有 vesting 时下注：reused = 0，不 emit YoloReused，全额从钱包扣。
    function testReuseVestingNoneAvailable() public {
        _createSimpleEvent(1);

        address u = address(0xBEE3);
        uint256 stake = 1000 ether;
        uint256 col = 400 * 1e6;

        betToken.mint(u, stake);
        yoloToken.mint(u, col);
        uint256 walletYoloBefore = yoloToken.balanceOf(u);

        // 不应该有 YoloReused（reused=0）。用 recordLogs 来确认。
        vm.recordLogs();

        vm.startPrank(u);
        betToken.approve(address(eventManager), stake);
        yoloToken.approve(address(eventManager), col);
        eventManager.betEvent(1, stake, IEventManager.EventResult.NO);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 reusedSig = keccak256("YoloReused(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != reusedSig, "must not emit YoloReused");
        }

        assertEq(yoloToken.balanceOf(u), walletYoloBefore - col, "wallet -= full collateral");
        assertEq(eventManager.userVestingTail(u), 0, "no vesting created yet");
    }

    function _createSimpleEvent(uint256 eventId) internal {
        uint256 nowT = block.timestamp;
        eventManager.createEvent(eventId, nowT, nowT + 86400, 100, address(betToken), 18000, 25000);
    }

    function _bet(uint256 eventId, address bettor, uint256 stake, uint256 collateral, IEventManager.EventResult side) internal {
        betToken.mint(bettor, stake);
        // Mint exactly the wallet top-up needed.
        uint256 active = eventManager.getActiveYoloVesting(bettor);
        uint256 walletNeed = collateral > active ? collateral - active : 0;
        if (walletNeed > 0) yoloToken.mint(bettor, walletNeed);

        vm.startPrank(bettor);
        betToken.approve(address(eventManager), stake);
        if (walletNeed > 0) yoloToken.approve(address(eventManager), walletNeed);
        eventManager.betEvent(eventId, stake, side);
        vm.stopPrank();
    }
}
