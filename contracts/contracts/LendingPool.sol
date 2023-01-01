// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./libraries/VaultAccounting.sol";
import "./libraries/InterestRate.sol";

contract LendingPool {
    using VaultAccountingLibrary for Vault;

    //--------------------------------------------------------------------
    /** VARIABLES */

    uint256 public constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 public constant LIQUIDATION_CLOSE_FACTOR = 50; // 50%
    uint256 public constant LIQUIDATION_REWARD = 5; // 5%
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    // USE uint256 instead of bool to save gas
    // paused = 1 && active = 2
    uint256 public paused = 1;
    address public manager;

    struct SupportedERC20 {
        address daiPriceFeed;
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
        private userCollateralBalance;
    mapping(address => mapping(address => uint256)) private userBorrowBalance;

    //--------------------------------------------------------------------
    /** ERRORS */

    error TokenNotSupported();
    error BorrowNotAllowed();
    error InsufficientBalance();
    error UnderCollateralized();
    error BorrowerIsSolvant();
    error InvalidLiquidation();
    error AlreadySupported(address token);
    error OnlyManager();
    error TransferFailed();
    error PoolIsPaused();

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

    constructor() {
        manager = msg.sender;
    }

    //--------------------------------------------------------------------
    /** FUNCTIONS */

    function supply(address token, uint256 amount) external {
        WhenNotPaused();
        allowedToken(token);

        _accrueInterest(token);

        transferERC20(token, msg.sender, address(this), amount);

        uint256 shares = vaults[token].totalAsset.toShares(amount, false);
        vaults[token].totalAsset.shares += uint128(shares);
        vaults[token].totalAsset.amount += uint128(amount);

        userCollateralBalance[msg.sender][token] += shares;

        emit Deposit(msg.sender, token, amount, shares);
    }

    function borrow(address token, uint256 amount) external {
        WhenNotPaused();
        allowedToken(token);

        _accrueInterest(token);

        if (amount > IERC20(token).balanceOf(address(this)))
            revert InsufficientBalance();

        uint256 shares = vaults[token].totalBorrow.toShares(amount, false);
        vaults[token].totalBorrow.shares += uint128(shares);
        vaults[token].totalBorrow.amount += uint128(amount);

        userBorrowBalance[msg.sender][token] += shares;

        transferERC20(token, address(this), msg.sender, amount);

        if (healthFactor(msg.sender) <= MIN_HEALTH_FACTOR)
            revert BorrowNotAllowed();

        emit Borrow(msg.sender, token, amount, shares);
    }

    function repay(address token, uint256 amount) external {
        _accrueInterest(token);

        transferERC20(token, msg.sender, address(this), amount);

        uint256 shares = vaults[token].totalBorrow.toShares(amount, false);
        vaults[token].totalBorrow.shares -= uint128(shares);
        vaults[token].totalBorrow.amount -= uint128(amount);

        userBorrowBalance[msg.sender][token] -= shares;

        emit Repay(msg.sender, token, amount, shares);
    }

    function withdraw(address token, uint256 amount) external {
        _accrueInterest(token);

        uint256 shares = vaults[token].totalAsset.toShares(amount, false);
        if (userCollateralBalance[msg.sender][token] < shares)
            revert InsufficientBalance();

        vaults[token].totalAsset.shares -= uint128(shares);
        vaults[token].totalAsset.amount -= uint128(amount);

        unchecked {
            userCollateralBalance[msg.sender][token] -= shares;
        }

        transferERC20(token, address(this), msg.sender, amount);

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

        uint256 collateralShares = userCollateralBalance[account][collateral];
        uint256 borrowShares = userBorrowBalance[account][userBorrowToken];
        if (collateralShares == 0 || borrowShares == 0) {
            revert InvalidLiquidation();
        }

        TokenVault memory _borrowTokenVault = vaults[userBorrowToken];
        uint256 totalBorrowAmount = _borrowTokenVault.totalBorrow.toAmount(
            borrowShares,
            false
        );
        uint256 maxBorrowAmountToLiquidate = (totalBorrowAmount *
            LIQUIDATION_CLOSE_FACTOR) / 100;

        amountToLiquidate = amountToLiquidate > maxBorrowAmountToLiquidate
            ? maxBorrowAmountToLiquidate
            : amountToLiquidate;

        TokenVault memory _collateralTokenVault = vaults[collateral];
        uint256 _userCollateralBalance = _collateralTokenVault
            .totalAsset
            .toAmount(collateralShares, false);

        uint256 collateralPrice = getTokenPrice(collateral);
        uint256 borrowTokenPrice = getTokenPrice(userBorrowToken);

        uint256 collateralAmountToLiquidate = (amountToLiquidate *
            borrowTokenPrice) / collateralPrice;

        if (collateralAmountToLiquidate > _userCollateralBalance) {
            collateralAmountToLiquidate = _userCollateralBalance;
            amountToLiquidate =
                (_userCollateralBalance * collateralPrice) /
                borrowTokenPrice;
        }

        _borrowTokenVault.totalBorrow.shares -= uint128(
            _borrowTokenVault.totalBorrow.toShares(amountToLiquidate, false)
        );
        _borrowTokenVault.totalBorrow.amount -= uint128(amountToLiquidate);

        _collateralTokenVault.totalAsset.shares -= uint128(
            collateralAmountToLiquidate
        );

        vaults[collateral] = _collateralTokenVault;
        vaults[userBorrowToken] = _borrowTokenVault;

        emit Liquidated(account, msg.sender);
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

            uint256 tokenAmount = vaults[token].totalAsset.toAmount(
                userCollateralBalance[user][token],
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

    function getUserTotalBorrow(address user)
        public
        view
        returns (uint256 totalInDai)
    {
        uint256 len = supportedTokensList.length;
        for (uint256 i; i < len; ) {
            address token = supportedTokensList[i];

            uint256 tokenAmount = vaults[token].totalBorrow.toAmount(
                userBorrowBalance[user][token],
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

    function getUserData(address user)
        public
        view
        returns (uint256 totalCollateral, uint256 totalBorrow)
    {
        totalCollateral = getUserTotalCollateral(user);
        totalBorrow = getUserTotalBorrow(user);
    }

    function getUserTokenCollateralAndBorrow(address user, address token)
        external
        view
        returns (uint256 tokenCollateralAmount, uint256 tokenBorrowAmount)
    {
        tokenCollateralAmount = userCollateralBalance[user][token];
        tokenBorrowAmount = userBorrowBalance[user][token];
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

    function getTokenVault(address token)
        public
        view
        returns (TokenVault memory vault)
    {
        vault = vaults[token];
    }

    function getTokenPrice(address token) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            supportedTokens[token].daiPriceFeed
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        uint256 decimals = priceFeed.decimals();
        return uint256(price) / 10**decimals;
    }

    function getTokenInterestRate(address token) public view returns (uint256) {
        return vaults[token].interestRateInfo.ratePerSec;
    }

    //--------------------------------------------------------------------
    /** INTERNAL FUNCTIONS */

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
        if (_vault.totalBorrow.shares == 0 || paused == 1) {
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);
            _vault.interestRateInfo = _currentRateInfo;
        } else {
            uint256 _deltaTime = block.timestamp -
                _currentRateInfo.lastTimestamp;

            _newRate = InterestRate.calculateInterestRate(
                _currentRateInfo,
                _vault.totalAsset.amount,
                _vault.totalBorrow.amount
            );

            emit UpdateInterestRate(_deltaTime, _newRate);

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

    function allowedToken(address token) internal view {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
    }

    function WhenNotPaused() internal view {
        if (paused == 1) revert PoolIsPaused();
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

    //--------------------------------------------------------------------
    /** OWNER FUNCTIONS */

    function setPaused(uint256 _state) external {
        if (msg.sender != manager) revert OnlyManager();
        if (_state == 1 || _state == 2) paused = _state;
    }

    function addSupportedToken(address token, address priceFeed) external {
        if (msg.sender != manager) revert OnlyManager();
        if (supportedTokens[token].supported) revert AlreadySupported(token);

        supportedTokens[token].daiPriceFeed = priceFeed;
        supportedTokens[token].supported = true;
        supportedTokensList.push(token);

        emit AddSupportedToken(token);
    }
}
