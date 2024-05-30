// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "./interfaces/ITradingStorage.sol";
import "./interfaces/IPairInfos.sol";
import "./interfaces/ICallbacks.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {PositionMath} from "./library/PositionMath.sol";

contract TradingCallbacks is Initializable, ICallbacks {
    using PositionMath for uint;

    ITradingStorage storageT;
    IPairInfos pairInfos;

    uint private constant PRECISION = 1e10;
    uint private constant MAX_SL_P = 80;
    uint private constant MAX_GAIN_P = 900;
    uint public override vaultFeeP;

    uint public liqFeeP;
    uint public liqTotalFeeP;
    uint private constant WITHDRAW_THRESHOLD_P = 80;

    function initialize(address _storageT, address _pairInfos) external initializer {
        storageT = ITradingStorage(_storageT);
        pairInfos = IPairInfos(_pairInfos);
        vaultFeeP = 20;
        liqFeeP = 5;
        liqTotalFeeP = 10;
    }

    // Modifiers
    modifier onlyGov() {
        require(msg.sender == storageT.gov(), "GOV_ONLY");
        _;
    }

    modifier onlyPriceAggregator() {
        require(msg.sender == address(storageT.priceAggregator()), "AGGREGATOR_ONLY");
        _;
    }

    function updateMarginCallback(
        AggregatorAnswer memory a
    ) external override onlyPriceAggregator {
        IPriceAggregator aggregator = storageT.priceAggregator();
        IPriceAggregator.PendingMarginUpdate memory o = aggregator.pendingMarginUpdateOrders(a.orderId);
        ITradingStorage.Trade memory _trade = storageT.openTrades(o.trader, o.pairIndex, o.index);
        
        if (o._type == ITradingStorage.updateType.DEPOSIT) {
            //Route USDC to Vault Mananger
            storageT.transferUSDC(_trade.trader, address(storageT), o.amount);
            storageT.vaultManager().receiveUSDCFromTrader(_trade.trader, o.amount, 0);
        } else if (o._type == ITradingStorage.updateType.WITHDRAW) {
            {
                int profitP = currentPercentProfit(_trade.openPrice, a.price, _trade.buy, _trade.leverage);
                int pnl = (int(_trade.initialPosToken) * profitP) / int(PRECISION) / 100;
                if (pnl < 0) {
                    pnl = (pnl * int(aggregator.pairsStorage().lossProtectionMultiplier(_trade.pairIndex, o.tier))) / 100;
                }
                require((int(_trade.initialPosToken) + pnl) > (int(_trade.initialPosToken) * int(100 - WITHDRAW_THRESHOLD_P)) / 100, 
                            "WITHDRAW_THRES_BREACHED");
            }
            storageT.vaultManager().sendUSDCToTrader(_trade.trader, o.amount);
        }
        aggregator.unregisterPendingMarginUpdateOrder(a.orderId);
    }

    function chargeRollOverFees(ITradingStorage.Trade memory _trade) external override returns (uint) {
        require(msg.sender == address(storageT.trading()), "TRADING_ONLY");
        uint marginFees = pairInfos.getTradeRolloverFee(
            _trade.trader,
            _trade.pairIndex,
            _trade.index,
            _trade.buy,
            _trade.initialPosToken,
            _trade.leverage
        );
        // Margin Fees can be zero in case of very low utilization/Last update time being close
        if (marginFees != 0) storageT.vaultManager().allocateRewards(marginFees);
        pairInfos.storeTradeInitialAccFees(_trade.trader, _trade.pairIndex, _trade.index, _trade.buy);

        return marginFees;
    }

    // Callbacks
    function openTradeMarketCallback(AggregatorAnswer memory a) external override onlyPriceAggregator {
        ITradingStorage.PendingMarketOrder memory o = storageT.reqID_pendingMarketOrder(a.orderId);
        if (o.block == 0) {
            return;
        }

        ITradingStorage.Trade memory t = o.trade;
        IPriceAggregator aggregator = storageT.priceAggregator();
        IPairStorage pairsStored = aggregator.pairsStorage();

        // crypto only
        if (pairsStored.pairGroupIndex(t.pairIndex) == 0) {
            (, uint priceAfterImpact) = pairInfos.getTradePriceImpact(
                marketExecutionPrice(a.price, a.spreadP, t.buy),
                t.pairIndex,
                t.buy,
                t.positionSizeUSDC.mul(t.leverage)
            );

            t.openPrice = priceAfterImpact;
        } else {
            t.openPrice = marketExecutionPrice(a.price, a.spreadP, t.buy);
        }

        uint maxSlippage = (o.wantedPrice * o.slippageP) / 100 / PRECISION;

        if (
            a.price == 0 ||
            (t.buy ? t.openPrice > o.wantedPrice + maxSlippage : t.openPrice < o.wantedPrice - maxSlippage) ||
            (t.tp > 0 && (t.buy ? t.openPrice >= t.tp : t.openPrice <= t.tp)) ||
            (t.sl > 0 && (t.buy ? t.openPrice <= t.sl : t.openPrice >= t.sl)) ||
            !withinExposureLimits(t.trader, t.pairIndex, t.positionSizeUSDC.mul(t.leverage))
        ) {
            /// Market order is cancelled and fees is deducted.
            storageT.transferUSDC(
                address(storageT),
                t.trader,
                t.positionSizeUSDC -
                    storageT.handleDevGovFees(
                        t.trader,
                        t.pairIndex,
                        t.positionSizeUSDC.mul(t.leverage),
                        true,
                        true,
                        t.buy
                    )
            );

            emit MarketOpenCanceled(a.orderId, t.trader, t.pairIndex, block.timestamp);
        } else {
            ITradingStorage.Trade memory finalTrade = registerTrade(t);

            emit MarketExecuted(
                a.orderId,
                finalTrade,
                true,
                finalTrade.openPrice,
                finalTrade.initialPosToken,
                0,
                0,
                block.timestamp
            );
        }

        storageT.unregisterPendingMarketOrder(a.orderId, true);
    }

    function closeTradeMarketCallback(AggregatorAnswer memory a) external override onlyPriceAggregator {
        ITradingStorage.PendingMarketOrder memory o = storageT.reqID_pendingMarketOrder(a.orderId);
        if (o.block == 0) {
            return;
        }

        ITradingStorage.Trade memory t = storageT.openTrades(o.trade.trader, o.trade.pairIndex, o.trade.index);

        if (t.leverage > 0) {
            ITradingStorage.TradeInfo memory i = storageT.openTradesInfo(t.trader, t.pairIndex, t.index);
            IPriceAggregator aggregator = storageT.priceAggregator();

            uint levPosToken = o.trade.initialPosToken.mul(t.leverage);

            if (a.price == 0) {
                uint feeToken = storageT.handleDevGovFees(t.trader, t.pairIndex, levPosToken, false, true, t.buy);

                if (t.initialPosToken > feeToken) {
                    t.initialPosToken -= feeToken;
                    storageT.updateTrade(t);
                } else {
                    unregisterTrade(t, -100, 0, i.openInterestUSDC.div(t.leverage), 0, 0, i.lossProtection);
                }

                emit MarketCloseCanceled(a.orderId, t.trader, t.pairIndex, t.index, block.timestamp);
            } else {
                Values memory v;
                v.profitP = currentPercentProfit(t.openPrice, a.price, t.buy, t.leverage);
                v.posUSDC = o.trade.initialPosToken;

                uint USDCSentToTrader = unregisterTrade(
                    t,
                    v.profitP,
                    v.posUSDC,
                    v.posUSDC,
                    0,
                    (levPosToken * aggregator.pairsStorage().pairCloseFeeP(t.pairIndex)) / 100 / PRECISION,
                    i.lossProtection
                );

                emit MarketExecuted(
                    a.orderId,
                    t,
                    false,
                    a.price,
                    v.posUSDC,
                    v.profitP,
                    USDCSentToTrader,
                    block.timestamp
                );
            }
        }

        storageT.unregisterPendingMarketOrder(a.orderId, false);
    }

    function executeLimitOpenOrderCallback(AggregatorAnswer memory a) external override onlyPriceAggregator {
        ITradingStorage.PendingLimitOrder memory n = storageT.reqID_pendingLimitOrder(a.orderId);
        IExecute executor = storageT.priceAggregator().executions();

        if (a.price != 0 && storageT.hasOpenLimitOrder(n.trader, n.pairIndex, n.index)) {
            ITradingStorage.OpenLimitOrder memory o = storageT.getOpenLimitOrder(n.trader, n.pairIndex, n.index);
            IExecute.OpenLimitOrderType t = executor.openLimitOrderTypes(n.trader, n.pairIndex, n.index);

            IPriceAggregator aggregator = storageT.priceAggregator();
            IPairStorage pairsStored = aggregator.pairsStorage();

            if (pairsStored.pairGroupIndex(o.pairIndex) == 0) {
                // crypto only
                (, uint priceAfterImpact) = pairInfos.getTradePriceImpact(
                    marketExecutionPrice(a.price, a.spreadP, o.buy),
                    o.pairIndex,
                    o.buy,
                    o.positionSize.mul(o.leverage)
                );

                a.price = priceAfterImpact;
            } else {
                a.price = marketExecutionPrice(a.price, a.spreadP, o.buy);
            }

            if (
                t == IExecute.OpenLimitOrderType.MARKET
                    ? (a.price >= o.minPrice && a.price <= o.maxPrice)
                    : (
                        t == IExecute.OpenLimitOrderType.REVERSAL
                            ? (o.buy ? a.price >= o.maxPrice : a.price <= o.minPrice)
                            : (o.buy ? a.price <= o.maxPrice : a.price >= o.minPrice)
                    ) && withinExposureLimits(o.trader, o.pairIndex, o.positionSize.mul(o.leverage))
            ) {
                ITradingStorage.Trade memory finalTrade = registerTrade(
                    ITradingStorage.Trade(
                        o.trader,
                        o.pairIndex,
                        0,
                        0,
                        o.positionSize,
                        a.price,
                        o.buy,
                        o.leverage,
                        o.tp,
                        o.sl,
                        0
                    )
                );

                if (o.executionFee > 0) {
                    storageT.transferUSDC(address(storageT), address(storageT.vaultManager()), o.executionFee);

                    executor.distributeReward(
                        IExecute.TriggeredLimitId(o.trader, o.pairIndex, o.index, ITradingStorage.LimitOrder.OPEN),
                        o.executionFee
                    );
                }

                storageT.unregisterOpenLimitOrder(o.trader, o.pairIndex, o.index);

                emit LimitExecuted(
                    a.orderId,
                    n.index,
                    finalTrade,
                    ITradingStorage.LimitOrder.OPEN,
                    finalTrade.openPrice,
                    finalTrade.initialPosToken,
                    0,
                    0,
                    block.timestamp
                );
            }
        }

        executor.unregisterTrigger(IExecute.TriggeredLimitId(n.trader, n.pairIndex, n.index, n.orderType));
        storageT.unregisterPendingLimitOrder(a.orderId);
    }

    function executeLimitCloseOrderCallback(AggregatorAnswer memory a) external override onlyPriceAggregator {
        ITradingStorage.PendingLimitOrder memory o = storageT.reqID_pendingLimitOrder(a.orderId);
        ITradingStorage.Trade memory t = storageT.openTrades(o.trader, o.pairIndex, o.index);

        IPriceAggregator aggregator = storageT.priceAggregator();
        IExecute executor = aggregator.executions();

        if (a.price != 0 && t.leverage > 0) {
            ITradingStorage.TradeInfo memory i = storageT.openTradesInfo(t.trader, t.pairIndex, t.index);
            Values memory v;

            v.price = aggregator.pairsStorage().guaranteedSlEnabled(t.pairIndex)
                ? o.orderType == ITradingStorage.LimitOrder.TP ? t.tp : o.orderType == ITradingStorage.LimitOrder.SL
                    ? t.sl
                    : a.price
                : a.price;

            v.profitP = currentPercentProfit(t.openPrice, v.price, t.buy, t.leverage);

            v.posToken = t.initialPosToken;
            v.posUSDC = t.initialPosToken;

            if (o.orderType == ITradingStorage.LimitOrder.LIQ) {
                uint liqPrice = pairInfos.getTradeLiquidationPrice(
                    t.trader,
                    t.pairIndex,
                    t.index,
                    t.openPrice,
                    t.buy,
                    v.posUSDC,
                    t.leverage
                );
                v.reward = (t.buy ? a.price <= liqPrice : a.price >= liqPrice) ? (v.posToken * liqFeeP) / 100 : 0;
            } else {
                v.reward = (o.orderType == ITradingStorage.LimitOrder.TP &&
                    t.tp > 0 &&
                    (t.buy ? a.price >= t.tp : a.price <= t.tp)) ||
                    (o.orderType == ITradingStorage.LimitOrder.SL &&
                        t.sl > 0 &&
                        (t.buy ? a.price <= t.sl : a.price >= t.sl))
                    ? (v.posToken.mul(t.leverage) * aggregator.pairsStorage().pairLimitOrderFeeP(t.pairIndex)) /
                        100 /
                        PRECISION
                    : 0;
            }

            if (o.orderType == ITradingStorage.LimitOrder.LIQ && v.reward > 0) {
                uint USDCSentToTrader = unregisterTrade(
                    t,
                    v.profitP,
                    v.posUSDC,
                    i.openInterestUSDC.div(t.leverage),
                    v.reward,
                    (v.reward * (liqTotalFeeP - liqFeeP)) / liqFeeP,
                    i.lossProtection
                );

                executor.distributeReward(
                    IExecute.TriggeredLimitId(o.trader, o.pairIndex, o.index, o.orderType),
                    v.reward
                );

                emit LimitExecuted(
                    a.orderId,
                    o.index,
                    t,
                    o.orderType,
                    v.price,
                    v.posUSDC,
                    v.profitP,
                    USDCSentToTrader,
                    block.timestamp
                );
            }

            if (o.orderType != ITradingStorage.LimitOrder.LIQ && v.reward > 0) {
                uint USDCSentToTrader = unregisterTrade(
                    t,
                    v.profitP,
                    v.posUSDC,
                    i.openInterestUSDC.div(t.leverage),
                    v.reward,
                    (v.posToken.mul(t.leverage) * aggregator.pairsStorage().pairCloseFeeP(t.pairIndex)) /
                        100 /
                        PRECISION,
                    i.lossProtection
                );

                if (v.reward > 0) {
                    executor.distributeReward(
                        IExecute.TriggeredLimitId(o.trader, o.pairIndex, o.index, o.orderType),
                        v.reward
                    );
                }
                emit LimitExecuted(
                    a.orderId,
                    o.index,
                    t,
                    o.orderType,
                    v.price,
                    v.posUSDC,
                    v.profitP,
                    USDCSentToTrader,
                    block.timestamp
                );
            }
        }

        executor.unregisterTrigger(IExecute.TriggeredLimitId(o.trader, o.pairIndex, o.index, o.orderType));
        storageT.unregisterPendingLimitOrder(a.orderId);
    }

    function updateSlCallback(AggregatorAnswer memory a) external override onlyPriceAggregator {
        IPriceAggregator aggregator = storageT.priceAggregator();
        IPriceAggregator.PendingSl memory o = aggregator.pendingSlOrders(a.orderId);

        ITradingStorage.Trade memory t = storageT.openTrades(o.trader, o.pairIndex, o.index);
        if (
            a.price != 0 &&
            t.leverage > 0 &&
            t.buy == o.buy &&
            t.openPrice == o.openPrice &&
            (t.buy ? o.newSl <= a.price : o.newSl >= a.price)
        ) {
            storageT.updateSl(o.trader, o.pairIndex, o.index, o.newSl);
            t.timestamp = block.timestamp;
            emit SlUpdated(a.orderId, o.trader, o.pairIndex, o.index, o.newSl, block.timestamp);
        } else {
            emit SlCanceled(a.orderId, o.trader, o.pairIndex, o.index, block.timestamp);
        }

        aggregator.unregisterPendingSlOrder(a.orderId);
    }

    // Shared code between market & limit callbacks
    function registerTrade(ITradingStorage.Trade memory _trade) private returns (ITradingStorage.Trade memory) {
        IPriceAggregator aggregator = storageT.priceAggregator();
        IPairStorage pairsStored = aggregator.pairsStorage();

        _trade.timestamp = block.timestamp;
        _trade.positionSizeUSDC -= storageT.handleDevGovFees(
            _trade.trader,
            _trade.pairIndex,
            _trade.positionSizeUSDC.mul(_trade.leverage),
            true,
            true,
            _trade.buy
        );

        storageT.vaultManager().reserveBalance(_trade.positionSizeUSDC.mul(_trade.leverage));
        storageT.vaultManager().receiveUSDCFromTrader(_trade.trader, _trade.positionSizeUSDC, 0);

        _trade.initialPosToken = _trade.positionSizeUSDC;
        _trade.positionSizeUSDC = 0;

        _trade.index = storageT.firstEmptyTradeIndex(_trade.trader, _trade.pairIndex);
        _trade.tp = correctTp(_trade.openPrice, _trade.leverage, _trade.tp, _trade.buy);
        _trade.sl = correctSl(_trade.openPrice, _trade.leverage, _trade.sl, _trade.buy);

        pairInfos.storeTradeInitialAccFees(_trade.trader, _trade.pairIndex, _trade.index, _trade.buy);

        pairsStored.updateGroupOI(_trade.pairIndex, _trade.initialPosToken.mul(_trade.leverage), _trade.buy, true);

        storageT.storeTrade(
            _trade,
            ITradingStorage.TradeInfo(
                0,
                _trade.initialPosToken.mul(_trade.leverage),
                0,
                0,
                false,
                pairInfos.lossProtectionTier(_trade)
            )
        );

        return (_trade);
    }

    function unregisterTrade(
        ITradingStorage.Trade memory _trade,
        int _percentProfit,
        uint _currentUSDCPos,
        uint _initialUSDCPos,
        uint _feeAmountToken, // executor reward
        uint _lpFeeToken,
        uint _tier
    ) private returns (uint USDCSentToTrader) {
        //Scoping Local Variables to avoid stack too deep
        {
            (uint feeAfterRebate, uint referrerRebate) = storageT.applyReferralClose(
                _trade.trader,
                _lpFeeToken,
                _trade.initialPosToken.mul(_trade.leverage)
            );
            int pnl;
            uint totalFees;
            (USDCSentToTrader, pnl, totalFees) = pairInfos.getTradeValue(
                _trade,
                _currentUSDCPos,
                _percentProfit,
                feeAfterRebate + _feeAmountToken,
                _tier
            );

            if (USDCSentToTrader > 0) {
                storageT.vaultManager().sendUSDCToTrader(_trade.trader, USDCSentToTrader);
            }
            if (pnl < 0) {
                storageT.vaultManager().allocateRewards(uint(-pnl) + totalFees - _feeAmountToken);
            } else storageT.vaultManager().allocateRewards(totalFees - _feeAmountToken);

            if (referrerRebate > 0) {
                storageT.vaultManager().sendReferrerRebateToStorage(referrerRebate);
            }
        }
        storageT.vaultManager().releaseBalance(_initialUSDCPos.mul(_trade.leverage));

        storageT.priceAggregator().pairsStorage().updateGroupOI(
            _trade.pairIndex,
            _initialUSDCPos.mul(_trade.leverage),
            _trade.buy,
            false
        );

        if (_trade.initialPosToken == _currentUSDCPos)
            storageT.unregisterTrade(_trade.trader, _trade.pairIndex, _trade.index);
        else {
            storageT.registerPartialTrade(_trade.trader, _trade.pairIndex, _trade.index, _currentUSDCPos);
        }
        return USDCSentToTrader;
    }

    function transferFromVault(address _trader, uint _amount) external override {
        require(msg.sender == address(storageT.priceAggregator().executions()), "EXECUTOR_ONLY");
        require(_amount > 0, "ZERO_AMOUNT");
        storageT.vaultManager().sendUSDCToTrader(_trader, _amount);
    }

    function withinExposureLimits(address _trader, uint _pairIndex, uint _leveragedPos) private view returns (bool) {
        IPairStorage pairsStored = storageT.priceAggregator().pairsStorage();
        return
            //90%TVL cap
            storageT.totalOI() + _leveragedPos <= storageT.maxOpenInterest() &&
            // Asset Wise Limitation
            pairsStored.groupOI(_pairIndex) + _leveragedPos <= pairsStored.groupMaxOI(_pairIndex) &&
            // Pair Wise limitation
            storageT.pairOI(_pairIndex) + _leveragedPos <= pairsStored.pairMaxOI(_pairIndex) &&
            // Wallet Exposure Limit
            storageT.walletOI(_trader) + _leveragedPos <= pairsStored.maxWalletOI(_pairIndex);
    }

    function currentPercentProfit(
        uint openPrice,
        uint currentPrice,
        bool buy,
        uint leverage
    ) private pure returns (int p) {
        int diff = buy ? (int(currentPrice) - int(openPrice)) : (int(openPrice) - int(currentPrice));
        int minPnlP = int(PRECISION) * (-100);
        int maxPnlP = int(MAX_GAIN_P) * int(PRECISION);
        p = (diff * 100 * int(PRECISION.mul(leverage))) / int(openPrice);
        p = p < minPnlP ? minPnlP : p > maxPnlP ? maxPnlP : p;
    }

    function correctTp(uint openPrice, uint leverage, uint tp, bool buy) private pure returns (uint) {
        if (tp == 0 || currentPercentProfit(openPrice, tp, buy, leverage) == int(MAX_GAIN_P) * int(PRECISION)) {
            uint tpDiff = ((openPrice * MAX_GAIN_P).div(leverage)) / 100;
            return buy ? openPrice + tpDiff : tpDiff <= openPrice ? openPrice - tpDiff : 0;
        }
        return tp;
    }

    function correctSl(uint openPrice, uint leverage, uint sl, bool buy) private pure returns (uint) {
        if (sl > 0 && currentPercentProfit(openPrice, sl, buy, leverage) < int(MAX_SL_P) * int(PRECISION) * (-1)) {
            uint slDiff = ((openPrice * MAX_SL_P).div(leverage)) / 100;
            return buy ? openPrice - slDiff : openPrice + slDiff;
        }
        return sl;
    }

    function marketExecutionPrice(uint _price, uint _spreadP, bool _long) private pure returns (uint) {
        uint priceDiff = (_price * _spreadP) / 100 / PRECISION;
        return _long ? _price + priceDiff : _price - priceDiff;
    }
}
