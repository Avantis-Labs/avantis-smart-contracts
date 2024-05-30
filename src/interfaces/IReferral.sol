// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

interface IReferral {
    struct Tier {
        uint256 feeDiscountPct; // e.g. 9500 for 95% of the original fee
        uint256 refRebatePct; // e.g. 500 for 5% rebate to referrer
    }

    //Events
    event SetHandler(address handler, bool isActive);
    event SetTraderReferralCode(address account, bytes32 code);
    event SetTier(uint256 tierId, uint256 feeDiscountPct, uint256 refRebatePct);
    event SetReferrerTier(address referrer, uint256 tierId);
    event SetReferrerDiscountShare(address referrer, uint256 discountShare);
    event RegisterCode(address account, bytes32 code);
    event SetCodeOwner(address account, address newAccount, bytes32 code);
    event GovSetCodeOwner(bytes32 code, address newAccount);
    event SetGov(address);
    function codeOwners(bytes32 _code) external view returns (address);

    function traderReferralCodes(address _account) external view returns (bytes32);

    function referrerTiers(address _account) external view returns (uint256);

    function getTraderReferralInfo(address _account) external view returns (bytes32, address);

    function setTraderReferralCode(address _account, bytes32 _code) external;

    function setTier(uint256 _tierId, uint256 _totalRebate, uint256 _discountShare) external;

    function setReferrerTier(address _referrer, uint256 _tierId) external;

    function govSetCodeOwner(bytes32 _code, address _newAccount) external;

    function traderReferralDiscount(address _account, uint _feeBips) external view returns (uint, address, uint);
}
