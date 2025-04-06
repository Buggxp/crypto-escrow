import { expect } from "chai";
import hardhat from "hardhat";

const { ethers } = hardhat;

describe("Escrow Contract - Mark As Shipped Function", function () {
    let escrow, token, buyer, seller, arbiter;
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
            5, // Return shipment fee
            86400, // Dispute time limit
            token.address
        );
        await escrow.deployed();

        // Approve and deposit tokens
        await token.connect(buyer).approve(escrow.address, depositAmount);
        await escrow.connect(buyer).deposit(depositAmount);
    });

    it("Should allow the seller to mark the shipment as shipped", async function () {
        // Mark as shipped
        await escrow.connect(seller).markAsShipped();

        // Verify shipment confirmation
        const shipmentConfirmed = await escrow.hasConfirmedShipment(seller.address);
        expect(shipmentConfirmed).to.be.true;
    });
});