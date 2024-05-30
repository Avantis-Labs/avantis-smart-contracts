// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

interface IPairStorage {
    struct Feed {
        uint maxDeviationP;
        bytes32 feedId;
    }

    struct BackupFeed {
        uint maxDeviationP;
        address feedId;
    }

    struct Pair {
        string from;
        string to;
        Feed feed;
        BackupFeed backupFeed;
        uint spreadP;
        uint groupIndex;
        uint feeIndex;
        uint groupOpenInterestPecentage;
        uint maxWalletOI;
    }

    struct Group {
        string name;
        uint minLeverage;
        uint maxLeverage;
        uint maxOpenInterestP; // % (of USDC vault current balance)
    }

    struct Fee {
        string name;
        uint openFeeP; // PRECISION (% of leveraged pos)
        uint closeFeeP; // PRECISION (% of leveraged pos)
        uint limitOrderFeeP; // PRECISION (% of leveraged pos)
        uint minLevPosUSDC; // 1e6 (collateral x leverage, useful for min fee)
    }

    struct SkewFee {
        uint thresholdHigh; // 80
        uint thresholdMid; // 70
        uint thresholdLow; // 60
        int slopeMid; // -7
        int slopeLow; // -25
        int interceptMid; // 565
        int interceptLow; // 2500
        uint feeHigh; // 4 (0.004% when multiplied by PRECISION and divided by 1000)
    }

    // Events
    event PairAdded(uint index, string from, string to);
    event PairUpdated(uint index);

    event GroupAdded(uint index, string name);
    event GroupUpdated(uint index);

    event FeeAdded(uint index, string name);
    event FeeUpdated(uint index);

    event SkewFeeAdded(uint index);
    event SkewFeeUpdated(uint index);

    event LossProtectionAdded(uint pairIndex, uint[] tier, uint[] multiplier);

    function updateGroupOI(uint, uint, bool, bool) external;

    function pairJob(uint) external returns (string memory, string memory, bytes32, address, uint);

    function pairGroupIndex(uint) external view returns (uint);

    function pairFeed(uint) external view returns (Feed memory);

    function pairBackupFeed(uint) external view returns (BackupFeed memory);

    function pairSpreadP(uint) external view returns (uint);

    function pairMinLeverage(uint) external view returns (uint);

    function pairMaxLeverage(uint) external view returns (uint);

    function groupMaxOI(uint) external view returns (uint);

    function groupOI(uint) external view returns (uint);

    function guaranteedSlEnabled(uint) external view returns (bool);

    function pairLimitOrderFeeP(uint) external view returns (uint);

    function pairOpenFeeP(uint, uint, bool) external view returns (uint);

    function pairCloseFeeP(uint) external view returns (uint);

    function pairMinLevPosUSDC(uint) external view returns (uint);

    function lossProtectionMultiplier(uint _pairIndex, uint _tier) external view returns (uint);

    function maxWalletOI(uint _pairIndex) external view returns (uint);

    function pairMaxOI(uint _pairIndex) external view returns (uint);

    function pairsCount() external view returns (uint);
}
