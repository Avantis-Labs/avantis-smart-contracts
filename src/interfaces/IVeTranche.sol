// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

interface IVeTranche {
    // Define events
    event Locked(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 shares,
        uint256 lockTime,
        uint256 lockMultiplier
    );
    event Unlocked(uint256 indexed tokenId, address indexed owner, uint256 shares, uint256 fee);
    event RewardsDistributed(uint256 totalRewards, uint256 totalLockPoints);
    event RewardClaimed(uint256 indexed tokenId, address indexed owner, uint256 amount);

    function distributeRewards(uint256, uint256) external returns (uint256);

    function getTotalLockPoints() external returns (uint256);

    function getLockPoints(uint256) external returns (uint256);
}
