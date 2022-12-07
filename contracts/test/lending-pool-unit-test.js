const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const {
  getAmountInWei,
  getAmountFromWei,
  moveTime,
  mintAndApproveERC20,
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

      before(async () => {
        [owner, user1, user2, user3, randomUser] = await ethers.getSigners();
      });

      describe("Correct Deployement", () => {
        before(async () => {
          // Deploy Lending Pool contract
          const LendingPool = await ethers.getContractFactory("LendingPool");
          pool = await LendingPool.deploy();
        });
        it("Lending Pool contract should have correct owner address", async () => {
          const ownerAddress = await owner.getAddress();
          expect(await pool.owner()).to.equal(ownerAddress);
        });
      });

      describe("Core Functions", () => {
        describe("supply()", () => {
          let erc20Token;
          let tokenPriceFeed;
          const suppliedAmount = 100;

          before(async () => {
            // Deploy Lending Pool contract
            const LendingPool = await ethers.getContractFactory("LendingPool");
            pool = await LendingPool.deploy();

            // Deploy ERC20 mock contract for testing
            erc20Token = await deployERC20Mock();

            tokenPriceFeed = await deployAggregatorMock(
              getAmountInWei(100),
              18
            );

            // give user1 1000 amount of erc20token
            await mintERC20(user1, erc20Token.address, 1000);
          });
          it("should revert if ERC20 token is not supported", async () => {
            const amount = 100;

            await approveERC20(user1, erc20Token.address, amount, pool.address);

            await expect(
              pool.connect(user1).supply(erc20Token.address, amount)
            ).to.be.revertedWithCustomError(pool, "TokenNotSupported");
          });
          it("should allow user to supply supported ERC20 tokens", async () => {
            await pool
              .connect(owner)
              .addSupportedToken(erc20Token.address, tokenPriceFeed.address);

            await approveERC20(
              user1,
              erc20Token.address,
              suppliedAmount,
              pool.address
            );

            const tx = await pool
              .connect(user1)
              .supply(erc20Token.address, suppliedAmount);
            let txReceipt = await tx.wait(1);

            const supplyEvent =
              txReceipt.events[txReceipt.events.length - 1].args;
            expect(supplyEvent.user).to.equal(user1.address);
            expect(supplyEvent.token).to.equal(erc20Token.address);
            expect(supplyEvent.amount).to.equal(suppliedAmount);
          });
          it("should add shares/amount to the token vault", async () => {
            const vault = await pool.getTokenVault(erc20Token.address);

            expect(vault.totalAsset.amount).to.equal(suppliedAmount);
            // for first supply we have shares == amount
            expect(vault.totalAsset.shares).to.equal(suppliedAmount);
          });
          it("should update user collateral balance", async () => {
            const tokenCollateralAmount = await pool.getUserTokenCollateral(
              user1.address,
              erc20Token.address
            );
            expect(tokenCollateralAmount).to.equal(suppliedAmount);
          });
        });
      });

      describe("Update Functions", () => {});

      describe("Admin Functions", () => {});
    });
