// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

interface PoolStructs {
    struct SupportedERC20 {
        address usdPriceFeed;
        bool supported;
    }

    struct AccountShares {
        uint256 collateral;
        uint256 borrow;
    }

    struct Vault {
        uint128 amount;
        uint128 shares;
    }

    struct TokenVault {
        Vault totalAsset;
        Vault totalBorrow;
        InterestRateInfo interestRateInfo;
    }

    struct InterestRateInfo {
        uint64 lastBlock;
        uint64 feeToProtocolRate;
        uint64 lastTimestamp;
        uint64 ratePerSec;
        uint64 optimalUtilization;
        uint64 baseRate;
        uint64 slope1;
        uint64 slope2;
    }

    struct InterestRateParams {
        uint64 feeToProtocolRate;
        uint64 optimalUtilization;
        uint64 baseRate;
        uint64 slope1;
        uint64 slope2;
    }
}
