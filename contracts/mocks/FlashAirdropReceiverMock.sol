// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title Simple FlashAirdropReceiver mock
/// @author kaymen99
/// @notice will do anything with flashlaoned amount
contract FlashAirdropReceiverMock is IERC721Receiver {
    constructor(address pool, address nftAddress) {
        IERC721(nftAddress).setApprovalForAll(address(pool), true);
    }

    /**
     * @dev Receive an NFT to claim airdrop.
     * @param initiator The initiator of the loan.
     * @param nftAddress address of the NFT collection.
     * @param tokenIds array of tokens Ids to be lent.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     * @return bool either the operation was successful or not.
     */
    function onFlashLoan(
        address initiator,
        address nftAddress,
        uint256[] calldata tokenIds,
        bytes calldata data
    ) external returns (bool) {
        // do user operations

        return true;
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

/// @title Bad FlashAirdropReceiver implementation mock
/// @author kaymen99
/// @dev will always return false in ´onFlashLoan´ callback
/// @dev should always cause flashloan transaction to revert
contract BadFlashAirdropReceiverMock is IERC721Receiver {
    constructor(address pool, address nftAddress) {
        IERC721(nftAddress).setApprovalForAll(address(pool), true);
    }

    /**
     * @dev Receive an NFT to claim airdrop.
     * @param initiator The initiator of the loan.
     * @param nftAddress address of the NFT collection.
     * @param tokenIds array of tokens Ids to be lent.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     * @return bool either the operation was successful or not.
     */
    function onFlashLoan(
        address initiator,
        address nftAddress,
        uint256[] calldata tokenIds,
        bytes calldata data
    ) external returns (bool) {
        // do user operations

        // will always return false which should revert the flashloan tx
        return false;
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
