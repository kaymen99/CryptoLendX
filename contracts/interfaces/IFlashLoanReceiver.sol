// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

interface IFlashLoanReceiver {
    /**
     * @dev Receive a flash loan.
     * @param initiator The initiator of the loan.
     * @param tokens array of tokens addresses to be lent.
     * @param amounts array of tokens amounts to be lent.
     * @param fees The additional fee amount of paid to the protocol.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     * @return bool either the operation was successful or not.
     */
    function onFlashLoan(
        address initiator,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external returns (bool);
}
