// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../VaultManager.sol";

contract VaultManagerMock is VaultManager {
    function receiveUSDCFromTraderMock(address _trader, uint _amount, uint _vaultFee) external {
        _receiveUSDCFromTrader(_trader, _amount, _vaultFee);
    }

    function sendUSDCToTraderMock(address _trader, uint _amount) external {
        _sendUSDCToTrader(_trader, _amount);
    }
}
