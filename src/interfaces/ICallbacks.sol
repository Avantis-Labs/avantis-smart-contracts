// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;
import "./ITradingStorage.sol";

interface ICallbacks {
    struct AggregatorAnswer {
        uint orderId;
        uint price;
        uint spreadP;
    }
    struct Values {
        uint price;
        int profitP;
        uint posToken;
        uint posUSDC;
        uint reward;
    }

    // Events
    event MarketExecuted(
        uint orderId,
        ITradingStorage.Trade t,
        bool open,
        uint price,
        uint positionSizeUSDC,
        int percentProfit,
        uint USDCSentToTrader,
        uint timestamp
    );
    event LimitExecuted(
        uint orderId,
        uint limitIndex,
        ITradingStorage.Trade t,
        ITradingStorage.LimitOrder orderType,
        uint price,
        uint positionSizeUSDC,
        int percentProfit,
        uint USDCSentToTrader,
        uint timestamp
    );

    event MarketOpenCanceled(uint orderId, address indexed trader, uint pairIndex, uint timestamp);
    event MarketCloseCanceled(uint orderId, address indexed trader, uint pairIndex, uint index, uint timestamp);

    event SlUpdated(uint orderId, address indexed trader, uint pairIndex, uint index, uint newSl, uint timestamp);
    event SlCanceled(uint orderId, address indexed trader, uint pairIndex, uint index, uint timestamp);

    event AddressUpdated(string name, address a);
    event NumberUpdated(string name, uint value);

    event Pause(bool paused);
    event Done(bool done);

    function vaultFeeP() external returns (uint);

    function openTradeMarketCallback(AggregatorAnswer memory) external;

    function closeTradeMarketCallback(AggregatorAnswer memory) external;

    function executeLimitOpenOrderCallback(AggregatorAnswer memory) external;

    function executeLimitCloseOrderCallback(AggregatorAnswer memory) external;

    function updateSlCallback(AggregatorAnswer memory) external;

    function updateMarginCallback(AggregatorAnswer memory ) external;

    function chargeRollOverFees(ITradingStorage.Trade memory _trade) external returns (uint);

    function transferFromVault(address _trader, uint _amount) external;
}
