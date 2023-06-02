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

            expect(
              parseInt(parseFloat(getAmountFromWei(vault.totalBorrow.amount)))
            ).to.equal(beforePoolBorrowAmount - getAmountFromWei(repaidAmount));
            expect(
              parseInt(parseFloat(getAmountFromWei(vault.totalBorrow.shares)))
            ).to.equal(beforePoolBorrowShares - getAmountFromWei(repaidShares));
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
            expect(parseInt(parseFloat(afterBorrowShares))).to.equal(
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
            expect(parseInt(parseFloat(afterBorrowShares))).to.equal(0);
          });
        });
      });

      describe("Admin Functions", () => {});
    });

async function supply(user, tokenAddress, amount, pool) {
  await approveERC20(user, tokenAddress, amount, pool.address);
  const tx = await pool.connect(user).supply(tokenAddress, amount);
  let txReceipt = await tx.wait(1);

  return txReceipt;
}
