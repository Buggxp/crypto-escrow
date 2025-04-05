// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./openzeppelin/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Escrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable buyer;
    address public immutable seller;
    address public immutable arbiter;
    uint256 public immutable escrowFee; // Fee percentage (e.g., 2 = 2%)
    uint256 public immutable returnShipmentFee; // Fee percentage for returns
    uint256 public immutable disputeTimeLimit; // Time limit for disputes in seconds

    uint256 public amount; // Amount held in escrow
    bool public isFunded; // Indicates if the escrow is funded
    address public immutable tokenAddress; // Address of the ERC20 token (address(0) for ETH)

    enum State { AWAITING_PAYMENT, AWAITING_DELIVERY, AWAITING_INSPECTION, COMPLETE, REFUNDED, DISPUTED }
    State public currentState;

    struct Milestone {
        string description;
        uint256 payment;
        bool completed;
    }
    Milestone[] public milestones;

    mapping(address => bool) private hasConfirmedInspection;
    mapping(address => bool) private hasConfirmedShipment;

    uint256 public shipmentStartTime;
    uint256 public inspectionStartTime;

    event Deposit(address indexed buyer, uint256 amount);
    event Refund(address indexed buyer, uint256 amount);
    event DeliveryConfirmed(address indexed seller, uint256 amount);
    event MilestoneCompleted(uint256 indexed milestoneIndex, uint256 payment);
    event EmergencyWithdrawal(address indexed arbiter, uint256 amount);

    modifier onlyBuyer() {
        require(msg.sender == buyer, "Only the buyer can call this.");
        _;
    }

    modifier onlySeller() {
        require(msg.sender == seller, "Only the seller can call this.");
        _;
    }

    modifier onlyArbiter() {
        require(msg.sender == arbiter, "Only the arbiter can call this.");
        _;
    }

    constructor(
        address _seller,
        address _arbiter,
        uint256 _escrowFee,
        uint256 _returnShipmentFee,
        uint256 _disputeTimeLimit,
        address _tokenAddress // Address of the ERC20 token (use address(0) for ETH)
    ) {
        require(_seller != address(0), "Seller address cannot be zero.");
        require(_arbiter != address(0), "Arbiter address cannot be zero.");
        require(_escrowFee <= 100, "Escrow fee must be <= 100%.");
        require(_returnShipmentFee <= 100, "Return shipment fee must be <= 100%.");

        buyer = msg.sender;
        seller = _seller;
        arbiter = _arbiter;
        escrowFee = _escrowFee;
        returnShipmentFee = _returnShipmentFee;
        disputeTimeLimit = _disputeTimeLimit;
        tokenAddress = _tokenAddress;
        currentState = State.AWAITING_PAYMENT;
    }

    function deposit(uint256 _amount) external payable onlyBuyer nonReentrant {
        require(currentState == State.AWAITING_PAYMENT, "Escrow is already funded.");
        require(_amount > 0, "Deposit amount must be greater than zero.");

        if (tokenAddress == address(0)) {
            // ETH deposit
            require(msg.value == _amount, "Incorrect ETH amount sent.");
            uint256 fee = (_amount * escrowFee) / 100;
            amount = _amount - fee;
        } else {
            // ERC20 token deposit
            IERC20 token = IERC20(tokenAddress);
            require(token.allowance(msg.sender, address(this)) >= _amount, "Insufficient token allowance.");
            uint256 fee = (_amount * escrowFee) / 100;
            amount = _amount - fee;

            // Transfer tokens from buyer to contract
            token.safeTransferFrom(msg.sender, address(this), _amount);
        }

        isFunded = true;
        shipmentStartTime = block.timestamp;
        currentState = State.AWAITING_DELIVERY;

        emit Deposit(msg.sender, _amount);
    }

    function createMilestone(string calldata _description, uint256 _payment) external onlyBuyer {
        require(currentState == State.AWAITING_DELIVERY, "Cannot create milestone now.");
        require(bytes(_description).length > 0, "Milestone description cannot be empty.");
        require(_payment > 0, "Milestone payment must be greater than zero.");
        require(_payment <= amount, "Milestone payment exceeds available funds.");

        milestones.push(Milestone(_description, _payment, false));
    }

    function markAsShipped() external onlySeller {
        require(currentState == State.AWAITING_DELIVERY, "Not in delivery state.");
        hasConfirmedShipment[buyer] = true;
    }

    function confirmShipment() external onlyBuyer {
        require(currentState == State.AWAITING_DELIVERY, "Not in delivery state.");
        require(hasConfirmedShipment[seller], "Seller has not marked as shipped.");
        require(block.timestamp <= shipmentStartTime + disputeTimeLimit, "Time limit exceeded.");

        currentState = State.AWAITING_INSPECTION;
        inspectionStartTime = block.timestamp;
    }

    function markAsInspected() external onlyBuyer {
        require(currentState == State.AWAITING_INSPECTION, "Cannot mark as inspected.");
        hasConfirmedInspection[buyer] = true;
    }

    function confirmDelivery() external onlyBuyer nonReentrant {
        require(currentState == State.AWAITING_INSPECTION, "Cannot confirm delivery.");
        require(hasConfirmedInspection[buyer], "Buyer has not inspected goods.");

        currentState = State.COMPLETE;
        uint256 paymentAmount = amount;
        amount = 0; // Prevent reentrancy

        if (tokenAddress == address(0)) {
            // ETH transfer
            (bool success, ) = seller.call{value: paymentAmount}("");
            require(success, "Transfer to seller failed.");
        } else {
            // ERC20 token transfer
            IERC20 token = IERC20(tokenAddress);
            token.safeTransfer(seller, paymentAmount);
        }

        emit DeliveryConfirmed(seller, paymentAmount);
    }

    function refundBuyer() external onlyArbiter nonReentrant {
        require(currentState == State.AWAITING_INSPECTION, "Cannot refund now.");
        require(block.timestamp > inspectionStartTime + disputeTimeLimit, "Dispute time limit not exceeded.");

        currentState = State.REFUNDED;
        uint256 refundAmount = amount;
        amount = 0; // Prevent reentrancy

        if (tokenAddress == address(0)) {
            // ETH refund
            (bool success, ) = buyer.call{value: refundAmount}("");
            require(success, "Refund to buyer failed.");
        } else {
            // ERC20 token refund
            IERC20 token = IERC20(tokenAddress);
            token.safeTransfer(buyer, refundAmount);
        }

        emit Refund(buyer, refundAmount);
    }

    function returnShipment() external onlyBuyer nonReentrant {
        require(currentState == State.AWAITING_INSPECTION, "Cannot return shipment now.");

        uint256 penaltyAmount = (amount * returnShipmentFee) / 100;
        uint256 sellerAmount = amount - penaltyAmount;
        amount = 0; // Prevent reentrancy

        currentState = State.REFUNDED;

        if (tokenAddress == address(0)) {
            // ETH transfers
            (bool successSeller, ) = seller.call{value: sellerAmount}("");
            require(successSeller, "Transfer to seller failed.");

            (bool successArbiter, ) = arbiter.call{value: penaltyAmount}("");
            require(successArbiter, "Transfer to arbiter failed.");
        } else {
            // ERC20 token transfers
            IERC20 token = IERC20(tokenAddress);
            token.safeTransfer(seller, sellerAmount);
            token.safeTransfer(arbiter, penaltyAmount);
        }
    }

    function completeMilestone(uint256 milestoneIndex) external onlyBuyer nonReentrant {
        require(milestoneIndex < milestones.length, "Invalid milestone index.");

        Milestone storage milestone = milestones[milestoneIndex];
        require(!milestone.completed, "Milestone already completed.");
        require(milestone.payment <= amount, "Insufficient funds for milestone.");

        milestone.completed = true;
        amount -= milestone.payment;

        if (tokenAddress == address(0)) {
            // ETH transfer
            (bool success, ) = seller.call{value: milestone.payment}("");
            require(success, "Transfer to seller failed.");
        } else {
            // ERC20 token transfer
            IERC20 token = IERC20(tokenAddress);
            token.safeTransfer(seller, milestone.payment);
        }

        emit MilestoneCompleted(milestoneIndex, milestone.payment);
    }

    function emergencyWithdraw() external onlyArbiter {
        uint256 balance = address(this).balance;
        if (tokenAddress == address(0)) {
            (bool success, ) = arbiter.call{value: balance}("");
            require(success, "Emergency withdrawal failed.");
        } else {
            IERC20 token = IERC20(tokenAddress);
            uint256 tokenBalance = token.balanceOf(address(this));
            token.safeTransfer(arbiter, tokenBalance);
        }

        emit EmergencyWithdrawal(arbiter, balance);
    }

    // Fallback function to prevent accidental Ether transfers
    fallback() external payable {
        revert("Direct Ether transfers not allowed. Use the deposit function.");
    }

    // Receive function to handle Ether sent directly to the contract
    receive() external payable {
        revert("Direct Ether transfers not allowed.");
    }
}
