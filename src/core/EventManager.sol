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
        address _underlyingToken,
        address _usdt,
        IYoloToken _yoloTokenAddress
    ) public initializer {
        __Ownable_init(initialOwner);
        manager = initialManager;
        underlyingToken = _underlyingToken;
        USDT = _usdt;
        yoloTokenAddress = _yoloTokenAddress;
        nextBetId = 1;
    }

    function setStakingManager(address _stakingManager) external onlyOwner {
        if (_stakingManager == address(0)) revert ZeroAddress();
        stakingManager = IStakingManager(_stakingManager);
    }


    function createEvent(uint256 eventId, uint256 startTime, uint256 endTime, uint256 settlementFeeRate, address betTokenAddress) external onlyEventManager whenNotPaused {
        if (events[eventId].eventId != 0) revert EventAlreadyExists(eventId);
        if (startTime >= endTime) revert InvalidEventTime();
        if (settlementFeeRate > 10000) revert InvalidSettlementFeeRate();
        if (betTokenAddress == address(0)) revert ZeroAddress();

        events[eventId] = Event({
            eventId: eventId,
            startTime: startTime,
            endTime: endTime,
            status: EventStatus.CREATED,
            result: EventResult.PENDING,
            betTokenAddress: betTokenAddress,
            totalAmount: 0,
            winAmount: 0,
            lossAmount: 0,
            settlementFeeRate: settlementFeeRate,
            createdAt: block.timestamp,
            settledAt: 0
        });

        eventIds.push(eventId);
        eventIdIndex[eventId] = eventIds.length - 1;

        emit EventCreated(eventId, startTime, endTime, settlementFeeRate);
    }

    function betEvent(uint256 eventId, uint256 amount, EventResult selectedResult) external whenNotPaused nonReentrant {
        _betWithToken(eventId, amount, selectedResult, msg.sender);
    }

    function betEventWithStaking(uint256 eventId, uint256 stakingRound, uint256 amount, EventResult selectedResult) external whenNotPaused nonReentrant {
        _betWithStaking(eventId, stakingRound, amount, selectedResult, msg.sender);
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

        uint256 tokenWinPool;
        uint256 tokenLossPool;
        uint256 stakingWinPool;
        uint256 stakingLossPool;

        if (eventInfo.result == EventResult.YES) {
            tokenWinPool = tokenYesAmount[eventId];
            tokenLossPool = tokenNoAmount[eventId];
            stakingWinPool = stakingYesAmount[eventId];
            stakingLossPool = stakingNoAmount[eventId];
        } else {
            tokenWinPool = tokenNoAmount[eventId];
            tokenLossPool = tokenYesAmount[eventId];
            stakingWinPool = stakingNoAmount[eventId];
            stakingLossPool = stakingYesAmount[eventId];
        }

        uint256 tokenSettlementFee = (tokenLossPool * eventInfo.settlementFeeRate) / 10000;
        uint256 stakingCreditSettlementFee = (stakingLossPool * eventInfo.settlementFeeRate) / 10000;

        for (uint256 i = 0; i < betCount; i++) {
            uint256 betId = eventBetIds[eventId][i];
            BetRecord storage betRecord = betRecords[betId];
            bool won = betRecord.selectedResult == eventInfo.result;
            uint256 payoutAmount = 0;

            if (won) {
                if (betRecord.paymentType == BetPaymentType.TOKEN) {
                    payoutAmount = _settleTokenWin(eventInfo, betRecord, tokenWinPool, tokenLossPool, tokenSettlementFee);
                } else {
                    payoutAmount = _settleStakingWin(betRecord, stakingWinPool, stakingLossPool, stakingCreditSettlementFee);
                }
            }

            emit BetSettled(
                betId,
                eventId,
                betRecord.bettor,
                won,
                payoutAmount,
                betRecord.paymentType,
                betRecord.stakingRound
            );
        }

        eventInfo.winAmount = tokenWinPool + stakingWinPool;
        eventInfo.lossAmount = tokenLossPool + stakingLossPool;
        eventInfo.status = EventStatus.SETTLED;
        eventInfo.settledAt = block.timestamp;
        feeBalances += tokenSettlementFee;

        emit EventFinished(
            eventId,
            eventInfo.result,
            eventInfo.winAmount,
            eventInfo.lossAmount,
            tokenSettlementFee,
            stakingCreditSettlementFee
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
        _recordBet(eventId, amount, selectedResult, bettor, BetPaymentType.TOKEN, 0);
    }

    function _betWithStaking(uint256 eventId, uint256 stakingRound, uint256 amount, EventResult selectedResult, address bettor) internal {
        _validateBet(eventId, amount, selectedResult);
        if (address(stakingManager) == address(0)) revert InvalidBetToken();

        stakingManager.useStakingCredit(bettor, stakingRound, amount);
        _recordBet(eventId, amount, selectedResult, bettor, BetPaymentType.STAKING_CREDIT, stakingRound);
    }

    function _validateBet(uint256 eventId, uint256 amount, EventResult selectedResult) internal view returns (Event storage eventInfo) {
        eventInfo = events[eventId];
        if (eventInfo.eventId == 0) revert EventNotFound(eventId);
        if (amount == 0) revert InvalidBetAmount();
        if (selectedResult != EventResult.YES && selectedResult != EventResult.NO) revert InvalidBetResult();
        if (eventInfo.status != EventStatus.CREATED && eventInfo.status != EventStatus.ACTIVE) revert EventNotBettable(eventId);
        if (block.timestamp < eventInfo.startTime || block.timestamp >= eventInfo.endTime) revert EventNotBettable(eventId);
    }

    function _recordBet(uint256 eventId, uint256 amount, EventResult selectedResult, address bettor, BetPaymentType paymentType, uint256 stakingRound) internal {
        uint256 betId = nextBetId++;

        betRecords[betId] = BetRecord({
            betId: betId,
            eventId: eventId,
            bettor: bettor,
            selectedResult: selectedResult,
            amount: amount,
            paymentType: paymentType,
            stakingRound: stakingRound,
            createdAt: block.timestamp
        });

        eventBetIds[eventId].push(betId);
        userBetIds[bettor].push(betId);

        Event storage eventInfo = events[eventId];
        eventInfo.totalAmount += amount;
        if (selectedResult == EventResult.YES) {
            eventYesAmount[eventId] += amount;
            if (paymentType == BetPaymentType.TOKEN) {
                tokenYesAmount[eventId] += amount;
            } else {
                stakingYesAmount[eventId] += amount;
            }
        } else {
            eventNoAmount[eventId] += amount;
            if (paymentType == BetPaymentType.TOKEN) {
                tokenNoAmount[eventId] += amount;
            } else {
                stakingNoAmount[eventId] += amount;
            }
        }

        emit EventBetPlaced(betId, eventId, bettor, selectedResult, amount, paymentType, stakingRound);
    }

    function _settleTokenWin(
        Event storage eventInfo,
        BetRecord storage betRecord,
        uint256 winPool,
        uint256 lossPool,
        uint256 settlementFee
    ) internal returns (uint256 payoutAmount) {
        uint256 rewardAmount = 0;
        if (winPool > 0 && lossPool > settlementFee) {
            rewardAmount = (betRecord.amount * (lossPool - settlementFee)) / winPool;
        }
        payoutAmount = betRecord.amount + rewardAmount;
        IERC20(eventInfo.betTokenAddress).safeTransfer(betRecord.bettor, payoutAmount);
    }

    function _settleStakingWin(
        BetRecord storage betRecord,
        uint256 winPool,
        uint256 lossPool,
        uint256 settlementFee
    ) internal returns (uint256 payoutAmount) {
        uint256 rewardAmount = 0;
        if (winPool > 0 && lossPool > settlementFee) {
            rewardAmount = (betRecord.amount * (lossPool - settlementFee)) / winPool;
        }
        payoutAmount = betRecord.amount + rewardAmount;
        stakingManager.addStakingCredit(betRecord.bettor, betRecord.stakingRound, payoutAmount);
    }

    function _refundInvalidEvent(Event storage eventInfo, uint256 eventId, uint256 betCount) internal {
        for (uint256 i = 0; i < betCount; i++) {
            uint256 betId = eventBetIds[eventId][i];
            BetRecord storage betRecord = betRecords[betId];

            if (betRecord.paymentType == BetPaymentType.TOKEN) {
                IERC20(eventInfo.betTokenAddress).safeTransfer(betRecord.bettor, betRecord.amount);
            } else {
                stakingManager.addStakingCredit(betRecord.bettor, betRecord.stakingRound, betRecord.amount);
            }

            emit BetSettled(
                betId,
                eventId,
                betRecord.bettor,
                false,
                betRecord.amount,
                betRecord.paymentType,
                betRecord.stakingRound
            );
        }

        eventInfo.winAmount = 0;
        eventInfo.lossAmount = 0;
        eventInfo.status = EventStatus.SETTLED;
        eventInfo.settledAt = block.timestamp;

        emit EventFinished(eventId, eventInfo.result, 0, 0, 0, 0);
    }

}
