import { expect } from "chai";
import hardhat from "hardhat";

const { ethers } = hardhat;

describe("Escrow Contract - Deposit Function", function () {
    let escrow, token, buyer, seller, arbiter;
    const escrowFee = 2; // 2% fee
    const initialSupply = ethers.utils.parseEther("10000"); // 10,000 tokens
    const depositAmount = ethers.utils.parseEther("100"); // 100 tokens

    beforeEach(async function () {
        // Get signers
        [buyer, seller, arbiter] = await ethers.getSigners();

        // Deploy mock ERC20 token
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        token = await MockERC20.deploy("Test Token", "TTK", initialSupply);
        await token.deployed();

        // Deploy Escrow contract
        const Escrow = await ethers.getContractFactory("Escrow");
        escrow = await Escrow.deploy(
            seller.address,
            arbiter.address,
            escrowFee,
            5, // Return shipment fee
            86400, // Dispute time limit
            token.address
        );
        await escrow.deployed();
    });

    it("Should allow the buyer to deposit tokens", async function () {
        // Approve and deposit tokens
        await token.connect(buyer).approve(escrow.address, depositAmount);
        await escrow.connect(buyer).deposit(depositAmount);

        // Verify the contract state
        const contractAmount = await escrow.amount();
        const expectedAmount = depositAmount.sub(depositAmount.mul(escrowFee).div(100));
        expect(contractAmount).to.equal(expectedAmount);

        const currentState = await escrow.currentState();
        expect(currentState).to.equal(1); // AWAITING_DELIVERY
    });
});