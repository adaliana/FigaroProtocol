// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SRPFees
 * @notice Handles protocol fee logic and treasury management.
 * @dev This contract facilitates fee collection from Figaro.sol to treasury via approve/transferFrom pattern.
 *      Design rationale: Maintains treasury control, fee rate flexibility, and gas efficiency.
 */
contract SRPFees {
    using SafeERC20 for IERC20;

    // =============================================================
    //                          ERRORS
    // =============================================================

    error OnlyTreasury();
    error OnlyPendingTreasury();
    error FeeTooHigh();
    error ZeroAddress();

    uint256 public feeBps;
    uint256 public constant MAX_FEE_BPS = 90; // 0.9%
    address public treasury;
    address public pendingTreasury;

    event FeeUpdated(uint256 newFeeBps);
    event TreasuryUpdated(address newTreasury);
    event TreasuryProposed(address indexed currentTreasury, address indexed proposedTreasury);
    event TreasuryProposalCancelled(address indexed treasury, address indexed cancelledProposal);
    event FeeCollected(address indexed token, uint256 amount, address indexed payer);

    constructor(address _treasury, uint256 _feeBps) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        treasury = _treasury;
        feeBps = _feeBps;
    }

    /// @notice Adjust protocol fee in basis points (treasury governance)
    /// @dev **Treasury only.** Change the fee charged on collateral deposits.
    ///      Fee applies to all new SRP creations (existing SRPs unaffected by changes).
    ///
    ///      **Hard Cap:** 90 BPS (0.9%) enforced by MAX_FEE_BPS constant.
    ///      No governance vote can exceed this limit (prevents platform capture).
    ///      Attempts to set above 90 BPS revert with FeeTooHigh error.
    ///
    ///      **Current Default:** 30 BPS (0.3%) → 3× lower than typical 0.9% crypto platforms.
    ///
    ///
    ///      **Access Control:** Only current treasury can call. No timelock, immediate effect.
    ///      Ensures treasury can respond to market conditions or protocol sustainability needs.
    ///
    ///      **Governance Philosophy:**
    ///      Fee funds protocol maintenance (audits, infrastructure, development), not profit extraction.
    ///      Treasury can lower fees as adoption scales (economies of scale).
    ///      Hard cap prevents future governance from extracting platform rents.
    ///
    ///      **Side Effects:**
    ///      - Updates feeBps state variable (affects all future collectFee() calls)
    ///      - Emits FeeUpdated event for off-chain tracking
    ///      - Existing SRPs unaffected
    ///      - No timelock delay (immediate effect on new SRPs)
    /// @param newFeeBps New fee in basis points (0-90 BPS, enforced by MAX_FEE_BPS)
    function setFeeBps(uint256 newFeeBps) external {
        if (msg.sender != treasury) revert OnlyTreasury();
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    /// @notice Propose a new treasury address (step 1 of 2)
    /// @dev **Current treasury only.** Step 1 of two-step treasury transfer.
    ///      Propose a new treasury address. New treasury must call acceptTreasury() to complete transfer.
    ///
    ///      **Security Rationale (Two-Step Pattern):**
    ///      Problem: Single-step setTreasury(address) could brick protocol if:
    ///      - Typo in address (wrong EOA, can't sign)
    ///      - Contract without ERC20 receive logic (collectFee() reverts forever)
    ///      - Multisig with incorrect threshold (can't execute transactions)
    ///
    ///      Solution: New treasury must prove it can:
    ///      1. Sign transactions (call acceptTreasury())
    ///      2. Receive ERC20 transfers (acceptTreasury() success implies valid address)
    ///
    ///      **Workflow:**
    ///      1. Current treasury: proposeTreasury(0xNEW) → sets pendingTreasury
    ///      2. New treasury: acceptTreasury() → completes transfer, clears pending
    ///      3. If mistake: cancelTreasuryProposal() → clears pending, try again
    ///
    ///      **Access Control:** Only current treasury can propose.
    /// @param newTreasury The proposed new treasury address
    function proposeTreasury(address newTreasury) external {
        if (msg.sender != treasury) revert OnlyTreasury();
        if (newTreasury == address(0)) revert ZeroAddress();
        pendingTreasury = newTreasury;
        emit TreasuryProposed(treasury, newTreasury);
    }

    /// @notice Accept treasury role (step 2 of 2)
    /// @dev **Pending treasury only.** Step 2 of two-step treasury transfer.
    ///      Accept ownership proposed by current treasury. This completes the transfer.
    ///
    ///      **Security:** By calling this function, you prove:
    ///      1. You control the proposed address (can sign transactions)
    ///      2. Address can execute protocol operations (not bricked contract)
    ///      3. Implicit: If you're a contract, your ERC20 receive logic works
    ///
    ///      **Side Effects:**
    ///      - treasury = msg.sender (you become active treasury)
    ///      - pendingTreasury = address(0) (clears proposal state)
    ///      - TreasuryUpdated event emitted
    ///
    ///      **Access Control:** Only address in pendingTreasury can call.
    ///      Check current proposal: SRPFees.pendingTreasury()
    ///
    ///      **Failed Transaction Causes:**
    ///      - Not the pending treasury (revert: OnlyPendingTreasury)
    ///      - No pending proposal (pendingTreasury == address(0))
    /// @dev No parameters or return values. Completes two-step treasury transfer.
    function acceptTreasury() external {
        if (msg.sender != pendingTreasury) revert OnlyPendingTreasury();
        treasury = msg.sender;
        pendingTreasury = address(0);
        emit TreasuryUpdated(treasury);
    }

    /// @notice Cancel pending treasury proposal
    /// @dev **Current treasury only.** Revoke a pending treasury proposal.
    ///      Clears pendingTreasury state without changing current treasury.
    ///
    ///      **Use Cases:**
    ///      - Typo in proposed address → cancel and repropose correct address
    ///      - Pending treasury never accepts → cancel and try different address
    ///      - Change of governance plans → cancel and keep current treasury
    ///
    ///      **Side Effects:**
    ///      - pendingTreasury = address(0) (clears proposal)
    ///      - treasury unchanged (you remain active treasury)
    ///      - TreasuryProposalCancelled event emitted
    ///
    ///      **Access Control:** Only current treasury can cancel.
    ///
    ///      @dev This does not change the current treasury.
    ///      Only affects the pending proposal. Current treasury remains in control.
    /// @dev No parameters or return values. Clears `pendingTreasury` without changing `treasury`.
    function cancelTreasuryProposal() external {
        if (msg.sender != treasury) revert OnlyTreasury();
        address cancelled = pendingTreasury;
        pendingTreasury = address(0);
        emit TreasuryProposalCancelled(treasury, cancelled);
    }

    /// @notice Collect protocol fee from caller and transfer to treasury
    /// @dev Transfers fee from msg.sender to treasury via ERC20 approval.
    ///      This is the core fee collection mechanism - Figaro approves SRPFees for fee amount,
    ///      then calls collectFee() which pulls tokens directly to treasury.
    ///
    ///      **Security:** Uses SafeERC20.safeTransferFrom for token transfer.
    ///      Protects against non-standard ERC20 implementations (no return value, etc).
    ///
    ///      **Treasury Revenue Tracking:**
    ///      - FeeCollected event emitted for every fee (even if zero)
    ///      - Off-chain indexers can track total protocol revenue by token
    ///      - Governors can query historical fee collection via event logs
    ///
    ///      **Access Control:** Any address can call.
    ///      Caller must have pre-approved this contract for feeAmount.
    ///
    ///      **Failed Transaction Causes:**
    ///      - Insufficient allowance (caller didn't approve SRPFees)
    ///      - Insufficient balance (caller doesn't have feeAmount)
    ///      - Invalid token address (token == address(0))
    /// @param token The ERC20 token address to collect fee in
    /// @param amount The base amount (fee calculated as amount × feeBps / 10000)
    /// @return feeAmount The actual fee collected and transferred to treasury
    function collectFee(address token, uint256 amount) external returns (uint256 feeAmount) {
        require(token != address(0), "Use WETH for ETH operations");
        feeAmount = (amount * feeBps) / 10000;
        if (feeAmount > 0) {
            IERC20(token).safeTransferFrom(msg.sender, treasury, feeAmount);
        }
        emit FeeCollected(token, feeAmount, msg.sender);
    }

    /// @notice Calculate protocol fee for a given collateral amount
    /// @dev **View function.** Pure calculation: (amount × feeBps) / 10000.
    ///      Governors use this to preview fees before adjusting feeBps.
    ///
    ///      **Governance Use Case:**
    ///      Before calling setFeeBps(newRate), governors can:
    ///      1. Query calculateFee(typicalCollateral) with current feeBps
    ///      2. Simulate new fee: (typicalCollateral × newRate) / 10000
    ///      3. Compare impact: newFee vs oldFee
    ///      4. Decide if fee change is appropriate
    ///
    ///      **Access Control:** Public view (anyone can query).
    ///      No state changes, no transaction costs (pure calculation).
    /// @param amount The collateral amount to calculate fee for (in token base units)
    /// @return The calculated fee amount (in same units as input)
    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * feeBps) / 10000;
    }
}
