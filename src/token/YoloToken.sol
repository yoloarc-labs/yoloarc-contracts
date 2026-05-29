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
import {SwapHelper} from "../utils/SwapHelper.sol";
import "./YoloTokenStorage.sol";

contract YoloToken is Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, OwnableUpgradeable, TradeSlippage, YoloTokenStorage {
    string private constant NAME = "Yolo";
    string private constant SYMBOL = "CHO";

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the Yolo token contract
     * @param _owner Owner address
     * @param _usdt usdt token address
     */
    function initialize(address _owner, address _usdt) public initializer {
        require(_owner != address(0), "YoloToken initialize: _owner can't be zero address");
        __ERC20_init(NAME, SYMBOL);
        __ERC20Burnable_init();
        __Ownable_init(_owner);
        _transferOwnership(_owner);

        USDT = _usdt;

        mainPair = IPancakeFactory(V2_FACTORY).createPair(USDT, address(this));
    }

    /**
     * @dev Returns token decimals
     * @return Token decimals (6 decimal places)
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    /**
     * @dev Get Yolo balance of specified address
     * @param _address Address to query
     * @return CMT balance of the address
     */
    function YoloBalance(address _address) external view returns (uint256) {
        return balanceOf(_address);
    }


    /**
     * @dev Set all pool addresses
     * @param _pool Struct containing all pool addresses
     */
    function setPoolAddress(YoloPool memory _pool, address[] memory _marketingPools) external onlyOwner {
        _beforeAllocation();
        _beforePoolAddress(_pool);
        cmPool = _pool;
        for (uint256 i = 0; i < _marketingPools.length; i++) {
            EnumerableSet.add(marketingPools, _marketingPools[i]);
        }
        emit SetPoolAddress(_pool);
    }

    /**
     * @dev Execute token pool allocation, minting tokens to each pool according to predefined ratios
     * @notice Can only be executed once. Allocation ratios: Node Pool 20%, DAO Reward 60%, Airdrop 6%, Tech Rewards 5%, Ecosystem 4%, Founding Strategy 2%, Marketing Development 3%
     */
    function poolAllocate() external onlyOwner {
        _beforeAllocation();
        _mint(cmPool.nodePool, (MaxTotalSupply * 5) / 100); // 5% of total supply
        _mint(cmPool.daoRewardPool, (MaxTotalSupply * 75) / 100); // 75% of total supply
        _mint(cmPool.airdropPool, (MaxTotalSupply * 6) / 100); // 6% of total supply
        _mint(cmPool.techPool, (MaxTotalSupply * 5) / 100); // 5% of total supply
        _mint(cmPool.capitalPool, (MaxTotalSupply * 2) / 100); // 2% of total supply
        _mint(cmPool.ecosystemPool, (MaxTotalSupply * 4) / 100); // 4% of total supply

        // 3% of total supply
        address[] memory marketingPoolsArray = EnumerableSet.values(marketingPools);
        if (marketingPoolsArray.length > 0) {
            uint256 marketingDevelopmentPoolEvery = (MaxTotalSupply * 3) / 100 / marketingPoolsArray.length;
            for (uint256 index = 0; index < marketingPoolsArray.length; index++) {
                _mint(marketingPoolsArray[index], marketingDevelopmentPoolEvery);
            }
        }
        isAllocation = true;
    }

    /**
     * @dev Burn tokens of specified user (only callable by DAO reward pool)
     * @param user User address whose tokens to burn
     * @param _amount Amount of tokens to burn
     */
    function burn(address user, uint256 _amount) external onlyOwner {
        _burn(user, _amount);
        _lpBurnedTokens += _amount;
        emit Burn(_amount, totalSupply());
    }

    /**
     * @dev Get current total supply of Yolo tokens
     * @return Current total supply
     */
    function YoloTotalSupply() external view returns (uint256) {
        return totalSupply();
    }

    // ==================== internal function =============================
    /**
     * @dev Pre-allocation check, ensures allocation happens only once
     */
    function _beforeAllocation() internal virtual {
        require(!isAllocation, "YoloToken _beforeAllocation:Fishcake is already allocate");
    }

    /**
     * @dev Validation before setting pool addresses, ensures all pool addresses are set
     * @param _pool Pool address struct to validate
     */
    function _beforePoolAddress(YoloPool memory _pool) internal virtual {
        require(_pool.nodePool != address(0), "Missing allocate bottomPool address");
        require(_pool.daoRewardPool != address(0), "Missing allocate daoRewardPool address");
        require(_pool.airdropPool != address(0), "Missing allocate airdropPool address");
        require(_pool.techPool != address(0), "Missing allocate techPool address");
        require(_pool.capitalPool != address(0), "Missing allocate capitalPool address");
    }

    function quote(uint256 amount) public view returns (uint256) {
        (uint256 rOther, uint256 rThis,,) = getReserves(mainPair, address(this));
        return IPancakeRouter01(V2_ROUTER).getAmountOut(amount, rThis, rOther);
    }

    function quoteThis(uint256 amount) public view returns (uint256) {
        (uint256 rOther, uint256 rThis,,) = getReserves(mainPair, address(this));
        return IPancakeRouter01(V2_ROUTER).getAmountOut(amount, rOther, rThis);
    }
}

