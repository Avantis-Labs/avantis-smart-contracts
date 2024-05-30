// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Tranche.sol";

contract TrancheMock is Tranche {
    function reserveBalanceMock(uint256 amount) external {
        _reserveBalance(amount);
    }

    function releaseBalanceMock(uint256 amount) external {
        _releaseBalance(amount);
    }

    function withdrawAsVaultManagerMock(uint256 amount) external {
        _withdrawAsVaultManager(amount);
    }
}
