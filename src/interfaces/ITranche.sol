// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ITranche is IERC4626 {
    function feesOn() external view returns (bool);

    function sendVeRewards(uint256 rewards) external;

    function totalReserved() external view returns (uint256);

    function depositCap() external view returns (uint256);

    function veTranche() external view returns (address);

    function withdrawAsVaultManager(uint256 amount) external;

    function reserveBalance(uint256) external;

    function releaseBalance(uint256) external;

    function hasLiquidity(uint256 _reserveAmount) external view returns (bool);
}
