// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./interfaces/ITranche.sol";
import "./interfaces/IVaultManager.sol";
import "./interfaces/IVeTranche.sol";

contract VeTranche is ERC721Upgradeable, ReentrancyGuardUpgradeable, IVeTranche {
    using MathUpgradeable for uint256;
    using Counters for Counters.Counter;
    Counters.Counter public tokenIds;

    ITranche public tranche;
    IVaultManager public vaultManager;

    mapping(uint256 => uint256) public rewardsByTokenId;
    mapping(uint256 => uint256) public tokensByTokenId;
    mapping(uint256 => uint256) public lockTimeByTokenId;
    mapping(uint256 => uint256) public lockStartTimeByTokenId;
    mapping(uint256 => uint256) public lockMultiplierByTokenId;
    mapping(uint256 => uint256) public lastSharePoint;
    
    uint256 private constant _PRECISION = 1e6;

    uint public multiplierCoeff;
    uint public multiplierDenom;
    uint public rewardsDistributedPerSharePerLockPoint;
    uint public totalLockPoints;

    function initialize(address _tranche, address _vaultManager) external initializer {
        tranche = ITranche(_tranche);
        vaultManager = IVaultManager(_vaultManager);
        multiplierCoeff = 181500000;
        multiplierDenom = 1960230 * _PRECISION;

        __ERC721_init_unchained(
            string(abi.encodePacked("Locked ", tranche.name())),
            string(abi.encodePacked("ve-", tranche.symbol()))
        );
        __ReentrancyGuard_init_unchained();
    }

    modifier onlyGov() {
        require(msg.sender == vaultManager.gov(), "GOV_ONLY");
        _;
    }
    modifier onlyManager() {
        require(msg.sender == address(vaultManager), "MANAGER_ONLY");
        _;
    }

    function setVaultManager(address _vaultManager) external onlyManager {
        require(_vaultManager != address(0), "ADDRESS_INVALID");
        vaultManager = IVaultManager(_vaultManager);
    }

    function setMultiplierDenom(uint256 _multiplierDenom) external onlyGov {
        require(_multiplierDenom > 0, "NUMBER_INVALID");
        multiplierDenom = _multiplierDenom;
    }

    function setMultiplierCoeff(uint256 _multiplierCoeff) external onlyGov {
        require(_multiplierCoeff > 0, "NUMBER_INVALID");
        multiplierCoeff = _multiplierCoeff;
    }

    function getEarlyWithdrawFee(uint256 assets) public view returns (uint256) {
        return tranche.feesOn() ? assets.mulDiv(vaultManager.earlyWithdrawFee(), 1e5, MathUpgradeable.Rounding.Up) : 0;
    }

    function getMaxLockTime() public view returns (uint256) {
        return vaultManager.maxLockTime();
    }

    function getMinLockTime() public view returns (uint256) {
        return vaultManager.minLockTime();
    }

    function lock(uint256 shares, uint endTime) public nonReentrant returns (uint256) {
        require(endTime - block.timestamp <= getMaxLockTime(), "OVER_MAX_LOCK_TIME");
        require(endTime - block.timestamp >= getMinLockTime(), "LOCK_TIME_TOO_SMALL");

        require(shares > 0, "LOCK_AMOUNT_IS_ZERO");
        require(tranche.balanceOf(msg.sender) >= shares, "INSUFFICIENT_TRANCHE_TOKENS");

        uint256 nextTokenId = tokenIds.current();
        tranche.transferFrom(msg.sender, address(this), shares);
        _mint(msg.sender, nextTokenId);

        tokensByTokenId[nextTokenId] = shares;
        lockTimeByTokenId[nextTokenId] = endTime;
        lockStartTimeByTokenId[nextTokenId] = block.timestamp;
        rewardsByTokenId[nextTokenId] = 0;
        lockMultiplierByTokenId[nextTokenId] = getLockPoints(endTime - block.timestamp);
        totalLockPoints += (shares * lockMultiplierByTokenId[nextTokenId]) / _PRECISION;
        
        tokenIds.increment();
        emit Locked(nextTokenId, msg.sender, shares, endTime, lockMultiplierByTokenId[nextTokenId]);

        return nextTokenId;
    }

    function checkUnlockFee(uint256 tokenId) public view returns (uint256) {
        if (lockTimeByTokenId[tokenId] > block.timestamp) {
            uint256 fee = getEarlyWithdrawFee(tokensByTokenId[tokenId]);

            if (fee > 0) {
                uint256 timeLeft = lockTimeByTokenId[tokenId] - block.timestamp;
                uint256 totalTime = lockTimeByTokenId[tokenId] - lockStartTimeByTokenId[tokenId];
                fee = fee.mulDiv(timeLeft, totalTime, MathUpgradeable.Rounding.Up);
            }
            return fee;
        }
        return 0;
    }

    function unlock(uint256 tokenId) public nonReentrant {
        require(tokensByTokenId[tokenId] > 0, "NOTHING_TO_UNLOCK");
        require(msg.sender == ownerOf(tokenId), "NOT_OWNER");
        uint256 fee = checkUnlockFee(tokenId);

        _claimRewards(tokenId);
        _burn(tokenId);

        tranche.transfer(msg.sender, tokensByTokenId[tokenId] - fee);
        tranche.transfer(address(vaultManager), fee);

        emit Unlocked(tokenId, msg.sender, tokensByTokenId[tokenId], fee);
        totalLockPoints -= tokensByTokenId[tokenId] * lockMultiplierByTokenId[tokenId] / _PRECISION;

        delete tokensByTokenId[tokenId];
        delete rewardsByTokenId[tokenId];
        delete lockTimeByTokenId[tokenId];
        delete lockStartTimeByTokenId[tokenId];
        delete lockMultiplierByTokenId[tokenId];
    }

    function forceUnlock(uint256 _tokenId) public nonReentrant {
        require(lockTimeByTokenId[_tokenId] < block.timestamp, "TOO_EARLY");
        require(tokensByTokenId[_tokenId] > 0, "NOTHING_TO_UNLOCK");

        _claimRewards(_tokenId);
        tranche.transfer(_ownerOf(_tokenId), tokensByTokenId[_tokenId] );

        _burn(_tokenId);

        emit Unlocked(_tokenId, _ownerOf(_tokenId), tokensByTokenId[_tokenId], 0);
        totalLockPoints -= tokensByTokenId[_tokenId]* lockMultiplierByTokenId[_tokenId] / _PRECISION;

        delete tokensByTokenId[_tokenId];
        delete rewardsByTokenId[_tokenId];
        delete lockTimeByTokenId[_tokenId];
        delete lockStartTimeByTokenId[_tokenId];
        delete lockMultiplierByTokenId[_tokenId];
    }

    function getLockPoints(uint256 timeLocked) public view override returns (uint256) {
        uint256 lockedDays = timeLocked > getMinLockTime() ? (timeLocked - getMinLockTime()) / 86400 : 0;
        uint256 points = _PRECISION + (((lockedDays ** 2) * multiplierCoeff * _PRECISION) / multiplierDenom);
        return points;
    }

    function distributeRewards(
        uint256 rewards,
        uint256 _totalLockPoints
    ) external override onlyManager returns (uint256) {
        return _distributeRewards(rewards, _totalLockPoints);
    }

    function getTotalLockPoints() external view override returns (uint256) {
        return totalLockPoints;
    }

    function _distributeRewards(uint256 rewards, uint256 _totalLockPoints) internal returns (uint256) {

        rewardsDistributedPerSharePerLockPoint += (rewards * (_PRECISION **2)) / _totalLockPoints;
        emit RewardsDistributed(rewards, _totalLockPoints);

        return _totalLockPoints;
    }

    // for situations where we need to manually distribute rewards and do the
    // calculation off-chain to save gas
    function distributeReward(uint256 reward, uint256 tokenId) external onlyManager {
        rewardsByTokenId[tokenId] += reward;
    }

    function _claimRewards(uint256 tokenId) internal {
        _updateReward(tokenId);
        if (rewardsByTokenId[tokenId] > 0) {
            SafeERC20.safeTransfer(IERC20(tranche.asset()), _ownerOf(tokenId), rewardsByTokenId[tokenId]);
            emit RewardClaimed(tokenId, _ownerOf(tokenId), rewardsByTokenId[tokenId]);
            rewardsByTokenId[tokenId] = 0;
        }   
    }

    function claimRewards(uint256 tokenId) public nonReentrant {
        require(msg.sender == _ownerOf(tokenId));
        _claimRewards(tokenId);
    }

    function _updateReward(uint256 _id) internal {
        if(lastSharePoint[_id] == rewardsDistributedPerSharePerLockPoint ) return;

        uint256 pendingReward = ((rewardsDistributedPerSharePerLockPoint - lastSharePoint[_id]) *
                                tokensByTokenId[_id] * 
                                lockMultiplierByTokenId[_id]) /
                                (_PRECISION **3);
        rewardsByTokenId[_id] += pendingReward;
        lastSharePoint[_id] =  rewardsDistributedPerSharePerLockPoint;

    }

}
