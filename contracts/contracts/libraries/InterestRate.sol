// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

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

library InterestRate {
    uint256 internal constant RATE_PRECISION = 1e18;

    function calculateInterestRate(
        InterestRateInfo memory _interestRateInfo,
        uint256 utilization
    ) internal pure returns (uint256 newRatePerSec) {
        uint256 optimalUtilization = uint256(
            _interestRateInfo.optimalUtilization
        );
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
