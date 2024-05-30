// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../VeTranche.sol";

contract VeTrancheMock is VeTranche {
    function distributeRewardsMock(uint256 amount, uint256 totalLockPoints) external {
        _distributeRewards(amount, totalLockPoints);
    }
}
