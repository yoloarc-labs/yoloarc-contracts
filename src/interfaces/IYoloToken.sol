// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IYoloToken {
    function burn(address user, uint256 _amount) external;
    function quote(uint256 amount) external view returns (uint256);
    function updateChoPrice() external;
    function setPlatformAddress(address platformAddress) external;
    function platformAddress() external view returns (address);

    event Burn(uint256 _burnAmount, uint256 _totalSupply);
    event SetStakingManager(address indexed stakingManager);
    event SetPoolAddress(YoloPool pool);
    event SetPlatformAddress(address indexed platformAddress);
    event UpdateChoPrice(uint256 timestamp, uint256 blockNumber, uint256 choPrice);
    event DeclineTaxApplied(uint256 amount, uint256 declineRate, uint256 toFomo);

    struct YoloPool {
        address lpPool;
        address cardPool;
    }
}
