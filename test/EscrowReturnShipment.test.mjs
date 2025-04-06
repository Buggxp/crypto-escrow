import { expect } from "chai";
import hardhat from "hardhat";

const { ethers } = hardhat;

describe("Escrow Contract - Return Shipment Function", function () {
    let escrow, token, buyer, seller, arbiter;
    const returnShipmentFee = 5; // 5% fee for returns
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
            2, // Escrow fee
            returnShipmentFee,
            86400, // Dispute time limit
            token.address
        );
        await escrow.deployed();

        // Approve and deposit tokens
        await token.connect(buyer).approve(escrow.address, depositAmount);
        await escrow.connect(buyer).deposit(depositAmount);

        // Mark as shipped and confirm shipment
        await escrow.connect(seller).markAsShipped();
        await escrow.connect(buyer).confirmShipment();
    });

    it("Should allow the buyer to return the shipment", async function () {
        // Return shipment
        await escrow.connect(buyer).returnShipment();

        // Verify the contract state
        const currentState = await escrow.currentState();
        expect(currentState).to.equal(4); // REFUNDED

        // Verify the seller's balance
        const penaltyAmount = depositAmount.mul(returnShipmentFee).div(100);
        const expectedSellerBalance = depositAmount.sub(penaltyAmount);
        const sellerBalance = await token.balanceOf(seller.address);
        expect(sellerBalance).to.equal(expectedSellerBalance);
    });
});