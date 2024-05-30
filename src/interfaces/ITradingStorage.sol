// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "./IPriceAggregator.sol";
import "./IToken.sol";
import "./IVaultManager.sol";
import "./IPausable.sol";
import "./ICallbacks.sol";

interface ITradingStorage {
    /**
    struct Trader {
        uint leverageUnlocked;
    }
    */

    // Enums
    enum LimitOrder {
        TP,
        SL,
        LIQ,
        OPEN
    }

    enum updateType {
        DEPOSIT,
        WITHDRAW
    }

    struct Trader {
        uint leverageUnlocked;
        address referral;
        uint referralRewardsTotal; // 1e6
    }

    struct Trade {
        address trader;
        uint pairIndex;
        uint index;
        uint initialPosToken; // 1e6
        uint positionSizeUSDC; // 1e6
        uint openPrice; // PRECISION
        bool buy;
        uint leverage;
        uint tp; // PRECISION
        uint sl; // PRECISION
        uint timestamp;
    }
    struct TradeInfo {
        uint tokenId;
        uint openInterestUSDC; // 1e6
        uint tpLastUpdated;
        uint slLastUpdated;
        bool beingMarketClosed;
        uint lossProtection;
    }
    struct OpenLimitOrder {
        address trader;
        uint pairIndex;
        uint index;
        uint positionSize; // 1e6 (USDC or GFARM2)
        bool buy;
        uint leverage;
        uint tp; // PRECISION (%)
        uint sl; // PRECISION (%)
        uint minPrice; // PRECISION
        uint maxPrice; // PRECISION
        uint block;
        uint executionFee;
    }

    struct PendingMarketOrder {
        Trade trade;
        uint block;
        uint wantedPrice; // PRECISION
        uint slippageP; // PRECISION (%)
        uint tokenId; // index in supportedTokens
    }

    struct PendingLimitOrder {
        address trader;
        uint pairIndex;
        uint index;
        LimitOrder orderType;
    }

    // Events
    event SupportedTokenAdded(address a);
    event TradingContractAdded(address a);
    event TradingContractRemoved(address a);
    event AddressUpdated(string name, address a);
    event NumberUpdated(string name, uint value);
    event NumberUpdatedPair(string name, uint pairIndex, uint value);
    event TradeOpenReferral(address, address, uint, uint);
    event TradeReferred(address _trader, address _referrer, uint _size, uint _fees, uint _discount, uint _rebate);
    function gov() external view returns (address);

    function dev() external view returns (address);

    function USDC() external view returns (IToken);

    function priceAggregator() external view returns (IPriceAggregator);

    function vaultManager() external view returns (IVaultManager);

    function trading() external view returns (address);

    function callbacks() external view returns (address);

    function transferUSDC(address, address, uint) external;

    function unregisterTrade(address, uint, uint) external;

    function registerPartialTrade(address, uint, uint, uint) external;

    function unregisterPendingMarketOrder(uint, bool) external;

    function unregisterOpenLimitOrder(address, uint, uint) external;

    function hasOpenLimitOrder(address, uint, uint) external view returns (bool);

    function storePendingMarketOrder(PendingMarketOrder memory, uint, bool) external;

    function openTrades(address, uint, uint) external view returns (Trade memory);

    function openTradesInfo(address, uint, uint) external view returns (TradeInfo memory);

    function updateSl(address, uint, uint, uint) external;

    function updateTp(address, uint, uint, uint) external;

    function getOpenLimitOrder(address, uint, uint) external view returns (OpenLimitOrder memory);

    function reqID_pendingLimitOrder(uint) external view returns (PendingLimitOrder memory);

    function storeOpenLimitOrder(OpenLimitOrder memory) external;

    function reqID_pendingMarketOrder(uint) external view returns (PendingMarketOrder memory);

    function storePendingLimitOrder(PendingLimitOrder memory, uint) external;

    function updateOpenLimitOrder(OpenLimitOrder calldata) external;

    function firstEmptyTradeIndex(address, uint) external view returns (uint);

    function firstEmptyOpenLimitIndex(address, uint) external view returns (uint);

    function updateTrade(Trade memory) external;

    function unregisterPendingLimitOrder(uint) external;

    function handleDevGovFees(address, uint, uint, bool, bool, bool) external returns (uint);

    function storeTrade(Trade memory, TradeInfo memory) external;

    function setLeverageUnlocked(address, uint) external;

    function getLeverageUnlocked(address) external view returns (uint);

    function openLimitOrdersCount(address, uint) external view returns (uint);

    function openTradesCount(address, uint) external view returns (uint);

    function pendingMarketOpenCount(address, uint) external view returns (uint);

    function pendingMarketCloseCount(address, uint) external view returns (uint);

    function maxTradesPerPair() external view returns (uint);

    function maxTradesPerBlock() external view returns (uint);

    function tradesPerBlock(uint) external view returns (uint);

    function pendingOrderIdsCount(address) external view returns (uint);

    function maxPendingMarketOrders() external view returns (uint);

    function defaultLeverageUnlocked() external view returns (uint);

    function totalOI() external view returns (uint);

    function openInterestUSDC(uint, uint) external view returns (uint);

    function pairOI(uint _pairIndex) external view returns (uint);

    function getPendingOrderIds(address) external view returns (uint[] memory);

    function traders(address) external view returns (Trader memory);

    function applyReferralOpen(address, uint, uint) external returns (uint);

    function applyReferralClose(address, uint, uint) external returns (uint, uint);

    function walletOI(address _trader) external view returns (uint);

    function maxOpenInterest() external view returns (uint);
}
