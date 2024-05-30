// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;
import {ITradingStorage} from "./ITradingStorage.sol";

interface IPairInfos {
    // Pair parameters
    struct PairParams {
        uint onePercentDepthAbove; // USDC
        uint onePercentDepthBelow; // USDC
        uint rolloverFeePerBlockP; // PRECISION
    }

    // Pair acc rollover fees
    struct PairRolloverFees {
        uint accPerOiLong; // 1e6 (USDC)
        uint accPerOiShort; // 1e6 (USDC)
        uint lastUpdateBlock;
    }

    // Trade initial acc fees
    struct TradeInitialAccFees {
        uint rollover; // 1e6 (USDC)
        bool openedAfterUpdate;
    }

    // Events
    event ManagerUpdated(address value);
    event MaxNegativePnlOnOpenPUpdated(uint value);
    event MultiplierUpdated(uint minMultiplierRate, uint maxMultiplierRate, uint groupId);
    event CoeffUpdated(uint multiplierCoeffMax, uint groupId);
    event DenomUpdated(uint multiplierDenom, uint groupId);
    event PairParamsUpdated(uint pairIndex, PairParams value);
    event OnePercentDepthUpdated(uint pairIndex, uint valueAbove, uint valueBelow);
    event RolloverFeePerBlockPUpdated(uint pairIndex, uint fee);
    event TradeInitialAccFeesStored(address trader, uint pairIndex, uint index, uint rollover);
    event AccRolloverFeesStored(uint pairIndex, uint valueLong, uint valueShort);
    event FeesCharged(
        uint pairIndex,
        bool long,
        uint collateral, // 1e6 (USDC)
        uint leverage,
        int percentProfit, // PRECISION (%)
        uint rolloverFees // 1e6 (USDC)
    );
    event LossProtectionConfigSet(uint numTiers, uint[] longSkewConfig, uint[] shortSkewConfig);

    function maxNegativePnlOnOpenP() external view returns (uint); // PRECISION (%)

    function storeTradeInitialAccFees(address trader, uint pairIndex, uint index, bool long) external;

    function getTradePriceImpact(
        uint openPrice, // PRECISION
        uint pairIndex,
        bool long,
        uint openInterest // 1e6 (USDC)
    )
        external
        view
        returns (
            uint priceImpactP, // PRECISION (%)
            uint priceAfterImpact // PRECISION
        );

    function getTradeLiquidationPrice(
        address trader,
        uint pairIndex,
        uint index,
        uint openPrice, // PRECISION
        bool long,
        uint collateral, // 1e6 (USDC)
        uint leverage
    ) external view returns (uint); // PRECISION

    function getTradeValue(
        ITradingStorage.Trade memory _trade,
        uint collateral, // 1e6 (USDC)
        int percentProfit, // PRECISION (%)
        uint closingFee, // 1e6 (USDC)
        uint _tier // 1e6
    ) external returns (uint, int, uint); // 1e6 (USDC)

    // Funding fee value
    function getTradeRolloverFee(
        address trader,
        uint pairIndex,
        uint index,
        bool long,
        uint collateral, // 1e6 (USDC)
        uint leverage
    ) external view returns (uint);

    function lossProtectionTier(ITradingStorage.Trade memory _trade) external view returns (uint _tier);
}
