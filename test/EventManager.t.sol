// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
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
    function testFinishEventDistributesRewardsWithYoloCollateral() public {
        uint256 yesOdds = 18000; // 1.8x
        uint256 noOdds  = 25000; // 2.5x
        uint256 feeRate = 100;   // 1%

        uint256 yesStake = 100 ether;   // 100 USDT each
        uint256 noStake  = 1000 ether;  // 1000 USDT each

        // YOLO collateral per bet (yoloAmount = stake * 0.2 / 0.5 in YOLO units, 6 decimals):
        //   YES (100 USDT)  ->  40 YOLO  (4e7 raw)
        //   NO  (1000 USDT) -> 400 YOLO  (4e8 raw)
        uint256 yesCollateral = 40 * 1e6;
        uint256 noCollateral  = 400 * 1e6;

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
            _bet(yesUsers[i], yesStake, yesCollateral, IEventManager.EventResult.YES);
        }

        address[3] memory noUsers;
        for (uint256 i = 0; i < 3; i++) {
            noUsers[i] = address(uint160(0xB000 + i));
            _bet(noUsers[i], noStake, noCollateral, IEventManager.EventResult.NO);
        }

        // Pre-finish invariants
        uint256 poolUsdt = 7 * yesStake + 3 * noStake; // 700 + 3000 = 3700 USDT
        uint256 poolYolo = 7 * yesCollateral + 3 * noCollateral; // 280 + 1200 = 1480 YOLO (1.48e9 raw)
        assertEq(betToken.balanceOf(address(eventManager)), poolUsdt, "pool usdt before finish");
        assertEq(yoloToken.balanceOf(address(eventManager)), poolYolo, "pool yolo before finish");
        assertEq(eventManager.eventYesAmount(1), 7 * yesStake);
        assertEq(eventManager.eventNoAmount(1), 3 * noStake);

        // Settle YES
        vm.warp(block.timestamp + 2 days);
        eventManager.setEventResult(1, IEventManager.EventResult.YES);
        eventManager.finishEvent(1);

        // ----- Expected per-YES-winner payout -----
        //   reward   = stake * 1.8                          = 180 USDT
        //   feeAmt   = reward * 1% = 180 * 0.01             = 1.8 USDT
        //   payout   = stake + reward - feeAmt = 100+180-1.8= 278.2 USDT
        uint256 expectedPayout = yesStake + (yesStake * yesOdds / 10000) - ((yesStake * yesOdds / 10000) * feeRate / 10000);
        uint256 expectedFeePerWinner = (yesStake * yesOdds / 10000) * feeRate / 10000;
        assertEq(expectedPayout, 278.2 ether, "sanity: payout per yes winner");
        assertEq(expectedFeePerWinner, 1.8 ether, "sanity: fee per yes winner");

        // YES winners: got USDT payout + YOLO collateral back
        for (uint256 i = 0; i < 7; i++) {
            assertEq(betToken.balanceOf(yesUsers[i]), expectedPayout, "yes winner usdt");
            assertEq(yoloToken.balanceOf(yesUsers[i]), yesCollateral, "yes winner yolo back");
        }

        // NO losers: lost USDT, YOLO collateral returned
        for (uint256 i = 0; i < 3; i++) {
            assertEq(betToken.balanceOf(noUsers[i]), 0, "no loser usdt");
            assertEq(yoloToken.balanceOf(noUsers[i]), noCollateral, "no loser yolo back");
        }

        // Contract bookkeeping:
        //   total payouts to winners: 7 * 278.2 = 1947.4 USDT
        //   total fees retained:      7 * 1.8   = 12.6 USDT
        //   YOLO fully returned:      0 left in contract
        //   USDT residual:            pool - payouts = 3700 - 1947.4 = 1752.4 USDT
        //                            (12.6 of that is fee, 1739.8 is leftover from losers)
        uint256 totalPayouts = 7 * expectedPayout;
        uint256 totalFees    = 7 * expectedFeePerWinner;

        assertEq(totalPayouts, 1947.4 ether, "sanity: total payouts");
        assertEq(totalFees,    12.6 ether,   "sanity: total fees");

        assertEq(betToken.balanceOf(address(eventManager)), poolUsdt - totalPayouts, "residual usdt in contract");
        assertEq(yoloToken.balanceOf(address(eventManager)), 0, "all yolo returned");
        assertEq(eventManager.feeBalances(), totalFees, "fee balances tracked");

        // Event state
        (
            uint256 storedEventId,
            ,
            ,
            IEventManager.EventStatus status,
            IEventManager.EventResult result,
            ,
            uint256 totalAmount,
            ,
            uint256 totalYesAmount,
            uint256 totalNoAmount,
            ,
            ,
            uint256 winAmount,
            uint256 lossAmount,
            ,
            ,

        ) = eventManager.events(1);
        assertEq(storedEventId, 1);
        assertEq(uint256(status), uint256(IEventManager.EventStatus.SETTLED));
        assertEq(uint256(result), uint256(IEventManager.EventResult.YES));
        assertEq(totalAmount, poolUsdt);
        assertEq(totalYesAmount, 7 * yesStake);
        assertEq(totalNoAmount, 3 * noStake);
        assertEq(winAmount, 7 * yesStake);
        assertEq(lossAmount, 3 * noStake);
    }

    function _bet(address bettor, uint256 stake, uint256 collateral, IEventManager.EventResult side) internal {
        betToken.mint(bettor, stake);
        yoloToken.mint(bettor, collateral);

        vm.startPrank(bettor);
        betToken.approve(address(eventManager), stake);
        yoloToken.approve(address(eventManager), collateral);
        eventManager.betEvent(1, stake, side);
        vm.stopPrank();
    }
}
