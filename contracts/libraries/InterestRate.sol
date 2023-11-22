// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "../interfaces/PoolStructs.sol";

library InterestRate {
    uint256 internal constant RATE_PRECISION = 1e18;

    function calculateInterestRate(
        PoolStructs.VaultInfo memory _interestRateInfo,
        uint256 utilization
    ) internal pure returns (uint256 newRatePerSec) {
        uint256 optimalUtilization = _interestRateInfo.optimalUtilization;
        uint256 baseRate = uint256(_interestRateInfo.baseRate);
        uint256 slope1 = uint256(_interestRateInfo.slope1);
        uint256 slope2 = uint256(_interestRateInfo.slope2);

        if (utilization <= optimalUtilization) {
            uint256 rate = (utilization * slope1) / optimalUtilization;
            newRatePerSec = baseRate + rate;
        } else {
            uint256 utilizationDelta = utilization - optimalUtilization;
            uint256 excessUtilizationRate = (utilizationDelta *
                RATE_PRECISION) / (RATE_PRECISION - optimalUtilization);
            newRatePerSec =
                baseRate +
                slope1 +
                (excessUtilizationRate * slope2) /
                RATE_PRECISION;
        }
    }
}
