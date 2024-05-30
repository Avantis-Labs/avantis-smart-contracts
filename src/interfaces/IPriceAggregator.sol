// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;
import "./IPairStorage.sol";
import "./IExecute.sol";
import "./ITradingStorage.sol";

interface IPriceAggregator {
    // Custom data types
    enum OrderType {
        MARKET_OPEN,
        MARKET_CLOSE,
        LIMIT_OPEN,
        LIMIT_CLOSE,
        UPDATE_MARGIN,
        UPDATE_SL
    }
    struct Order {
        uint pairIndex;
        OrderType orderType;
        bytes32 job;
        bool initiated;
    }
    struct PendingSl {
        address trader;
        uint pairIndex;
        uint index;
        uint openPrice;
        bool buy;
        uint newSl;
    }

    struct PendingMarginUpdate {
        address trader;
        uint pairIndex;
        uint index;
        ITradingStorage.updateType _type;
        uint amount;
        uint tier;
    }

    // Events
    event AddressUpdated(string name, address a);
    event NumberUpdated(string name, uint value);
    event PythUpdated(address a);
    event PriceReceived(uint orderId, uint pairIndex, uint price);
    event BackupPriceReceived(uint orderId, uint pairIndex, uint price);

    function pairsStorage() external view returns (IPairStorage);

    function executions() external view returns (IExecute);

    function getPrice(uint, OrderType) external returns (uint);

    function fulfill(uint orderId, bytes[] calldata priceUpdateData) external payable;

    function openFeeP(uint, uint, bool) external view returns (uint);

    function pendingSlOrders(uint) external view returns (PendingSl memory);

    function pendingMarginUpdateOrders(uint) external view returns (PendingMarginUpdate memory);

    function storePendingSlOrder(uint orderId, PendingSl calldata p) external;

    function storePendingMarginUpdateOrder(uint orderId, PendingMarginUpdate calldata p) external;

    function unregisterPendingSlOrder(uint orderId) external;

    function unregisterPendingMarginUpdateOrder(uint orderId) external;
}
