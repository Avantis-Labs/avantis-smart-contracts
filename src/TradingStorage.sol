// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "./interfaces/IToken.sol";
import "./interfaces/IPriceAggregator.sol";
import "./interfaces/IPausable.sol";
import "./interfaces/ICallbacks.sol";
import "./interfaces/IVaultManager.sol";
import "./interfaces/ITradingStorage.sol";
import "./interfaces/IReferral.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PositionMath} from "./library/PositionMath.sol";

contract TradingStorage is Initializable, ITradingStorage {
    using PositionMath for uint;

    IPriceAggregator public override priceAggregator;
    IPausable public _trading;
    ICallbacks public _callbacks;
    IToken public override USDC;
    IVaultManager public override vaultManager;
    IReferral public referral;

    uint private constant PRECISION = 1e10;

    uint public override maxTradesPerPair;
    uint public override maxTradesPerBlock;
    uint public override maxPendingMarketOrders;
    uint public override defaultLeverageUnlocked;
    uint public override totalOI;
    uint public tvlCap;

    address public override gov;
    address public override dev;

    uint public devFeesUSDC;
    uint public govFeesUSDC;

    mapping(address => Trader) private _traders;

    // Trades mappings
    mapping(address => mapping(uint => mapping(uint => Trade))) private _openTrades;
    mapping(address => mapping(uint => mapping(uint => TradeInfo))) private _openTradesInfo;
    mapping(address => mapping(uint => uint)) private _openTradesCount;
    mapping(address => uint) private _walletOI;

    // Limit orders mappings
    mapping(address => mapping(uint => mapping(uint => uint))) public openLimitOrderIds;
    mapping(address => mapping(uint => uint)) public override openLimitOrdersCount;
    OpenLimitOrder[] public openLimitOrders;

    // Pending orders mappings
    mapping(uint => PendingMarketOrder) private _reqID_pendingMarketOrder;
    mapping(uint => PendingLimitOrder) private _reqID_pendingLimitOrder;
    mapping(address => uint[]) public pendingOrderIds;
    mapping(address => mapping(uint => uint)) public override pendingMarketOpenCount;
    mapping(address => mapping(uint => uint)) public override pendingMarketCloseCount;

    // List of open trades & limit orders
    mapping(uint => address[]) public pairTraders;
    mapping(address => mapping(uint => uint)) public pairTradersId;

    // Current and max open interests for each pair
    mapping(uint => uint[3]) public override openInterestUSDC;

    // Restrictions & Timelocks
    mapping(uint => uint) public override tradesPerBlock;

    // List of allowed contracts => can update storage + mint/burn tokens
    mapping(address => bool) public isTradingContract;
    mapping(address => uint) public rebates;

    function initialize() external initializer {
        gov = msg.sender;
        dev = msg.sender;
        maxTradesPerPair = 5;
        maxTradesPerBlock = 5;
        maxPendingMarketOrders = 5;
        defaultLeverageUnlocked = 50;
        tvlCap = 90 * PRECISION;
    }

    // Modifiers
    modifier onlyGov() {
        require(msg.sender == gov);
        _;
    }

    modifier onlyTrading() {
        require(isTradingContract[msg.sender]);
        _;
    }

    // Manage addresses
    function setUSDC(address _token) external onlyGov {
        require(_token != address(0));
        USDC = IToken(_token);
        emit AddressUpdated("USDC", _token);
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0));
        gov = _gov;
        emit AddressUpdated("gov", _gov);
    }

    function setDev(address _dev) external onlyGov {
        require(_dev != address(0));
        dev = _dev;
        emit AddressUpdated("dev", _dev);
    }

    function addTradingContract(address __trading) external onlyGov {
        require(__trading != address(0));
        isTradingContract[__trading] = true;
        emit TradingContractAdded(__trading);
    }

    function removeTradingContract(address __trading) external onlyGov {
        require(__trading != address(0));
        isTradingContract[__trading] = false;
        emit TradingContractRemoved(__trading);
    }

    function setPriceAggregator(address _aggregator) external onlyGov {
        require(_aggregator != address(0));
        priceAggregator = IPriceAggregator(_aggregator);
        emit AddressUpdated("priceAggregator", _aggregator);
    }

    function setVaultManager(address _vaultManager) external onlyGov {
        require(_vaultManager != address(0));
        vaultManager = IVaultManager(_vaultManager);
        emit AddressUpdated("vaultManager", _vaultManager);
    }

    function setReferral(address _refferal) external onlyGov {
        require(_refferal != address(0));
        referral = IReferral(_refferal);
        emit AddressUpdated("Referral", _refferal);
    }

    function setTrading(address __trading) external onlyGov {
        require(__trading != address(0));
        _trading = IPausable(__trading);
        emit AddressUpdated("trading", __trading);
    }

    function setCallbacks(address __callbacks) external onlyGov {
        require(__callbacks != address(0));
        _callbacks = ICallbacks(__callbacks);
        emit AddressUpdated("callbacks", __callbacks);
    }

    function setMaxTradesPerBlock(uint _maxTradesPerBlock) external onlyGov {
        require(_maxTradesPerBlock > 0);
        maxTradesPerBlock = _maxTradesPerBlock;
        emit NumberUpdated("maxTradesPerBlock", _maxTradesPerBlock);
    }

    function setMaxTradesPerPair(uint _maxTradesPerPair) external onlyGov {
        require(_maxTradesPerPair > 0);
        maxTradesPerPair = _maxTradesPerPair;
        emit NumberUpdated("maxTradesPerPair", _maxTradesPerPair);
    }

    function setMaxPendingMarketOrders(uint _maxPendingMarketOrders) external onlyGov {
        require(_maxPendingMarketOrders > 0);
        maxPendingMarketOrders = _maxPendingMarketOrders;
        emit NumberUpdated("maxPendingMarketOrders", _maxPendingMarketOrders);
    }

    function setMaxOpenInterestUSDC(uint _pairIndex, uint _newMaxOpenInterest) external onlyGov {
        // Can set max open interest to 0 to pause _trading on this pair only
        openInterestUSDC[_pairIndex][2] = _newMaxOpenInterest;
        emit NumberUpdatedPair("maxOpenInterestUSDC", _pairIndex, _newMaxOpenInterest);
    }

    function setTvlCap(uint _newCap) external onlyGov {
        // Can set max open interest to 0 to pause _trading on this pair only
        tvlCap = _newCap;
        emit NumberUpdated("tvlCap", _newCap);
    }

    function maxOpenInterest() external view override returns (uint) {
        return (vaultManager.currentBalanceUSDC() * tvlCap) / PRECISION / 100;
    }

    function traders(address _trader) external view override returns (Trader memory) {
        return _traders[_trader];
    }

    function openTrades(address _trader, uint _pairIndex, uint _index) external view override returns (Trade memory) {
        return _openTrades[_trader][_pairIndex][_index];
    }

    function openTradesInfo(
        address _trader,
        uint _pairIndex,
        uint _index
    ) external view override returns (TradeInfo memory) {
        return _openTradesInfo[_trader][_pairIndex][_index];
    }

    function reqID_pendingMarketOrder(uint orderId) external view override returns (PendingMarketOrder memory) {
        return _reqID_pendingMarketOrder[orderId];
    }

    function reqID_pendingLimitOrder(uint orderId) external view override returns (PendingLimitOrder memory) {
        return _reqID_pendingLimitOrder[orderId];
    }

    function openTradesCount(address _trader, uint _pairIndex) external view override returns (uint) {
        return _openTradesCount[_trader][_pairIndex];
    }

    function callbacks() external view override returns (address) {
        return address(_callbacks);
    }

    function trading() external view override returns (address) {
        return address(_trading);
    }

    // Manage stored trades
    function storeTrade(Trade memory _trade, TradeInfo memory _tradeInfo) external override onlyTrading {
        _trade.index = firstEmptyTradeIndex(_trade.trader, _trade.pairIndex);
        _openTrades[_trade.trader][_trade.pairIndex][_trade.index] = _trade;

        _openTradesCount[_trade.trader][_trade.pairIndex]++;
        tradesPerBlock[block.number]++;

        if (_openTradesCount[_trade.trader][_trade.pairIndex] == 1) {
            pairTradersId[_trade.trader][_trade.pairIndex] = pairTraders[_trade.pairIndex].length;
            pairTraders[_trade.pairIndex].push(_trade.trader);
        }

        _tradeInfo.beingMarketClosed = false;
        _openTradesInfo[_trade.trader][_trade.pairIndex][_trade.index] = _tradeInfo;

        updateOpenInterestUSDC(_trade.trader, _trade.pairIndex, _tradeInfo.openInterestUSDC, true, _trade.buy);
    }

    function registerPartialTrade(
        address trader,
        uint pairIndex,
        uint index,
        uint _amountReduced
    ) external override onlyTrading {
        Trade storage t = _openTrades[trader][pairIndex][index];
        TradeInfo storage i = _openTradesInfo[trader][pairIndex][index];
        if (t.leverage == 0) {
            return;
        }
        t.initialPosToken -= _amountReduced;
        i.openInterestUSDC -= _amountReduced.mul(t.leverage);
        updateOpenInterestUSDC(trader, pairIndex, i.openInterestUSDC, false, t.buy);
        tradesPerBlock[block.number]++;
    }

    function unregisterTrade(address trader, uint pairIndex, uint index) external override onlyTrading {
        Trade storage t = _openTrades[trader][pairIndex][index];
        TradeInfo storage i = _openTradesInfo[trader][pairIndex][index];
        if (t.leverage == 0) {
            return;
        }
        updateOpenInterestUSDC(trader, pairIndex, i.openInterestUSDC, false, t.buy);

        if (_openTradesCount[trader][pairIndex] == 1) {
            uint _pairTradersId = pairTradersId[trader][pairIndex];
            address[] storage p = pairTraders[pairIndex];

            p[_pairTradersId] = p[p.length - 1];
            pairTradersId[p[_pairTradersId]][pairIndex] = _pairTradersId;

            delete pairTradersId[trader][pairIndex];
            p.pop();
        }

        delete _openTrades[trader][pairIndex][index];
        delete _openTradesInfo[trader][pairIndex][index];

        _openTradesCount[trader][pairIndex]--;
        tradesPerBlock[block.number]++;
    }

    // Manage pending market orders
    function storePendingMarketOrder(
        PendingMarketOrder memory _order,
        uint _id,
        bool _open
    ) external override onlyTrading {
        pendingOrderIds[_order.trade.trader].push(_id);

        _reqID_pendingMarketOrder[_id] = _order;
        _reqID_pendingMarketOrder[_id].block = block.number;

        if (_open) {
            pendingMarketOpenCount[_order.trade.trader][_order.trade.pairIndex]++;
        } else {
            pendingMarketCloseCount[_order.trade.trader][_order.trade.pairIndex]++;
            _openTradesInfo[_order.trade.trader][_order.trade.pairIndex][_order.trade.index].beingMarketClosed = true;
        }
    }

    function unregisterPendingMarketOrder(uint _id, bool _open) external override onlyTrading {
        PendingMarketOrder memory _order = _reqID_pendingMarketOrder[_id];
        uint[] storage orderIds = pendingOrderIds[_order.trade.trader];

        for (uint i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == _id) {
                if (_open) {
                    pendingMarketOpenCount[_order.trade.trader][_order.trade.pairIndex]--;
                } else {
                    pendingMarketCloseCount[_order.trade.trader][_order.trade.pairIndex]--;
                    _openTradesInfo[_order.trade.trader][_order.trade.pairIndex][_order.trade.index]
                        .beingMarketClosed = false;
                }

                orderIds[i] = orderIds[orderIds.length - 1];
                orderIds.pop();

                delete _reqID_pendingMarketOrder[_id];
                return;
            }
        }
    }

    // Manage Limit orders
    function storePendingLimitOrder(PendingLimitOrder memory _limitOrder, uint _orderId) external override onlyTrading {
        _reqID_pendingLimitOrder[_orderId] = _limitOrder;
    }

    function unregisterPendingLimitOrder(uint _order) external override onlyTrading {
        delete _reqID_pendingLimitOrder[_order];
    }

    // Manage open interest
    function updateOpenInterestUSDC(
        address _trader,
        uint _pairIndex,
        uint _leveragedPosUSDC,
        bool _open,
        bool _long
    ) private {
        uint index = _long ? 0 : 1;
        uint[3] storage o = openInterestUSDC[_pairIndex];

        // Fix beacuse of Dust during partial close
        if (!_open) _leveragedPosUSDC = _leveragedPosUSDC > o[index] ? o[index] : _leveragedPosUSDC;

        o[index] = _open ? o[index] + _leveragedPosUSDC : o[index] - _leveragedPosUSDC;
        totalOI = _open ? totalOI + _leveragedPosUSDC : totalOI - _leveragedPosUSDC;
        _walletOI[_trader] = _open ? _walletOI[_trader] + _leveragedPosUSDC : _walletOI[_trader] - _leveragedPosUSDC;
    }

    function storeOpenLimitOrder(OpenLimitOrder memory o) external override onlyTrading {
        o.index = firstEmptyOpenLimitIndex(o.trader, o.pairIndex);
        o.block = block.number;
        openLimitOrders.push(o);
        openLimitOrderIds[o.trader][o.pairIndex][o.index] = openLimitOrders.length - 1;
        openLimitOrdersCount[o.trader][o.pairIndex]++;
    }

    function updateOpenLimitOrder(OpenLimitOrder calldata _o) external override onlyTrading {
        if (!hasOpenLimitOrder(_o.trader, _o.pairIndex, _o.index)) {
            return;
        }
        OpenLimitOrder storage o = openLimitOrders[openLimitOrderIds[_o.trader][_o.pairIndex][_o.index]];
        o.positionSize = _o.positionSize;
        o.buy = _o.buy;
        o.leverage = _o.leverage;
        o.tp = _o.tp;
        o.sl = _o.sl;
        o.minPrice = _o.minPrice;
        o.maxPrice = _o.maxPrice;
        o.block = block.number;
    }

    function unregisterOpenLimitOrder(address _trader, uint _pairIndex, uint _index) external override onlyTrading {
        if (!hasOpenLimitOrder(_trader, _pairIndex, _index)) {
            return;
        }

        // Copy last order to deleted order => update id of this limit order
        uint id = openLimitOrderIds[_trader][_pairIndex][_index];
        openLimitOrders[id] = openLimitOrders[openLimitOrders.length - 1];
        openLimitOrderIds[openLimitOrders[id].trader][openLimitOrders[id].pairIndex][openLimitOrders[id].index] = id;

        // Remove
        delete openLimitOrderIds[_trader][_pairIndex][_index];
        openLimitOrders.pop();

        openLimitOrdersCount[_trader][_pairIndex]--;
    }

    // Manage open trade
    function updateSl(address _trader, uint _pairIndex, uint _index, uint _newSl) external override onlyTrading {
        Trade storage t = _openTrades[_trader][_pairIndex][_index];
        TradeInfo storage i = _openTradesInfo[_trader][_pairIndex][_index];
        if (t.leverage == 0) {
            return;
        }
        t.sl = _newSl;
        i.slLastUpdated = block.number;
    }

    function updateTp(address _trader, uint _pairIndex, uint _index, uint _newTp) external override onlyTrading {
        Trade storage t = _openTrades[_trader][_pairIndex][_index];
        TradeInfo storage i = _openTradesInfo[_trader][_pairIndex][_index];
        if (t.leverage == 0) {
            return;
        }
        t.tp = _newTp;
        i.tpLastUpdated = block.number;
    }

    function updateTrade(Trade memory _t) external override onlyTrading {
        // useful when partial adding/closing
        Trade storage t = _openTrades[_t.trader][_t.pairIndex][_t.index];
        if (t.leverage == 0) {
            return;
        }
        t.initialPosToken = _t.initialPosToken;
        t.positionSizeUSDC = _t.positionSizeUSDC;
        t.openPrice = _t.openPrice;
        t.leverage = _t.leverage;
    }

    function setLeverageUnlocked(address _trader, uint _newLeverage) external override onlyTrading {
        _traders[_trader].leverageUnlocked = _newLeverage;
    }

    function applyReferralOpen(
        address _trader,
        uint _fees,
        uint _leveragedPosition
    ) public override onlyTrading returns (uint) {
        (uint traderDiscount, address referrer, uint referrerRebate) = referral.traderReferralDiscount(_trader, _fees);

        if (referrer != address(0)) {
            rebates[referrer] += referrerRebate;
            _emitTradeReferral(_trader, referrer, _leveragedPosition, _fees - traderDiscount, traderDiscount, referrerRebate);
            return _fees - traderDiscount - referrerRebate;
        }
        return _fees;
    }

    function applyReferralClose(
        address _trader,
        uint _fees,
        uint _leveragedPosition
    ) public override onlyTrading returns (uint, uint) {
        (uint traderDiscount, address referrer, uint referrerRebate) = referral.traderReferralDiscount(_trader, _fees);

        if (referrer != address(0)) {
            rebates[referrer] += referrerRebate;
            _emitTradeReferral(_trader, referrer, _leveragedPosition, _fees - traderDiscount, traderDiscount, referrerRebate);
            return ((_fees - traderDiscount), referrerRebate);
        }
        return (_fees, referrerRebate);
    }

    // Manage dev & gov fees
    function handleDevGovFees(
        address _trader,
        uint _pairIndex,
        uint _leveragedPositionSize,
        bool _USDC,
        bool _fullFee,
        bool _buy
    ) external override onlyTrading returns (uint feeAfterRebate) {
        uint fee = (_leveragedPositionSize * priceAggregator.openFeeP(_pairIndex, _leveragedPositionSize, _buy)) /
            PRECISION /
            100;

        if (!_fullFee) {
            fee /= 2;
        }

        feeAfterRebate = applyReferralOpen(_trader, fee, _leveragedPositionSize);

        uint vaultAllocation = (feeAfterRebate * (100 - _callbacks.vaultFeeP())) / 100;
        uint govFees = (feeAfterRebate * _callbacks.vaultFeeP()) / 100 / 2;

        if (_USDC) USDC.transfer(address(vaultManager), vaultAllocation);

        vaultManager.allocateRewards(vaultAllocation);
        govFeesUSDC += govFees;
        devFeesUSDC += feeAfterRebate - vaultAllocation - govFees;
    }

    function claimFees() external onlyGov {
        USDC.transfer(gov, govFeesUSDC);
        USDC.transfer(dev, devFeesUSDC);

        devFeesUSDC = 0;
        govFeesUSDC = 0;
    }

    /**
     * Referrer Claims the rebate
     */
    function claimRebate() external {
        USDC.transfer(msg.sender, rebates[msg.sender]);
        rebates[msg.sender] = 0;
    }

    // Manage tokens
    function transferUSDC(address _from, address _to, uint _amount) external override onlyTrading {
        if (_from == address(this)) {
            USDC.transfer(_to, _amount);
        } else {
            USDC.transferFrom(_from, _to, _amount);
        }
    }

    // View utils functions
    function firstEmptyTradeIndex(address trader, uint pairIndex) public view override returns (uint index) {
        for (uint i = 0; i < maxTradesPerPair; i++) {
            if (_openTrades[trader][pairIndex][i].leverage == 0) {
                index = i;
                break;
            }
        }
    }

    function firstEmptyOpenLimitIndex(address trader, uint pairIndex) public view override returns (uint index) {
        for (uint i = 0; i < maxTradesPerPair; i++) {
            if (!hasOpenLimitOrder(trader, pairIndex, i)) {
                index = i;
                break;
            }
        }
    }

    function hasOpenLimitOrder(address trader, uint pairIndex, uint index) public view override returns (bool) {
        if (openLimitOrders.length == 0) {
            return false;
        }
        OpenLimitOrder storage o = openLimitOrders[openLimitOrderIds[trader][pairIndex][index]];
        return o.trader == trader && o.pairIndex == pairIndex && o.index == index;
    }

    function getLeverageUnlocked(address _trader) external view override returns (uint) {
        return _traders[_trader].leverageUnlocked;
    }

    function pairTradersArray(uint _pairIndex) external view returns (address[] memory) {
        return pairTraders[_pairIndex];
    }

    function getPendingOrderIds(address _trader) external view override returns (uint[] memory) {
        return pendingOrderIds[_trader];
    }

    function pendingOrderIdsCount(address _trader) external view override returns (uint) {
        return pendingOrderIds[_trader].length;
    }

    function pairOI(uint _pairIndex) external view override returns (uint) {
        return openInterestUSDC[_pairIndex][0] + openInterestUSDC[_pairIndex][1];
    }

    function walletOI(address _trader) external view override returns (uint) {
        return _walletOI[_trader];
    }

    function getOpenLimitOrder(
        address _trader,
        uint _pairIndex,
        uint _index
    ) external view override returns (OpenLimitOrder memory) {
        require(hasOpenLimitOrder(_trader, _pairIndex, _index));
        return openLimitOrders[openLimitOrderIds[_trader][_pairIndex][_index]];
    }

    function getOpenLimitOrders() external view returns (OpenLimitOrder[] memory) {
        return openLimitOrders;
    }

    function _emitTradeReferral(address _trader, address _referrer, uint _size, uint _fees, uint _discount, uint _rebate) internal {
        emit TradeReferred(_trader, _referrer, _size, _fees, _discount, _rebate);
    }
}
