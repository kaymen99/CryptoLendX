// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./libraries/VaultAccounting.sol";
import "./utils/PriceConverter.sol";

contract LendingPool is PriceConverter, Ownable, Pausable {
    using VaultAccountingLibrary for Vault;

    //--------------------------------------------------------------------
    /** VARIABLES */

    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 public constant LIQUIDATION_CLOSE_FACTOR = 50; // 50%
    uint256 public constant LIQUIDATION_REWARD = 5; // 5%
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant UTILIZATION_PRECISION = 1e5;

    struct SupportedERC20 {
        address daiPriceFeed;
        bool supported;
    }

    struct InterestRateInfo {
        uint64 lastBlock;
        uint64 feeToProtocolRate;
        uint64 lastTimestamp;
        uint64 ratePerSec;
        uint64 optimalUtilization;
        uint64 baseRate;
        uint64 slope1;
        uint64 slope2;
    }

    struct TokenVault {
        Vault totalAsset;
        Vault totalBorrow;
        InterestRateInfo interestRateInfo;
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
    event Liquidated(address user, address liquidator, address rewardToken);
    event UpdateInterestRate(
        uint256 utilisationRate,
        uint256 elapsedTime,
        uint64 newInterestRate
    );
    event AccruedInterest(
        uint64 interestRatePerSec,
        uint256 interestEarned,
        uint256 feesAmount,
        uint256 feesShare
    );
    event AddSupportedToken(address token);

    //--------------------------------------------------------------------
    /** FUNCTIONS */

    function supply(address token, uint256 amount)
        external
        allowedToken(token)
    {
        _accrueInterest(token);
        TokenVault memory _vault = vaults[token];

        bool success = IERC20(token).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) revert TransferFailed();

        uint256 shares = _vault.totalAsset.toShares(amount, false);
        _vault.totalAsset.shares += uint128(shares);
        _vault.totalAsset.amount += uint128(amount);

        userCollateralBalance[msg.sender][token] += shares;
        vaults[token] = _vault;

        emit Deposit(msg.sender, token, amount, shares);
    }

    function borrow(address token, uint256 amount)
        external
        allowedToken(token)
    {
        _accrueInterest(token);
        TokenVault memory _vault = vaults[token];

        if (amount > IERC20(token).balanceOf(address(this)))
            revert InsufficientBalance();

        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();

        uint256 shares = _vault.totalBorrow.toShares(amount, false);
        _vault.totalBorrow.shares += uint128(shares);
        _vault.totalBorrow.amount += uint128(amount);

        userBorrowBalance[msg.sender][token] += shares;
        vaults[token] = _vault;

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert BorrowNotAllowed();

        emit Borrow(msg.sender, token, amount, shares);
    }

    function repay(address token, uint256 amount) external allowedToken(token) {
        _accrueInterest(token);
        TokenVault memory _vault = vaults[token];

        bool success = IERC20(token).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) revert TransferFailed();

        uint256 shares = _vault.totalBorrow.toShares(amount, false);
        _vault.totalBorrow.shares -= uint128(shares);
        _vault.totalBorrow.amount -= uint128(amount);

        userBorrowBalance[msg.sender][token] -= shares;
        vaults[token] = _vault;

        emit Repay(msg.sender, token, amount, shares);
    }

    function withdraw(address token, uint256 amount)
        external
        allowedToken(token)
    {
        _accrueInterest(token);
        TokenVault memory _vault = vaults[token];

        uint256 shares = _vault.totalAsset.toShares(amount, false);
        if (userCollateralBalance[msg.sender][token] < shares)
            revert InsufficientBalance();

        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();

        _vault.totalAsset.shares -= uint128(shares);
        _vault.totalAsset.amount -= uint128(amount);

        userCollateralBalance[msg.sender][token] -= shares;
        vaults[token] = _vault;

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert UnderCollateralized();

        emit Withdraw(msg.sender, token, amount, shares);
    }

    function liquidate(address account) external {
        if (healthFactor(account) >= MIN_HEALTH_FACTOR)
            revert BorrowerIsSolvant();

        uint256 totalBorrowAmountDAI = getUserTotalBorrow(account);

        uint256 totalLiquidationAmountDAI = (totalBorrowAmountDAI *
            LIQUIDATION_CLOSE_FACTOR) / 100;
        uint256 repaidBorrowInDAI = totalLiquidationAmountDAI;

        uint256 liquidationRewardDAI = (totalLiquidationAmountDAI *
            LIQUIDATION_REWARD) / 100;

        uint256 len = supportedTokensList.length;
        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];
            (uint256 tokenPrice, uint256 decimals) = getPrice(
                supportedTokens[token].daiPriceFeed
            );

            uint256 collateralShares = userCollateralBalance[account][token];
            uint256 borrowShares = userBorrowBalance[account][token];

            TokenVault memory _vault = vaults[token];

            // liquidate equivalent of half user collaterals amount
            if (collateralShares != 0 && totalLiquidationAmountDAI != 0) {
                _accrueInterest(token);

                uint256 collateralAmount = _vault.totalAsset.toAmount(
                    collateralShares,
                    false
                );
                uint256 tokenAmountInDai = (collateralAmount * tokenPrice) /
                    10**decimals;

                uint256 liquidatedShares;
                if (totalLiquidationAmountDAI >= tokenAmountInDai) {
                    totalLiquidationAmountDAI -= tokenAmountInDai;
                    liquidatedShares = collateralShares;
                    _vault.totalAsset.shares -= uint128(collateralShares);
                } else {
                    uint256 liquidatedTokenAmount = (totalLiquidationAmountDAI *
                        10**decimals) / tokenPrice;
                    liquidatedShares = _vault.totalAsset.toShares(
                        liquidatedTokenAmount,
                        false
                    );
                    totalLiquidationAmountDAI = 0;
                    _vault.totalAsset.shares -= uint128(liquidatedShares);
                }

                userCollateralBalance[account][token] -= liquidatedShares;
            }

            // repay equivalent of half user borrow amount
            if (borrowShares != 0 && repaidBorrowInDAI != 0) {
                _accrueInterest(token);

                uint256 borrowAmount = _vault.totalBorrow.toAmount(
                    borrowShares,
                    false
                );
                uint256 tokenAmountInDai = (borrowAmount * tokenPrice) /
                    10**decimals;

                if (repaidBorrowInDAI >= tokenAmountInDai) {
                    repaidBorrowInDAI -= tokenAmountInDai;
                    userBorrowBalance[account][token] = 0;
                    _vault.totalBorrow.shares -= uint128(borrowShares);
                    _vault.totalBorrow.amount -= uint128(borrowAmount);
                } else {
                    uint256 repaidTokenAmount = (repaidBorrowInDAI *
                        10**decimals) / tokenPrice;
                    uint256 repaidShares = _vault.totalBorrow.toShares(
                        repaidTokenAmount,
                        false
                    );

                    repaidBorrowInDAI = 0;
                    userBorrowBalance[account][token] -= repaidShares;
                    _vault.totalBorrow.shares -= uint128(repaidShares);
                    _vault.totalBorrow.amount -= uint128(repaidTokenAmount);
                }
            }

            vaults[token] = _vault;

            unchecked {
                ++i;
            }
        }

        address rewardToken = _payLiquidator(msg.sender, liquidationRewardDAI);

        emit Liquidated(account, msg.sender, rewardToken);
    }

    function _payLiquidator(address liquidator, uint256 rewardInDAI)
        internal
        returns (address rewardToken)
    {
        uint256 len = supportedTokensList.length;
        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            (uint256 tokenPrice, uint256 decimals) = getPrice(
                supportedTokens[token].daiPriceFeed
            );
            uint256 tokenBalanceInDAI = (tokenBalance * tokenPrice) /
                10**decimals;

            if (tokenBalanceInDAI >= rewardInDAI) {
                rewardToken = token;
                uint256 amount = (rewardInDAI * 10**decimals) / tokenPrice;
                bool success = IERC20(token).transfer(liquidator, amount);
                if (!success) revert TransferFailed();

                vaults[token].totalAsset.amount -= uint128(amount);
                break;
            }

            unchecked {
                ++i;
            }
        }
    }
    
    function accrueInterest(address token)
        external
        returns (
            uint256 _interestEarned,
            uint256 _feesAmount,
            uint256 _feesShare,
            uint64 _newRate
        )
    {
        return _accrueInterest(token);
    }

    function getUserTotalCollateral(address user)
        public
        view
        returns (uint256 totalInDai)
    {
        uint256 len = supportedTokensList.length;

        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];
            uint256 tokenShares = userCollateralBalance[user][token];

            TokenVault memory _vault = vaults[token];
            uint256 tokenAmount = _vault.totalAsset.toAmount(
                tokenShares,
                false
            );
            if (tokenAmount != 0) {
                uint256 amountInDai = converttoUSD(
                    supportedTokens[token].daiPriceFeed,
                    tokenAmount
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
        view
        returns (uint256 totalInDai)
    {
        uint256 len = supportedTokensList.length;

        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];
            uint256 tokenShares = userBorrowBalance[user][token];

            TokenVault memory _vault = vaults[token];
            uint256 tokenAmount = _vault.totalBorrow.toAmount(
                tokenShares,
                false
            );
            if (tokenAmount != 0) {
                uint256 amountInDai = converttoUSD(
                    supportedTokens[token].daiPriceFeed,
                    tokenAmount
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
        view
        returns (uint256 totalCollateral, uint256 totalBorrow)
    {
        totalCollateral = getUserTotalCollateral(user);
        totalBorrow = getUserTotalBorrow(user);
    }

    function healthFactor(address user) public view returns (uint256 factor) {
        (
            uint256 totalCollateralAmount,
            uint256 totalBorrowAmount
        ) = getUserData(user);

        if (totalBorrowAmount == 0) return 100 * MIN_HEALTH_FACTOR;

        uint256 collateralAmountWithThreshold = (totalCollateralAmount *
            LIQUIDATION_THRESHOLD) / 100;
        factor =
            (collateralAmountWithThreshold * MIN_HEALTH_FACTOR) /
            totalBorrowAmount;
    }
    
    function getUserTokenCollateral(address user, address token)
        external
        view
        returns (uint256 tokenCollateralAmount)
    {
        tokenCollateralAmount = userCollateralBalance[user][token];
    }

    function getUserTokenBorrow(address user, address token)
        external
        view
        returns (uint256 tokenBorrowAmount)
    {
        tokenBorrowAmount = userBorrowBalance[user][token];
    }

    function getTokenVault(address token)
        public
        view
        returns (TokenVault memory vault)
    {
        vault = vaults[token];
    }

    function _accrueInterest(address token)
        internal
        returns (
            uint256 _interestEarned,
            uint256 _feesAmount,
            uint256 _feesShare,
            uint64 _newRate
        )
    {
        TokenVault memory _vault = vaults[token];

        if (_vault.totalAsset.amount == 0) {
            return (0, 0, 0, 0);
        }

        // Add interest only once per block
        InterestRateInfo memory _currentRateInfo = _vault.interestRateInfo;
        if (_currentRateInfo.lastTimestamp == block.timestamp) {
            _newRate = _currentRateInfo.ratePerSec;
            return (_interestEarned, _feesAmount, _feesShare, _newRate);
        }

        // If there are no borrows or contract is paused, no interest accrues
        if (_vault.totalBorrow.shares == 0 || paused()) {
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);
            _vault.interestRateInfo = _currentRateInfo;
        } else {
            uint256 _deltaTime = block.timestamp -
                _currentRateInfo.lastTimestamp;

            uint256 _utilizationRate = (UTILIZATION_PRECISION *
                _vault.totalBorrow.amount) / _vault.totalAsset.amount;

            _newRate = getNewRate(_currentRateInfo, _utilizationRate);

            emit UpdateInterestRate(_utilizationRate, _deltaTime, _newRate);

            _currentRateInfo.ratePerSec = _newRate;
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);

            // Calculate interest accrued
            _interestEarned =
                (_deltaTime *
                    _vault.totalBorrow.amount *
                    _currentRateInfo.ratePerSec) /
                1e18;

            // Accumulate interest and fees

            _vault.totalBorrow.amount += uint128(_interestEarned);
            _vault.totalAsset.amount += uint128(_interestEarned);

            if (_currentRateInfo.feeToProtocolRate > 0) {
                _feesAmount = (_interestEarned *
                    _currentRateInfo.feeToProtocolRate);

                _feesShare =
                    (_feesAmount * _vault.totalAsset.shares) /
                    (_vault.totalAsset.amount - _feesAmount);

                _vault.totalAsset.shares += uint128(_feesShare);

                // give fee shares to this contract
                userCollateralBalance[address(this)][token] += _feesShare;
            }
            emit AccruedInterest(
                _currentRateInfo.ratePerSec,
                _interestEarned,
                _feesAmount,
                _feesShare
            );

            _vault = vaults[token];
        }
    }

    function getNewRate(
        InterestRateInfo memory _interestRateInfo,
        uint256 _utilization
    ) internal pure returns (uint64 _newRatePerSec) {
        uint256 optimalUtilization = uint256(
            _interestRateInfo.optimalUtilization
        );
        uint256 baseRate = uint256(_interestRateInfo.baseRate);
        uint256 slope1 = uint256(_interestRateInfo.slope1);
        uint256 slope2 = uint256(_interestRateInfo.slope2);

        if (_utilization <= optimalUtilization) {
            uint256 _slope = (slope1 * UTILIZATION_PRECISION) /
                optimalUtilization;
            _newRatePerSec = uint64(
                baseRate + ((_utilization * _slope) / UTILIZATION_PRECISION)
            );
        } else {
            uint256 _slope = ((slope2 * UTILIZATION_PRECISION) /
                (UTILIZATION_PRECISION - optimalUtilization));
            _newRatePerSec = uint64(
                baseRate +
                    slope1 +
                    (((_utilization - optimalUtilization) * _slope) /
                        UTILIZATION_PRECISION)
            );
        }
    }

    //--------------------------------------------------------------------
    /** OWNER FUNCTIONS */

    function setPaused() external onlyOwner {
        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
    }

    function addSupportedToken(address token, address priceFeed)
        external
        onlyOwner
    {
        if (supportedTokens[token].supported) revert AlreadySupported(token);

        supportedTokens[token].daiPriceFeed = priceFeed;
        supportedTokens[token].supported = true;
        supportedTokensList.push(token);

        emit AddSupportedToken(token);
    }
}
