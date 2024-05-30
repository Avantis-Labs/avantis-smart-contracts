// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "./interfaces/ITradingStorage.sol";
import "./interfaces/IPairStorage.sol";
import "./interfaces/IPairInfos.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PositionMath} from "./library/PositionMath.sol";

contract PairInfos is Initializable, IPairInfos {
    using PositionMath for uint;

    ITradingStorage public storageT;
    IPairStorage public pairsStorage;

    address public manager;
    uint public override maxNegativePnlOnOpenP;

    uint private constant PRECISION = 1e10; // 10 decimals
    uint private constant LIQ_THRESHOLD_P = 90; // -90% (of collateral)

    mapping(uint => uint) public maxMultiplierRateByGroup;
    mapping(uint => uint) public minMultiplierRateByGroup;
    mapping(uint => uint) public multiplierCoeffMaxByGroup;
    mapping(uint => uint) public multiplierDenomByGroup;

    mapping(uint => PairParams) public pairParams;
    mapping(uint => PairRolloverFees) public pairRolloverFees;
    mapping(address => mapping(uint => mapping(uint => TradeInitialAccFees))) public tradeInitialAccFees;

    mapping(uint => uint) lossProtectionNumTiers;
    mapping(uint => uint[]) longSkewConfig;
    mapping(uint => uint[]) shortSkewConfig;

    function initialize(address _storageT, address _pairsStorage) external initializer {
        storageT = ITradingStorage(_storageT);
        pairsStorage = IPairStorage(_pairsStorage);
        maxNegativePnlOnOpenP = 40 * PRECISION;

        // crypto default
        _setMultiplierRate(0, 600, 0);
        _setCoeffMultiplier(83030000000, 0);
        _setDenomMultiplier(221400000000000, 0);

        // forex default
        _setMultiplierRate(0, 300, 1);
        _setCoeffMultiplier(415100000000, 1);
        _setDenomMultiplier(221400000000000, 1);
    }

    // Modifiers
    modifier onlyGov() {
        require(msg.sender == storageT.gov(), "GOV_ONLY");
        _;
    }
    modifier onlyManager() {
        require(msg.sender == manager, "MANAGER_ONLY");
        _;
    }
    modifier onlyCallbacks() {
        require(msg.sender == storageT.callbacks(), "CALLBACKS_ONLY");
        _;
    }

    // Set manager address
    function setManager(address _manager) external onlyGov {
        manager = _manager;

        emit ManagerUpdated(_manager);
    }

    // Set max negative PnL % on trade opening
    function setMaxNegativePnlOnOpenP(uint value) external onlyManager {
        maxNegativePnlOnOpenP = value;

        emit MaxNegativePnlOnOpenPUpdated(value);
    }

    // Set multiplier
    function _setMultiplierRate(uint _minMultiplierRate, uint _maxMultiplierRate, uint _groupId) internal {
        minMultiplierRateByGroup[_groupId] = _minMultiplierRate;
        maxMultiplierRateByGroup[_groupId] = _maxMultiplierRate;

        emit MultiplierUpdated(_minMultiplierRate, _maxMultiplierRate, _groupId);
    }

    // Set coeff
    function _setCoeffMultiplier(uint _multiplierCoeffMax, uint _groupId) internal {
        multiplierCoeffMaxByGroup[_groupId] = _multiplierCoeffMax;

        emit CoeffUpdated(_multiplierCoeffMax, _groupId);
    }

    // Set denom
    function _setDenomMultiplier(uint _multiplierDenom, uint _groupId) internal {
        multiplierDenomByGroup[_groupId] = _multiplierDenom;

        emit DenomUpdated(_multiplierDenom, _groupId);
    }

    // Set multiplier
    function setMultiplierRate(uint _minMultiplierRate, uint _maxMultiplierRate, uint _groupId) external onlyManager {
        _setMultiplierRate(_minMultiplierRate, _maxMultiplierRate, _groupId);
    }

    // Set coeff
    function setCoeffMultiplier(uint _multiplierCoeffMax, uint _groupId) external onlyManager {
        _setCoeffMultiplier(_multiplierCoeffMax, _groupId);
    }

    // Set denom
    function setDenomMultiplier(uint _multiplierDenom, uint _groupId) external onlyManager {
        _setDenomMultiplier(_multiplierDenom, _groupId);
    }

    // Set parameters for pair
    function setPairParams(uint pairIndex, PairParams calldata value) public onlyManager {
        storeAccRolloverFees(pairIndex);

        pairParams[pairIndex] = value;
        emit PairParamsUpdated(pairIndex, value);
    }

    function setPairParamsArray(uint[] calldata indices, PairParams[] calldata values) external onlyManager {
        require(indices.length == values.length, "WRONG_LENGTH");

        for (uint i; i < indices.length; ++i) {
            setPairParams(indices[i], values[i]);
        }
    }

    // Set one percent depth for pair
    function setOnePercentDepth(uint pairIndex, uint valueAbove, uint valueBelow) public onlyManager {
        PairParams storage p = pairParams[pairIndex];

        p.onePercentDepthAbove = valueAbove;
        p.onePercentDepthBelow = valueBelow;

        emit OnePercentDepthUpdated(pairIndex, valueAbove, valueBelow);
    }

    function setLossProtectionConfig(
        uint _pairIndex,
        uint[] calldata _longSkewConfig,
        uint[] calldata _shortSkewConfig
    ) external onlyManager {
        require(_longSkewConfig.length == _shortSkewConfig.length);

        lossProtectionNumTiers[_pairIndex] = _longSkewConfig.length;
        longSkewConfig[_pairIndex] = _longSkewConfig;
        shortSkewConfig[_pairIndex] = _shortSkewConfig;

        emit LossProtectionConfigSet(lossProtectionNumTiers[_pairIndex], _longSkewConfig, _shortSkewConfig);
    }

    function setOnePercentDepthArray(
        uint[] calldata indices,
        uint[] calldata valuesAbove,
        uint[] calldata valuesBelow
    ) external onlyManager {
        require(indices.length == valuesAbove.length && indices.length == valuesBelow.length, "WRONG_LENGTH");

        for (uint i; i < indices.length; ++i) {
            setOnePercentDepth(indices[i], valuesAbove[i], valuesBelow[i]);
        }
    }

    // Set rollover fee for pair
    function setRolloverFeePerBlockP(uint pairIndex, uint value) public onlyManager {
        require(value <= 25000000, "TOO_HIGH"); // ≈ 100% per day, 43200 blocks per day, 1800 per hour, 0.01% per hour is

        storeAccRolloverFees(pairIndex);

        pairParams[pairIndex].rolloverFeePerBlockP = value;

        emit RolloverFeePerBlockPUpdated(pairIndex, value);
    }

    function setRolloverFeePerBlockPArray(uint[] calldata indices, uint[] calldata values) external onlyManager {
        require(indices.length == values.length, "WRONG_LENGTH");

        for (uint i; i < indices.length; ++i) {
            setRolloverFeePerBlockP(indices[i], values[i]);
        }
    }

    function storeAccRolloverFees(uint pairIndex) private {
        PairRolloverFees storage f = pairRolloverFees[pairIndex];

        (f.accPerOiLong, f.accPerOiShort) = getPendingAccRolloverFees(pairIndex);
        f.lastUpdateBlock = block.number;

        emit AccRolloverFeesStored(pairIndex, f.accPerOiLong, f.accPerOiShort);
    }

    function getUtilizationMultiplier(uint pairIndex) public view returns (uint) {
        return
            ((storageT.openInterestUSDC(pairIndex, 0) + storageT.openInterestUSDC(pairIndex, 1)) * PRECISION) /
            (pairsStorage.groupMaxOI(pairIndex));
    }

    function getLongMultiplier(uint pairIndex) public view returns (uint) {
        uint openInterestUSDCLong = storageT.openInterestUSDC(pairIndex, 0);
        uint openInterestUSDCShort = storageT.openInterestUSDC(pairIndex, 1);
        uint groupIndex = pairsStorage.pairGroupIndex(pairIndex);
        uint multiplierCoeffMax = multiplierCoeffMaxByGroup[groupIndex];
        uint multiplierDenom = multiplierDenomByGroup[groupIndex];
        uint maxMultiplierRate = maxMultiplierRateByGroup[groupIndex];
        uint minMultiplierRate = minMultiplierRateByGroup[groupIndex];

        uint longMultiplier = 100;
        if (openInterestUSDCLong + openInterestUSDCShort == 0) return longMultiplier;

        uint openInterestUSDCLongPct = (100 * openInterestUSDCLong) / (openInterestUSDCLong + openInterestUSDCShort);
        if (openInterestUSDCLongPct > 60) {
            longMultiplier += (((openInterestUSDCLongPct - 60) ** 2) * 100 * multiplierCoeffMax) / multiplierDenom;
            longMultiplier = Math.min(longMultiplier, maxMultiplierRate);
        }
        if (openInterestUSDCLongPct < 31) {
            longMultiplier = minMultiplierRate;
        }
        return longMultiplier;
    }

    function getShortMultiplier(uint pairIndex) public view returns (uint) {
        uint openInterestUSDCLong = storageT.openInterestUSDC(pairIndex, 0);
        uint openInterestUSDCShort = storageT.openInterestUSDC(pairIndex, 1);
        uint groupIndex = pairsStorage.pairGroupIndex(pairIndex);
        uint multiplierCoeffMax = multiplierCoeffMaxByGroup[groupIndex];
        uint multiplierDenom = multiplierDenomByGroup[groupIndex];
        uint maxMultiplierRate = maxMultiplierRateByGroup[groupIndex];
        uint minMultiplierRate = minMultiplierRateByGroup[groupIndex];

        uint shortMultiplier = 100;
        if (openInterestUSDCLong + openInterestUSDCShort == 0) return shortMultiplier;

        uint openInterestUSDCShortPct = (100 * openInterestUSDCShort) / (openInterestUSDCLong + openInterestUSDCShort);
        if (openInterestUSDCShortPct > 60) {
            shortMultiplier += (((openInterestUSDCShortPct - 60) ** 2) * 100 * multiplierCoeffMax) / multiplierDenom;
            shortMultiplier = Math.min(shortMultiplier, maxMultiplierRate);
        }
        if (openInterestUSDCShortPct < 31) {
            shortMultiplier = minMultiplierRate;
        }
        return shortMultiplier;
    }

    function getPendingAccRolloverFees(uint pairIndex) public view returns (uint valueLong, uint valueShort) {
        PairRolloverFees storage f = pairRolloverFees[pairIndex];

        valueLong = f.accPerOiLong;
        valueShort = f.accPerOiShort;

        uint openInterestUSDCLong = storageT.openInterestUSDC(pairIndex, 0);
        uint openInterestUSDCShort = storageT.openInterestUSDC(pairIndex, 1);

        if (openInterestUSDCLong > 0) {
            uint rolloverFeesPaidByLongs = (getLongMultiplier(pairIndex) *
                1e6 *
                getUtilizationMultiplier(pairIndex) *
                (block.number - f.lastUpdateBlock) *
                pairParams[pairIndex].rolloverFeePerBlockP) /
                PRECISION /
                PRECISION /
                100 /
                100;

            valueLong += rolloverFeesPaidByLongs;
        }

        if (openInterestUSDCShort > 0) {
            uint rolloverFeesPaidByShort = (getShortMultiplier(pairIndex) *
                1e6 *
                getUtilizationMultiplier(pairIndex) *
                (block.number - f.lastUpdateBlock) *
                pairParams[pairIndex].rolloverFeePerBlockP) /
                PRECISION /
                PRECISION /
                100 /
                100;

            valueShort += rolloverFeesPaidByShort;
        }
    }

    // Funding fee value
    function getTradeRolloverFee(
        address trader,
        uint pairIndex,
        uint index,
        bool long,
        uint collateral,
        uint leverage
    ) public view override returns (uint) {
        TradeInitialAccFees memory t = tradeInitialAccFees[trader][pairIndex][index];
        if (!t.openedAfterUpdate) {
            return 0;
        }

        (uint pendingLong, uint pendingShort) = getPendingAccRolloverFees(pairIndex);
        return getTradeRolloverFeePure(t.rollover, long ? pendingLong : pendingShort, collateral, leverage);
    }

    function getTradeRolloverFeePure(
        uint accRolloverFeesPerOi,
        uint endAccRolloverFeesPerOi,
        uint collateral,
        uint leverage
    ) public pure returns (uint) {
        return ((endAccRolloverFeesPerOi - accRolloverFeesPerOi) * collateral.mul(leverage)) / 1e6;
    }

    // Store trade details when opened (acc fee values)
    function storeTradeInitialAccFees(
        address trader,
        uint pairIndex,
        uint index,
        bool long
    ) external override onlyCallbacks {
        storeAccRolloverFees(pairIndex);

        TradeInitialAccFees storage t = tradeInitialAccFees[trader][pairIndex][index];

        t.rollover = long ? pairRolloverFees[pairIndex].accPerOiLong : pairRolloverFees[pairIndex].accPerOiShort;

        t.openedAfterUpdate = true;

        emit TradeInitialAccFeesStored(trader, pairIndex, index, t.rollover);
    }

    // Dynamic price impact value on trade opening
    function getTradePriceImpact(
        uint openPrice,
        uint pairIndex,
        bool long,
        uint tradeOpenInterest
    ) external view override returns (uint priceImpactP, uint priceAfterImpact) {
        (priceImpactP, priceAfterImpact) = getTradePriceImpactPure(
            openPrice,
            long,
            tradeOpenInterest,
            long ? pairParams[pairIndex].onePercentDepthAbove : pairParams[pairIndex].onePercentDepthBelow
        );
    }

    function getTradePriceImpactPure(
        uint openPrice,
        bool long,
        uint tradeOpenInterest,
        uint onePercentDepth
    ) public pure returns (uint priceImpactP, uint priceAfterImpact) {
        if (onePercentDepth == 0) {
            return (0, openPrice);
        }

        priceImpactP = (tradeOpenInterest * PRECISION) / 1e6 / onePercentDepth;

        uint priceImpact = (priceImpactP * openPrice) / PRECISION / 100;

        priceAfterImpact = long ? openPrice + priceImpact : openPrice - priceImpact;
    }

    // Liquidation price value after rollover
    function getTradeLiquidationPrice(
        address trader,
        uint pairIndex,
        uint index,
        uint openPrice,
        bool long,
        uint collateral,
        uint leverage
    ) external view override returns (uint) {
        return
            getTradeLiquidationPricePure(
                openPrice,
                long,
                collateral,
                leverage,
                getTradeRolloverFee(trader, pairIndex, index, long, collateral, leverage)
            );
    }

    function getTradeLiquidationPricePure(
        uint openPrice,
        bool long,
        uint collateral,
        uint leverage,
        uint rolloverFee
    ) public pure returns (uint) {
        int liqPriceDistance = (int(openPrice) * (int((collateral * LIQ_THRESHOLD_P) / 100) - int(rolloverFee))) /
            int(collateral.mul(leverage));

        int liqPrice = long ? int(openPrice) - liqPriceDistance : int(openPrice) + liqPriceDistance;

        return liqPrice > 0 ? uint(liqPrice) : 0;
    }

    // USDC sent to trader after PnL and fees
    function getTradeValue(
        ITradingStorage.Trade memory _trade,
        uint collateral,
        int percentProfit,
        uint closingFee,
        uint _tier
    ) external override onlyCallbacks returns (uint amount, int pnl, uint fees) {
        storeAccRolloverFees(_trade.pairIndex);

        uint r = getTradeRolloverFee(
            _trade.trader,
            _trade.pairIndex,
            _trade.index,
            _trade.buy,
            collateral,
            _trade.leverage
        );

        (amount, pnl, fees) = getTradeValuePure(
            collateral,
            percentProfit,
            r,
            closingFee,
            pairsStorage.lossProtectionMultiplier(_trade.pairIndex, _tier)
        );

        emit FeesCharged(_trade.pairIndex, _trade.buy, collateral, _trade.leverage, percentProfit, r);
    }

    function getTradeValuePure(
        uint collateral,
        int percentProfit,
        uint rolloverFee,
        uint closingFee,
        uint lossProtection
    ) public pure returns (uint, int, uint) {
        int pnl = (int(collateral) * percentProfit) / int(PRECISION) / 100;
        if (pnl < 0) {
            pnl = (pnl * int(lossProtection)) / 100;
        }
        int fees = int(rolloverFee) + int(closingFee);
        int value = int(collateral) + pnl - fees;
        if (value <= (int(collateral) * int(100 - LIQ_THRESHOLD_P)) / 100) {
            value = 0;
        }
        return (value > 0 ? uint(value) : 0, pnl, uint(fees));
    }

    function lossProtectionTier(ITradingStorage.Trade memory _trade) external view override returns (uint) {
        uint openInterestUSDCLong = storageT.openInterestUSDC(_trade.pairIndex, 0);
        uint openInterestUSDCShort = storageT.openInterestUSDC(_trade.pairIndex, 1);

        uint updatedInterest = _trade.initialPosToken.mul(_trade.leverage);

        if (!_trade.buy) {
            openInterestUSDCShort += updatedInterest;
            uint openInterestUSDCLongPct = (100 * openInterestUSDCLong) /
                (openInterestUSDCLong + openInterestUSDCShort);
            for (uint i = longSkewConfig[_trade.pairIndex].length; i > 0; --i) {
                if (openInterestUSDCLongPct >= longSkewConfig[_trade.pairIndex][i - 1]) return i - 1;
            }
        } else {
            openInterestUSDCLong += updatedInterest;
            uint openInterestUSDCShortPct = (100 * openInterestUSDCShort) /
                (openInterestUSDCLong + openInterestUSDCShort);

            for (uint i = shortSkewConfig[_trade.pairIndex].length; i > 0; --i) {
                if (openInterestUSDCShortPct >= shortSkewConfig[_trade.pairIndex][i - 1]) return i - 1;
            }
        }
        return 0; // No Protection Tier
    }

    // Useful getters
    function getPairInfos(
        uint[] calldata indices
    ) external view returns (PairParams[] memory, PairRolloverFees[] memory) {
        PairParams[] memory params = new PairParams[](indices.length);
        PairRolloverFees[] memory rolloverFees = new PairRolloverFees[](indices.length);

        for (uint i; i < indices.length; ++i) {
            uint index = indices[i];

            params[i] = pairParams[index];
            rolloverFees[i] = pairRolloverFees[index];
        }

        return (params, rolloverFees);
    }

    function getOnePercentDepthAbove(uint pairIndex) external view returns (uint) {
        return pairParams[pairIndex].onePercentDepthAbove;
    }

    function getOnePercentDepthBelow(uint pairIndex) external view returns (uint) {
        return pairParams[pairIndex].onePercentDepthBelow;
    }

    function getRolloverFeePerBlockP(uint pairIndex) external view returns (uint) {
        return pairParams[pairIndex].rolloverFeePerBlockP;
    }

    function getAccRolloverFeesLong(uint pairIndex) external view returns (uint) {
        return pairRolloverFees[pairIndex].accPerOiLong;
    }

    function getAccRolloverFeesShort(uint pairIndex) external view returns (uint) {
        return pairRolloverFees[pairIndex].accPerOiShort;
    }

    function getAccRolloverFeesUpdateBlock(uint pairIndex) external view returns (uint) {
        return pairRolloverFees[pairIndex].lastUpdateBlock;
    }

    function getTradeInitialAccRolloverFeesPerCollateral(
        address trader,
        uint pairIndex,
        uint index
    ) external view returns (uint) {
        return tradeInitialAccFees[trader][pairIndex][index].rollover;
    }

    function getTradeOpenedAfterUpdate(address trader, uint pairIndex, uint index) external view returns (bool) {
        return tradeInitialAccFees[trader][pairIndex][index].openedAfterUpdate;
    }
}
