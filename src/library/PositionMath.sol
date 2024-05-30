// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

library PositionMath {
    uint constant LEVERAGE_PRCECISION = 1e10;

    function mul(uint a, uint _leverage) internal pure returns (uint) {
        return (a * _leverage) / LEVERAGE_PRCECISION;
    }

    function div(uint a, uint _leverage) internal pure returns (uint) {
        return (a * LEVERAGE_PRCECISION) / _leverage;
    }
}
