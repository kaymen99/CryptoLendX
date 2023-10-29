// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {VaultAccounting} from "./libraries/VaultAccounting.sol";
import "./libraries/ChainlinkOracle.sol";
import "./libraries/TokenHelper.sol";
import "./libraries/InterestRate.sol";
import "./utils/Pausable.sol";
import "./utils/Constants.sol";
import "./interfaces/PoolStructs.sol";

contract LendingPool is Ownable, Pausable, Constants {
    using VaultAccounting for PoolStructs.Vault;
    using InterestRate for PoolStructs.InterestRateInfo;
    using TokenHelper for address;
    using ChainlinkOracle for AggregatorV3Interface;

    //--------------------------------------------------------------------
    /** VARIABLES */

    address[] private supportedTokensList;
    mapping(address => PoolStructs.SupportedERC20) supportedTokens;

    mapping(address => PoolStructs.TokenVault) private vaults;

    // user => token => (colletral, borrow) shares
    mapping(address => mapping(address => PoolStructs.AccountShares))
        private userShares;

    //--------------------------------------------------------------------
    /** ERRORS */

    error TokenNotSupported();
    error BorrowNotAllowed();
    error InsufficientBalance();
    error UnderCollateralized();
    error BorrowerIsSolvant();
    error InvalidLiquidation();
    error InvalidFeeAmount(uint fee);
    error AlreadySupported(address token);
    error OnlyManager();

    //--------------------------------------------------------------------
    /** EVENTS */

    event Deposit(address user, address token, uint256 amount, uint256 shares);
    event Borrow(address user, address token, uint256 amount, uint256 shares);
    event Repay(address user, address token, uint256 amount, uint256 shares);
    event Withdraw(address user, address token, uint256 amount, uint256 shares);
    event Liquidated(
        address borrower,
        address liquidator,
        uint256 repaidAmount,
        uint256 liquidatedCollateral,
        uint256 reward
    );
    event UpdateInterestRate(uint256 elapsedTime, uint64 newInterestRate);
    event AccruedInterest(
        uint64 interestRatePerSec,
        uint256 interestEarned,
        uint256 feesAmount,
        uint256 feesShare
    );
    event AddSupportedToken(address token);

    //--------------------------------------------------------------------
    /** FUNCTIONS */

    function supply(address token, uint256 amount) external {
        WhenNotPaused();
        allowedToken(token);
        _accrueInterest(token);

        token.transferERC20(msg.sender, address(this), amount);
        uint256 shares = vaults[token].totalAsset.toShares(amount, false);

        vaults[token].totalAsset.shares += uint128(shares);
        vaults[token].totalAsset.amount += uint128(amount);
        userShares[msg.sender][token].collateral += shares;

        emit Deposit(msg.sender, token, amount, shares);
    }

    function borrow(address token, uint256 amount) external {
        WhenNotPaused();
        if (amount > IERC20(token).balanceOf(address(this)))
            revert InsufficientBalance();

        _accrueInterest(token);
        uint256 shares = vaults[token].totalBorrow.toShares(amount, false);

        vaults[token].totalBorrow.shares += uint128(shares);
        vaults[token].totalBorrow.amount += uint128(amount);
        userShares[msg.sender][token].borrow += shares;

        token.transferERC20(address(this), msg.sender, amount);

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert BorrowNotAllowed();

        emit Borrow(msg.sender, token, amount, shares);
    }

    function repay(address token, uint256 amount) external {
        _accrueInterest(token);

        uint256 userBorrowShare = userShares[msg.sender][token].borrow;
        uint256 shares = vaults[token].totalBorrow.toShares(amount, false);
        if (amount == type(uint256).max || shares > userBorrowShare) {
            shares = userBorrowShare;
            amount = vaults[token].totalBorrow.toAmount(shares, false);
        }

        token.transferERC20(msg.sender, address(this), amount);
        unchecked {
            vaults[token].totalBorrow.shares -= uint128(shares);
            vaults[token].totalBorrow.amount -= uint128(amount);
            userShares[msg.sender][token].borrow = userBorrowShare - shares;
        }

        emit Repay(msg.sender, token, amount, shares);
    }

    function withdraw(address token, uint256 amount) external {
        _withdraw(token, amount, false);
    }

    function redeem(address token, uint256 shares) external {
        _withdraw(token, shares, true);
    }

    function liquidate(
        address account,
        address collateral,
        address userBorrowToken,
        uint256 amountToLiquidate
    ) external {
        if (healthFactor(account) >= MIN_HEALTH_FACTOR)
            revert BorrowerIsSolvant();

        uint256 collateralShares = userShares[account][collateral].collateral;
        uint256 borrowShares = userShares[account][userBorrowToken].borrow;
        if (collateralShares == 0 || borrowShares == 0) {
            revert InvalidLiquidation();
        }

        {
            uint256 totalBorrowAmount = vaults[userBorrowToken]
                .totalBorrow
                .toAmount(borrowShares, false);
            uint256 maxBorrowAmountToLiquidate = (totalBorrowAmount *
                LIQUIDATION_CLOSE_FACTOR) / BPS;

            amountToLiquidate = amountToLiquidate > maxBorrowAmountToLiquidate
                ? maxBorrowAmountToLiquidate
                : amountToLiquidate;
        }

        uint256 collateralAmountToLiquidate;
        uint256 liquidationReward;
        {
            // avoid stack too deep error
            address user = account;
            address borrowToken = userBorrowToken;
            address collToken = collateral;

            uint256 _userTotalCollateralAmount = vaults[collToken]
                .totalAsset
                .toAmount(collateralShares, false);

            uint256 collateralPrice = getTokenPrice(collToken);
            uint256 borrowTokenPrice = getTokenPrice(borrowToken);

            uint8 collateralDecimals = collToken.tokenDecimals();
            uint8 borrowTokenDecimals = borrowToken.tokenDecimals();

            collateralAmountToLiquidate =
                (amountToLiquidate *
                    borrowTokenPrice *
                    10 ** collateralDecimals) /
                (collateralPrice * 10 ** borrowTokenDecimals);
            uint256 maxLiquidationReward = (collateralAmountToLiquidate *
                LIQUIDATION_REWARD) / BPS;

            if (collateralAmountToLiquidate > _userTotalCollateralAmount) {
                collateralAmountToLiquidate = _userTotalCollateralAmount;
                amountToLiquidate =
                    ((_userTotalCollateralAmount *
                        collateralPrice *
                        10 ** borrowTokenDecimals) / borrowTokenPrice) *
                    10 ** collateralDecimals;
            } else {
                uint256 collateralBalanceAfter = _userTotalCollateralAmount -
                    collateralAmountToLiquidate;
                liquidationReward = maxLiquidationReward >
                    collateralBalanceAfter
                    ? collateralBalanceAfter
                    : maxLiquidationReward;
            }

            // Update borrow vault
            uint128 repaidBorrowShares = uint128(
                vaults[borrowToken].totalBorrow.toShares(
                    amountToLiquidate,
                    false
                )
            );
            vaults[borrowToken].totalBorrow.shares -= repaidBorrowShares;
            vaults[borrowToken].totalBorrow.amount -= uint128(
                amountToLiquidate
            );

            // Update collateral vault
            uint128 liquidatedCollShares = uint128(
                vaults[collToken].totalAsset.toShares(
                    collateralAmountToLiquidate + liquidationReward,
                    false
                )
            );
            vaults[collToken].totalAsset.shares -= liquidatedCollShares;
            vaults[collToken].totalAsset.amount -= uint128(
                collateralAmountToLiquidate + liquidationReward
            );

            // Update borrower collateral and borrow shares
            userShares[user][borrowToken].borrow -= repaidBorrowShares;
            userShares[user][collToken].collateral -= liquidatedCollShares;
        }

        // Repay borrowed amount
        userBorrowToken.transferERC20(
            msg.sender,
            address(this),
            amountToLiquidate
        );

        // Transfer collateral & liquidation reward to liquidator
        collateral.transferERC20(
            address(this),
            msg.sender,
            collateralAmountToLiquidate + liquidationReward
        );

        emit Liquidated(
            account,
            msg.sender,
            amountToLiquidate,
            collateralAmountToLiquidate + liquidationReward,
            liquidationReward
        );
    }

    function accrueInterest(
        address token
    )
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

    function getUserTotalCollateral(
        address user
    ) public view returns (uint256 totalInDai) {
        uint256 len = supportedTokensList.length;
        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];

            uint256 tokenAmount = vaults[token].totalAsset.toAmount(
                userShares[user][token].collateral,
                false
            );
            if (tokenAmount != 0) {
                totalInDai += getAmountInUSD(token, tokenAmount);
            }

            unchecked {
                ++i;
            }
        }
    }

    function getUserTotalBorrow(
        address user
    ) public view returns (uint256 totalInDai) {
        uint256 len = supportedTokensList.length;
        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];

            uint256 tokenAmount = vaults[token].totalBorrow.toAmount(
                userShares[user][token].borrow,
                false
            );
            if (tokenAmount != 0) {
                totalInDai += getAmountInUSD(token, tokenAmount);
            }

            unchecked {
                ++i;
            }
        }
    }

    function getUserData(
        address user
    ) public view returns (uint256 totalCollateral, uint256 totalBorrow) {
        totalCollateral = getUserTotalCollateral(user);
        totalBorrow = getUserTotalBorrow(user);
    }

    function getUserTokenCollateralAndBorrow(
        address user,
        address token
    )
        external
        view
        returns (uint256 tokenCollateralAmount, uint256 tokenBorrowAmount)
    {
        tokenCollateralAmount = userShares[user][token].collateral;
        tokenBorrowAmount = userShares[user][token].borrow;
    }

    function healthFactor(address user) public view returns (uint256 factor) {
        (
            uint256 totalCollateralAmount,
            uint256 totalBorrowAmount
        ) = getUserData(user);

        if (totalBorrowAmount == 0) return 100 * MIN_HEALTH_FACTOR;

        uint256 collateralAmountWithThreshold = (totalCollateralAmount *
            LIQUIDATION_THRESHOLD) / BPS;
        factor =
            (collateralAmountWithThreshold * MIN_HEALTH_FACTOR) /
            totalBorrowAmount;
    }

    function getAmountInUSD(
        address token,
        uint256 amount
    ) public view returns (uint256 value) {
        uint256 price = getTokenPrice(token);
        uint8 decimals = token.tokenDecimals();
        uint256 amountIn18Decimals = amount * 10 ** (18 - decimals);
        // return USD value scaled by 18 decimals
        value = (amountIn18Decimals * price) / PRECISION;
    }

    function getTokenPrice(address token) public view returns (uint256 price) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            supportedTokens[token].usdPriceFeed
        );
        price = priceFeed.getPrice();
    }

    function getTokenVault(
        address token
    ) public view returns (PoolStructs.TokenVault memory vault) {
        vault = vaults[token];
    }

    function getTokenInterestRateInfo(
        address token
    ) external view returns (PoolStructs.InterestRateInfo memory) {
        return vaults[token].interestRateInfo;
    }

    function amountToShares(
        address token,
        uint256 amount,
        bool isAsset
    ) external view returns (uint256 shares) {
        if (isAsset) {
            shares = uint256(vaults[token].totalAsset.toShares(amount, false));
        } else {
            shares = uint256(vaults[token].totalBorrow.toShares(amount, false));
        }
    }

    function sharesToAmount(
        address token,
        uint256 shares,
        bool isAsset
    ) external view returns (uint256 amount) {
        if (isAsset) {
            amount = uint256(vaults[token].totalAsset.toAmount(shares, false));
        } else {
            amount = uint256(vaults[token].totalBorrow.toAmount(shares, false));
        }
    }

    //--------------------------------------------------------------------
    /** INTERNAL FUNCTIONS */

    function _withdraw(address token, uint256 amount, bool share) internal {
        _accrueInterest(token);

        uint256 userCollShares = userShares[msg.sender][token].collateral;
        uint256 shares;
        if (share) {
            shares = amount;
            amount = vaults[token].totalAsset.toAmount(shares, false);
        } else {
            shares = vaults[token].totalAsset.toShares(amount, false);
        }
        if (
            userCollShares < shares ||
            IERC20(token).balanceOf(address(this)) < amount
        ) revert InsufficientBalance();

        unchecked {
            vaults[token].totalAsset.shares -= uint128(shares);
            vaults[token].totalAsset.amount -= uint128(amount);
            userShares[msg.sender][token].collateral -= shares;
        }

        token.transferERC20(address(this), msg.sender, amount);

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert UnderCollateralized();

        emit Withdraw(msg.sender, token, amount, shares);
    }

    function _accrueInterest(
        address token
    )
        internal
        returns (
            uint256 _interestEarned,
            uint256 _feesAmount,
            uint256 _feesShare,
            uint64 newRate
        )
    {
        PoolStructs.TokenVault memory _vault = vaults[token];

        if (_vault.totalAsset.amount == 0) {
            return (0, 0, 0, 0);
        }

        // Add interest only once per block
        PoolStructs.InterestRateInfo memory _currentRateInfo = _vault
            .interestRateInfo;
        if (_currentRateInfo.lastTimestamp == block.timestamp) {
            newRate = _currentRateInfo.ratePerSec;
            return (_interestEarned, _feesAmount, _feesShare, newRate);
        }

        // If there are no borrows or contract is paused, no interest accrues
        if (_vault.totalBorrow.shares == 0 || paused == 1) {
            if (paused == 2) {
                _currentRateInfo.ratePerSec = DEFAULT_INTEREST;
            }
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);
            _vault.interestRateInfo = _currentRateInfo;
        } else {
            uint256 _deltaTime = block.number - _currentRateInfo.lastBlock;

            uint _utilization = (_vault.totalBorrow.amount * PRECISION) /
                _vault.totalAsset.amount;

            // Calculate new interest rate
            uint256 _newRate = _currentRateInfo.calculateInterestRate(
                _utilization
            );

            newRate = uint64(_newRate);

            _currentRateInfo.ratePerSec = newRate;
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);

            emit UpdateInterestRate(_deltaTime, newRate);

            // Calculate interest accrued
            _interestEarned =
                (_deltaTime *
                    _vault.totalBorrow.amount *
                    _currentRateInfo.ratePerSec) /
                (PRECISION * BLOCKS_PER_YEAR);

            // Accumulate interest and fees
            _vault.totalBorrow.amount += uint128(_interestEarned);
            _vault.totalAsset.amount += uint128(_interestEarned);
            _vault.interestRateInfo = _currentRateInfo;

            if (_currentRateInfo.feeToProtocolRate > 0) {
                _feesAmount =
                    (_interestEarned * _currentRateInfo.feeToProtocolRate) /
                    BPS;

                _feesShare =
                    (_feesAmount * _vault.totalAsset.shares) /
                    (_vault.totalAsset.amount - _feesAmount);

                _vault.totalAsset.shares += uint128(_feesShare);

                // give fee shares to this contract
                userShares[address(this)][token].collateral += _feesShare;
            }
            emit AccruedInterest(
                _currentRateInfo.ratePerSec,
                _interestEarned,
                _feesAmount,
                _feesShare
            );
        }
        // save to storage
        vaults[token] = _vault;
    }

    function allowedToken(address token) internal view {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
    }

    //--------------------------------------------------------------------
    /** OWNER FUNCTIONS */

    function addSupportedToken(
        address token,
        address priceFeed,
        PoolStructs.InterestRateParams memory params
    ) external onlyOwner {
        if (supportedTokens[token].supported) revert AlreadySupported(token);
        if (params.feeToProtocolRate > MAX_PROTOCOL_FEE)
            revert InvalidFeeAmount(params.feeToProtocolRate);

        supportedTokens[token].usdPriceFeed = priceFeed;
        supportedTokens[token].supported = true;
        supportedTokensList.push(token);

        PoolStructs.InterestRateInfo storage _interestRate = vaults[token]
            .interestRateInfo;
        _interestRate.feeToProtocolRate = params.feeToProtocolRate;
        _interestRate.optimalUtilization = params.optimalUtilization;
        _interestRate.baseRate = params.baseRate;
        _interestRate.slope1 = params.slope1;
        _interestRate.slope2 = params.slope2;

        emit AddSupportedToken(token);
    }
}
