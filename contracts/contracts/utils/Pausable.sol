// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
    A custom implementation for contract pausing functionnalities
*/
contract Pausable is Ownable {
    // USE uint256 instead of bool to save gas
    // paused = 1 && active = 2
    uint256 public paused = 1;

    /** ERRORS */
    error isPaused();
    error isNotPaused();

    /** EVENTS */
    event Paused(uint256 state);

    function WhenPaused() internal view {
        if (paused == 2) revert isNotPaused();
    }

    function WhenNotPaused() internal view {
        if (paused == 1) revert isPaused();
    }

    function setPaused(uint256 _state) external onlyOwner {
        if (_state == 1 || _state == 2) paused = _state;
        emit Paused(_state);
    }
}
