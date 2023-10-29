// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

abstract contract Constants {
    uint256 public constant BPS = 1e5; // 5 decimals precision
    uint256 public constant PRECISION = 1e18; //18 decimals precision
    uint256 internal constant LIQUIDATION_THRESHOLD = 8e4; // 80%
    uint256 internal constant LIQUIDATION_CLOSE_FACTOR = 5e4; // 50%
    uint256 internal constant LIQUIDATION_REWARD = 5e3; // 5%
    uint256 internal constant MIN_HEALTH_FACTOR = 1e18;

    // Default Interest Rate (if borrows = 0)
    uint64 internal constant DEFAULT_INTEREST = 158247046; // 0.5% annual rate 1e18 precision

    // Protocol Fee (1e5 precision)
    uint16 internal constant DEFAULT_PROTOCOL_FEE = 0;
    uint256 internal constant MAX_PROTOCOL_FEE = 1e4; // 10%

    uint256 public constant BLOCKS_PER_YEAR = 2102400; // Average Ethereum blocks per year
}
