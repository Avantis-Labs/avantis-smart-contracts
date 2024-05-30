// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

interface IPausable {
    function isPaused() external view returns (bool);
}
