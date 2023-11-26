// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Simple FlashloanReceiver mock
/// @author kaymen99
/// @notice will do anything with flashlaoned amount
contract FlashloanReceiverMock {
    constructor(address pool, address weth, address wbtc) {
        IERC20(weth).approve(address(pool), type(uint256).max);
        IERC20(wbtc).approve(address(pool), type(uint256).max);
    }

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
    ) external returns (bool) {
        // do user operations

        return true;
    }
}

/// @title Bad FlashloanReceiver implementation mock
/// @author kaymen99
/// @dev will always return false in ´onFlashLoan´ callback
/// @dev should always cause flashloan transaction to revert
contract BadFlashloanReceiverMock {
    constructor(address pool, address weth, address wbtc) {
        IERC20(weth).approve(address(pool), type(uint256).max);
        IERC20(wbtc).approve(address(pool), type(uint256).max);
    }

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
    ) external returns (bool) {
        // do user operations

        // will always return false which should revert the flashloan tx
        return false;
    }
}
