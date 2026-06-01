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

    struct Event {
        uint256 eventId;             // 事件ID
        uint256 startTime;           // 开始时间
        uint256 endTime;             // 结束时间
        EventStatus status;          // 事件状态
        EventResult result;          // 事件结果
        address betTokenAddress;     // 投注的币种
        uint256 totalAmount;         // 总资金池
        uint256 totalYoloAmount;     // 总Yolo资金
        uint256 totalYesAmount;      // 总YES资金
        uint256 totalNoAmount;       // 总NO资金
        uint256 yesOdds;             // YES赔
        uint256 noOdds;              // NO赔
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
        uint256 odds;
        uint256 amount;
        uint256 yoloAmount;
        uint256 createdAt;
    }

    /// @notice Tracks a YOLO collateral release schedule for one settled bet.
    /// `totalAmount` 是开始释放时的原始数量；
    /// `withdrawn` 累计被 user 提取 OR 被新下注消费 的数量；
    /// `startDay = block.timestamp / 1 days` (UTC 自然日)。
    /// Cliff 释放：currentDay < startDay + YOLO_VESTING_DAYS 时已释放=0；到达 cliff 后全部解锁。
    struct YoloVesting {
        uint256 totalAmount;
        uint256 withdrawn;
        uint256 startDay;
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
    error InvalidYoloCollateral();

    event EventCreated(
        uint256 indexed eventId,
        uint256 startTime,
        uint256 endTime,
        uint256 settlementFeeRate,
        address betTokenAddress
    );
    event EventBetPlaced(
        uint256 indexed betId,
        uint256 indexed eventId,
        address indexed bettor,
        EventResult selectedResult,
        uint256 amount,
        uint256 yoloAmount,
        uint256 dayIndex
    );
    event EventResultSet(uint256 indexed eventId, EventResult result);
    event EventOddsUpdated(uint256 indexed eventId, uint256 yesOdds, uint256 noOdds);
    event BetSettled(
        uint256 indexed betId,
        uint256 indexed eventId,
        address indexed bettor,
        bool won,
        uint256 payoutAmount,
        uint256 feeAmount
    );
    event EventFinished(
        uint256 indexed eventId,
        EventResult result,
        uint256 winAmount,
        uint256 lossAmount,
        uint256 tokenSettlementFee
    );
    event YoloVestingStarted(
        address indexed user,
        uint256 indexed eventId,
        uint256 indexed vestingId,
        uint256 amount,
        uint256 startDay
    );
    event YoloClaimed(address indexed user, uint256 amount);
    event YoloReused(address indexed user, uint256 indexed eventId, uint256 amount);

    function createEvent(
        uint256 eventId,
        uint256 startTime,
        uint256 endTime,
        uint256 settlementFeeRate,
        address betTokenAddress,
        uint256 yesOdds,
        uint256 noOdds
    ) external;
    function betEvent(uint256 eventId, uint256 amount, EventResult selectedResult) external;
    function setEventOdds(uint256 eventId, uint256 yesOdds, uint256 noOdds) external;
    function setEventResult(uint256 eventId, EventResult result) external;
    function finishEvent(uint256 eventId) external;
    function getEventBetIds(uint256 eventId) external view returns (uint256[] memory);
    function getUserBetIds(address user) external view returns (uint256[] memory);

    function claimYolo() external;
    function getClaimableYolo(address user) external view returns (uint256);
    function getActiveYoloVesting(address user) external view returns (uint256);
    function getUserVestings(address user) external view returns (YoloVesting[] memory);
    function getYoloVesting(address user, uint256 vestingId) external view returns (YoloVesting memory);
}
