// SPDX-License-Identifier: ISC
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

library InterestRate {
    uint256 public constant UTILIZATION_PRECISION = 1e5;

    function calculateInterestRate(
        InterestRateInfo memory _interestRateInfo,
        uint256 totalAssetAmount,
        uint256 totalBorrowAmount
    ) internal pure returns (uint64 _newRatePerSec) {
        uint256 utilization = (UTILIZATION_PRECISION * totalBorrowAmount) /
            totalAssetAmount;

        uint256 optimalUtilization = uint256(
            _interestRateInfo.optimalUtilization
        );
        uint256 baseRate = uint256(_interestRateInfo.baseRate);
        uint256 slope1 = uint256(_interestRateInfo.slope1);
        uint256 slope2 = uint256(_interestRateInfo.slope2);

        if (utilization <= optimalUtilization) {
            uint256 _slope = (slope1 * UTILIZATION_PRECISION) /
                optimalUtilization;
            _newRatePerSec = uint64(
                baseRate + ((utilization * _slope) / UTILIZATION_PRECISION)
            );
        } else {
            uint256 _slope = ((slope2 * UTILIZATION_PRECISION) /
                (UTILIZATION_PRECISION - optimalUtilization));
            _newRatePerSec = uint64(
                baseRate +
                    slope1 +
                    (((utilization - optimalUtilization) * _slope) /
                        UTILIZATION_PRECISION)
            );
        }
    }
}
