// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

interface IFlashAirdropReceiver {
    /**
     * @dev Receive a flash loan.
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
    ) external returns (bool);
}
