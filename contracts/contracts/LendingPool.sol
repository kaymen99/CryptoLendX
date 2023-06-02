// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/VaultAccounting.sol";
import "./libraries/InterestRate.sol";
import "./utils/Pausable.sol";
import "./utils/Constants.sol";

contract LendingPool is Pausable, Constants {
    using VaultAccountingLibrary for Vault;

    //--------------------------------------------------------------------
    /** VARIABLES */

    struct SupportedERC20 {
        address usdPriceFeed;
        bool supported;
    }

    struct TokenVault {
        Vault totalAsset;
        Vault totalBorrow;
        InterestRateInfo interestRateInfo;
    }

    address[] private supportedTokensList;
    mapping(address => SupportedERC20) supportedTokens;

    mapping(address => TokenVault) private vaults;

    mapping(address => mapping(address => uint256))
        private userCollateralShares;
    mapping(address => mapping(address => uint256)) private userBorrowShares;

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
    error TransferFailed();

    //--------------------------------------------------------------------
    /** EVENTS */

    event Deposit(address user, address token, uint256 amount, uint256 shares);
    event Borrow(address user, address token, uint256 amount, uint256 shares);
    event Repay(address user, address token, uint256 amount, uint256 shares);
    event Withdraw(address user, address token, uint256 amount, uint256 shares);
    event Liquidated(address user, address liquidator);
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

        _transferERC20(token, msg.sender, address(this), amount);
        uint256 shares = vaults[token].totalAsset.toShares(amount, false);

        vaults[token].totalAsset.shares += uint128(shares);
        vaults[token].totalAsset.amount += uint128(amount);
        userCollateralShares[msg.sender][token] += shares;

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
        userBorrowShares[msg.sender][token] += shares;

        _transferERC20(token, address(this), msg.sender, amount);

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert BorrowNotAllowed();

        emit Borrow(msg.sender, token, amount, shares);
    }

    function repay(address token, uint256 amount) external {
        _accrueInterest(token);

        uint256 userBorrowShare = userBorrowShares[msg.sender][token];
        uint256 shares = vaults[token].totalBorrow.toShares(amount, false);
        if (amount == type(uint256).max || shares > userBorrowShare) {
            shares = userBorrowShare;
            amount = vaults[token].totalBorrow.toAmount(shares, false);
        }

        _transferERC20(token, msg.sender, address(this), amount);
        unchecked {
            vaults[token].totalBorrow.shares -= uint128(shares);
            vaults[token].totalBorrow.amount -= uint128(amount);
            userBorrowShares[msg.sender][token] = userBorrowShare - shares;
        }

        emit Repay(msg.sender, token, amount, shares);
    }

    function withdraw(address token, uint256 amount) external {
        uint256 userShares = userCollateralShares[msg.sender][token];
        uint256 shares = vaults[token].totalAsset.toShares(amount, false);
        if (
            userShares < shares ||
            IERC20(token).balanceOf(address(this)) < amount
        ) revert InsufficientBalance();

        _accrueInterest(token);

        unchecked {
            vaults[token].totalAsset.shares -= uint128(shares);
            vaults[token].totalAsset.amount -= uint128(amount);
            userCollateralShares[msg.sender][token] -= shares;
        }

        _transferERC20(token, address(this), msg.sender, amount);

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert UnderCollateralized();

        emit Withdraw(msg.sender, token, amount, shares);
    }

    function redeem(address token, uint256 shares) external {
        uint256 userShares = userCollateralShares[msg.sender][token];
        uint256 amount = vaults[token].totalAsset.toAmount(shares, false);
        if (
            userShares < shares ||
            IERC20(token).balanceOf(address(this)) < amount
        ) revert InsufficientBalance();

        _accrueInterest(token);

        unchecked {
            vaults[token].totalAsset.shares -= uint128(shares);
            vaults[token].totalAsset.amount -= uint128(amount);
            userCollateralShares[msg.sender][token] = userShares - shares;
        }

        _transferERC20(token, address(this), msg.sender, amount);

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert UnderCollateralized();

        emit Withdraw(msg.sender, token, amount, shares);
    }

    function liquidate(
        address account,
        address collateral,
        address userBorrowToken,
        uint256 amountToLiquidate
    ) external {
        if (healthFactor(account) >= MIN_HEALTH_FACTOR)
            revert BorrowerIsSolvant();

        uint256 collateralShares = userCollateralShares[account][collateral];
        uint256 borrowShares = userBorrowShares[account][userBorrowToken];
        if (collateralShares == 0 || borrowShares == 0) {
            revert InvalidLiquidation();
        }

        TokenVault memory _borrowVault = vaults[userBorrowToken];
        {
            uint256 totalBorrowAmount = _borrowVault.totalBorrow.toAmount(
                borrowShares,
                false
            );
            uint256 maxBorrowAmountToLiquidate = (totalBorrowAmount *
                LIQUIDATION_CLOSE_FACTOR) / PRECISION;

            amountToLiquidate = amountToLiquidate > maxBorrowAmountToLiquidate
                ? maxBorrowAmountToLiquidate
                : amountToLiquidate;
        }

        TokenVault memory _collateralVault = vaults[collateral];

        uint256 collateralAmountToLiquidate;
        uint256 liquidationReward;
        {
            // avoid stack too deep error

            uint256 _userTotalCollateralAmount = _collateralVault
                .totalAsset
                .toAmount(collateralShares, false);

            uint256 collateralPrice = getTokenPrice(collateral);
            uint256 borrowTokenPrice = getTokenPrice(userBorrowToken);

            collateralAmountToLiquidate =
                (amountToLiquidate * borrowTokenPrice) /
                collateralPrice;
            uint256 maxLiquidationReward = (collateralAmountToLiquidate *
                LIQUIDATION_REWARD) / PRECISION;

            if (collateralAmountToLiquidate > _userTotalCollateralAmount) {
                collateralAmountToLiquidate = _userTotalCollateralAmount;
                amountToLiquidate =
                    (_userTotalCollateralAmount * collateralPrice) /
                    borrowTokenPrice;
            } else {
                uint256 collateralBalanceAfter = _userTotalCollateralAmount -
                    collateralAmountToLiquidate;
                liquidationReward = maxLiquidationReward >
                    collateralBalanceAfter
                    ? collateralBalanceAfter
                    : maxLiquidationReward;
            }

            // Update borrow vault
            _borrowVault.totalBorrow.shares -= uint128(
                _borrowVault.totalBorrow.toShares(amountToLiquidate, false)
            );
            _borrowVault.totalBorrow.amount -= uint128(amountToLiquidate);

            // Update collateral vault
            _collateralVault.totalAsset.shares -= uint128(
                _collateralVault.totalAsset.toShares(
                    collateralAmountToLiquidate + liquidationReward,
                    false
                )
            );
            _collateralVault.totalAsset.amount -= uint128(
                collateralAmountToLiquidate + liquidationReward
            );
        }

        // Repay borrowed amount
        _transferERC20(
            userBorrowToken,
            msg.sender,
            address(this),
            amountToLiquidate
        );

        // Transfer collateral & liquidation reward to liquidator
        _transferERC20(
            collateral,
            address(this),
            msg.sender,
            collateralAmountToLiquidate + liquidationReward
        );

        // Save vaults states
        vaults[collateral] = _collateralVault;
        vaults[userBorrowToken] = _borrowVault;

        emit Liquidated(account, msg.sender);
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
                userCollateralShares[user][token],
                false
            );
            if (tokenAmount != 0) {
                totalInDai += getTokenPrice(token) * tokenAmount;
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
                userBorrowShares[user][token],
                false
            );
            if (tokenAmount != 0) {
                totalInDai += getTokenPrice(token) * tokenAmount;
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
        tokenCollateralAmount = userCollateralShares[user][token];
        tokenBorrowAmount = userBorrowShares[user][token];
    }

    function healthFactor(address user) public view returns (uint256 factor) {
        (
            uint256 totalCollateralAmount,
            uint256 totalBorrowAmount
        ) = getUserData(user);

        if (totalBorrowAmount == 0) return 100 * MIN_HEALTH_FACTOR;

        uint256 collateralAmountWithThreshold = (totalCollateralAmount *
            LIQUIDATION_THRESHOLD) / PRECISION;
        factor =
            (collateralAmountWithThreshold * MIN_HEALTH_FACTOR) /
            totalBorrowAmount;
    }

    function getTokenPrice(address token) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            supportedTokens[token].usdPriceFeed
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();

        // return price in USD scaled by priceFeed.decimals()
        return uint256(price);
    }

    function getTokenVault(
        address token
    ) public view returns (TokenVault memory vault) {
        vault = vaults[token];
    }

    function getTokenInterestRateInfo(
        address token
    ) external view returns (InterestRateInfo memory) {
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
        TokenVault memory _vault = vaults[token];

        if (_vault.totalAsset.amount == 0) {
            return (0, 0, 0, 0);
        }

        // Add interest only once per block
        InterestRateInfo memory _currentRateInfo = _vault.interestRateInfo;
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

            uint _utilization = (_vault.totalBorrow.amount * RATE_PRECISION) /
                _vault.totalAsset.amount;

            // Calculate new interest rate
            uint256 _newRate = InterestRate.calculateInterestRate(
                _currentRateInfo,
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
                (RATE_PRECISION * BLOCKS_PER_YEAR);

            // Accumulate interest and fees
            _vault.totalBorrow.amount += uint128(_interestEarned);
            _vault.totalAsset.amount += uint128(_interestEarned);
            _vault.interestRateInfo = _currentRateInfo;

            if (_currentRateInfo.feeToProtocolRate > 0) {
                _feesAmount =
                    (_interestEarned * _currentRateInfo.feeToProtocolRate) /
                    PRECISION;

                _feesShare =
                    (_feesAmount * _vault.totalAsset.shares) /
                    (_vault.totalAsset.amount - _feesAmount);

                _vault.totalAsset.shares += uint128(_feesShare);

                // give fee shares to this contract
                userCollateralShares[address(this)][token] += _feesShare;
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

    function _transferERC20(
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

    //--------------------------------------------------------------------
    /** OWNER FUNCTIONS */

    function addSupportedToken(
        address token,
        address priceFeed,
        InterestRateParams memory params
    ) external onlyOwner {
        if (supportedTokens[token].supported) revert AlreadySupported(token);
        if (params.feeToProtocolRate > MAX_PROTOCOL_FEE)
            revert InvalidFeeAmount(params.feeToProtocolRate);

        supportedTokens[token].usdPriceFeed = priceFeed;
        supportedTokens[token].supported = true;
        supportedTokensList.push(token);

        InterestRateInfo storage _interestRate = vaults[token].interestRateInfo;
        _interestRate.feeToProtocolRate = params.feeToProtocolRate;
        _interestRate.optimalUtilization = params.optimalUtilization;
        _interestRate.baseRate = params.baseRate;
        _interestRate.slope1 = params.slope1;
        _interestRate.slope2 = params.slope2;

        emit AddSupportedToken(token);
    }
}
