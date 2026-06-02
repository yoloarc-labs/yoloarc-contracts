// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin-upgrades/contracts/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin-upgrades/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../interfaces/pancake/IPancakeV3Pool.sol";
import "@pancake-v2-core/interfaces/IPancakePair.sol";
import "@pancake-v2-core/interfaces/IPancakeFactory.sol";
import "@pancake-v2-periphery/interfaces/IPancakeRouter02.sol";
import {TradeSlippage} from "../utils/TradeSlippage.sol";
import "./YoloTokenStorage.sol";

contract YoloToken is  Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, OwnableUpgradeable, TradeSlippage, YoloTokenStorage  {
    string private constant NAME = "Yolo Token";
    string private constant SYMBOL = "Yolo";

    constructor() {
        _disableInitializers();
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "YoloToken: caller is not the operator");
        _;
    }

    modifier onlyStakingManager() {
        require(
            msg.sender == stakingManager, "YoloToken onlyStakingManager: Only StakingManager can call this function"
        );
        _;
    }

    /**
     * @dev Initialize the Yolo token contract
     * @param _owner Owner address
     * @param _stakingManager Staking manager address
     */
    function initialize(address _owner, address _stakingManager, address _usdt, address _fundingPod) public initializer {
        require(_owner != address(0), "YoloToken initialize: _owner can't be zero address");
        __ERC20_init(NAME, SYMBOL);
        __ERC20Burnable_init();
        __Ownable_init(_owner);
        _transferOwnership(_owner);
        operator = _owner;
        stakingManager = _stakingManager;
        fundingPod = _fundingPod;
        USDT = _usdt;

        EnumerableSet.add(factories, V2_FACTORY); // PancakeSwap V2 Factory address on BSC

        mainPair = IPancakeFactory(V2_FACTORY).createPair(USDT, address(this));

        emit SetStakingManager(_stakingManager);
    }


    function _update(address from, address to, uint256 value) internal override {
        if (isWhitelisted(from, to) || !isAllocation) {
            super._update(from, to, value);
            return;
        }

        (bool isBuy, bool isSell,,,,) = _getTradeFlags(from, to, value);

        if (!isStakingManager(to) && !isFundingPod(to) && (isBuy && !isOpenBuy)) {
            revert("YoloToken: Buying is not enabled yet");
        }

        if (isSell && !isOpenSell) {
            revert("YoloToken: Selling is not enabled yet");
        }

        if (isSell) {
            value = _takeSellFee(from, value);
            value = _takeDeclineTax(from, value);
        }

        super._update(from, to, value);
    }

    function getDeclineTaxRate(uint256 value, bool isSell) internal returns (uint256 sellTax) {
        if (!isSell || latestChoPrice == 0 || value == 0) {
            return 0;
        }

        uint256 currentPrice = quote(1000000);
        if (currentPrice >= latestChoPrice) {
            return 0;
        }

        uint256 declineRate = ((latestChoPrice - currentPrice) * BPS_DENOMINATOR) / latestChoPrice;
        if (declineRate >= PRICE_DROP_6_BPS) {
            sellTax = (value * DOWN_TAX_6_BPS) / BPS_DENOMINATOR;
        } else if (declineRate >= PRICE_DROP_3_BPS) {
            sellTax = (value * DOWN_TAX_3_BPS) / BPS_DENOMINATOR;
        }

        if (sellTax > 0) {
            downsideTax = sellTax;
        }
        emit DeclineTaxApplied(value, declineRate, sellTax);
    }

    function isStakingManager(address addr) internal view returns (bool) {
        return addr == stakingManager;
    }

    function isFundingPod(address addr) internal view returns (bool) {
        return addr == fundingPod;
    }

    function isWhitelisted(address from, address to) public view returns (bool) {
        return EnumerableSet.contains(whiteList, from) || EnumerableSet.contains(whiteList, to);
    }

    function addWhitelist(address[] memory _address) external onlyOperator {
        for (uint256 i = 0; i < _address.length; i++) {
            EnumerableSet.add(whiteList, _address[i]);
        }
    }

    function removeWhitelist(address[] memory _address) external onlyOperator {
        for (uint256 i = 0; i < _address.length; i++) {
            EnumerableSet.remove(whiteList, _address[i]);
        }
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }


    function YoloBalance(address _address) external view returns (uint256) {
        return balanceOf(_address);
    }

    function setPlatformAddress(address _platformAddress) public onlyOwner {
        require(_platformAddress != address(0), "YoloToken: platform address cannot be zero address");
        fomoTreasureAddress = _platformAddress;
        emit SetPlatformAddress(_platformAddress);
    }

    function platformAddress() external view returns (address) {
        return fomoTreasureAddress;
    }

    function setStakingManager(address _stakingManager) external onlyOperator {
        stakingManager = _stakingManager;
        emit SetStakingManager(_stakingManager);
    }

    function setPoolAddress(YoloPool memory _pool) external onlyOperator {
        _beforeAllocation();
        _beforePoolAddress(_pool);
        cmPool = _pool;
        emit SetPoolAddress(_pool);
    }

    function poolAllocate() external onlyOperator {
        _beforeAllocation();
        _mint(cmPool.lpPool, (MaxTotalSupply * 40) / 100);
        _mint(cmPool.cardPool, (MaxTotalSupply * 60) / 100);

        isAllocation = true;
    }

    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "YoloToken: operator cannot be zero address");
        operator = _operator;
    }

    function setFomoTreasureAddress(address _fomoTreasureAddress) external onlyOwner {
        require(_fomoTreasureAddress != address(0), "YoloToken: _fomoTreasureAddress cannot be zero address");
        fomoTreasureAddress = _fomoTreasureAddress;
        emit SetPlatformAddress(_fomoTreasureAddress);
    }

    function updateChoPrice() external onlyOperator {
        (uint256 rOther, uint256 rThis,,) = getReserves(mainPair, address(this));
        latestChoPrice = IPancakeRouter01(V2_ROUTER).getAmountOut(1000000, rThis, rOther);
        emit UpdateChoPrice(block.timestamp, block.number, latestChoPrice);
    }

    function burn(address user, uint256 _amount) external onlyStakingManager {
        _burn(user, _amount);
        _lpBurnedTokens += _amount;
        emit Burn(_amount, totalSupply());
    }

    function YoloTotalSupply() external view returns (uint256) {
        return totalSupply();
    }

    // ==================== internal function =============================
    function _beforeAllocation() internal virtual {
        require(!isAllocation, "YoloToken _beforeAllocation:Fishcake is already allocate");
    }

    function _beforePoolAddress(YoloPool memory _pool) internal virtual {
        require(_pool.lpPool != address(0), "Missing allocate lpPoo address");
        require(_pool.cardPool != address(0), "Missing allocate cardPool address");
    }

    function quote(uint256 amount) public view returns (uint256) {
        (uint256 rOther, uint256 rThis,,) = getReserves(mainPair, address(this));
        return IPancakeRouter01(V2_ROUTER).getAmountOut(amount, rThis, rOther);
    }

    function quoteThis(uint256 amount) public view returns (uint256) {
        (uint256 rOther, uint256 rThis,,) = getReserves(mainPair, address(this));
        return IPancakeRouter01(V2_ROUTER).getAmountOut(amount, rOther, rThis);
    }

    function openBuy(bool _isOpenBuy) external onlyOperator {
        isOpenBuy = _isOpenBuy;
    }

    function openSell(bool _isOpenSell) external onlyOperator {
        isOpenSell = _isOpenSell;
    }

    function _getTradeFlags(address from, address to, uint256 value)
        internal
        view
        returns (bool isBuy, bool isSell, bool isAddLiquidity, bool isRemoveLiquidity, uint256 rOther, uint256 rThis)
    {
        return getTradeType(from, to, value, address(this));
    }

    function _takeSellFee(address from, uint256 value) internal returns (uint256 remainingValue) {
        uint256 sellFee = (value * SELL_FEE_BPS) / BPS_DENOMINATOR;
        if (sellFee == 0) {
            return value;
        }

        uint256 burnAmount = (sellFee * 70) / 100;
        uint256 platformAmount = sellFee - burnAmount;

        if (burnAmount > 0) {
            _burn(from, burnAmount);
        }
        if (platformAmount > 0) {
            require(fomoTreasureAddress != address(0), "YoloToken: platform address not set");
            super._update(from, fomoTreasureAddress, platformAmount);
        }

        return value - sellFee;
    }

    function _takeDeclineTax(address from, uint256 value) internal returns (uint256 remainingValue) {
        uint256 taxAmount = getDeclineTaxRate(value, true);
        if (taxAmount > 0) {
            if (fomoTreasureAddress != address(0)) {
                super._update(from, fomoTreasureAddress, taxAmount);
            } else {
                _burn(from, taxAmount);
            }
            value -= taxAmount;
        }
        return value;
    }
}
