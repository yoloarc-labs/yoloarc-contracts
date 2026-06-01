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

    function setEventOdds(uint256 eventId, uint256 yesOdds, uint256 noOdds) external onlyOwner whenNotPaused {
        Event storage eventInfo = events[eventId];
        if (eventInfo.eventId == 0) revert EventNotFound(eventId);
        if (eventInfo.status == EventStatus.SETTLED || eventInfo.status == EventStatus.CANCELLED) revert EventNotSettleable(eventId);
        if (eventInfo.result != EventResult.PENDING) revert EventNotSettleable(eventId);

        eventInfo.yesOdds = yesOdds;
        eventInfo.noOdds = noOdds;
        emit EventOddsUpdated(eventId, yesOdds, noOdds);
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

        // Prefer the user's still-locked vesting (un-claimed YOLO from past settled bets),
        // then top up the shortfall from wallet.
        uint256 reused = _consumeVesting(bettor, yoloAmount);
        uint256 fromWallet = yoloAmount - reused;
        if (fromWallet > 0) {
            IERC20(address(yoloTokenAddress)).safeTransferFrom(bettor, address(this), fromWallet);
        }
        if (reused > 0) emit YoloReused(bettor, eventId, reused);

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
        _addYoloVesting(betRecord.bettor, betRecord.eventId, betRecord.yoloAmount);
    }

    function _settleTokenLose(BetRecord storage betRecord) internal {
        _addYoloVesting(betRecord.bettor, betRecord.eventId, betRecord.yoloAmount);
    }

    // Invalid event: 平台原因导致，直接原路退还 USDT + YOLO，不走 vesting。
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

    // ============== YOLO vesting ==============

    function claimYolo() external nonReentrant whenNotPaused {
        uint256 today = block.timestamp / 1 days;
        uint256 head = userVestingHead[msg.sender];
        uint256 tail = userVestingTail[msg.sender];

        uint256 total;
        for (uint256 i = head; i < tail; i++) {
            YoloVesting storage v = _userVestings[msg.sender][i];
            if (v.totalAmount == 0) continue;
            uint256 vested = _vestedAmount(v.totalAmount, v.startDay, today);
            if (vested > v.withdrawn) {
                uint256 claimable = vested - v.withdrawn;
                v.withdrawn += claimable;
                total += claimable;
            }
        }

        _compactHead(msg.sender);

        if (total > 0) {
            IERC20(address(yoloTokenAddress)).safeTransfer(msg.sender, total);
            emit YoloClaimed(msg.sender, total);
        }
        // 0 可领时静默返回，不 revert
    }

    function getClaimableYolo(address user) external view returns (uint256 total) {
        uint256 today = block.timestamp / 1 days;
        uint256 head = userVestingHead[user];
        uint256 tail = userVestingTail[user];
        for (uint256 i = head; i < tail; i++) {
            YoloVesting storage v = _userVestings[user][i];
            if (v.totalAmount == 0) continue;
            uint256 vested = _vestedAmount(v.totalAmount, v.startDay, today);
            if (vested > v.withdrawn) total += vested - v.withdrawn;
        }
    }

    function getActiveYoloVesting(address user) external view returns (uint256 total) {
        uint256 head = userVestingHead[user];
        uint256 tail = userVestingTail[user];
        for (uint256 i = head; i < tail; i++) {
            YoloVesting storage v = _userVestings[user][i];
            if (v.totalAmount == 0) continue;
            total += v.totalAmount - v.withdrawn;
        }
    }

    function getUserVestings(address user) external view returns (YoloVesting[] memory result) {
        uint256 head = userVestingHead[user];
        uint256 tail = userVestingTail[user];
        uint256 count;
        //防御性写法
        for (uint256 i = head; i < tail; i++) {
            YoloVesting storage v = _userVestings[user][i];
            if (v.totalAmount > 0 && v.withdrawn < v.totalAmount) count++;
        }
        result = new YoloVesting[](count);
        uint256 j;
        for (uint256 i = head; i < tail; i++) {
            YoloVesting storage v = _userVestings[user][i];
            if (v.totalAmount > 0 && v.withdrawn < v.totalAmount) {
                result[j++] = v;
            }
        }
    }

    function getYoloVesting(address user, uint256 vestingId) external view returns (YoloVesting memory) {
        require(vestingId < userVestingTail[user], "Invalid vesting id");
        require(vestingId >= userVestingHead[user], "Invalid vesting id");
        return _userVestings[user][vestingId];
    }

    function _addYoloVesting(address user, uint256 eventId, uint256 amount) internal {
        if (amount == 0) return;
        uint256 id = userVestingTail[user];
        uint256 startDay = block.timestamp / 1 days;
        _userVestings[user][id] = YoloVesting({
            totalAmount: amount,
            withdrawn: 0,
            startDay: startDay
        });
        userVestingTail[user] = id + 1;
        emit YoloVestingStarted(user, eventId, id, amount, startDay);
    }

    /// 从用户已结算但未取走的 YOLO 中扣除 `needed`，FIFO 消费；返回实际消费量。
    /// 同时把 withdrawn 累加（既包含 claim 也包含 reuse），剩余部分还能继续释放。
    function _consumeVesting(address user, uint256 needed) internal returns (uint256 consumed) {
        uint256 head = userVestingHead[user];
        uint256 tail = userVestingTail[user];
        for (uint256 i = head; i < tail && consumed < needed; i++) {
            YoloVesting storage v = _userVestings[user][i];
            uint256 left = v.totalAmount - v.withdrawn;
            if (left == 0) continue;
            uint256 take = needed - consumed;
            if (take > left) take = left;
            v.withdrawn += take;
            consumed += take;
        }
        _compactHead(user);
    }

    /// 把队首已完全消耗的 tranche 跳过，释放存储 gas。
    function _compactHead(address user) internal {
        uint256 head = userVestingHead[user];
        uint256 tail = userVestingTail[user];
        while (head < tail) {
            YoloVesting storage v = _userVestings[user][head];
            if (v.totalAmount != 0 && v.withdrawn < v.totalAmount) break;
            delete _userVestings[user][head];
            head++;
        }
        userVestingHead[user] = head;
    }

    // 10 天 cliff 释放：在 startDay + YOLO_VESTING_DAYS 之前为 0，到达后全部解锁。
    function _vestedAmount(uint256 totalAmount, uint256 startDay, uint256 currentDay) internal pure returns (uint256) {
        if (currentDay < startDay + YOLO_VESTING_DAYS) return 0;
        return totalAmount;
    }
}
