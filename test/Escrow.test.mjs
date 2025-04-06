import { expect } from "chai";
import hardhat from "hardhat";

const { ethers } = hardhat;

describe("Escrow Contract", function () {
    let escrow, token, buyer, seller, arbiter;
    const escrowFee = 2; // 2% fee
    const returnShipmentFee = 5; // 5% fee for returns
    const disputeTimeLimit = 86400; // 1 day in seconds
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
            returnShipmentFee,
            disputeTimeLimit,
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

    it("Should allow the buyer to return the shipment", async function () {
        // Mark as shipped and confirm shipment
        await escrow.connect(seller).markAsShipped();
        await escrow.connect(buyer).confirmShipment();

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