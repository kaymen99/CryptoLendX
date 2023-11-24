// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {TokenSupport} from "./TokenSupport.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/PoolStructs.sol";

/**
 * @title NFT Collateral
 * @dev used for handling the deposit and withdrawal of NFTs as collateral.
 */
contract NFTCollateral is TokenSupport, IERC721Receiver {
    using EnumerableSet for EnumerableSet.UintSet;

    error InvalidNFT();

    // track deposited NFTs for each user and NFT collection
    mapping(address user => mapping(address nft => EnumerableSet.UintSet tokenIds)) depositedNFT;

    /**
     * @dev Internal function to deposit an NFT into the contract.
     * @dev will revert if NFT is not allowed as collateral.
     * @param nftAddress The address of the NFT contract.
     * @param tokenId The ID of the NFT.
     */
    function _depositNFT(address nftAddress, uint256 tokenId) internal {
        allowedToken(nftAddress);
        IERC721(nftAddress).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );
        depositedNFT[msg.sender][nftAddress].add(tokenId);
    }

    /**
     * @dev Internal function to withdraw an NFT from the contract.
     * @dev will revert if owner did not deposit NFT.
     * @param owner The current owner of the NFT.
     * @param recipient The recipient of the withdrawn NFT.
     * @param nftAddress The address of the NFT contract.
     * @param tokenId The ID of the NFT.
     */
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

    /**
     * @dev Checks if a specific NFT has been deposited by a user.
     * @param account The address of the user.
     * @param nftAddress The address of the NFT contract.
     * @param tokenId The ID of the NFT.
     * @return Whether the NFT has been deposited by the user.
     */
    function hasDepositedNFT(
        address account,
        address nftAddress,
        uint256 tokenId
    ) public view returns (bool) {
        return depositedNFT[account][nftAddress].contains(tokenId);
    }

    /**
     * @dev Gets the list of NFTs deposited by a user for a specific NFT contract.
     * @param account The address of the user.
     * @param nftAddress The address of the NFT contract.
     */
    function getDepositedNFTs(
        address account,
        address nftAddress
    ) public view returns (uint256[] memory) {
        return depositedNFT[account][nftAddress].values();
    }

    /**
     * @dev Gets the count of NFTs deposited by a user for a specific NFT contract.
     * @param account The address of the user.
     * @param nftAddress The address of the NFT contract.
     */
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
