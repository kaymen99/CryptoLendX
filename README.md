# Defi-Lending

This is a decentralized lending and borrowing protocol built from scratch, designed to provide users with the ability to supply and borrow assets in a secure and efficient manner inspired by the AAVE V2.

## Key Features

* **LendingPool Contract**: The main component of the protocol, where users can supply collateral and borrow assets. Users can interact with this contract to manage their positions.

* **Supply and Borrow**: Any user can execute common `supply`/`borrow`/`repay` operations in order to deposit collateral, borrow against them and repay the borrowed amout plus interest that goes to the lenders, similar to the AAVE protocol.

* **Liquidation Mechanism**: If a user's health factor falls below a certain threshold, their position becomes liquidatable. Any user can execute the `liquidate` call to repay the defaulted borrower's borrows and receive a liquidation bonus as an incentive for their action.

* **Interest Model**: the protocol follows an interest rate model similar to AAVE V2 to ensure that borrowers and lenders are incentivized appropriately.

* **Protocol Fee**: The protocol owner may choose to impose a fee, capped at a maximum of 10% of the interest accrued, on a specific asset included in the lending pool. This fee will be collected each time interest is earned.

* **Asset Price Oracle**: Asset prices in USD are determined using the Chainlink oracle price feeds, ensuring reliable and up-to-date pricing information.

## Future developments

* Introducing flashloan functionality to the lending pool.
  
* Enabling users to utilize NFTs (ERC721 and ERC1155) as collateral and borrow against them.

## Getting Started

Steps to run the tests: (Hardhat version 2.9.9)

### Clone this repo

> git clone https://github.com/kaymen99/Defi-Lending.git

### Installs all of the files

> yarn install

### Required for tests and all other actions to work  

> Create .env file with env var PRIVATE_KEY= , POLYGON_RPC_URL= , POLYGONSCAN_API_KEY= (use http://alchemy.com)

### Compiles all of the contracts

> yarn compile

### Runs all of the tests

> yarn test

### Displays the coverage of the contracts

> yarn coverage


