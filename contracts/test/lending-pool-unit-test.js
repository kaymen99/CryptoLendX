const { expect } = require("chai");
const hre = require("hardhat");
const { ethers, network } = require("hardhat");
const {
  getAmountInWei,
  getAmountFromWei,
  mintAndapproveERC20,
  deployERC20Mock,
  developmentChains,
  mintERC20,
  approveERC20,
  deployAggregatorMock,
  round,
} = require("../utils/helpers");

!developmentChains.includes(network.name)
  ? describe.skip
  : describe("Lending Pool Unit Tests", () => {
      let owner;
      let pool;

      let interestParams = {
        feeToProtocolRate: 1000, // 1 %
        optimalUtilization: getAmountInWei(0.8), // 80 %
        baseRate: 0,
        slope1: getAmountInWei(0.04), // 4 %
        slope2: getAmountInWei(3), // 300 %
      };

      before(async () => {
        [owner, user1, user2, user3, randomUser] = await ethers.getSigners();
      });

      describe("Correct Deployement", () => {
        before(async () => {
          // Deploy Lending Pool contract
          const LendingPool = await ethers.getContractFactory("LendingPool");
          pool = await LendingPool.deploy();
        });
        it("Lending Pool contract should have correct manager address", async () => {
          const ownerAddress = await owner.getAddress();
          expect(await pool.owner()).to.equal(ownerAddress);
        });
        it("Lending Pool contract should be in paused state", async () => {
          expect(await pool.paused()).to.equal(1);
        });
      });

      describe("Core Functions", () => {
        describe("supply()", () => {
          let token1, token2;
          let token1Feed, token2Feed;
          const suppliedAmount = getAmountInWei(100);
          let beforePoolbalance;
          before(async () => {
            // Deploy Lending Pool contract
            const LendingPool = await ethers.getContractFactory("LendingPool");
            pool = await LendingPool.deploy();

            // Deploy ERC20 mocks contract for testing
            token1 = await deployERC20Mock();
            token2 = await deployERC20Mock();

            token1Feed = await deployAggregatorMock(getAmountInWei(100), 18);
            token2Feed = await deployAggregatorMock(getAmountInWei(300), 18);
          });
          it("should revert if pool is paused", async () => {
            await mintAndapproveERC20(
              user1,
              token1.address,
              suppliedAmount,
              pool.address
            );

            await expect(
              pool.connect(user1).supply(token1.address, suppliedAmount)
            ).to.be.revertedWithCustomError(pool, "isPaused");
          });
          it("should revert if ERC20 token is not supported", async () => {
            // unpause pool
            await pool.connect(owner).setPaused(2);

            await expect(
              pool.connect(user1).supply(token1.address, suppliedAmount)
            ).to.be.revertedWithCustomError(pool, "TokenNotSupported");
          });
          it("should allow user to supply supported ERC20 tokens", async () => {
            beforePoolbalance = getAmountFromWei(
              await token1.balanceOf(pool.address)
            );
            await pool
              .connect(owner)
              .addSupportedToken(
                token1.address,
                token1Feed.address,
                interestParams
              );

            const tx = await pool
              .connect(user1)
              .supply(token1.address, suppliedAmount);
            let txReceipt = await tx.wait(1);

            const supplyEvent =
              txReceipt.events[txReceipt.events.length - 1].args;
            expect(supplyEvent.user).to.equal(user1.address);
            expect(supplyEvent.token).to.equal(token1.address);
            expect(supplyEvent.amount).to.equal(suppliedAmount);
          });
          it("should transfer supplied amount to pool", async () => {
            const afterPoolbalance = getAmountFromWei(
              await token1.balanceOf(pool.address)
            );
            expect(afterPoolbalance).to.be.equal(
              getAmountFromWei(suppliedAmount) + beforePoolbalance
            );
          });
          it("should add shares/amount to the token vault", async () => {
            const vault = await pool.getTokenVault(token1.address);

            expect(vault.totalAsset.amount).to.equal(suppliedAmount);
            // for first supply we have shares == amount
            expect(vault.totalAsset.shares).to.equal(suppliedAmount);
          });
          it("should update user collateral balance", async () => {
            const tokenCollateralAmount = (
              await pool.getUserTokenCollateralAndBorrow(
                user1.address,
                token1.address
              )
            )[0];
            expect(tokenCollateralAmount).to.equal(suppliedAmount);
          });
          it("should calculate correct shares to new suppliers", async () => {
            await pool
              .connect(owner)
              .addSupportedToken(
                token2.address,
                token2Feed.address,
                interestParams
              );

            // user 2 supplies token2 and borrows token1
            await mintERC20(user2, token2.address, suppliedAmount);
            await supply(user2, token2.address, suppliedAmount, pool);
            // user 2 borrows 50 token1
            await pool
              .connect(user2)
              .borrow(token1.address, getAmountInWei(50));

            await hre.network.provider.send("hardhat_mine", ["0x4e20"]);

            await pool.connect(user2).accrueInterest(token1.address);

            const vault = await pool.getTokenVault(token1.address);
            const beforeAssetShares = getAmountFromWei(vault.totalAsset.shares);
            const beforeAssetAmount = getAmountFromWei(vault.totalAsset.amount);

            // user 3 supplies token1
            await mintERC20(user3, token1.address, getAmountInWei(150));
            await supply(user3, token1.address, getAmountInWei(150), pool);

            const collateralShares = (
              await pool.getUserTokenCollateralAndBorrow(
                user3.address,
                token1.address
              )
            )[0];

            const expectedShares = parseFloat(
              (150 * beforeAssetShares) / beforeAssetAmount
            ).toFixed(5);

            expect(
              parseFloat(getAmountFromWei(collateralShares)).toFixed(5)
            ).to.be.equal(expectedShares);
          });
        });
        describe("borrow()", () => {
          let token1, token2;
          let token1Feed, token2Feed;

          before(async () => {
            // Deploy Lending Pool contract
            const LendingPool = await ethers.getContractFactory("LendingPool");
            pool = await LendingPool.deploy();

            // Deploy ERC20 mocks contract for testing
            token1 = await deployERC20Mock();
            token2 = await deployERC20Mock();

            token1Feed = await deployAggregatorMock(getAmountInWei(100), 18);
            token2Feed = await deployAggregatorMock(getAmountInWei(300), 18);

            // add supported ERC20 tokens
            await pool
              .connect(owner)
              .addSupportedToken(
                token1.address,
                token1Feed.address,
                interestParams
              );
            await pool
              .connect(owner)
              .addSupportedToken(
                token2.address,
                token2Feed.address,
                interestParams
              );
          });
          const borrowAmount = getAmountInWei(50);
          let beforeBorrowerBalance;
          it("should revert if pool is paused", async () => {
            await expect(
              pool.connect(user1).borrow(token1.address, borrowAmount)
            ).to.be.revertedWithCustomError(pool, "isPaused");
          });
          it("should revert if insufficient ERC20 token balance", async () => {
            // unpause pool
            await pool.connect(owner).setPaused(2);

            await expect(
              pool.connect(user2).borrow(token2.address, borrowAmount)
            ).to.be.revertedWithCustomError(pool, "InsufficientBalance");
          });
          it("should allow user to borrow supported ERC20 tokens", async () => {
            // user 1 supplies token1
            await mintERC20(user1, token1.address, getAmountInWei(200));
            await supply(user1, token1.address, getAmountInWei(200), pool);

            beforeBorrowerBalance = getAmountFromWei(
              await token1.balanceOf(user2.address)
            );

            // user 2 supplies token2
            const amount = getAmountInWei(100);
            await mintERC20(user2, token2.address, amount);
            await supply(user2, token2.address, amount, pool);

            // user2 borrows token 1
            const tx = await pool
              .connect(user2)
              .borrow(token1.address, borrowAmount);
            let txReceipt = await tx.wait(1);

            const borrowEvent =
              txReceipt.events[txReceipt.events.length - 1].args;
            expect(borrowEvent.user).to.equal(user2.address);
            expect(borrowEvent.token).to.equal(token1.address);
            expect(borrowEvent.amount).to.equal(borrowAmount);
          });
          it("should transfer borrow amount to borrower", async () => {
            const afterBorrowerbalance = getAmountFromWei(
              await token1.balanceOf(user2.address)
            );
            expect(afterBorrowerbalance).to.be.equal(
              getAmountFromWei(borrowAmount) + beforeBorrowerBalance
            );
          });
          it("should add borrow shares/amount to the token vault", async () => {
            const vault = await pool.getTokenVault(token1.address);

            expect(vault.totalBorrow.amount).to.equal(borrowAmount);
            // for first borrower we have shares == amount
            expect(vault.totalBorrow.shares).to.equal(borrowAmount);
          });
          it("should update user borrow balance", async () => {
            const tokenBorrowAmount = (
              await pool.getUserTokenCollateralAndBorrow(
                user2.address,
                token1.address
              )
            )[1];
            expect(tokenBorrowAmount).to.equal(borrowAmount);
          });
          it("should calculate correct shares for new borrowers", async () => {
            // user 2 supplies token2 and borrows token1
            const suppliedAmount = getAmountInWei(40);
            await mintERC20(user3, token2.address, suppliedAmount);
            await supply(user3, token2.address, suppliedAmount, pool);

            await hre.network.provider.send("hardhat_mine", ["0x4e20"]);
            await pool.connect(user2).accrueInterest(token1.address);

            // user3 borrows 10 token1
            await pool
              .connect(user3)
              .borrow(token1.address, getAmountInWei(10));

            const vault = await pool.getTokenVault(token1.address);
            const beforeBorrowShares = getAmountFromWei(
              vault.totalBorrow.shares
            );
            const beforeBorrowAmount = getAmountFromWei(
              vault.totalBorrow.amount
            );

            const borrowShares = (
              await pool.getUserTokenCollateralAndBorrow(
                user3.address,
                token1.address
              )
            )[1];

            const expectedShares = parseFloat(
              (10 * beforeBorrowShares) / beforeBorrowAmount
            ).toFixed(5);

            expect(
              parseFloat(getAmountFromWei(borrowShares)).toFixed(5)
            ).to.be.equal(expectedShares);
          });
          it("should revert if borrower is not healthy", async () => {
            // user3 tries to borrow more token1
            await expect(
              pool.connect(user3).borrow(token1.address, getAmountInWei(100))
            ).to.be.revertedWithCustomError(pool, "BorrowNotAllowed");
          });
        });
        describe("repay()", () => {
          let token1, token2;
          let token1Feed, token2Feed;
          before(async () => {
            // Deploy Lending Pool contract
            const LendingPool = await ethers.getContractFactory("LendingPool");
            pool = await LendingPool.deploy();

            // unpause pool
            await pool.connect(owner).setPaused(2);

            // Deploy ERC20 mocks contract for testing
            token1 = await deployERC20Mock();
            token2 = await deployERC20Mock();

            token1Feed = await deployAggregatorMock(getAmountInWei(100), 18);
            token2Feed = await deployAggregatorMock(getAmountInWei(300), 18);

            // add supported ERC20 tokens
            await pool
              .connect(owner)
              .addSupportedToken(
                token1.address,
                token1Feed.address,
                interestParams
              );
            await pool
              .connect(owner)
              .addSupportedToken(
                token2.address,
                token2Feed.address,
                interestParams
              );

            // user 1 supplies token1
            await mintERC20(user1, token1.address, getAmountInWei(200));
            await supply(user1, token1.address, getAmountInWei(200), pool);

            // user 2 supplies token2
            const amount = getAmountInWei(100);
            await mintERC20(user2, token2.address, amount);
            await supply(user2, token2.address, amount, pool);

            // user2 borrows token 1
            await pool
              .connect(user2)
              .borrow(token1.address, getAmountInWei(50));
          });
          let beforePoolbalance,
            beforePoolBorrowShares,
            beforePoolBorrowAmount,
            beforeUserBorrowShares,
            repaidAmount,
            repaidShares;
          it("should allow user to repay borrowed amount", async () => {
            const vault = await pool.getTokenVault(token1.address);
            beforePoolBorrowShares = getAmountFromWei(vault.totalBorrow.shares);
            beforePoolBorrowAmount = getAmountFromWei(vault.totalBorrow.amount);
            beforePoolbalance = getAmountFromWei(
              await token1.balanceOf(pool.address)
            );

            beforeUserBorrowShares = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user2.address,
                  token1.address
                )
              )[1]
            );

            repaidAmount = getAmountInWei(35);
            repaidShares = await pool.amountToShares(
              token1.address,
              repaidAmount,
              false
            );
            await approveERC20(
              user2,
              token1.address,
              repaidAmount,
              pool.address
            );

            // user2 repays 35 token1
            const tx = await pool
              .connect(user2)
              .repay(token1.address, repaidAmount);
            let txReceipt = await tx.wait(1);

            const repayEvent =
              txReceipt.events[txReceipt.events.length - 1].args;
            expect(repayEvent.user).to.equal(user2.address);
            expect(repayEvent.token).to.equal(token1.address);
            expect(repayEvent.amount).to.equal(repaidAmount);
          });
          it("should transfer repaid amount to pool", async () => {
            const afterPoolbalance = getAmountFromWei(
              await token1.balanceOf(pool.address)
            );
            expect(afterPoolbalance).to.be.equal(
              getAmountFromWei(repaidAmount) + beforePoolbalance
            );
          });
          it("should update borrow shares/amount in the token vault", async () => {
            const vault = await pool.getTokenVault(token1.address);

            expect(round(getAmountFromWei(vault.totalBorrow.amount))).to.equal(
              beforePoolBorrowAmount - getAmountFromWei(repaidAmount)
            );
            expect(round(getAmountFromWei(vault.totalBorrow.shares))).to.equal(
              beforePoolBorrowShares - getAmountFromWei(repaidShares)
            );
          });
          it("should update user borrow balance", async () => {
            const afterBorrowShares = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user2.address,
                  token1.address
                )
              )[1]
            );
            expect(round(afterBorrowShares)).to.equal(
              beforeUserBorrowShares - getAmountFromWei(repaidShares)
            );
          });
          it("should allow user to repay full amount", async () => {
            const realRepaidShares = (
              await pool.getUserTokenCollateralAndBorrow(
                user2.address,
                token1.address
              )
            )[1];
            const realRepaidAmount = await pool.sharesToAmount(
              token1.address,
              realRepaidShares,
              false
            );
            // user2 repays full amount, providing big number
            await mintAndapproveERC20(
              user2,
              token1.address,
              getAmountInWei(100),
              pool.address
            );

            // user2 repays 35 token1
            const tx = await pool
              .connect(user2)
              .repay(token1.address, getAmountInWei(100000));
            let txReceipt = await tx.wait(1);

            const repayEvent =
              txReceipt.events[txReceipt.events.length - 1].args;
            expect(repayEvent.amount).to.greaterThanOrEqual(realRepaidAmount);

            const afterBorrowShares = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user2.address,
                  token1.address
                )
              )[1]
            );
            expect(round(afterBorrowShares)).to.equal(0);
          });
        });
        describe("withdraw()", () => {
          let token1, token2;
          let token1Feed, token2Feed;
          before(async () => {
            // Deploy Lending Pool contract
            const LendingPool = await ethers.getContractFactory("LendingPool");
            pool = await LendingPool.deploy();

            // unpause pool
            await pool.connect(owner).setPaused(2);

            // Deploy ERC20 mocks contract for testing
            token1 = await deployERC20Mock();
            token2 = await deployERC20Mock();

            token1Feed = await deployAggregatorMock(getAmountInWei(100), 18);
            token2Feed = await deployAggregatorMock(getAmountInWei(300), 18);

            // add supported ERC20 tokens
            await pool
              .connect(owner)
              .addSupportedToken(
                token1.address,
                token1Feed.address,
                interestParams
              );
            await pool
              .connect(owner)
              .addSupportedToken(
                token2.address,
                token2Feed.address,
                interestParams
              );

            // user 1 supplies token1
            await mintERC20(user1, token1.address, getAmountInWei(200));
            await supply(user1, token1.address, getAmountInWei(200), pool);
          });
          it("should revert if withdraw amount is greater than supply balance", async () => {
            await expect(
              pool.connect(user1).withdraw(token1.address, getAmountInWei(250))
            ).to.be.revertedWithCustomError(pool, "InsufficientBalance");
          });
          it("should revert if insufficient token balance in pool", async () => {
            // user 2 supplies token2
            const amount = getAmountInWei(100);
            await mintERC20(user2, token2.address, amount);
            await supply(user2, token2.address, amount, pool);

            // user2 borrows token 1
            await pool
              .connect(user2)
              .borrow(token1.address, getAmountInWei(60));
            await expect(
              pool.connect(user1).withdraw(token1.address, getAmountInWei(200))
            ).to.be.revertedWithCustomError(pool, "InsufficientBalance");
          });
          let beforeUserbalance,
            beforePoolAssetShares,
            beforePoolAssetAmount,
            beforeUserAssetShares,
            withdrawAmount,
            withdrawnShares;
          it("should allow user to withdraw supplied amount", async () => {
            const vault = await pool.getTokenVault(token1.address);
            beforePoolAssetShares = getAmountFromWei(vault.totalAsset.shares);
            beforePoolAssetAmount = getAmountFromWei(vault.totalAsset.amount);
            beforeUserbalance = getAmountFromWei(
              await token1.balanceOf(user1.address)
            );

            beforeUserAssetShares = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user1.address,
                  token1.address
                )
              )[0]
            );

            withdrawAmount = getAmountInWei(100);
            withdrawnShares = await pool.amountToShares(
              token1.address,
              withdrawAmount,
              false
            );

            // user1 withdraws 100 token1
            const tx = await pool
              .connect(user1)
              .withdraw(token1.address, withdrawAmount);
            let txReceipt = await tx.wait(1);

            const withdrawEvent =
              txReceipt.events[txReceipt.events.length - 1].args;
            expect(withdrawEvent.user).to.equal(user1.address);
            expect(withdrawEvent.token).to.equal(token1.address);
            expect(withdrawEvent.amount).to.equal(withdrawAmount);
          });
          it("should transfer withdrawn amount to user", async () => {
            const afterUserbalance = getAmountFromWei(
              await token1.balanceOf(user1.address)
            );
            expect(afterUserbalance).to.be.equal(
              getAmountFromWei(withdrawAmount) + beforeUserbalance
            );
          });
          it("should update asset shares/amount in the token vault", async () => {
            const vault = await pool.getTokenVault(token1.address);

            expect(round(getAmountFromWei(vault.totalAsset.amount))).to.equal(
              beforePoolAssetAmount - getAmountFromWei(withdrawAmount)
            );
            expect(round(getAmountFromWei(vault.totalAsset.shares))).to.equal(
              beforePoolAssetShares - getAmountFromWei(withdrawnShares)
            );
          });
          it("should update user asset balance", async () => {
            const afterAssetShares = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user1.address,
                  token1.address
                )
              )[0]
            );
            expect(round(afterAssetShares)).to.equal(
              beforeUserAssetShares - getAmountFromWei(withdrawnShares)
            );
          });
          it("should revert if user becomes not solvent", async () => {
            // user1 borrows token2
            await pool
              .connect(user1)
              .borrow(token2.address, getAmountInWei(20));

            // user1 tries to withdraw supplied token1
            await expect(
              pool.connect(user1).withdraw(token1.address, getAmountInWei(40))
            ).to.be.revertedWithCustomError(pool, "UnderCollateralized");
          });
        });
        describe("redeem()", () => {
          let token1, token2;
          let token1Feed, token2Feed;
          before(async () => {
            // Deploy Lending Pool contract
            const LendingPool = await ethers.getContractFactory("LendingPool");
            pool = await LendingPool.deploy();

            // unpause pool
            await pool.connect(owner).setPaused(2);

            // Deploy ERC20 mocks contract for testing
            token1 = await deployERC20Mock();
            token2 = await deployERC20Mock();

            token1Feed = await deployAggregatorMock(getAmountInWei(100), 18);
            token2Feed = await deployAggregatorMock(getAmountInWei(300), 18);

            // add supported ERC20 tokens
            await pool
              .connect(owner)
              .addSupportedToken(
                token1.address,
                token1Feed.address,
                interestParams
              );
            await pool
              .connect(owner)
              .addSupportedToken(
                token2.address,
                token2Feed.address,
                interestParams
              );

            // user 1 supplies token1
            await mintERC20(user1, token1.address, getAmountInWei(200));
            await supply(user1, token1.address, getAmountInWei(200), pool);
          });
          it("should revert if withdrawn shares are greater than supplied shares", async () => {
            const userAssetShares = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user1.address,
                  token1.address
                )
              )[0]
            );
            const redeemShares = getAmountInWei(userAssetShares + 100);
            await expect(
              pool.connect(user1).redeem(token1.address, redeemShares)
            ).to.be.revertedWithCustomError(pool, "InsufficientBalance");
          });
          it("should revert if insufficient token balance in pool", async () => {
            // user 2 supplies token2
            const amount = getAmountInWei(100);
            await mintERC20(user2, token2.address, amount);
            await supply(user2, token2.address, amount, pool);

            const userAssetShares = (
              await pool.getUserTokenCollateralAndBorrow(
                user1.address,
                token1.address
              )
            )[0];
            // user2 borrows token 1
            await pool
              .connect(user2)
              .borrow(token1.address, getAmountInWei(60));
            await expect(
              pool.connect(user1).redeem(token1.address, userAssetShares)
            ).to.be.revertedWithCustomError(pool, "InsufficientBalance");
          });
          let beforeUserbalance,
            beforePoolAssetShares,
            beforePoolAssetAmount,
            beforeUserAssetShares,
            withdrawnAmount,
            withdrawnShares;
          it("should allow user to withdraw supplied amount", async () => {
            const vault = await pool.getTokenVault(token1.address);
            beforePoolAssetShares = getAmountFromWei(vault.totalAsset.shares);
            beforePoolAssetAmount = getAmountFromWei(vault.totalAsset.amount);
            beforeUserbalance = getAmountFromWei(
              await token1.balanceOf(user1.address)
            );

            beforeUserAssetShares = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user1.address,
                  token1.address
                )
              )[0]
            );

            withdrawnShares = getAmountInWei(100);
            withdrawnAmount = await pool.sharesToAmount(
              token1.address,
              withdrawnShares,
              false
            );

            // user1 withdraws 100 token1
            const tx = await pool
              .connect(user1)
              .redeem(token1.address, withdrawnShares);
            let txReceipt = await tx.wait(1);

            const withdrawEvent =
              txReceipt.events[txReceipt.events.length - 1].args;
            expect(withdrawEvent.user).to.equal(user1.address);
            expect(withdrawEvent.token).to.equal(token1.address);
            expect(withdrawEvent.shares).to.equal(withdrawnShares);
          });
          it("should transfer withdrawn amount to user", async () => {
            const afterUserbalance = getAmountFromWei(
              await token1.balanceOf(user1.address)
            );
            // received amount is greater because of interest accrued
            expect(afterUserbalance).to.be.greaterThanOrEqual(
              getAmountFromWei(withdrawnAmount) + beforeUserbalance
            );
          });
          it("should update asset shares/amount in the token vault", async () => {
            const vault = await pool.getTokenVault(token1.address);

            expect(round(getAmountFromWei(vault.totalAsset.amount))).to.equal(
              beforePoolAssetAmount - getAmountFromWei(withdrawnAmount)
            );
            expect(round(getAmountFromWei(vault.totalAsset.shares))).to.equal(
              beforePoolAssetShares - getAmountFromWei(withdrawnShares)
            );
          });
          it("should update user asset balance", async () => {
            const afterAssetShares = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user1.address,
                  token1.address
                )
              )[0]
            );
            expect(round(afterAssetShares)).to.equal(
              beforeUserAssetShares - getAmountFromWei(withdrawnShares)
            );
          });
          it("should revert if user becomes not solvent", async () => {
            // user1 borrows token2
            await pool
              .connect(user1)
              .borrow(token2.address, getAmountInWei(20));

            // user1 tries to withdraw supplied token1
            await expect(
              pool.connect(user1).withdraw(token1.address, getAmountInWei(30))
            ).to.be.revertedWithCustomError(pool, "UnderCollateralized");
          });
        });
        describe("liquidate()", () => {
          let token1, token2;
          let token1Feed, token2Feed;
          before(async () => {
            // Deploy Lending Pool contract
            const LendingPool = await ethers.getContractFactory("LendingPool");
            pool = await LendingPool.deploy();

            // unpause pool
            await pool.connect(owner).setPaused(2);

            // Deploy ERC20 mocks contract for testing
            token1 = await deployERC20Mock();
            token2 = await deployERC20Mock();

            token1Feed = await deployAggregatorMock(getAmountInWei(100), 18);
            token2Feed = await deployAggregatorMock(getAmountInWei(300), 18);

            // add supported ERC20 tokens
            await pool
              .connect(owner)
              .addSupportedToken(
                token1.address,
                token1Feed.address,
                interestParams
              );
            await pool
              .connect(owner)
              .addSupportedToken(
                token2.address,
                token2Feed.address,
                interestParams
              );

            // user 1 supplies token1
            await mintERC20(user1, token1.address, getAmountInWei(200));
            await supply(user1, token1.address, getAmountInWei(200), pool);

            // user 2 supplies token2
            const amount = getAmountInWei(60);
            await mintERC20(user2, token2.address, amount);
            await supply(user2, token2.address, amount, pool);

            // user2 borrows token 1
            await pool
              .connect(user2)
              .borrow(token1.address, getAmountInWei(120));
          });
          it("should revert if borrower is solvent", async () => {
            await expect(
              pool
                .connect(user1)
                .liquidate(
                  user2.address,
                  token2.address,
                  token1.address,
                  getAmountInWei(40)
                )
            ).to.be.revertedWithCustomError(pool, "BorrowerIsSolvant");
          });
          let repaidAmount,
            totalReceivedCollateral,
            beforePoolbalance1,
            beforePoolAssetShares,
            beforePoolAssetAmount,
            beforePoolBorrowShares,
            beforePoolBorrowAmount,
            beforeUserBorrowShares1,
            beforeUserAssetShares2;
          it("should allow liquidator to liquidate unsolvant borrower", async () => {
            // simulate decrease in token2 price 300 -> 240
            await token2Feed.updateAnswer(getAmountInWei(240));

            // user2 health factor is less than 1
            expect(await pool.healthFactor(user2.address)).to.be.lessThan(
              getAmountInWei(1)
            );

            beforePoolbalance1 = getAmountFromWei(
              await token1.balanceOf(pool.address)
            );

            let vault = await pool.getTokenVault(token1.address);
            beforePoolBorrowAmount = getAmountFromWei(vault.totalBorrow.amount);
            beforePoolBorrowShares = getAmountFromWei(vault.totalBorrow.shares);
            vault = await pool.getTokenVault(token2.address);
            beforePoolAssetAmount = getAmountFromWei(vault.totalAsset.amount);
            beforePoolAssetShares = getAmountFromWei(vault.totalAsset.shares);

            const userShares1 = await pool.getUserTokenCollateralAndBorrow(
              user2.address,
              token1.address
            );
            beforeUserBorrowShares1 = getAmountFromWei(userShares1[1]);

            const userShares2 = await pool.getUserTokenCollateralAndBorrow(
              user2.address,
              token2.address
            );
            beforeUserAssetShares2 = getAmountFromWei(userShares2[0]);

            const liquidatedAmount = getAmountInWei(50);
            await mintAndapproveERC20(
              user3,
              token1.address,
              liquidatedAmount,
              pool.address
            );

            const tx = await pool
              .connect(user3)
              .liquidate(
                user2.address,
                token2.address,
                token1.address,
                liquidatedAmount
              );
            let txReceipt = await tx.wait(1);

            const liquidateEvent =
              txReceipt.events[txReceipt.events.length - 1].args;
            expect(liquidateEvent.borrower).to.equal(user2.address);
            expect(liquidateEvent.liquidator).to.equal(user3.address);
            expect(liquidateEvent.repaidAmount).to.equal(liquidatedAmount);
            repaidAmount = liquidateEvent.repaidAmount;
            totalReceivedCollateral = liquidateEvent.liquidatedCollateral;
          });
          it("should transfer repaid tokens to pool", async () => {
            const afterPoolbalance1 = getAmountFromWei(
              await token1.balanceOf(pool.address)
            );
            expect(afterPoolbalance1).to.be.equal(
              beforePoolbalance1 + getAmountFromWei(repaidAmount)
            );
          });
          it("should transfer liquidated collateral to liquidator", async () => {
            const beforeLiquidatorBalance = 0;
            const afterLiquidatorBalance = getAmountFromWei(
              await token2.balanceOf(user3.address)
            );
            expect(afterLiquidatorBalance).to.be.equal(
              beforeLiquidatorBalance +
                getAmountFromWei(totalReceivedCollateral)
            );
          });
          it("should update asset shares/amount of the token vault", async () => {
            const vault = await pool.getTokenVault(token2.address);

            expect(getAmountFromWei(vault.totalAsset.amount)).to.equal(
              beforePoolAssetAmount - getAmountFromWei(totalReceivedCollateral)
            );
          });
          it("should update borrow shares/amount of the token vault", async () => {
            const vault = await pool.getTokenVault(token1.address);

            expect(round(getAmountFromWei(vault.totalBorrow.amount))).to.equal(
              beforePoolBorrowAmount - getAmountFromWei(repaidAmount)
            );
          });
          it("should update borrower borrow shares", async () => {
            const afterUserBorrowShares1 = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user2.address,
                  token1.address
                )
              )[1]
            );
            const repaidShares =
              (getAmountFromWei(repaidAmount) * beforePoolBorrowShares) /
              beforePoolBorrowAmount;

            expect(afterUserBorrowShares1).to.equal(
              beforeUserBorrowShares1 - repaidShares
            );
          });
          it("should update borrower collateral shares", async () => {
            const afterUserAssetShares2 = getAmountFromWei(
              (
                await pool.getUserTokenCollateralAndBorrow(
                  user2.address,
                  token2.address
                )
              )[0]
            );
            const liquidatedCollShares =
              (getAmountFromWei(totalReceivedCollateral) *
                beforePoolAssetShares) /
              beforePoolAssetAmount;
            totalReceivedCollateral *
              expect(afterUserAssetShares2).to.equal(
                beforeUserAssetShares2 - liquidatedCollShares
              );
          });
        });
      });

      describe("Admin Functions", () => {
        before(async () => {
          // Deploy Lending Pool contract
          const LendingPool = await ethers.getContractFactory("LendingPool");
          pool = await LendingPool.deploy();
        });
        it("only owner should be allowed to change pool paused status", async () => {
          expect(await pool.paused()).to.equal(1);
          // Non owner tries to unpause
          await expect(
            pool.connect(randomUser).setPaused(2)
          ).to.be.revertedWith("Ownable: caller is not the owner");
          // owner unpause pool
          await pool.connect(owner).setPaused(2);
          expect(await pool.paused()).to.equal(2);
        });
        it("only owner should be allowed to add supported tokens", async () => {
          // Deploy ERC20 mocks contract for testing
          const token1 = await deployERC20Mock();
          const token1Feed = await deployAggregatorMock(
            getAmountInWei(100),
            18
          );

          // Non owner tries to add new token
          await expect(
            pool
              .connect(randomUser)
              .addSupportedToken(
                token1.address,
                token1Feed.address,
                interestParams
              )
          ).to.be.revertedWith("Ownable: caller is not the owner");
          // owner add new supported token
          await pool
            .connect(owner)
            .addSupportedToken(
              token1.address,
              token1Feed.address,
              interestParams
            );
        });
      });
    });

async function supply(user, tokenAddress, amount, pool) {
  await approveERC20(user, tokenAddress, amount, pool.address);
  const tx = await pool.connect(user).supply(tokenAddress, amount);
  let txReceipt = await tx.wait(1);

  return txReceipt;
}
