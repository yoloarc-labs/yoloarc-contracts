// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IYoloToken {
    function burn(address user, uint256 _amount) external;
    function quote(uint256 amount) external view returns (uint256);

    event Burn(uint256 _burnAmount, uint256 _totalSupply);
    event SetPoolAddress(YoloPool indexed pool);

    struct YoloPool {
        address nodePool; // Base pool (node income pool)
        address daoRewardPool; // DAO organization rewards
        address airdropPool; // Airdrop
        address techFeePool; // Technical Fee
        address techPool; // Technical
        address capitalPool; // Capital strategy
        address marketingFeePool; // Marketing development
        address subTokenPool; // Sub token liquidity pool
        address ecosystemPool; // ecosystemPool
    }
}
