// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Escrow is ReentrancyGuard {
    enum State {
        AWAITING_PAYMENT,
        AWAITING_DELIVERY,
        AWAITING_INSPECTION,
        COMPLETE,
        REFUNDED,
        DISPUTED
    }

    struct Milestone {
        string description;
        uint256 payment;
        bool completed;
    }

    address public immutable buyer;
    address public immutable seller;
    address public immutable arbiter;
    IERC20 public immutable token;

    uint256 public immutable escrowFee; // in %
    uint256 public immutable returnShipmentFee; // in %
    uint256 public immutable disputeTimeLimit;

    uint256 public amount;
    uint256 public lastActionTimestamp;
    State public currentState;

    Milestone[] public milestones;
    bool public shipmentMarked;
    bool public deliveryConfirmed;
    string public trackingNumber;

    event Deposit(address indexed buyer, uint256 amount);
    event MilestoneCreated(string description, uint256 payment);
    event MilestoneCompleted(uint256 index);
    event ShipmentMarked(string trackingNumber);
    event DeliveryConfirmed();
    event Refunded(address indexed to, uint256 amount);
    event DisputeOpened();
    event DisputeResolved(address indexed to, uint256 amount);
    event PartialRefund(address indexed to, uint256 amount);
    event TimeoutRelease(address indexed seller, uint256 amount);

    modifier onlyBuyer() {
        require(msg.sender == buyer, "Only buyer");
        _;
    }

    modifier onlySeller() {
        require(msg.sender == seller, "Only seller");
        _;
    }

    modifier onlyArbiter() {
        require(msg.sender == arbiter, "Only arbiter");
        _;
    }

    constructor(
        address _seller,
        address _arbiter,
        uint256 _escrowFee,
        uint256 _returnShipmentFee,
        uint256 _disputeTimeLimit,
        address _tokenAddress
    ) {
        require(_seller != address(0) && _arbiter != address(0) && _tokenAddress != address(0), "Zero address");
        require(_escrowFee <= 100 && _returnShipmentFee <= 100, "Fee too high");

        buyer = msg.sender;
        seller = _seller;
        arbiter = _arbiter;
        escrowFee = _escrowFee;
        returnShipmentFee = _returnShipmentFee;
        disputeTimeLimit = _disputeTimeLimit;
        token = IERC20(_tokenAddress);
        currentState = State.AWAITING_PAYMENT;
    }

    function deposit(uint256 _amount) external onlyBuyer nonReentrant {
        require(currentState == State.AWAITING_PAYMENT, "Wrong state");
        require(_amount > 0, "Amount must be > 0");

        uint256 fee = (_amount * escrowFee) / 100;
        uint256 netAmount = _amount - fee;

        require(token.transferFrom(buyer, address(this), _amount), "Transfer failed");
        amount += netAmount;
        currentState = State.AWAITING_DELIVERY;
        lastActionTimestamp = block.timestamp;

        emit Deposit(msg.sender, netAmount);
    }

    function createMilestone(string memory _desc, uint256 _payment) external onlyBuyer {
        require(currentState != State.COMPLETE, "Already complete");
        require(bytes(_desc).length > 0, "Empty description");
        require(_payment > 0 && _payment <= amountRemainingForMilestones(), "Invalid payment");

        milestones.push(Milestone(_desc, _payment, false));
        emit MilestoneCreated(_desc, _payment);
    }

    function completeMilestone(uint256 index) external onlyBuyer nonReentrant {
        require(index < milestones.length, "Invalid index");
        Milestone storage m = milestones[index];
        require(!m.completed, "Already completed");
        require(m.payment <= amount, "Insufficient funds");

        m.completed = true;
        amount -= m.payment;
        require(token.transfer(seller, m.payment), "Transfer failed");

        emit MilestoneCompleted(index);
    }

    function markAsShipped(string memory _trackingNumber) external onlySeller {
        require(currentState == State.AWAITING_DELIVERY, "Wrong state");
        require(!shipmentMarked, "Already marked");
        require(bytes(_trackingNumber).length > 0, "Tracking required");

        shipmentMarked = true;
        trackingNumber = _trackingNumber;
        currentState = State.AWAITING_INSPECTION;
        lastActionTimestamp = block.timestamp;

        emit ShipmentMarked(_trackingNumber);
    }

    function confirmDelivery() external onlyBuyer nonReentrant {
        require(currentState == State.AWAITING_INSPECTION, "Wrong state");
        require(shipmentMarked, "Not shipped yet");

        deliveryConfirmed = true;
        currentState = State.COMPLETE;
        uint256 remaining = amount;
        amount = 0;
        require(token.transfer(seller, remaining), "Transfer failed");

        emit DeliveryConfirmed();
    }

    function openDispute() external onlyBuyer {
        require(currentState == State.AWAITING_INSPECTION, "Cannot dispute now");
        currentState = State.DISPUTED;
        emit DisputeOpened();
    }

    function resolveDispute(bool refundBuyer, uint256 refundAmount) external onlyArbiter nonReentrant {
        require(currentState == State.DISPUTED, "Not disputed");
        require(refundAmount <= amount, "Refund too much");

        amount -= refundAmount;
        address recipient = refundBuyer ? buyer : seller;
        require(token.transfer(recipient, refundAmount), "Transfer failed");

        if (amount == 0) currentState = State.COMPLETE;
        emit DisputeResolved(recipient, refundAmount);
    }

    function refundBuyer() external onlySeller nonReentrant {
        require(currentState == State.AWAITING_DELIVERY || currentState == State.AWAITING_INSPECTION, "Wrong state");
        uint256 refund = (amount * (100 - returnShipmentFee)) / 100;
        amount = 0;
        currentState = State.REFUNDED;
        require(token.transfer(buyer, refund), "Transfer failed");
        emit Refunded(buyer, refund);
    }

    function partialRefund(uint256 refundAmount) external onlySeller nonReentrant {
        require(refundAmount > 0 && refundAmount <= amount, "Invalid refund amount");
        amount -= refundAmount;
        require(token.transfer(buyer, refundAmount), "Transfer failed");
        emit PartialRefund(buyer, refundAmount);
    }

    function timeoutRelease() external onlySeller nonReentrant {
        require(currentState == State.AWAITING_INSPECTION, "Not inspectable");
        require(block.timestamp > lastActionTimestamp + disputeTimeLimit, "Too early");

        uint256 remaining = amount;
        amount = 0;
        currentState = State.COMPLETE;
        require(token.transfer(seller, remaining), "Transfer failed");

        emit TimeoutRelease(seller, remaining);
    }

    function getMilestone(uint256 index) external view returns (string memory, uint256, bool) {
        require(index < milestones.length, "Invalid index");
        Milestone memory m = milestones[index];
        return (m.description, m.payment, m.completed);
    }

    function milestoneCount() external view returns (uint256) {
        return milestones.length;
    }

    function getCurrentState() external view returns (string memory) {
        if (currentState == State.AWAITING_PAYMENT) return "AWAITING_PAYMENT";
        if (currentState == State.AWAITING_DELIVERY) return "AWAITING_DELIVERY";
        if (currentState == State.AWAITING_INSPECTION) return "AWAITING_INSPECTION";
        if (currentState == State.COMPLETE) return "COMPLETE";
        if (currentState == State.REFUNDED) return "REFUNDED";
        if (currentState == State.DISPUTED) return "DISPUTED";
        return "UNKNOWN";
    }

    function amountRemainingForMilestones() public view returns (uint256 remaining) {
        uint256 committed;
        for (uint256 i = 0; i < milestones.length; i++) {
            if (!milestones[i].completed) {
                committed += milestones[i].payment;
            }
        }
        return amount - committed;
    }
}
