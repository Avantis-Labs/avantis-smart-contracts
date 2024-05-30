// SPDX-License-Identifier: MIT
import "./interfaces/ITradingStorage.sol";
import "./interfaces/IPairInfos.sol";
import "./interfaces/IExecute.sol";
import "./interfaces/ICallbacks.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {PositionMath} from "./library/PositionMath.sol";

pragma solidity 0.8.7;

contract Trading is PausableUpgradeable {
    using PositionMath for uint;

    ITradingStorage storageT;
    IPairInfos pairInfos;

    uint private constant PRECISION = 1e10;
    uint private constant MAX_SL_P = 80; // -75% PNL

    uint public maxPosUSDC;
    uint public limitOrdersTimelock;
    bool public isWhitelisted; // Toggle whitelisting

    mapping(address => bool) public whitelistedAddress;

    // Events
    event Whitelist(bool whitelist);

    event NumberUpdated(string name, uint value);
    event AddressUpdated(string name, address a);

    event MarketOrderInitiated(address indexed trader, uint pairIndex, bool open, uint orderId, uint timestamp);

    event LimitOrderInitiated(address indexed trader, uint pairIndex, uint orderId, uint timestamp);
    event LimitOrderSameBlock(address indexed trader, uint pairIndex, uint timestamp);

    event OpenLimitPlaced(address indexed trader, uint pairIndex, uint index, uint timestamp, uint executionFee);

    event OpenLimitUpdated(
        address indexed trader,
        uint pairIndex,
        uint index,
        uint newPrice,
        uint newTp,
        uint newSl,
        uint timestamp
    );
    event OpenLimitCanceled(address indexed trader, uint pairIndex, uint index, uint timestamp);

    event TpUpdated(address indexed trader, uint pairIndex, uint index, uint newTp, uint timestamp);
    event SlUpdated(address indexed trader, uint pairIndex, uint index, uint newSl, uint timestamp);
    event SlUpdateInitiated(
        address indexed trader,
        uint pairIndex,
        uint index,
        uint newSl,
        uint orderId,
        uint timestamp
    );
    event MarginUpdateInitiated(
        address indexed trader,
        uint pairIndex,
        uint index,
        ITradingStorage.updateType _type,
        uint amount,
        uint lossProtectionTier,
        uint timestamp
    );

    function initialize(address _storageT, address _pairInfos) external initializer {
        storageT = ITradingStorage(_storageT);
        pairInfos = IPairInfos(_pairInfos);
        limitOrdersTimelock = 30;
        isWhitelisted = true;
    }

    // Modifiers
    modifier onlyGov() {
        require(msg.sender == storageT.gov(), "GOV_ONLY");
        _;
    }
    modifier onlyWhitelist() {
        if (isWhitelisted) require(whitelistedAddress[msg.sender], "WHITELIST_ONLY");
        _;
    }

    // Manage params
    function setMaxPosUSDC(uint _max) external onlyGov {
        require(_max > 0, "VALUE_0");
        maxPosUSDC = _max;
        emit NumberUpdated("maxPosUSDC", _max);
    }

    function setLimitOrdersTimelock(uint _blocks) external onlyGov {
        require(_blocks > 0, "VALUE_0");
        limitOrdersTimelock = _blocks;
        emit NumberUpdated("limitOrdersTimelock", _blocks);
    }

    function addWhitelist(address _address) external onlyGov {
        require(_address != address(0));
        whitelistedAddress[_address] = true;
        emit AddressUpdated("addWhitelist", _address);
    }

    // Manage state
    function pause() external onlyGov {
        _pause();
    }

    function unpause() external onlyGov {
        _unpause();
    }

    function toggleWhitelist() external onlyGov {
        isWhitelisted = !isWhitelisted;
        emit Whitelist(isWhitelisted);
    }

    ///@dev Add Events
    function updateMargin(
        uint _pairIndex,
        uint _index,
        ITradingStorage.updateType _type,
        uint _amount,
        bytes[] calldata priceUpdateData
    ) external payable onlyWhitelist whenNotPaused {
        IPriceAggregator aggregator = storageT.priceAggregator();
        IPairStorage pairsStored = aggregator.pairsStorage();

        ITradingStorage.Trade memory t = storageT.openTrades(msg.sender, _pairIndex, _index);
        ITradingStorage.TradeInfo memory i = storageT.openTradesInfo(msg.sender, _pairIndex, _index);

        require(!i.beingMarketClosed, "ALREADY_BEING_CLOSED");
        require(t.leverage > 0, "NO_TRADE");

        (t.leverage, t.initialPosToken) = _calculateNewLeverage(
            i.openInterestUSDC,
            t.initialPosToken,
            _type,
            _amount,
            ICallbacks(storageT.callbacks()).chargeRollOverFees(t)
        );
        require(
            t.leverage > 0 &&
                t.leverage >= pairsStored.pairMinLeverage(t.pairIndex) &&
                t.leverage <= pairsStored.pairMaxLeverage(t.pairIndex),
            "LEVERAGE_INCORRECT"
        );
        storageT.updateTrade(t);

        uint orderId = aggregator.getPrice(_pairIndex, IPriceAggregator.OrderType.UPDATE_MARGIN);

        aggregator.storePendingMarginUpdateOrder(
            orderId,
            IPriceAggregator.PendingMarginUpdate(msg.sender, _pairIndex, _index, _type, _amount, i.lossProtection )
        );

        emit MarginUpdateInitiated(msg.sender, _pairIndex, _index, _type, _amount, i.lossProtection, block.timestamp);

        aggregator.fulfill{value: msg.value}(orderId, priceUpdateData);
    }

    function openTrade(
        ITradingStorage.Trade calldata t,
        IExecute.OpenLimitOrderType _type,
        uint _slippageP,
        bytes[] calldata priceUpdateData,
        uint _executionFee // In USDC. Optional for Limit orders
    ) external payable onlyWhitelist whenNotPaused {
        IPriceAggregator aggregator = storageT.priceAggregator();
        IPairStorage pairsStored = aggregator.pairsStorage();

        require(
            storageT.openTradesCount(msg.sender, t.pairIndex) +
                storageT.pendingMarketOpenCount(msg.sender, t.pairIndex) +
                storageT.openLimitOrdersCount(msg.sender, t.pairIndex) <
                storageT.maxTradesPerPair(),
            "MAX_TRADES_PER_PAIR"
        );

        require(storageT.pendingOrderIdsCount(msg.sender) < storageT.maxPendingMarketOrders(), "MAX_PENDING_ORDERS");

        require(t.positionSizeUSDC.mul(t.leverage) >= pairsStored.pairMinLevPosUSDC(t.pairIndex), "BELOW_MIN_POS");

        require(
            t.leverage > 0 &&
                t.leverage >= pairsStored.pairMinLeverage(t.pairIndex) &&
                t.leverage <= pairsStored.pairMaxLeverage(t.pairIndex),
            "LEVERAGE_INCORRECT"
        );

        require(t.tp == 0 || (t.buy ? t.tp > t.openPrice : t.tp < t.openPrice), "WRONG_TP");
        require(t.sl == 0 || (t.buy ? t.sl < t.openPrice : t.sl > t.openPrice), "WRONG_SL");

        storageT.transferUSDC(msg.sender, address(storageT), t.positionSizeUSDC + _executionFee);

        if (_type != IExecute.OpenLimitOrderType.MARKET) {
            uint index = storageT.firstEmptyOpenLimitIndex(msg.sender, t.pairIndex);

            storageT.storeOpenLimitOrder(
                ITradingStorage.OpenLimitOrder(
                    msg.sender,
                    t.pairIndex,
                    index,
                    t.positionSizeUSDC,
                    t.buy,
                    t.leverage,
                    t.tp,
                    t.sl,
                    t.openPrice,
                    t.openPrice,
                    block.number,
                    _executionFee
                )
            );

            aggregator.executions().setOpenLimitOrderType(msg.sender, t.pairIndex, index, _type);

            emit OpenLimitPlaced(msg.sender, t.pairIndex, index, block.timestamp, _executionFee);
        } else {
            uint orderId = aggregator.getPrice(t.pairIndex, IPriceAggregator.OrderType.MARKET_OPEN);

            storageT.storePendingMarketOrder(
                ITradingStorage.PendingMarketOrder(
                    ITradingStorage.Trade(
                        msg.sender,
                        t.pairIndex,
                        0,
                        0,
                        t.positionSizeUSDC,
                        0,
                        t.buy,
                        t.leverage,
                        t.tp,
                        t.sl,
                        0
                    ),
                    0,
                    t.openPrice,
                    _slippageP,
                    0
                ),
                orderId,
                true
            );

            emit MarketOrderInitiated(msg.sender, t.pairIndex, true, orderId, block.timestamp);

            aggregator.fulfill{value: msg.value}(orderId, priceUpdateData);
        }
    }

    function closeTradeMarket(
        uint _pairIndex,
        uint _index,
        uint _amount, // Collateral being closed
        bytes[] calldata priceUpdateData
    ) external payable onlyWhitelist whenNotPaused {
        uint leverage = storageT.openTrades(msg.sender, _pairIndex, _index).leverage;
        bool beingMarketClosed = storageT.openTradesInfo(msg.sender, _pairIndex, _index).beingMarketClosed;

        require(storageT.pendingOrderIdsCount(msg.sender) < storageT.maxPendingMarketOrders(), "MAX_PENDING_ORDERS");
        require(!beingMarketClosed, "ALREADY_BEING_CLOSED");
        require(leverage > 0, "NO_TRADE");

        uint orderId = storageT.priceAggregator().getPrice(_pairIndex, IPriceAggregator.OrderType.MARKET_CLOSE);

        storageT.storePendingMarketOrder(
            ITradingStorage.PendingMarketOrder(
                ITradingStorage.Trade(msg.sender, _pairIndex, _index, _amount, 0, 0, false, 0, 0, 0, 0),
                0,
                0,
                0,
                0
            ),
            orderId,
            false
        );

        emit MarketOrderInitiated(msg.sender, _pairIndex, false, orderId, block.timestamp);

        storageT.priceAggregator().fulfill{value: msg.value}(orderId, priceUpdateData);
    }

    // Manage limit order (OPEN)
    function updateOpenLimitOrder(
        uint _pairIndex,
        uint _index,
        uint _price, // PRECISION
        uint _tp,
        uint _sl
    ) external onlyWhitelist whenNotPaused {
        ITradingStorage.OpenLimitOrder memory o = storageT.getOpenLimitOrder(msg.sender, _pairIndex, _index);
        require(block.number - o.block >= limitOrdersTimelock, "LIMIT_TIMELOCK");

        require(_tp == 0 || (o.buy ? _price < _tp : _price > _tp), "WRONG_TP");
        require(_sl == 0 || (o.buy ? _price > _sl : _price < _sl), "WRONG_SL");

        o.minPrice = _price;
        o.maxPrice = _price;

        o.tp = _tp;
        o.sl = _sl;

        storageT.updateOpenLimitOrder(o);

        emit OpenLimitUpdated(msg.sender, _pairIndex, _index, _price, _tp, _sl, block.timestamp);
    }

    function cancelOpenLimitOrder(uint _pairIndex, uint _index) external onlyWhitelist whenNotPaused {
        ITradingStorage.OpenLimitOrder memory o = storageT.getOpenLimitOrder(msg.sender, _pairIndex, _index);
        require(block.number - o.block >= limitOrdersTimelock, "LIMIT_TIMELOCK");

        storageT.transferUSDC(address(storageT), msg.sender, o.positionSize + o.executionFee);
        storageT.unregisterOpenLimitOrder(msg.sender, _pairIndex, _index);

        emit OpenLimitCanceled(msg.sender, _pairIndex, _index, block.timestamp);
    }

    function updateTpAndSl(
        uint _pairIndex,
        uint _index,
        uint _newSl,
        uint _newTP,
        bytes[] calldata priceUpdateData
    ) external payable onlyWhitelist whenNotPaused {
        _updateTp(_pairIndex, _index, _newTP);
        _updateSl(_pairIndex, _index, _newSl, priceUpdateData);
    }

    // Manage limit order (TP/SL)
    function updateTp(uint _pairIndex, uint _index, uint _newTp) external onlyWhitelist whenNotPaused {
        _updateTp(_pairIndex, _index, _newTp);
    }

    function updateSl(
        uint _pairIndex,
        uint _index,
        uint _newSl,
        bytes[] calldata priceUpdateData
    ) external payable onlyWhitelist whenNotPaused {
        _updateSl(_pairIndex, _index, _newSl, priceUpdateData);
    }

    // Execute limit order
    function executeLimitOrder(
        ITradingStorage.LimitOrder _orderType,
        address _trader,
        uint _pairIndex,
        uint _index,
        bytes[] calldata priceUpdateData
    ) external payable onlyWhitelist whenNotPaused {
        ITradingStorage.Trade memory t;

        if (_orderType == ITradingStorage.LimitOrder.OPEN) {
            require(storageT.hasOpenLimitOrder(_trader, _pairIndex, _index), "NO_LIMIT");
        } else {
            t = storageT.openTrades(_trader, _pairIndex, _index);

            require(t.leverage > 0, "NO_TRADE");
            require(_orderType != ITradingStorage.LimitOrder.SL || t.sl > 0, "NO_SL");

            if (_orderType == ITradingStorage.LimitOrder.LIQ) {
                uint liqPrice = _getTradeLiquidationPrice(t);
                require(t.sl == 0 || (t.buy ? liqPrice > t.sl : liqPrice < t.sl), "HAS_SL");
            }
        }

        IPriceAggregator aggregator = storageT.priceAggregator();
        IExecute executor = aggregator.executions();

        IExecute.TriggeredLimitId memory triggeredLimitId = IExecute.TriggeredLimitId(
            _trader,
            _pairIndex,
            _index,
            _orderType
        );

        if (!executor.triggered(triggeredLimitId) || executor.timedOut(triggeredLimitId)) {
            uint leveragedPosUSDC;

            if (_orderType == ITradingStorage.LimitOrder.OPEN) {
                ITradingStorage.OpenLimitOrder memory l = storageT.getOpenLimitOrder(_trader, _pairIndex, _index);
                leveragedPosUSDC = l.positionSize.mul(l.leverage);

            } else {
                leveragedPosUSDC = t.initialPosToken.mul(t.leverage);
            }

            uint orderId = aggregator.getPrice(
                _pairIndex,
                _orderType == ITradingStorage.LimitOrder.OPEN
                    ? IPriceAggregator.OrderType.LIMIT_OPEN
                    : IPriceAggregator.OrderType.LIMIT_CLOSE
            );

            storageT.storePendingLimitOrder(
                ITradingStorage.PendingLimitOrder(_trader, _pairIndex, _index, _orderType),
                orderId
            );

            executor.storeFirstToTrigger(triggeredLimitId, msg.sender);
            emit LimitOrderInitiated(_trader, _pairIndex, orderId, block.timestamp);

            aggregator.fulfill{value: msg.value}(orderId, priceUpdateData);
        }
    }

    function _getTradeLiquidationPrice(ITradingStorage.Trade memory t) private view returns (uint) {
        return
            pairInfos.getTradeLiquidationPrice(
                t.trader,
                t.pairIndex,
                t.index,
                t.openPrice,
                t.buy,
                t.initialPosToken,
                t.leverage
            );
    }

    function _calculateNewLeverage(
        uint _openInterestUSDC,
        uint _currentCollateral,
        ITradingStorage.updateType _type,
        uint _newAmount,
        uint _fees
    ) internal pure returns (uint newLeverage, uint newAmount) {
        if (_type == ITradingStorage.updateType.DEPOSIT) {
            newAmount = _currentCollateral + _newAmount - _fees;
            newLeverage = (_openInterestUSDC * PRECISION) / (newAmount);
        } else if (_type == ITradingStorage.updateType.WITHDRAW) {
            newAmount = _currentCollateral - _newAmount - _fees;
            newLeverage = (_openInterestUSDC * PRECISION) / (newAmount);
        }
    }

    function _updateTp(uint _pairIndex, uint _index, uint _newTp) internal {
        uint leverage = storageT.openTrades(msg.sender, _pairIndex, _index).leverage;
        uint tpLastUpdated = storageT.openTradesInfo(msg.sender, _pairIndex, _index).tpLastUpdated;

        require(leverage > 0, "NO_TRADE");
        require(block.number - tpLastUpdated >= limitOrdersTimelock, "LIMIT_TIMELOCK");

        storageT.updateTp(msg.sender, _pairIndex, _index, _newTp);

        emit TpUpdated(msg.sender, _pairIndex, _index, _newTp, block.timestamp);
    }

    function _updateSl(uint _pairIndex, uint _index, uint _newSl, bytes[] calldata priceUpdateData) internal {
        ITradingStorage.Trade memory t = storageT.openTrades(msg.sender, _pairIndex, _index);
        uint slLastUpdated = storageT.openTradesInfo(msg.sender, _pairIndex, _index).slLastUpdated;

        require(t.leverage > 0, "NO_TRADE");

        uint maxSlDist = ((t.openPrice * MAX_SL_P) / 100).div(t.leverage);
        require(
            _newSl == 0 || (t.buy ? _newSl >= t.openPrice - maxSlDist : _newSl <= t.openPrice + maxSlDist),
            "SL_TOO_BIG"
        );

        require(block.number - slLastUpdated >= limitOrdersTimelock, "LIMIT_TIMELOCK");

        IPriceAggregator aggregator = storageT.priceAggregator();

        if (_newSl == 0 || !aggregator.pairsStorage().guaranteedSlEnabled(_pairIndex)) {
            storageT.updateSl(msg.sender, _pairIndex, _index, _newSl);
            emit SlUpdated(msg.sender, _pairIndex, _index, _newSl, block.timestamp);
        } else {
            uint levPosUSDC = t.initialPosToken.mul(t.leverage);

            t.initialPosToken -= storageT.handleDevGovFees(t.trader, t.pairIndex, levPosUSDC / 2, false, true, t.buy);

            storageT.updateTrade(t);

            uint orderId = aggregator.getPrice(_pairIndex, IPriceAggregator.OrderType.UPDATE_SL);

            aggregator.storePendingSlOrder(
                orderId,
                IPriceAggregator.PendingSl(msg.sender, _pairIndex, _index, t.openPrice, t.buy, _newSl)
            );

            emit SlUpdateInitiated(msg.sender, _pairIndex, _index, _newSl, orderId, block.timestamp);

            aggregator.fulfill{value: msg.value}(orderId, priceUpdateData);
        }
    }
}
