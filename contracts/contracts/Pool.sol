// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "./libraries/VaultAccounting.sol";
import "./utils/PriceConverter.sol";

contract Pool is PriceConverter {
    using VaultAccountingLibrary for Vault;

    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 public constant LIQUIDATION_REWARD = 5; // 5%
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    struct SupportedERC20 {
        address daiPriceFeed;
        bool supported;
    }

    mapping(address => SupportedERC20) supportedTokens;
    address[] public supportedTokensList;

    struct TokenVault {
        Vault totalAsset;
        Vault totalBorrow;
    }

    modifier allowedToken(address token) {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
        _;
    }

    mapping(address => TokenVault) vaults;

    mapping(address => mapping(address => uint256))
        public userCollateralBalance;

    mapping(address => mapping(address => uint256)) public userBorrowBalance;

    function supply(address token, uint256 amount)
        external
        allowedToken(token)
    {
        TokenVault memory _vault = vaults[token];

        bool success = IERC20(token).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) revert TransferFailed();

        uint256 shares = _vault.totalAsset.toShares(_vault, amount, false);
        _vault.totalAsset.shares += shares;
        _vault.totalAsset.amount += amount;

        userCollateralBalance[msg.sender][token] += amount;
        vaults[_token] = _vault;

        emit Deposit(msg.sender, token, amount, shares);
    }

    function borrow(address token, uint256 amount)
        external
        allowedToken(token)
    {
        TokenVault memory _vault = vaults[token];

        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();

        uint256 shares = _vault.totalBorrow.toShares(_vault, amount, false);
        _vault.totalBorrow.shares += shares;
        _vault.totalBorrow.amount += amount;

        userBorrowBalance[msg.sender][token] += shares;
        vaults[_token] = _vault;

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert BorrowNotAllowed();

        emit Borrow(msg.sender, token, amount, shares);
    }

    function repay(address token, uint256 amount) external allowedToken(token) {
        TokenVault memory _vault = vaults[token];

        bool success = IERC20(token).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) revert TransferFailed();

        uint256 shares = _vault.totalBorrow.toShares(_vault, amount, false);
        _vault.totalBorrow.shares -= shares;
        _vault.totalBorrow.amount -= amount;

        userBorrowBalance[msg.sender][token] -= shares;
        vaults[_token] = _vault;

        emit Repay(msg.sender, token, amount, shares);
    }

    function withdraw(address token, uint256 amount)
        external
        allowedToken(token)
    {
        TokenVault memory _vault = vaults[_token];

        if (userCollateralBalance[msg.sender][token] < amount)
            revert InsufficientBalance();

        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();

        uint256 shares = _vault.totalAsset.toShares(_vault, amount, false);
        _vault.totalAsset.shares -= shares;
        _vault.totalAsset.amount -= amount;

        userCollateralBalance[msg.sender][token] -= amount;
        vaults[_token] = _vault;

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert UnderCollateral();

        emit Deposit(msg.sender, token, amount, shares);
    }

    function liquidate(address user) external {
        if (healthFactor(user) > MIN_HEALTH_FACTOR) revert BorrowerSolvant();

        uint256 len = supportedTokensList.length;
        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];
            uint256 amount = userCollateralBalance[user][token];

            uint256 liquidationReward = (amount * LIQUIDATION_REWARD) / 100;

            bool success = IERC20(token).transfer(
                msg.sender,
                liquidationReward
            );
            if (!success) revert TransferFailed();

            TokenVault memory _vault = vaults[token];

            uint256 assetShares = _vault.totalAsset.toShares(
                _vault,
                amount,
                false
            );
            _vault.totalAsset.shares -= assetShares;

            uint256 borrowShares = _vault.totalBorrow.toShares(
                _vault,
                amount,
                false
            );
            _vault.totalBorrow.shares -= borrowShares;
            _vault.totalBorrow.amount -= amount;

            userCollateralBalance[msg.sender][token] = 0;
            userCollateralBalance[msg.sender][token] = 0;
            vaults[_token] = _vault;

            unchecked {
                ++i;
            }
        }
    }

    function getUserTotalCollateral(address user)
        public
        returns (uint256 totalInDai)
    {
        uint256 len = supportedTokensList.length;

        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];
            uint256 amount = userCollateralBalance[msg.sender][token];
            if (amount != 0) {
                uint256 amountInDai = converttoUSD(
                    supportedTokens[token].daiPriceFeed,
                    amount
                );
                totalInDai += amountInDai;
            }

            unchecked {
                ++i;
            }
        }
    }

    function getUserTotalBorrow(address user)
        public
        returns (uint256 totalInDai)
    {
        uint256 len = supportedTokensList.length;

        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];
            uint256 amount = userBorrowBalance[msg.sender][token];
            if (amount != 0) {
                uint256 amountInDai = converttoUSD(
                    supportedTokens[token].daiPriceFeed,
                    amount
                );
                totalInDai += amountInDai;
            }

            unchecked {
                ++i;
            }
        }
    }

    function getUserData(address user)
        public
        returns (uint256 totalCollateral, uint256 totalBorrow)
    {
        totalCollateral = getUserTotalCollateral(user);
        totalBorrow = getUserTotalBorrow(user);
    }

    function healthFactor(address user) public returns (uint256 factor) {
        (
            uint256 totalCollateralAmount,
            uint256 totalBorrowAmount
        ) = getUserData(user);

        if (totalBorrowAmount == 0) return 100e18;

        uint256 collateralAmountWithThreshold = (collateralAmount *
            LIQUIDATION_THRESHOLD) / 100;
        factor = (collateralAmountWithThreshold * 1e18) / totalBorrowAmount;
    }
}
