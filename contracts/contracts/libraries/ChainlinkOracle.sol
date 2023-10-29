// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library ChainlinkOracle {
    error InvalidPrice();

    // duration after which returned price is considered outdated
    uint256 private constant TIMEOUT = 2 hours;

    // chainlink USD feed are in 8 decimals
    // need to multiply by 10^10 to return price in 18 decimals
    uint256 private constant USD_ORACLE_DECIMALS = 10;

    /// @notice Fetch token price using chainlink price feeds
    /// @dev Checks that returned price is positive and not stale
    /// @param priceFeed chainlink aggregator interface
    /// @return price of the token in USD (scaled by 18 decimals)
    function getPrice(
        AggregatorV3Interface priceFeed
    ) internal view returns (uint256 price) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        if (
            answer <= 0 ||
            updatedAt == 0 ||
            answeredInRound < roundId ||
            block.timestamp - updatedAt > TIMEOUT
        ) revert InvalidPrice();

        price = uint256(answer) * 10 ** USD_ORACLE_DECIMALS;
    }

    /// @notice Get timeout duration after which prices are considered stale
    function getTimeout(AggregatorV3Interface) public pure returns (uint256) {
        return TIMEOUT;
    }
}
