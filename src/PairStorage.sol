// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "./interfaces/ITradingStorage.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IPairStorage.sol";

contract PairStorage is Initializable, IPairStorage {
    ITradingStorage public storageT;

    uint private constant MAX_LOSS_REBATE = 50;
    uint private constant PRECISION = 1e10;
    uint private constant MIN_LEVERAGE = 2 * PRECISION;
    uint private constant MAX_LEVERAGE = 150 * PRECISION;

    uint public currentOrderId;
    uint public override pairsCount;
    uint public groupsCount;
    uint public feesCount;
    uint public skewedFeesCount;

    mapping(uint => Pair) public pairs;
    mapping(uint => Group) public groups;
    mapping(uint => Fee) public fees;
    mapping(string => mapping(string => bool)) public isPairListed;
    mapping(uint => uint[2]) public groupOIs;
    mapping(uint => mapping(uint => uint)) public lossProtection;
    mapping(uint => SkewFee) public skewFees;

    function initialize(address _storageT, uint _currentOrderId) external initializer {
        require(_currentOrderId > 0, "ORDER_ID_0");
        currentOrderId = _currentOrderId;
        storageT = ITradingStorage(_storageT);
    }

    // Modifiers
    modifier onlyGov() {
        require(msg.sender == storageT.gov(), "GOV_ONLY");
        _;
    }

    modifier groupListed(uint _groupIndex) {
        require(groups[_groupIndex].minLeverage > 0, "GROUP_NOT_LISTED");
        _;
    }
    modifier feeListed(uint _feeIndex) {
        require(fees[_feeIndex].openFeeP > 0, "FEE_NOT_LISTED");
        _;
    }

    modifier feedOk(Feed calldata _feed) {
        require(_feed.maxDeviationP > 0, "WRONG_FEED");
        _;
    }
    modifier groupOk(Group calldata _group) {
        require(
            _group.minLeverage >= MIN_LEVERAGE &&
                _group.maxLeverage <= MAX_LEVERAGE &&
                _group.minLeverage < _group.maxLeverage,
            "WRONG_LEVERAGES"
        );
        _;
    }

    modifier feeOk(Fee calldata _fee) {
        require(
            _fee.openFeeP > 0 && _fee.closeFeeP > 0 && _fee.limitOrderFeeP > 0 && _fee.minLevPosUSDC > 0,
            "WRONG_FEES"
        );
        _;
    }

    function addSkewOpenFees(SkewFee calldata _skewFee) external onlyGov {
        skewFees[skewedFeesCount] = _skewFee;
        emit SkewFeeAdded(skewedFeesCount++);
    }

    function udpateSkewOpenFees(uint _pairIndex, SkewFee calldata _skewFee) external onlyGov {
        skewFees[_pairIndex] = _skewFee;
        emit SkewFeeUpdated(_pairIndex);
    }

    // Manage pairs
    function addPair(
        Pair calldata _pair
    ) public onlyGov feedOk(_pair.feed) groupListed(_pair.groupIndex) feeListed(_pair.feeIndex) {
        require(!isPairListed[_pair.from][_pair.to], "PAIR_ALREADY_LISTED");

        pairs[pairsCount] = _pair;
        isPairListed[_pair.from][_pair.to] = true;

        emit PairAdded(pairsCount++, _pair.from, _pair.to);
    }

    function addPairs(Pair[] calldata _pairs) external {
        for (uint i; i < _pairs.length; ++i) {
            addPair(_pairs[i]);
        }
    }

    function updatePair(
        uint _pairIndex,
        Pair calldata _pair
    ) external onlyGov feedOk(_pair.feed) feeListed(_pair.feeIndex) {
        Pair storage p = pairs[_pairIndex];
        require(isPairListed[p.from][p.to], "PAIR_NOT_LISTED");

        p.feed = _pair.feed;
        p.spreadP = _pair.spreadP;
        p.feeIndex = _pair.feeIndex;
        if (_pair.backupFeed.maxDeviationP > 0 && _pair.backupFeed.feedId != address(0)) {
            p.backupFeed = _pair.backupFeed;
        } else {
            delete p.backupFeed;
        }

        emit PairUpdated(_pairIndex);
    }

    function delistPair(
        uint _pairIndex
    ) external onlyGov {
        Pair storage p = pairs[_pairIndex];
        require(isPairListed[p.from][p.to], "PAIR_NOT_LISTED");
        
        isPairListed[p.from][p.to]= false;
        emit PairUpdated(_pairIndex);
    }
    // Manage groups
    function addGroup(Group calldata _group) external onlyGov groupOk(_group) {
        groups[groupsCount] = _group;
        emit GroupAdded(groupsCount++, _group.name);
    }

    function updateGroup(uint _id, Group calldata _group) external onlyGov groupListed(_id) groupOk(_group) {
        groups[_id] = _group;
        emit GroupUpdated(_id);
    }

    // Manage fees
    function addFee(Fee calldata _fee) external onlyGov feeOk(_fee) {
        fees[feesCount] = _fee;
        emit FeeAdded(feesCount++, _fee.name);
    }

    function updateFee(uint _id, Fee calldata _fee) external onlyGov feeListed(_id) feeOk(_fee) {
        fees[_id] = _fee;
        emit FeeUpdated(_id);
    }

    // Update collateral open exposure for a group (callbacks)
    function updateGroupOI(uint _pairIndex, uint _amount, bool _long, bool _increase) external override {
        require(msg.sender == storageT.callbacks(), "CALLBACKS_ONLY");

        uint[2] storage oi = groupOIs[pairs[_pairIndex].groupIndex];
        uint index = _long ? 0 : 1;

        if (_increase) {
            oi[index] += _amount;
        } else {
            oi[index] = oi[index] > _amount ? oi[index] - _amount : 0;
        }
    }

    function updateLossProtectionMultiplier(
        uint _pairIndex,
        uint[] calldata _tier,
        uint[] calldata _multiplierPercent
    ) external onlyGov {
        require(_tier.length == _multiplierPercent.length);

        for (uint i; i < _tier.length; ++i) {
            require(_multiplierPercent[i] >= MAX_LOSS_REBATE, "REBATE_EXCEEDS_MAX");
            lossProtection[_pairIndex][_tier[i]] = _multiplierPercent[i];
        }

        emit LossProtectionAdded(_pairIndex, _tier, _multiplierPercent);
    }

    // Fetch relevant info for order (aggregator)
    function pairJob(uint _pairIndex) external override returns (string memory, string memory, bytes32, address, uint) {
        require(msg.sender == address(storageT.priceAggregator()), "AGGREGATOR_ONLY");

        Pair memory p = pairs[_pairIndex];
        require(isPairListed[p.from][p.to], "PAIR_NOT_LISTED");

        return (p.from, p.to, p.feed.feedId, p.backupFeed.feedId, currentOrderId++);
    }

    // Getters (pairs & groups)
    function pairFeed(uint _pairIndex) external view override returns (Feed memory) {
        return pairs[_pairIndex].feed;
    }

    function pairBackupFeed(uint _pairIndex) external view override returns (BackupFeed memory) {
        return pairs[_pairIndex].backupFeed;
    }

    function pairSpreadP(uint _pairIndex) external view override returns (uint) {
        return pairs[_pairIndex].spreadP;
    }

    function pairGroupIndex(uint _pairIndex) external view override returns (uint) {
        return pairs[_pairIndex].groupIndex;
    }

    function pairMinLeverage(uint _pairIndex) external view override returns (uint) {
        return groups[pairs[_pairIndex].groupIndex].minLeverage;
    }

    function pairMaxLeverage(uint _pairIndex) external view override returns (uint) {
        return groups[pairs[_pairIndex].groupIndex].maxLeverage;
    }

    function groupMaxOI(uint _pairIndex) public view override returns (uint) {
        return
            (groups[pairs[_pairIndex].groupIndex].maxOpenInterestP * storageT.vaultManager().currentBalanceUSDC()) /
            100;
    }

    function pairMaxOI(uint _pairIndex) external view override returns (uint) {
        return (pairs[_pairIndex].groupOpenInterestPecentage * groupMaxOI(_pairIndex)) / 100;
    }

    function groupOI(uint _pairIndex) public view override returns (uint) {
        return groupOIs[pairs[_pairIndex].groupIndex][0] + groupOIs[pairs[_pairIndex].groupIndex][1];
    }

    function lossProtectionMultiplier(uint _pairIndex, uint _tier) external view override returns (uint) {
        return lossProtection[_pairIndex][_tier];
    }

    function guaranteedSlEnabled(uint _pairIndex) external view override returns (bool) {
        return pairs[_pairIndex].groupIndex == 0; // crypto only
    }

    function maxWalletOI(uint _pairIndex) external view override returns (uint) {
        return (groupMaxOI(_pairIndex) * pairs[_pairIndex].maxWalletOI) / 100;
    }

    function pairOpenFeeP(uint _pairIndex, uint _leveragedPosition, bool _buy) external view override returns (uint) {
        uint openInterestUSDCLong = storageT.openInterestUSDC(_pairIndex, 0);
        uint openInterestUSDCShort = storageT.openInterestUSDC(_pairIndex, 1);

        if (_buy) {
            openInterestUSDCLong += _leveragedPosition;
        } else {
            openInterestUSDCShort += _leveragedPosition;
        }

        uint openInterestPct = (100 * (_buy ? openInterestUSDCShort : openInterestUSDCLong)) /
            (openInterestUSDCLong + openInterestUSDCShort);
        SkewFee memory skewFee = skewFees[_pairIndex];
        if (openInterestPct >= skewFee.thresholdHigh) return (skewFee.feeHigh * PRECISION) / 10000;
        if (openInterestPct >= skewFee.thresholdMid)
            return (uint((skewFee.slopeMid * int(openInterestPct) + skewFee.interceptMid)) * PRECISION) / 10000;
        if (openInterestPct >= skewFee.thresholdLow)
            return (uint((skewFee.slopeLow * int(openInterestPct) + skewFee.interceptLow)) * PRECISION) / 10000;

        return fees[pairs[_pairIndex].feeIndex].openFeeP;
    }

    function pairCloseFeeP(uint _pairIndex) external view override returns (uint) {
        return fees[pairs[_pairIndex].feeIndex].closeFeeP;
    }

    function pairLimitOrderFeeP(uint _pairIndex) external view override returns (uint) {
        return fees[pairs[_pairIndex].feeIndex].limitOrderFeeP;
    }

    function pairMinLevPosUSDC(uint _pairIndex) external view override returns (uint) {
        return fees[pairs[_pairIndex].feeIndex].minLevPosUSDC;
    }

    // Getters (backend)
    function pairsBackend(uint _index) external view returns (Pair memory, Group memory, Fee memory) {
        Pair memory p = pairs[_index];
        return (p, groups[p.groupIndex], fees[p.feeIndex]);
    }
}
