// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/VaultAccounting.sol";
import "./utils/PriceConverter.sol";

contract Pool is PriceConverter, Ownable {
    using VaultAccountingLibrary for Vault;

    //--------------------------------------------------------------------
    /** VARIABLES */

    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 public constant LIQUIDATION_CLOSE_FACTOR = 50; // 50%
    uint256 public constant LIQUIDATION_REWARD = 5; // 5%
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    struct SupportedERC20 {
        address daiPriceFeed;
        bool supported;
    }

    struct TokenVault {
        Vault totalAsset;
        Vault totalBorrow;
    }

    address[] public supportedTokensList;
    mapping(address => SupportedERC20) supportedTokens;

    mapping(address => TokenVault) vaults;

    mapping(address => mapping(address => uint256))
        public userCollateralBalance;
    mapping(address => mapping(address => uint256)) public userBorrowBalance;

    //--------------------------------------------------------------------
    /** MODIFIERS */

    modifier allowedToken(address token) {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
        _;
    }

    //--------------------------------------------------------------------
    /** ERRORS */

    error TokenNotSupported();
    error BorrowNotAllowed();
    error InsufficientBalance();
    error UnderCollateralized();
    error BorrowerIsSolvant();
    error AlreadySupported(address token);
    error TransferFailed();

    //--------------------------------------------------------------------
    /** EVENTS */

    event Deposit(address user, address token, uint256 amount, uint256 shares);
    event Borrow(address user, address token, uint256 amount, uint256 shares);
    event Repay(address user, address token, uint256 amount, uint256 shares);
    event Withdraw(address user, address token, uint256 amount, uint256 shares);
    event Liquidated(address user, address liquidator);
    event AddSupportedToken(address token);

    //--------------------------------------------------------------------
    /** CONSTRUCTOR */

    //--------------------------------------------------------------------
    /** FUNCTIONS */

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
            revert UnderCollateralized();

        emit Withdraw(msg.sender, token, amount, shares);
    }

    function liquidate(address user) external {
        if (healthFactor(user) > MIN_HEALTH_FACTOR) revert BorrowerIsSolvant();

        uint256 totalBorrowAmount = getUserTotalBorrow(user);

        uint256 liquidationAmount = (totalBorrowAmount *
            LIQUIDATION_CLOSE_FACTOR) / 100;

        uint256 liquidationReward = (liquidationAmount * LIQUIDATION_REWARD) /
            100;
            
        // TODO : repay half user's debt with multiple ERC20 tokens and pay liquidator liquidation reward

        emit Liquidated(user, msg.sender);
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

    //--------------------------------------------------------------------
    /** OWNER FUNCTIONS */

    function addSupportedToken(address token, address priceFeed)
        external
        onlyOwner
    {
        uint256 len = supportedTokensList.length;
        for (uint256 i; i < len; ) {
            if (token == supportedTokensList[i]) {
                revert AlreadySupported(token);
            }
            unchecked {
                ++i;
            }
        }

        supportedTokens[token] = SupportedERC20(priceFeed, true);
        supportedTokensList.push(token);

        emit AddSupportedToken(token);
    }
}
