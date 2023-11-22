// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {TokenSupport} from "./TokenSupport.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/PoolStructs.sol";

contract NFTCollateral is TokenSupport, IERC721Receiver {
    using EnumerableSet for EnumerableSet.UintSet;

    error InvalidNFT();

    mapping(address user => mapping(address nft => EnumerableSet.UintSet tokenIds)) depositedNFT;

    function _depositNFT(address nftAddress, uint256 tokenId) internal {
        allowedToken(nftAddress);
        IERC721(nftAddress).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );
        depositedNFT[msg.sender][nftAddress].add(tokenId);
    }

    function _withdrawNFT(
        address owner,
        address recipient,
        address nftAddress,
        uint256 tokenId
    ) internal {
        if (!hasDepositedNFT(owner, nftAddress, tokenId)) revert InvalidNFT();
        depositedNFT[owner][nftAddress].remove(tokenId);
        IERC721(nftAddress).safeTransferFrom(address(this), recipient, tokenId);
    }

    function hasDepositedNFT(
        address account,
        address nftAddress,
        uint256 tokenId
    ) public view returns (bool) {
        return depositedNFT[account][nftAddress].contains(tokenId);
    }

    function getDepositedNFTs(
        address account,
        address nftAddress
    ) public view returns (uint256[] memory) {
        return depositedNFT[account][nftAddress].values();
    }

    function getDepositedNFTCount(
        address account,
        address nftAddress
    ) public view returns (uint256) {
        return depositedNFT[account][nftAddress].length();
    }

    /**
     * @dev ERC721 receiver callback to accept incoming NFT transfers.
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
