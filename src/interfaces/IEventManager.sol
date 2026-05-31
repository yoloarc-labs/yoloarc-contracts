// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IEventManager {
    // Enums
    enum EventStatus {
        CREATED,          // 已创建
        ACTIVE,           // 激活中
        PENDING_RESULT,   // 等待结果
        SETTLED,          // 已结算
        CANCELLED         // 已取消
    }

    enum EventResult {
        PENDING,       // 待定
        YES,           // YES胜出
        NO,            // NO胜出
        INVALID        // 无效
    }

    enum BetPaymentType {
        TOKEN,
        STAKING_CREDIT
    }

    struct Event {
        uint256 eventId;             // 事件ID
        uint256 startTime;           // 开始时间
        uint256 endTime;             // 结束时间
        EventStatus status;          // 事件状态
        EventResult result;          // 事件结果
        address betTokenAddress;     // 投注的币种
        uint256 totalAmount;         // 总资金池
        uint256 winAmount;           // 总盈利资金
        uint256 lossAmount;          // 总亏损资金
        uint256 settlementFeeRate;   // 结算费率 (basis points, 1/10000)
        uint256 createdAt;           // 创建时间
        uint256 settledAt;           // 结算时间
    }

    struct BetRecord {
        uint256 betId;
        uint256 eventId;
        address bettor;
        EventResult selectedResult;
        uint256 amount;
        BetPaymentType paymentType;
        uint256 stakingRound;
        uint256 createdAt;
    }

    error EventAlreadyExists(uint256 eventId);
    error EventNotFound(uint256 eventId);
    error InvalidEventTime();
    error InvalidSettlementFeeRate();
    error InvalidBetAmount();
    error InvalidBetResult();
    error InvalidBetToken();
    error EventNotBettable(uint256 eventId);
    error EventNotSettleable(uint256 eventId);
    error CallerIsNotEventManager();
    error ZeroAddress();

    event EventCreated(uint256 indexed eventId, uint256 startTime, uint256 endTime, uint256 settlementFeeRate);
    event EventBetPlaced(
        uint256 indexed betId,
        uint256 indexed eventId,
        address indexed bettor,
        EventResult selectedResult,
        uint256 amount,
        BetPaymentType paymentType,
        uint256 stakingRound,
        uint256 dayIndex
    );
    event EventResultSet(uint256 indexed eventId, EventResult result);
    event BetSettled(
        uint256 indexed betId,
        uint256 indexed eventId,
        address indexed bettor,
        bool won,
        uint256 payoutAmount,
        BetPaymentType paymentType,
        uint256 stakingRound
    );
    event EventFinished(
        uint256 indexed eventId,
        EventResult result,
        uint256 winAmount,
        uint256 lossAmount,
        uint256 tokenSettlementFee,
        uint256 stakingCreditSettlementFee
    );

    function createEvent(uint256 eventId, uint256 startTime, uint256 endTime, uint256 settlementFeeRate, address betTokenAddress) external;
    function betEvent(uint256 eventId, uint256 amount, EventResult selectedResult) external;
    function betEventWithStaking(uint256 eventId, uint256 stakingRound, uint256 amount, EventResult selectedResult) external;
    function setEventResult(uint256 eventId, EventResult result) external;
    function finishEvent(uint256 eventId) external;
    function getEventBetIds(uint256 eventId) external view returns (uint256[] memory);
    function getUserBetIds(address user) external view returns (uint256[] memory);
}
