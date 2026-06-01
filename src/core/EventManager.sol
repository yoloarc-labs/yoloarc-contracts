// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./EventManagerStorage.sol";
import "../interfaces/IEventManager.sol";
import "../interfaces/IYoloToken.sol";


contract EventManager is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard, EventManagerStorage {
    using SafeERC20 for IERC20;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address initialManager,
        address _usdt,
        IYoloToken _yoloTokenAddress
    ) public initializer {
        __Ownable_init(initialOwner);
        manager = initialManager;
        USDT = _usdt;
        yoloTokenAddress = _yoloTokenAddress;
        nextBetId = 1;
    }

    function createEvent(uint256 eventId, uint256 startTime, uint256 endTime, uint256 settlementFeeRate, address betTokenAddress, uint256 yesOdds, uint256 noOdds) external onlyEventManager whenNotPaused {
        if (events[eventId].eventId != 0) revert EventAlreadyExists(eventId);
        if (startTime >= endTime) revert InvalidEventTime();
        if (settlementFeeRate > 10000) revert InvalidSettlementFeeRate();

        events[eventId] = Event({
            eventId: eventId,
            startTime: startTime,
            endTime: endTime,
            status: EventStatus.CREATED,
            result: EventResult.PENDING,
            betTokenAddress: betTokenAddress,
            totalAmount: 0,
            totalYesAmount: 0,
            totalNoAmount: 0,
            totalYoloAmount: 0,
            yesOdds: yesOdds,
            noOdds: noOdds,
            winAmount: 0,
            lossAmount: 0,
            settlementFeeRate: settlementFeeRate,
            createdAt: block.timestamp,
            settledAt: 0
        });

        eventIds.push(eventId);
        eventIdIndex[eventId] = eventIds.length - 1;

        emit EventCreated(eventId, startTime, endTime, settlementFeeRate, betTokenAddress);
    }

    function betEvent(uint256 eventId, uint256 amount, EventResult selectedResult) external whenNotPaused nonReentrant {
        _betWithToken(eventId, amount, selectedResult, msg.sender);
    }

    function setEventResult(uint256 eventId, EventResult result) external onlyEventManager whenNotPaused {
        Event storage eventInfo = events[eventId];
        if (eventInfo.eventId == 0) revert EventNotFound(eventId);
        if (result != EventResult.YES && result != EventResult.NO && result != EventResult.INVALID) revert InvalidBetResult();

        eventInfo.result = result;
        eventInfo.status = EventStatus.PENDING_RESULT;
        emit EventResultSet(eventId, result);
    }

    function finishEvent(uint256 eventId) external whenNotPaused nonReentrant {
        Event storage eventInfo = events[eventId];
        if (eventInfo.eventId == 0) revert EventNotFound(eventId);
        if (eventInfo.status == EventStatus.SETTLED || eventInfo.status == EventStatus.CANCELLED) revert EventNotSettleable(eventId);
        if (eventInfo.result == EventResult.PENDING) revert EventNotSettleable(eventId);
        if (block.timestamp < eventInfo.endTime) revert EventNotSettleable(eventId);

        uint256 betCount = eventBetIds[eventId].length;
        if (eventInfo.result == EventResult.INVALID) {
            _refundInvalidEvent(eventInfo, eventId, betCount);
            return;
        }

        if (eventInfo.result == EventResult.YES) {
            eventInfo.winAmount  = eventInfo.totalYesAmount;
            eventInfo.lossAmount = eventInfo.totalNoAmount;
        } else {
            eventInfo.winAmount  = eventInfo.totalNoAmount;
            eventInfo.lossAmount = eventInfo.totalYesAmount;
        }

        uint256 totalFee = 0;

        for (uint256 i = 0; i < betCount; i++) {
            uint256 betId = eventBetIds[eventId][i];
            BetRecord storage betRecord = betRecords[betId];
            bool won = betRecord.selectedResult == eventInfo.result;
            uint256 payoutAmount = 0;
            uint256 feeAmount = 0;

            if (won) {
                (payoutAmount, feeAmount) = _settleTokenWin(eventInfo, betRecord);
                totalFee += feeAmount;
            } else {
                _settleTokenLose(betRecord);
            }

            emit BetSettled(
                betId,
                eventId,
                betRecord.bettor,
                won,
                payoutAmount,
                feeAmount
            );
        }

        eventInfo.status = EventStatus.SETTLED;
        eventInfo.settledAt = block.timestamp;
        feeBalances += totalFee;

        emit EventFinished(
            eventId,
            eventInfo.result,
            eventInfo.winAmount,
            eventInfo.lossAmount,
            totalFee
        );
    }

    function getEventBetIds(uint256 eventId) external view returns (uint256[] memory) {
        return eventBetIds[eventId];
    }

    function getUserBetIds(address user) external view returns (uint256[] memory) {
        return userBetIds[user];
    }

    function _betWithToken(uint256 eventId, uint256 amount, EventResult selectedResult, address bettor) internal {
        Event storage eventInfo = _validateBet(eventId, amount, selectedResult);
        if (eventInfo.betTokenAddress == address(0)) revert InvalidBetToken();
        IERC20(eventInfo.betTokenAddress).safeTransferFrom(bettor, address(this), amount);

        // YOLO collateral worth 20% of the bet amount.
        // YOLO has 6 decimals; quote(1e6) returns how much paired token (USDT) 1 YOLO can swap for (raw units).
        // required_YOLO_raw = (amount * 20 / 100) * 1e6 / quote(1e6)
        uint256 price = yoloTokenAddress.quote(1e6);
        uint256 yoloAmount = (amount * 20 * 1e6) / (100 * price);
        if (yoloAmount == 0) revert InvalidYoloCollateral();

        IERC20(address(yoloTokenAddress)).safeTransferFrom(bettor, address(this), yoloAmount);

        uint256 odds = eventInfo.yesOdds;
        if (selectedResult == EventResult.YES) {
            eventInfo.totalYesAmount += amount;
        } else {
            eventInfo.totalNoAmount += amount;
            odds = eventInfo.noOdds;
        }

        _recordBet(eventId, amount, yoloAmount, selectedResult, odds, bettor);
    }

    function _validateBet(uint256 eventId, uint256 amount, EventResult selectedResult) internal view returns (Event storage eventInfo) {
        eventInfo = events[eventId];
        if (eventInfo.eventId == 0) revert EventNotFound(eventId);
        if (amount == 0) revert InvalidBetAmount();
        if (selectedResult != EventResult.YES && selectedResult != EventResult.NO) revert InvalidBetResult();
        if (eventInfo.status != EventStatus.CREATED && eventInfo.status != EventStatus.ACTIVE) revert EventNotBettable(eventId);
        if (block.timestamp < eventInfo.startTime || block.timestamp >= eventInfo.endTime) revert EventNotBettable(eventId);
    }

    function _recordBet(
        uint256 eventId,
        uint256 amount,
        uint256 yoloAmount,
        EventResult selectedResult,
        uint256 odds,
        address bettor
    ) internal {
        uint256 betId = nextBetId++;

        betRecords[betId] = BetRecord({
            betId: betId,
            eventId: eventId,
            bettor: bettor,
            selectedResult: selectedResult,
            odds: odds,
            amount: amount,
            yoloAmount: yoloAmount,
            createdAt: block.timestamp
        });
 
        eventBetIds[eventId].push(betId);
        userBetIds[bettor].push(betId);

        Event storage eventInfo = events[eventId];
        eventInfo.totalAmount += amount;
        eventInfo.totalYoloAmount += yoloAmount;

        if (selectedResult == EventResult.YES) {
            eventYesAmount[eventId] += amount;
        } else {
            eventNoAmount[eventId] += amount;
        }

        uint256 dayIndex = block.timestamp / 1 days;
        emit EventBetPlaced(betId, eventId, bettor, selectedResult, amount, yoloAmount, dayIndex);
    }

    function _settleTokenWin(
        Event storage eventInfo,
        BetRecord storage betRecord
    ) internal returns (uint256 payoutAmount, uint256 feeAmount) {
        uint256 rewardAmount = betRecord.amount * betRecord.odds / 10000;
        feeAmount = (rewardAmount * eventInfo.settlementFeeRate) / 10000;
        payoutAmount = betRecord.amount + rewardAmount - feeAmount;

        IERC20(eventInfo.betTokenAddress).safeTransfer(betRecord.bettor, payoutAmount);
        IERC20(address(yoloTokenAddress)).safeTransfer(betRecord.bettor, betRecord.yoloAmount);
    }

    function _settleTokenLose(BetRecord storage betRecord) internal {
        IERC20(address(yoloTokenAddress)).safeTransfer(betRecord.bettor, betRecord.yoloAmount);
    }

    function _refundInvalidEvent(Event storage eventInfo, uint256 eventId, uint256 betCount) internal {
        for (uint256 i = 0; i < betCount; i++) {
            uint256 betId = eventBetIds[eventId][i];
            BetRecord storage betRecord = betRecords[betId];

            IERC20(eventInfo.betTokenAddress).safeTransfer(betRecord.bettor, betRecord.amount);
            IERC20(address(yoloTokenAddress)).safeTransfer(betRecord.bettor, betRecord.yoloAmount);

            emit BetSettled(
                betId,
                eventId,
                betRecord.bettor,
                false,
                betRecord.amount,
                0
            );
        }

        eventInfo.winAmount = 0;
        eventInfo.lossAmount = 0;
        eventInfo.status = EventStatus.SETTLED;
        eventInfo.settledAt = block.timestamp;

        emit EventFinished(eventId, eventInfo.result, 0, 0, 0);
    }
}
