// SPDX-License-Identifier: MIT

pragma solidity 0.8.7;

import "./interfaces/ITradingStorage.sol";
import "./interfaces/IVaultManager.sol";
import "./interfaces/ITranche.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract Tranche is ERC4626Upgradeable, ReentrancyGuardUpgradeable {
    using MathUpgradeable for uint256;

    uint private constant PRECISION = 1e10;

    IVaultManager public vaultManager;
    address public veTranche;
    uint256 public totalReserved;
    uint256 public withdrawThreshold;
    uint256 public totalPrincipalDeposited;
    bool public feesOn;
    uint256 public depositCap;// reserveCap was giving error maybe due to selector clashes

    mapping(address => uint256) public principalSharesDeposited;
    mapping(address => uint256) public principalAssetsDeposited;

    event FeesStatusUpdated(bool feesOn);
    event VeTrancheUpdated(address indexed veTranche);
    event VaultManagerUpdated(address indexed vaultManager);
    event WithdrawThresholdUpdated(uint256 newThreshold);
    event BalanceReserved(uint256 amount);
    event BalanceReleased(uint256 amount);
    event ReserveCapUpdated(uint256 newCap);

    function initialize(address _asset, address _vaultManager, string memory trancheName) external initializer {
        vaultManager = IVaultManager(_vaultManager);
        withdrawThreshold = 90 * PRECISION;
        depositCap = 1e18; // 1 Trillion. For now. Will be less on mainnet

        __ERC4626_init_unchained(IERC20Upgradeable(_asset));
        __ERC20_init_unchained(
            string(abi.encodePacked(trancheName, abi.encodePacked(" Tranche ", ERC20(_asset).name()))),
            string(abi.encodePacked("j", ERC20(_asset).symbol()))
        );
        __ReentrancyGuard_init_unchained();
    }

    modifier onlyManager() {
        require(msg.sender == address(vaultManager), "MANAGER_ONLY");
        _;
    }

    modifier onlyGov() {
        require(msg.sender == vaultManager.gov(), "GOV_ONLY");
        _;
    }

    modifier onlyVe() {
        require(msg.sender == veTranche, "veTRANCHE_ONLY");
        _;
    }

    function setFeesOn(bool _feesOn) external onlyGov {
        feesOn = _feesOn;
        emit FeesStatusUpdated(_feesOn);
    }

    function setCap(uint _newCap) external onlyGov {
        depositCap = _newCap;
        emit ReserveCapUpdated(_newCap);
    }

    function setVeTranche(address _veTranche) external onlyGov {
        require(_veTranche != address(0), "ADDRESS_INVALID");
        veTranche = _veTranche;
        emit VeTrancheUpdated(_veTranche);
    }

    function setVaultManager(address _vaultManager) external onlyGov {
        require(_vaultManager != address(0), "ADDRESS_INVALID");
        vaultManager = IVaultManager(_vaultManager);
        emit VaultManagerUpdated(_vaultManager);
    }

    function setWithdrawThreshold(uint256 _withdrawThreshold) external {
        require(_withdrawThreshold < 100 * PRECISION, "THRESHOLD_EXCEEDS_MAX");
        withdrawThreshold = _withdrawThreshold;
        emit WithdrawThresholdUpdated(_withdrawThreshold);
    }

    // only used when the vault manager needs to reserve/release a certain amount for trading
    function reserveBalance(uint256 amount) external onlyManager {
        _reserveBalance(amount);
    }

    function releaseBalance(uint256 amount) external onlyManager {
        _releaseBalance(amount);
    }

    function withdrawAsVaultManager(uint256 amount) external onlyManager {
        _withdrawAsVaultManager(amount);
    }

    /**
     * Returns Utilizattion % upto 10 decimal points
     * For say, 21.9876543210%
     */
    function utilizationRatio() public view returns (uint256) {
        return ((totalReserved * PRECISION * 100) / super.totalAssets());
    }

    function _reserveBalance(uint256 amount) internal {
        require(super.totalAssets() >= amount + totalReserved, "RESERVE_AMOUNT_EXCEEDS_AVAILABLE");
        totalReserved += amount;
        emit BalanceReserved(amount);
    }

    function _releaseBalance(uint256 amount) internal {
        require(totalReserved >= amount, "RELEASE_AMOUNT_EXCEEDS_AVAILABLE");
        totalReserved -= amount;
        emit BalanceReleased(amount);
    }

    function _withdrawAsVaultManager(uint256 amount) internal {
        SafeERC20.safeTransfer(ERC20(asset()), address(vaultManager), amount);
    }

    function hasLiquidity(uint256 _reserveAmount) public view returns (bool) {
        return super.totalAssets() > (_reserveAmount + totalReserved);
    }

    function getEarnings(address _receiver) public view returns (int) {
        return int(convertToAssets(this.balanceOf(_receiver)) * PRECISION) - int(principalAssetsDeposited[_receiver]);
    }

    function getTotalEarnings() public view returns (int) {
        return int(ERC20(asset()).balanceOf(address(this)) * PRECISION) - int(totalPrincipalDeposited);
    }

    /* ERC4626 logic
     *
     */
    /** @dev See {IERC4626-previewDeposit}. */
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        return super.previewDeposit(assets - getDepositFeesTotal(assets));
    }

    /** @dev See {IERC4626-previewMint}. */
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        uint256 assets = super.previewMint(shares);
        return assets + getDepositFeesRaw(assets);
    }

    /** @dev See {IERC4626-previewWithdraw}. */
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        return super.previewWithdraw(assets + getWithdrawalFeesRaw(assets));
    }

    /** @dev See {IERC4626-previewRedeem}. */
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - getWithdrawalFeesTotal(assets);
    }

    function getDepositFeesRaw(uint256 assets) public view returns (uint256) {
        if (!feesOn) return 0;
        return _feeOnRaw(assets, balancingFee(true));
    }

    function getDepositFeesTotal(uint256 assets) public view returns (uint256) {
        if (!feesOn) return 0;
        return _feeOnTotal(assets, balancingFee(true));
    }

    function getWithdrawalFeesRaw(uint256 assets) public view returns (uint256) {
        if (!feesOn) return 0;
        return _feeOnRaw(assets, balancingFee(false)) + _feeOnRaw(assets, collateralHealthFee());
    }

    function getWithdrawalFeesTotal(uint256 assets) public view returns (uint256) {
        if (!feesOn) return 0;
        return _feeOnTotal(assets, balancingFee(false)) + _feeOnTotal(assets, collateralHealthFee());
    }

    function balancingFee(bool isDeposit) public view returns (uint256) {
        return vaultManager.getBalancingFee(address(this), isDeposit);
    }

    function collateralHealthFee() public view returns (uint256) {
        return vaultManager.getCollateralFee();
    }

    function _feeOnRaw(uint256 assets, uint256 feeBasePoint) private pure returns (uint256) {
        return assets.mulDiv(feeBasePoint, 1e5, MathUpgradeable.Rounding.Up);
    }

    function _feeOnTotal(uint256 assets, uint256 feeBasePoint) private pure returns (uint256) {
        return assets.mulDiv(feeBasePoint, feeBasePoint + 1e5, MathUpgradeable.Rounding.Up);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        require(totalAssets() + assets < depositCap, "DEPOSIT_CAP_BREACHED");

        uint256 fee = getDepositFeesTotal(assets);
        super._deposit(caller, receiver, assets, shares);

        if (fee > 0) {
            SafeERC20.safeTransfer(ERC20(asset()), address(vaultManager), fee);
        }

        principalSharesDeposited[receiver] += shares;
        principalAssetsDeposited[receiver] += assets * PRECISION;
        totalPrincipalDeposited += assets * PRECISION;
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        require(utilizationRatio() < withdrawThreshold, "UTILIZATION_RATIO_MAX");

        uint256 fee = getWithdrawalFeesRaw(assets);

        super._withdraw(caller, receiver, owner, assets, shares);

        if (fee > 0) {
            SafeERC20.safeTransfer(ERC20(asset()), address(vaultManager), fee);
        }

        // use original asset / share ratio and subject the relative asset amount
        if (principalSharesDeposited[receiver] > 0) {
            principalAssetsDeposited[receiver] -=
                (shares * principalAssetsDeposited[receiver]) /
                principalSharesDeposited[receiver];
            totalPrincipalDeposited -=
                (shares * principalAssetsDeposited[receiver]) /
                principalSharesDeposited[receiver];
            principalSharesDeposited[receiver] -= shares;
        }
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        super._transfer(sender, recipient, amount);
        // if it's transferring to/from a lock, do not change values VeTranche
        if (recipient == address(veTranche) || sender == address(veTranche)) return;

        // amount in this case is shares, for normal transfers
        if (principalSharesDeposited[sender] > 0) {
            principalAssetsDeposited[sender] -=
                (amount * principalAssetsDeposited[sender]) /
                principalSharesDeposited[sender];
            principalSharesDeposited[sender] -= amount;
            totalPrincipalDeposited -= (amount * principalAssetsDeposited[sender]) / principalSharesDeposited[sender];
        }

        principalAssetsDeposited[recipient] += convertToAssets(amount);
        principalSharesDeposited[recipient] += amount;
        totalPrincipalDeposited += convertToAssets(amount);
    }
}
