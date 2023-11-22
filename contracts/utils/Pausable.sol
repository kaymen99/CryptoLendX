// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
    A custom implementation for contract pausing functionalities
*/
contract Pausable is Ownable {
    // global lending pool paused state
    bool public globalPaused = true;

    // single ERC20 token vault => paused state
    mapping(address vaultToken => bool status) vaultPaused;

    /** ERRORS */
    error isPaused();
    error isNotPaused();

    /** EVENTS */
    event SystemPaused(bool state);
    event VaultPaused(address vault, bool state);

    function WhenPaused(address vault) internal view {
        if (!globalPaused && !vaultPaused[vault]) revert isNotPaused();
    }

    function WhenNotPaused(address vault) internal view {
        if (pausedStatus(vault)) revert isPaused();
    }

    function pausedStatus(address vault) public view returns (bool) {
        return globalPaused || vaultPaused[vault];
    }

    function setPausedStatus(address vault, bool status) external onlyOwner {
        if (vault == address(0)) {
            // pass address(0) to pause all lending vault
            globalPaused = status;
            emit SystemPaused(status);
        } else {
            // change paused status for a given vault in the lending pool
            vaultPaused[vault] = status;
            emit VaultPaused(vault, status);
        }
    }
}
