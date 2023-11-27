const hre = require("hardhat");
const { verify } = require("../utils/verify");
const { getAmountInWei, developmentChains } = require("../utils/helpers");

// mumbai addresses
const DAI = "0xd393b1E02dA9831Ff419e22eA105aAe4c47E1253";
const daiPriceFeed = "0x0FCAa9c899EC5A91eBc3D5Dd869De833b06fB046";
const daiVaultParams = {
  reserveRatio: 20000, // 20%
  feeToProtocolRate: 1000, // 1%
  flashFeeRate: 500, // 0.5%
  optimalUtilization: getAmountInWei(0.8), // 80%
  baseRate: 0,
  slope1: getAmountInWei(0.04), // 4%
  slope2: getAmountInWei(3), // 300%
};

async function main() {
  const deployNetwork = hre.network.name;

  // Deploy Lending Pool contract
  const pool = await ethers.deployContract("LendingPool", [
    DAI,
    daiPriceFeed,
    daiVaultParams,
  ]);
  await pool.waitForDeployment();

  console.log("Lending Pool contract deployed at:", pool.target);
  console.log("Network deployed to:", deployNetwork);

  if (
    !developmentChains.includes(deployNetwork) &&
    hre.config.etherscan.apiKey[deployNetwork]
  ) {
    console.log("waiting for 6 blocks verification ...");
    await pool.deployTransaction.wait(6);

    // args represent contract constructor arguments
    const args = [DAI, daiPriceFeed, daiVaultParams];
    await verify(pool.address, args);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
