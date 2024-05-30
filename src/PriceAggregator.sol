// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "./interfaces/ICallbacks.sol";
import "./interfaces/ITradingStorage.sol";
import "./interfaces/IExecute.sol";
import "./interfaces/IPriceAggregator.sol";
import "pyth-sdk-solidity/IPyth.sol";
import "pyth-sdk-solidity/PythStructs.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";

contract PriceAggregator is Initializable, IPriceAggregator {
    IPyth public pyth;

    ITradingStorage storageT;
    IPairStorage public override pairsStorage;
    IExecute public override executions;

    uint private constant PRECISION = 1e10;

    mapping(uint => Order) public orders;
    mapping(uint => uint[]) public ordersAnswers;
    mapping(uint => PendingSl) private _pendingSlOrders;
    mapping(uint => PendingMarginUpdate) private _pendingMarginUpdateOrders;

    function initialize(address _storageT, address _pairsStorage, address _executions) external initializer {
        require(address(_pairsStorage) != address(0), "WRONG_PARAMS");

        pairsStorage = IPairStorage(_pairsStorage);
        executions = IExecute(_executions);
        storageT = ITradingStorage(_storageT);
    }

    // Modifiers
    modifier onlyGov() {
        require(msg.sender == storageT.gov(), "GOV_ONLY");
        _;
    }
    modifier onlyTrading() {
        require(msg.sender == storageT.trading(), "TRADING_ONLY");
        _;
    }

    // Manage contracts
    function updatePairsStorage(address _pairsStorage) external onlyGov {
        require(address(_pairsStorage) != address(0), "VALUE_0");
        pairsStorage = IPairStorage(_pairsStorage);
        emit AddressUpdated("pairsStorage", address(_pairsStorage));
    }

    // Manage Pyth
    function setPyth(address pythContract) external onlyGov {
        pyth = IPyth(pythContract);
        emit PythUpdated(pythContract);
    }

    function pendingSlOrders(uint index) external view override returns (PendingSl memory) {
        return _pendingSlOrders[index];
    }

    function pendingMarginUpdateOrders(uint index) external view override returns (PendingMarginUpdate memory) {
        return _pendingMarginUpdateOrders[index];
    }
    // Create order which is used later to fulfill price
    function getPrice(uint _pairIndex, OrderType _orderType) external override onlyTrading returns (uint) {
        (, , bytes32 job, , uint orderId) = pairsStorage.pairJob(_pairIndex);

        orders[orderId] = Order(_pairIndex, _orderType, job, true);
        return orderId;
    }

    function fulfill(uint orderId, bytes[] calldata priceUpdateData) external payable override onlyTrading {
        Order storage r = orders[orderId];

        if (r.initiated) {
            uint fee = pyth.getUpdateFee(priceUpdateData);
            pyth.updatePriceFeeds{value: fee}(priceUpdateData);

            uint[] storage answers = ordersAnswers[orderId];

            PythStructs.Price memory pythPrice = pyth.getPrice(r.job);
            uint price;
            uint conf;
            if (pythPrice.expo > 0) {
                price = uint64(pythPrice.price) * PRECISION * 10 ** uint32(pythPrice.expo);
                conf = pythPrice.conf * PRECISION * 10 ** uint32(pythPrice.expo);
            } else {
                price = (uint64(pythPrice.price) * PRECISION) / 10 ** uint32(-pythPrice.expo);
                conf = (pythPrice.conf * PRECISION) / 10 ** uint32(-pythPrice.expo);
            }

            IPairStorage.Feed memory f = pairsStorage.pairFeed(r.pairIndex);
            IPairStorage.BackupFeed memory backupFeed = pairsStorage.pairBackupFeed(r.pairIndex);

            require(price > 0 && (conf * PRECISION * 100) / price <= f.maxDeviationP, "PRICE_DEVIATION_TOO_HIGH");

            if (backupFeed.maxDeviationP > 0 && backupFeed.feedId != address(0)) {
                AggregatorV2V3Interface chainlinkFeed = AggregatorV2V3Interface(backupFeed.feedId);
                (, int256 rawBkPrice, , , ) = chainlinkFeed.latestRoundData(); // e.g. 160414750000, 8 decimals
                uint bkPrice = (uint256(rawBkPrice) * PRECISION) / 10 ** uint8(chainlinkFeed.decimals());
                emit BackupPriceReceived(orderId, r.pairIndex, bkPrice);

                if (bkPrice > price) {
                    require(
                        (((bkPrice - price) * 100 * PRECISION) / price) <= backupFeed.maxDeviationP,
                        "BACKUP_DEVIATION_TOO_HIGH"
                    );
                }
                if (bkPrice < price) {
                    require(
                        (((price - bkPrice) * 100 * PRECISION) / bkPrice) <= backupFeed.maxDeviationP,
                        "BACKUP_DEVIATION_TOO_HIGH"
                    );
                }
            }

            answers.push(price);
            emit PriceReceived(orderId, r.pairIndex, price);

            if (answers.length > 0) {
                ICallbacks.AggregatorAnswer memory a = ICallbacks.AggregatorAnswer(
                    orderId,
                    median(answers),
                    pairsStorage.pairSpreadP(r.pairIndex)
                );

                ICallbacks c = ICallbacks(storageT.callbacks());

                if (r.orderType == OrderType.MARKET_OPEN) {
                    c.openTradeMarketCallback(a);
                } else if (r.orderType == OrderType.MARKET_CLOSE) {
                    c.closeTradeMarketCallback(a);
                } else if (r.orderType == OrderType.LIMIT_OPEN) {
                    c.executeLimitOpenOrderCallback(a);
                } else if (r.orderType == OrderType.LIMIT_CLOSE) {
                    c.executeLimitCloseOrderCallback(a);
                } else if (r.orderType == OrderType.UPDATE_MARGIN) {
                    c.updateMarginCallback(a);
                } else {
                    c.updateSlCallback(a);
                }

                delete orders[orderId];
                delete ordersAnswers[orderId];
            }
        }
    }

    // Manage pending SL orders
    function storePendingSlOrder(uint orderId, PendingSl calldata p) external override onlyTrading {
        _pendingSlOrders[orderId] = p;
    }

    // Manage pending Margin update orders
    function storePendingMarginUpdateOrder(uint orderId, PendingMarginUpdate calldata p) external override onlyTrading {
        _pendingMarginUpdateOrders[orderId] = p;
    }

    function unregisterPendingSlOrder(uint orderId) external override {
        require(msg.sender == storageT.callbacks(), "CALLBACKS_ONLY");
        delete _pendingSlOrders[orderId];
    }

    function unregisterPendingMarginUpdateOrder(uint orderId) external override {
        require(msg.sender == storageT.callbacks(), "CALLBACKS_ONLY");
        delete _pendingMarginUpdateOrders[orderId];
    }

    // Median function
    function swap(uint[] memory array, uint i, uint j) private pure {
        (array[i], array[j]) = (array[j], array[i]);
    }

    function sort(uint[] memory array, uint begin, uint end) private pure {
        if (begin >= end) {
            return;
        }
        uint j = begin;
        uint pivot = array[j];
        for (uint i = begin + 1; i < end; ++i) {
            if (array[i] < pivot) {
                swap(array, i, ++j);
            }
        }
        swap(array, begin, j);
        sort(array, begin, j);
        sort(array, j + 1, end);
    }

    function median(uint[] memory array) private pure returns (uint) {
        sort(array, 0, array.length);
        return
            array.length % 2 == 0
                ? (array[array.length / 2 - 1] + array[array.length / 2]) / 2
                : array[array.length / 2];
    }

    function openFeeP(uint _pairIndex, uint _leveragedPositionSize, bool _buy) external view override returns (uint) {
        return pairsStorage.pairOpenFeeP(_pairIndex, _leveragedPositionSize, _buy);
    }
}
