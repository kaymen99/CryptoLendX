# CryptoLendX

This is a decentralized lending and borrowing protocol built from scratch, inspired from the AAVE protocol. It's designed to provide users with the ability to provide both ERC20 tokens and NFTs as collaterals and borrow other ERC20 assets against them in a secure and efficient manner.

## Key Features

* **LendingPool Contract**: The main component of the protocol, where users can supply collateral and borrow assets. Users can interact with this contract to manage their positions.

* **Supply and Borrow**: Any user can execute common `supply`/`borrow`/`repay` operations in order to deposit ERC20 collateral, borrow against them and repay the borrowed amout plus interest that goes to the lenders, similar to the AAVE protocol.

* **NFT collateral**: users can also deposit NFTs (ERC721 tokens) as collateral through the `depositNFT` function. This grants them the ability to borrow ERC20 assets, unlocking additional liquidity without the need to sell their NFTs. Withdrawal of deposited NFTs is possible, provided that the borrower has repaid their debt and maintains a health factor above the minimum threshold.

* **ERC20 Liquidation Mechanism**: If a user's health factor falls below a certain threshold, their position becomes liquidatable. Any user can execute the `liquidate` call to repay the defaulted borrower's borrows and receive a liquidation bonus as an incentive for their action.

* **NFT Liquidation Mechanism**: similar to ERC20 liquidation, NFT liquidation occurs if a user's health factor falls below the minimum threshold. To protect the borrower from rapid market fluctuations, the liquidation can only be triggered once all borrower ERC20 collateral has been liquidated. The liquidator first warns the borrower about the impending NFT liquidation by calling `triggerNFTLiquidation`, providing a 2-hour delay for the borrower to increase their health factor. If the borrower remains insolvent after the delay, the liquidator can proceed with NFT liquidation by invoking `executeNFTLiquidation`. During this process, the liquidator repays some of the borrower's debt (borrower must become healthy after liquidation), purchases the NFT at a discounted price (akin to a liquidation bonus), and the remaining funds (DAI) from the NFT sale are supplied to the pool on behalf of the borrower for later withdrawal.

* **Interest Model**: the protocol follows an interest rate model similar to AAVE V2 to ensure that borrowers and lenders are incentivized appropriately.

* **Protocol Fee**: The protocol owner may choose to impose a fee, capped at a maximum of 10% of the interest accrued, on a specific asset included in the lending pool. This fee will be collected each time interest is earned.

* **Asset Price Oracle**: Asset prices in USD are determined using the Chainlink oracle price feeds, for ERC20 tokens the normal market prices are fetched from the oracle but for the NFTs we will fetch the collection floor price.

## Getting Started

Steps to run the tests: (Hardhat version 2.19.0)

### Clone this repo

```shell
git clone https://github.com/kaymen99/CryptoLendX
```

### Installs all of the files

```shell
yarn install
```

### Setup environment variables for real/test networks 

> Create .env file with env var PRIVATE_KEY= , POLYGON_RPC_URL= , POLYGONSCAN_API_KEY= (use http://alchemy.com)

### Compiles all of the contracts

```shell
yarn compile
```

### Deploy lending pool
```shell
yarn deploy --<network-name>
```

### Runs all of the tests

```shell
yarn test
```

### Displays the coverage of the contracts

```shell
yarn coverage
```
