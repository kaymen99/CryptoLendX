const { ethers } = require("hardhat");

const developmentChains = ["hardhat", "localhost", "ganache"];

function getAmountInWei(amount) {
  return ethers.parseEther(amount.toString(), "ether");
}

function getAmountFromWei(amount) {
  return Number(ethers.formatUnits(amount.toString(), "ether"));
}

function scaleAmount(amount, decimals) {
  return Number(amount) * 10 ** decimals;
}
function normalizeAmount(amount, decimals) {
  return Number(amount) / 10 ** decimals;
}

function round(num) {
  return Math.round(num * 10) / 10;
}

async function moveTime(waitingPeriod) {
  await ethers.provider.send("evm_increaseTime", [waitingPeriod]);
  await ethers.provider.send("evm_mine");
}

async function deployAggregatorMock(price, decimals) {
  const mockContract = await ethers.deployContract("MockV3Aggregator", [
    decimals,
    price,
  ]);
  await mockContract.waitForDeployment();
  return mockContract;
}

async function deployERC721Mock(name, symbol) {
  const mockContract = await ethers.deployContract("ERC721Mock", [
    name,
    symbol,
  ]);
  await mockContract.waitForDeployment();
  return mockContract;
}

async function mintAndapproveNFT(account, nftAddress, tokenId, spender) {
  const erc20 = await ethers.getContractAt("ERC721Mock", nftAddress);
  const mint_tx = await erc20.connect(account).mint(account.address, tokenId);
  await mint_tx.wait(1);
  const tx = await erc20.connect(account).setApprovalForAll(spender, true);
  await tx.wait(1);
}

async function deployERC20Mock(name, symbol, decimals) {
  const mockContract = await ethers.deployContract("ERC20DecimalsMock", [
    name,
    symbol,
    decimals,
  ]);
  await mockContract.waitForDeployment();
  return mockContract;
}

async function mintERC20(account, erc20Address, amount) {
  const erc20 = await ethers.getContractAt("ERC20DecimalsMock", erc20Address);
  const mint_tx = await erc20.connect(account).mint(account.address, amount);
  await mint_tx.wait(1);
}

async function approveERC20(account, erc20Address, approvedAmount, spender) {
  const erc20 = await ethers.getContractAt("ERC20DecimalsMock", erc20Address);
  const tx = await erc20.connect(account).approve(spender, approvedAmount);
  await tx.wait(1);
}

async function mintAndapproveERC20(account, erc20Address, amount, spender) {
  const erc20 = await ethers.getContractAt("ERC20DecimalsMock", erc20Address);
  const mint_tx = await erc20.connect(account).mint(account.address, amount);
  await mint_tx.wait(1);
  const tx = await erc20.connect(account).approve(spender, amount);
  await tx.wait(1);
}

module.exports = {
  developmentChains,
  normalizeAmount,
  scaleAmount,
  getAmountFromWei,
  getAmountInWei,
  deployAggregatorMock,
  deployERC721Mock,
  mintAndapproveNFT,
  deployERC20Mock,
  mintERC20,
  approveERC20,
  mintAndapproveERC20,
  moveTime,
  round,
};
