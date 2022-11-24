// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PoolMock {
    address public atoken;

    constructor(address atokenAddress) {
        atoken = atokenAddress;
    }

    mapping(address => uint256) erc20DaiBalances;

    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        IERC20(atoken).transfer(msg.sender, amount);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256) {
        IERC20(atoken).transferFrom(msg.sender, address(this), amount);
        IERC20(asset).transfer(to, amount);
        return amount;
    }
}
