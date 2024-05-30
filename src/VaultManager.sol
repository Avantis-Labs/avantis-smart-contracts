// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "./interfaces/ITradingStorage.sol";
import "./interfaces/ITranche.sol";
import "./interfaces/IVeTranche.sol";
import "./interfaces/IVaultManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract VaultManager is Initializable, IVaultManager {
    address public override gov;
    ITradingStorage public storageT;
    ITranche public junior;
    ITranche public senior;

    // lock params
    uint256 public override maxLockTime;
    uint256 public override minLockTime;

    // fees
    uint256 public override earlyWithdrawFee;
    uint256 public balancingFee;
    uint256 public balancingDeltaThreshold;
    uint256[5] public collateralFees;
    uint256[5] public bufferThresholds;

    // skew params for multpliers
    uint256 public targetReserveRatio;
    uint256 public constrainedLiquidityThreshold;
    uint256 public baseMultiplier;
    uint256 public minMultiplier;
    uint256 public maxMultiplier;

    // curve parameters
    uint256 public multiplierCoeff;
    uint256 public multiplierDenom;

    // reward parameters
    uint256 public totalRewards;
    uint256 public rewardPeriod;
    uint256 public lastRewardTime;

    int public currentOpenPnl;

    mapping(address => bool) public isTradingContract;

    uint private constant PRECISION = 1e10; // 10 decimals

    function initialize(address _gov, address _storageT) external initializer {
        gov = _gov;
        storageT = ITradingStorage(_storageT);
        minLockTime = 14 days;
        maxLockTime = 180 days;
        earlyWithdrawFee = 10000; // 10 Percent
        balancingFee = 500;
        targetReserveRatio = 65;
        balancingDeltaThreshold = 6250;
        constrainedLiquidityThreshold = 6750;
        baseMultiplier = 100;
        minMultiplier = 80;
        maxMultiplier = 240;
        multiplierCoeff = 3103;
        multiplierDenom = 9366500;
        rewardPeriod = 7 days;
        lastRewardTime = block.timestamp;
        totalRewards = 0; // Not needed to set
        currentOpenPnl = 0;
        collateralFees = [250, 150, 100, 25, 10];
        bufferThresholds = [90, 95, 100, 105, 110];
    }

    modifier onlyGov() {
        require(msg.sender == gov, "GOV_ONLY");
        _;
    }
    modifier onlyCallbacks() {
        require(msg.sender == storageT.callbacks(), "CALLBACKS_ONLY");
        _;
    }

    modifier onlyTranches() {
        require(msg.sender == address(junior) || msg.sender == address(senior), "TRANCHES_ONLY");
        _;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "INVALID_ADDRESS");
        emit GovChanged(gov, _gov);
        gov = _gov;
    }

    function setStorage(address _storageT) external onlyGov {
        require(_storageT != address(0), "INVALID_ADDRESS");
        emit StorageChanged(address(storageT), _storageT);
        storageT = ITradingStorage(_storageT);
    }

    function setJuniorTranche(address _junior) external onlyGov {
        require(_junior != address(0), "INVALID_ADDRESS");
        emit JuniorTrancheChanged(address(junior), _junior);
        junior = ITranche(_junior);
    }

    function setSeniorTranche(address _senior) external onlyGov {
        require(_senior != address(0), "INVALID_ADDRESS");
        emit SeniorTrancheChanged(address(senior), _senior);
        senior = ITranche(_senior);
    }

    function setReserveRatio(uint256 _targetReserveRatio) external onlyGov {
        require(_targetReserveRatio < 100, "TOO_HIGH");
        emit ReserveRatioUpdated(targetReserveRatio, _targetReserveRatio);
        targetReserveRatio = _targetReserveRatio;
    }

    function setBalancingDeltaThreshold(uint256 _balancingDeltaThreshold) external onlyGov {
        require(_balancingDeltaThreshold < 10000, "TOO_HIGH");
        emit BalancingDeltaUpdated(balancingDeltaThreshold, _balancingDeltaThreshold);
        balancingDeltaThreshold = _balancingDeltaThreshold;
    }

    function setConstrainedLiquidityThreshold(uint256 _constrainedLiquidityThreshold) external onlyGov {
        require(_constrainedLiquidityThreshold < 10000, "TOO_HIGH");
        emit ConstrainedLiquidityThresholdUpdated(constrainedLiquidityThreshold, _constrainedLiquidityThreshold);
        constrainedLiquidityThreshold = _constrainedLiquidityThreshold;
    }

    function setEarlyWithdrawFee(uint256 _earlyWithdrawFee) external onlyGov {
        require(_earlyWithdrawFee <= 10000, "TOO_HIGH");
        emit EarlyWithdrawFeeUpdated(earlyWithdrawFee, _earlyWithdrawFee);
        earlyWithdrawFee = _earlyWithdrawFee;
    }

    function setBalancingFee(uint256 _balancingFee) external onlyGov {
        require(_balancingFee <= 10000, "TOO_HIGH");
        balancingFee = _balancingFee;
    }

    ///dev Check if this can be made dynamic
    function setCollateralFees(uint256[5] memory _collateralFees) external onlyGov {
        for (uint i = 0; i < _collateralFees.length; ) {
            require(_collateralFees[i] < 10000, "TOO_HIGH");
            if (i != _collateralFees.length)
                require(_collateralFees[i] < _collateralFees[i + 1], "NOT_DESCENDING_ORDER");
            i++;
        }
        collateralFees = _collateralFees;
    }

    function setBufferThresholds(uint256[5] calldata _bufferThresholds) external onlyGov {
        for (uint i; i < _bufferThresholds.length; ) {
            if (i != _bufferThresholds.length)
                require(_bufferThresholds[i] < _bufferThresholds[i + 1], "NOT_DESCENDING_ORDER");
            i++;
        }
        bufferThresholds = _bufferThresholds;
    }

    function setMaxLockTime(uint256 _maxLockTime) external onlyGov {
        require(_maxLockTime > 0, "MAX_LOCK_TIME_IS_ZERO");
        maxLockTime = _maxLockTime;
    }

    function setMinLockTime(uint256 _minLockTime) external onlyGov {
        require(_minLockTime > 0, "MIN_LOCK_TIME_IS_ZERO");
        minLockTime = _minLockTime;
    }

    function setBaseMultiplier(uint256 _baseMultiplier) external onlyGov {
        require(_baseMultiplier > 99, "TOO_LOW");
        baseMultiplier = _baseMultiplier;
    }

    function setMinMultiplier(uint256 _minMultiplier) external onlyGov {
        require(_minMultiplier > 0, "TOO_LOW");
        require(_minMultiplier < baseMultiplier, "TOO_HIGH");
        minMultiplier = _minMultiplier;
    }

    function setMaxMultiplier(uint256 _maxMultiplier) external onlyGov {
        require(_maxMultiplier > baseMultiplier, "TOO_LOW");
        maxMultiplier = _maxMultiplier;
    }

    function setMultiplierDenom(uint256 _multiplierDenom) external onlyGov {
        require(_multiplierDenom > 0, "NUMBER_INVALID");
        multiplierDenom = _multiplierDenom;
    }

    function setMultiplierCoeff(uint256 _multiplierCoeff) external onlyGov {
        require(_multiplierCoeff > 0, "NUMBER_INVALID");
        multiplierCoeff = _multiplierCoeff;
    }

    function setRewardPeriod(uint256 _rewardPeriod) external onlyGov {
        require(_rewardPeriod > 24 * 60 * 60, "TOO_LOW");
        rewardPeriod = _rewardPeriod;
    }

    function setCurrentOpenPnl(int _currentOpenPnl) external onlyGov {
        currentOpenPnl = _currentOpenPnl;
    }

    function addTradingContract(address _trading) external onlyGov {
        require(_trading != address(0));
        isTradingContract[_trading] = true;
        emit TradingContractAdded(_trading);
    }

    function removeTradingContract(address _trading) external onlyGov {
        require(_trading != address(0));
        isTradingContract[_trading] = false;
        emit TradingContractRemoved(_trading);
    }

    function getReserveRatio(uint _reserveAmount) public view returns (uint256) {
        if (_reserveAmount > 0) {
            uint currentReserveRatio = getCurrentReserveRatio();
            if (
                !isNormalLiquidityMode(currentReserveRatio) ||
                !junior.hasLiquidity((_reserveAmount * targetReserveRatio) / 100) ||
                !senior.hasLiquidity((_reserveAmount * targetReserveRatio) / 100)
            ) {
                // constrained Liquidity Mode
                return currentReserveRatio;
            }
        }
        return targetReserveRatio;
    }

    function getReleaseRatio() public view returns (uint256) {
        return (junior.totalReserved() * 100 * PRECISION) / (junior.totalReserved() + senior.totalReserved());
    }

    function getCurrentReserveRatio() public view returns (uint256) {
        IERC20 asset = IERC20(junior.asset());
        if (asset.balanceOf(address(senior)) == 0 && asset.balanceOf(address(junior)) == 0) {
            return targetReserveRatio;
        }
        return
            (100 * asset.balanceOf(address(junior))) /
            (asset.balanceOf(address(junior)) + asset.balanceOf(address(senior)));
    }

    function getBalancingFee(address tranche, bool isDeposit) external view override returns (uint256) {
        if ((getCurrentReserveRatio() * 100) > balancingDeltaThreshold) {
            // charge junior deposits, and senior withdraws
            if ((tranche == address(junior) && isDeposit) || (tranche == address(senior) && !isDeposit)) {
                return balancingFee;
            }
        }
        if ((getCurrentReserveRatio() * 100) < 1e4 - balancingDeltaThreshold) {
            // charge senior deposits, and junior withdrawals
            if ((tranche == address(senior) && isDeposit) || (tranche == address(junior) && !isDeposit)) {
                return balancingFee;
            }
        }
        return 0;
    }

    function getBufferRatio() public view returns (uint256) {
        IERC20 asset = IERC20(junior.asset());
        uint256 currentTrancheBalances = asset.balanceOf(address(junior)) + asset.balanceOf(address(senior));
        uint256 currentBalance = asset.balanceOf(address(this)) - totalRewards;

        // bankrupt...
        if (int(currentTrancheBalances) == 0) return 0;
        if (currentOpenPnl > int(currentBalance + currentTrancheBalances)) return 0;
        return
            uint256(
                ((int(currentBalance + currentTrancheBalances) - currentOpenPnl) * 100) / int(currentTrancheBalances)
            );
    }

    function getCollateralFee() external view override returns (uint256) {
        uint256 currentBufferRatio = getBufferRatio();
        for (uint i = 0; i < bufferThresholds.length; ) {
            if (currentBufferRatio < bufferThresholds[i]) {
                return collateralFees[i];
            }
            i++;
        }
        return 0; // default free
    }

    function _distributeVeRewards(
        IVeTranche veTranche,
        uint256 rewards,
        uint256 totalLockPoints
    ) internal returns (uint256) {
        // if locktime is not accumulated, no rewards to give
        if (totalLockPoints > 0) {
            veTranche.distributeRewards(rewards, totalLockPoints);
            IERC20(junior.asset()).transfer(address(veTranche), rewards);
        }

        return totalLockPoints;
    }

    function _distributeRewards(address tranche, uint256 rewards) internal {
        if (rewards > 0) {
            if (tranche == address(junior) || tranche == address(senior)) {
                IERC20(junior.asset()).transfer(tranche, rewards);
            }
        }
    }

    function isNormalLiquidityMode(uint _currentReserveRatio) internal view returns (bool) {
        if (
            _currentReserveRatio * 100 > 10000 - constrainedLiquidityThreshold &&
            _currentReserveRatio * 100 < constrainedLiquidityThreshold
        ) return true;

        return false;
    }

    function getProfitMultiplier() public view returns (uint256) {
        uint256 currentReserveRatio = getCurrentReserveRatio();
        if (isNormalLiquidityMode(currentReserveRatio)) return baseMultiplier;

        if (currentReserveRatio > targetReserveRatio) {
            uint256 totalRange = 100 - targetReserveRatio;
            uint256 distance = (currentReserveRatio - targetReserveRatio);
            uint256 rateOfChange = (baseMultiplier - minMultiplier);

            return baseMultiplier - (distance * rateOfChange) / totalRange;
        } else if (currentReserveRatio < (100 - targetReserveRatio)) {
            uint256 distance = (targetReserveRatio - currentReserveRatio);
            return baseMultiplier + (((distance ** 2) * multiplierCoeff * 100) / multiplierDenom);
        }
        return baseMultiplier;
    }

    function getLossMultiplier() public view returns (uint256) {
        return baseMultiplier;
    }

    function allocateRewards(uint256 rewards) external override {
        require(rewards > 0, "NO_REWARDS_ALLOCATED");
        if (!isTradingContract[msg.sender]) IERC20(junior.asset()).transferFrom(msg.sender, address(this), rewards);
        emit RewardsAllocated(rewards);
        totalRewards += rewards;
    }

    function sendReferrerRebateToStorage(uint _amount) external override onlyCallbacks {
        require(_amount > 0, "NO_REWARDS_ALLOCATED");
        require(totalRewards >= _amount, "UNDERFLOW_DETECTED");

        totalRewards -= _amount;
        IERC20(junior.asset()).transfer(address(storageT), _amount);

        emit ReferralRebateAwarded(_amount);
    }

    function distributeRewards() external onlyGov {
        require(totalRewards > 0, "NO_REWARDS_ALLOCATED");
        uint256 timeSinceLastReward = block.timestamp - lastRewardTime;
        // 1. reserve ratio / 100 provides reward allocation
        // 2. time since last reward / rewardPeriod provides owed rewards
        // 3. profit multiplier adjust total rewards
        uint256 totalRewardsForPeriod = (totalRewards * timeSinceLastReward) / rewardPeriod;
        if (totalRewards < totalRewardsForPeriod) totalRewardsForPeriod = totalRewards;

        uint256 totalJuniorRewards = (getProfitMultiplier() * totalRewardsForPeriod * getReserveRatio(0)) / 100 / 100;
        totalJuniorRewards = (totalJuniorRewards > totalRewardsForPeriod) ? totalRewardsForPeriod : totalJuniorRewards;

        uint256 totalSeniorRewards = totalRewardsForPeriod - totalJuniorRewards;

        uint256 juniorTotalPoints = IVeTranche(junior.veTranche()).getTotalLockPoints();
        uint256 seniorTotalPoints = IVeTranche(senior.veTranche()).getTotalLockPoints();

        lastRewardTime = block.timestamp;
        totalRewards -= totalRewardsForPeriod;

        ///dev, Why this double check here
        if ((junior.totalSupply() + juniorTotalPoints) > 0) {
            uint256 juniorRewards = (totalJuniorRewards * junior.totalSupply()) /
                (junior.totalSupply() + juniorTotalPoints);
            uint256 veJuniorRewards = totalJuniorRewards - juniorRewards;

            _distributeVeRewards(IVeTranche(junior.veTranche()), veJuniorRewards, juniorTotalPoints);
            _distributeRewards(address(junior), juniorRewards);
            _distributeCollectedFeeShares(address(junior));
        }

        if ((senior.totalSupply() + seniorTotalPoints) > 0) {
            uint256 seniorRewards = (totalSeniorRewards * senior.totalSupply()) /
                (senior.totalSupply() + seniorTotalPoints);
            uint256 veSeniorRewards = totalSeniorRewards - seniorRewards;

            _distributeVeRewards(IVeTranche(senior.veTranche()), veSeniorRewards, seniorTotalPoints);
            _distributeRewards(address(senior), seniorRewards);
            _distributeCollectedFeeShares(address(senior));
        }
        emit RewardsDistributed(totalJuniorRewards, totalSeniorRewards);
    }

    function distributeVeRewards(
        address _tranche,
        uint256 rewards,
        uint256 totalPoints
    ) public onlyGov returns (uint256) {
        return _distributeVeRewards(IVeTranche(ITranche(_tranche).veTranche()), rewards, totalPoints);
    }

    function distributeTrancheRewards(address _tranche, uint256 rewards) public onlyGov {
        _distributeRewards(_tranche, rewards);
    }

    function _sendUSDCToTrader(address _trader, uint _amount) internal {
        uint256 balanceAvailable = storageT.USDC().balanceOf(address(this)) - totalRewards;
        if (_amount > balanceAvailable) {
            // take difference (losses) from vaults
            uint256 difference = _amount - balanceAvailable;

            uint256 juniorUSDC = (getLossMultiplier() * difference * getReserveRatio(0)) / 100 / 100;
            juniorUSDC = (juniorUSDC > difference) ? difference : juniorUSDC;

            uint256 seniorUSDC = difference - juniorUSDC;

            junior.withdrawAsVaultManager(juniorUSDC);
            senior.withdrawAsVaultManager(seniorUSDC);
        }
        require(storageT.USDC().transfer(_trader, _amount));
        emit USDCSentToTrader(_trader, _amount);
    }

    function sendUSDCToTrader(address _trader, uint _amount) external override onlyCallbacks {
        _sendUSDCToTrader(_trader, _amount);
    }

    function _receiveUSDCFromTrader(address _trader, uint _amount, uint _vaultFee) internal {
        storageT.transferUSDC(address(storageT), address(this), _amount);

        if (_vaultFee > 0) totalRewards += _vaultFee;
        emit USDCReceivedFromTrader(_trader, _amount, _vaultFee);
    }

    function receiveUSDCFromTrader(address _trader, uint _amount, uint _vaultFee) external override onlyCallbacks {
        _receiveUSDCFromTrader(_trader, _amount, _vaultFee);
    }

    function reserveBalance(uint256 _amount) external override onlyCallbacks {
        uint256 juniorAmount = (_amount * getReserveRatio(_amount)) / 100;
        uint256 seniorAmount = _amount - juniorAmount;

        junior.reserveBalance(juniorAmount);
        senior.reserveBalance(seniorAmount);
    }

    function releaseBalance(uint256 _amount) external override onlyCallbacks {
        uint256 juniorAmount = (_amount * getReleaseRatio()) / PRECISION / 100;

        uint256 seniorAmount = ((_amount - juniorAmount));
        if (seniorAmount > senior.totalReserved()) {
            juniorAmount += seniorAmount - senior.totalReserved();
            seniorAmount = senior.totalReserved();
        }

        junior.releaseBalance(juniorAmount);
        senior.releaseBalance(seniorAmount);
    }

    function currentBalanceUSDC() external view override returns (uint256) {
        return junior.totalAssets() + senior.totalAssets();
    }

    function distributeCollectedFeeShares(address _tranche) external onlyGov {
        _distributeCollectedFeeShares(_tranche);
    }

    /**
     *
     * @param _tranche Address of Tranche to distribute rewards for
     * @notice Distribute collected fee in veTranche lock/unlock
     */
    function _distributeCollectedFeeShares(address _tranche) internal {
        uint256 assets = ITranche(_tranche).redeem(
            ITranche(_tranche).maxRedeem(address(this)),
            address(this),
            address(this)
        );

        if (assets > 0) {
            uint256 totalPoints = IVeTranche(ITranche(_tranche).veTranche()).getTotalLockPoints();
            _distributeVeRewards(IVeTranche(ITranche(_tranche).veTranche()), assets, totalPoints);
        }
    }
}
