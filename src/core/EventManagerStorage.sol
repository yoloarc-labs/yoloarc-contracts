// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../interfaces/IEventManager.sol";
import "../interfaces/IYoloToken.sol";


abstract contract EventManagerStorage is IEventManager  {
    address public manager;

    address public eventManager;

    address public oracle;

    address public USDT;

    address public underlyingToken;

    IYoloToken public yoloTokenAddress;

    uint256 public feeBalances;

    uint256 public defaultSettlementFeeRate;

    mapping(uint256 => Event) public events;

    uint256[] public eventIds;

    mapping(uint256 => uint256) public eventIdIndex;

    mapping(uint256 => uint256) public oracleRequests;

    uint256 public nextBetId;

    mapping(uint256 => BetRecord) public betRecords;

    mapping(uint256 => uint256[]) internal eventBetIds;

    mapping(address => uint256[]) internal userBetIds;

    mapping(uint256 => uint256) public eventYesAmount;

    mapping(uint256 => uint256) public eventNoAmount;

    // ---- YOLO 抵押释放 (vesting) ----
    uint256 public constant YOLO_VESTING_DAYS = 10;

    /// 每个用户的 vesting 队列，按 vestingId 索引；id 在 [head, tail) 范围内有效。
    mapping(address => mapping(uint256 => YoloVesting)) internal _userVestings;
    mapping(address => uint256) public userVestingHead;
    mapping(address => uint256) public userVestingTail;

    modifier onlyEventManager() {
        if (msg.sender != manager && msg.sender != eventManager) revert CallerIsNotEventManager();
        _;
    }
}
