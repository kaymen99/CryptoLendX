// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract PriceConverter {
    function getPrice(address _priceFeedAddress)
        public
        view
        returns (uint256, uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            _priceFeedAddress
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        uint256 decimals = priceFeed.decimals();
        return (uint256(price), decimals);
    }

    function convertFromUSD(address _priceFeedAddress, uint256 amountInUSD)
        public
        view
        returns (uint256)
    {
        (uint256 price, uint256 decimals) = getPrice(_priceFeedAddress);
        uint256 convertedPrice = (amountInUSD * 10**decimals) / price;
        return convertedPrice;
    }

    function converttoUSD(address _priceFeedAddress, uint256 amount)
        public
        view
        returns (uint256)
    {
        (uint256 price, uint256 decimals) = getPrice(_priceFeedAddress);
        uint256 convertedPrice = (amount * price) / 10**decimals;
        return convertedPrice;
    }
}
