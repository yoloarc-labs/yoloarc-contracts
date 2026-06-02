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
    }

    function createEvent(uint256 eventId, uint256 startTime, uint256 endTime, uint256 settlementFeeRate, address betTokenAddress) external {

    }

    function betEvent(uint256 eventId, uint256 amount, EventResult selectedResult) external {

    }

    function setEventResult(uint256 eventId, EventResult result) external {

    }

    function finishEvent(uint256 eventId) external {

    }

    function getEventBetIds(uint256 eventId) external view returns (uint256[] memory) {

    }

    function getUserBetIds(address user) external view returns (uint256[] memory) {

    }
}
