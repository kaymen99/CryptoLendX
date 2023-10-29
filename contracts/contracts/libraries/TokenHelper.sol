// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library TokenHelper {
    error TransferFailed();

    function tokenDecimals(
        address token
    ) internal view returns (uint8 decimals) {
        decimals = IERC20Metadata(token).decimals();
    }

    function transferERC20(
        address _token,
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        bool success;
        if (_from == address(this)) {
            success = IERC20(_token).transfer(_to, _amount);
        } else {
            success = IERC20(_token).transferFrom(_from, _to, _amount);
        }
        if (!success) revert TransferFailed();
    }
}
