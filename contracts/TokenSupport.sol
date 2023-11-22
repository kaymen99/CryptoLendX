// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./libraries/ChainlinkOracle.sol";
import "./utils/Constants.sol";
import "./interfaces/PoolStructs.sol";

contract TokenSupport is Constants {
    using ChainlinkOracle for AggregatorV3Interface;

    //--------------------------------------------------------------------
    /** VARIABLES */

    // list of all supported ERC20 tokens
    address[] internal supportedERC20s;
    // list of all supported NFT ERC721 tokens
    address[] internal supportedNFTs;
    // token => SupportedToken
    mapping(address => PoolStructs.SupportedToken) internal supportedTokens;

    //--------------------------------------------------------------------
    /** ERRORS */

    error TokenNotSupported();
    error AlreadySupported(address token);
    error InvalidTokenType(PoolStructs.TokenType tokenType);

    //--------------------------------------------------------------------
    /** EVENTS */

    event AddSupportedToken(address token, PoolStructs.TokenType tokenType);

    //--------------------------------------------------------------------
    /** FUNCTIONS */

    function addSupportedToken(
        address token,
        address priceFeed,
        PoolStructs.TokenType tokenType
    ) internal {
        if (supportedTokens[token].supported) revert AlreadySupported(token);
        if (uint256(tokenType) > 2) revert InvalidTokenType(tokenType);

        supportedTokens[token].usdPriceFeed = priceFeed;
        supportedTokens[token].tokenType = tokenType;
        supportedTokens[token].supported = true;

        if (tokenType == PoolStructs.TokenType.ERC721) {
            supportedNFTs.push(token);
        } else {
            supportedERC20s.push(token);
        }

        emit AddSupportedToken(token, tokenType);
    }

    function getTokenPrice(address token) public view returns (uint256 price) {
        if (!supportedTokens[token].supported) return 0;
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            supportedTokens[token].usdPriceFeed
        );
        price = priceFeed.getPrice();
    }

    //--------------------------------------------------------------------
    /** INTERNAL FUNCTIONS */

    function allowedToken(address token) internal view {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
    }
}
