const { ethers } = require("hardhat");

const developmentChains = ["hardhat", "localhost", "ganache"]

function getAmountInWei(amount) {
    return ethers.utils.parseEther(amount.toString(), "ether")
}
function getAmountFromWei(amount) {
    return Number(ethers.utils.formatUnits(amount.toString(), "ether"))
}

async function deployERC20Mock() {

    const Mock = await hre.ethers.getContractFactory("ERC20Mock")
    const mockContract = await Mock.deploy()
    await mockContract.deployed();

    return mockContract;
}

async function moveTime(waitingPeriod) {
    await ethers.provider.send('evm_increaseTime', [waitingPeriod]);
    await ethers.provider.send('evm_mine');
}


module.exports = {
    developmentChains,
    getAmountFromWei,
    getAmountInWei,
    deployERC20Mock,
    moveTime
}
