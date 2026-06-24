// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IYoloToken {
    function burn(address user, uint256 _amount) external;
    function quote(uint256 amount) external view returns (uint256);
    function updateChoPrice() external;
    function setPlatformAddress(address platformAddress) external;
    function platformAddress() external view returns (address);

    /// @notice 做市回收: 从交易对抽取代币到 marking 地址 (上限 pair 余额 1/3), 仅 marking 可调用
    /// @param amount 期望回收数量
    function recycle(uint256 amount) external;

    event Burn(uint256 _burnAmount, uint256 _totalSupply);
    event SetStakingManager(address indexed stakingManager);
    event SetPoolAddress(YoloPool pool);
    event SetPlatformAddress(address indexed platformAddress);
    event UpdateChoPrice(uint256 timestamp, uint256 blockNumber, uint256 choPrice);
    event DeclineTaxApplied(uint256 amount, uint256 declineRate, uint256 toFomo);
    /// @param pair 交易对地址
    /// @param marking 做市合约地址
    /// @param amount 实际回收数量
    event Recycle(address indexed pair, address indexed marking, uint256 amount);
    /// @param marking 新做市合约地址
    event SetMarking(address indexed marking);

    struct YoloPool {
        address lpPool;
        address cardPool;
    }
}
