const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Escrow Contract", function () {
    let escrow, buyer, seller, arbiter, token;
    let escrowFee = 2;
    let returnShipmentFee = 5;
    let disputeTimeLimit = 86400; // 1 day
    let tokenAddress;

    beforeEach(async function () {
        [buyer, seller, arbiter] = await ethers.getSigners();

        // Deploy mock ERC20 token for testing
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        token = await MockERC20.deploy("Test Token", "TTK", 18, ethers.utils.parseEther("10000"));
        await token.deployed();
        tokenAddress = token.address;

        // Deploy Escrow contract
        const Escrow = await ethers.getContractFactory("Escrow");
        escrow = await Escrow.deploy(
            seller.address,
            arbiter.address,
            escrowFee,
            returnShipmentFee,
            disputeTimeLimit,
            tokenAddress
        );
        await escrow.deployed();
    });

    it("Should allow the buyer to deposit tokens", async function () {
        await token.connect(buyer).approve(escrow.address, ethers.utils.parseEther("100"));
        await escrow.connect(buyer).deposit(ethers.utils.parseEther("100"));

        expect(await escrow.amount()).to.equal(ethers.utils.parseEther("98")); // Deducting 2% fee
    });
});
