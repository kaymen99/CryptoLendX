const { ethers } = require("hardhat");

const developmentChains = ["hardhat", "localhost", "ganache"]

const networkConfig = {
    default: {
        name: "hardhat",
        daiAddress: "0x6b175474e89094c44da98b954eedeac495271d0f",
        aDaiAddress: "0x028171bCA77440897B824Ca71D1c56caC55b68A3",
        AAVELendingPool: "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9",
        subscriptionId: 6926,
        gasLane: "0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc", // 30 gwei
        keepersUpdateInterval: "60",
        callbackGasLimit: 500000, // 500,000 gas
        vrfCoordinatorV2: "0x6168499c0cFfCaCD319c818142124B7A15E857ab",
    },
    31337: {
        name: "localhost",
        daiAddress: "0x6b175474e89094c44da98b954eedeac495271d0f",
        aDaiAddress: "0x028171bCA77440897B824Ca71D1c56caC55b68A3",
        AAVELendingPool: "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9",
        subscriptionId: 6926,
        gasLane: "0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc", // 30 gwei
        keepersUpdateInterval: "60",
        callbackGasLimit: 500000, // 500,000 gas
        // vrfCoordinatorV2: mock is used,
    },
    1: {
        name: "mainnet",
        daiAddress: "0x6b175474e89094c44da98b954eedeac495271d0f",
        aDaiAddress: "0x028171bCA77440897B824Ca71D1c56caC55b68A3",
        AAVELendingPool: "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9",
        subscriptionId: 6926,
        gasLane: "0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc", // 30 gwei
        keepersUpdateInterval: "60",
        callbackGasLimit: 500000, // 500,000 gas
        vrfCoordinatorV2: "0x6168499c0cFfCaCD319c818142124B7A15E857ab",
    },
}

function getAmountInWei(amount) {
    return ethers.utils.parseEther(amount.toString(), "ether")
}
function getAmountFromWei(amount) {
    return Number(ethers.utils.formatUnits(amount.toString(), "ether"))
}

async function mintAndApproveDai(account, daiAddress, amount, spender, approvedAmount) {
    const dai = await ethers.getContractAt("IERC20Mock", daiAddress)

    const mint_tx = await dai.connect(account).mint(account.address, getAmountInWei(amount))
    await mint_tx.wait(1)

    const tx = await dai.connect(account).approve(spender, approvedAmount)
    await tx.wait(1)
}

async function fundPoolWithADAI(account, poolAddress, aDaiAddress) {
    const aDai = await ethers.getContractAt("IERC20Mock", aDaiAddress)

    const mint_tx = await aDai.connect(account).mint(account.address, getAmountInWei(100000))
    await mint_tx.wait(1)

    const tx = await aDai.connect(account).transfer(poolAddress, getAmountInWei(100000))
    await tx.wait(1)
}

async function deployVRFCoordinatorMock() {
    const FUND_AMOUNT = "1000000000000000000000"
    const BASE_FEE = getAmountInWei(0.25)
    const GAS_PRICE_LINK = 1e9

    const Mock = await hre.ethers.getContractFactory("VRFCoordinatorV2Mock")
    const vrfCoordinatorV2Mock = await Mock.deploy(BASE_FEE, GAS_PRICE_LINK)
    await vrfCoordinatorV2Mock.deployed();

    const transactionResponse = await vrfCoordinatorV2Mock.createSubscription()
    const transactionReceipt = await transactionResponse.wait()
    const subscriptionId = transactionReceipt.events[0].args.subId
    // Fund the subscription
    // Our mock makes it so we don't actually have to worry about sending fund
    await vrfCoordinatorV2Mock.fundSubscription(subscriptionId, FUND_AMOUNT)

    return [vrfCoordinatorV2Mock, subscriptionId];
}

async function deployERC20Mock() {

    const Mock = await hre.ethers.getContractFactory("ERC20Mock")
    const mockContract = await Mock.deploy()
    await mockContract.deployed();

    return mockContract;
}

async function deployLendingPoolMock(atoken) {

    const Mock = await hre.ethers.getContractFactory("PoolMock")
    const mockContract = await Mock.deploy(atoken)
    await mockContract.deployed();

    return mockContract;
}

async function moveTime(waitingPeriod) {
    await ethers.provider.send('evm_increaseTime', [waitingPeriod]);
    await ethers.provider.send('evm_mine');
}


module.exports = {
    developmentChains,
    networkConfig,
    getAmountFromWei,
    getAmountInWei,
    deployVRFCoordinatorMock,
    deployERC20Mock,
    deployLendingPoolMock,
    mintAndApproveDai,
    fundPoolWithADAI,
    moveTime
}