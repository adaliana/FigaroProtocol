// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SRPFees.sol";
import {TestToken} from "test/mocks/TestToken.sol";
import {RevertingToken} from "test/mocks/RevertingToken.sol";

contract SRPFeesTest is Test {
    SRPFees public fees;
    TestToken public token;

    // local copy of events for expectEmit
    event FeeCollected(address indexed token, uint256 amount, address indexed payer);
    event FeeUpdated(uint256 newFeeBps);
    event TreasuryProposed(address indexed currentTreasury, address indexed proposedTreasury);
    event TreasuryUpdated(address indexed newTreasury);
    event TreasuryProposalCancelled(address indexed treasury, address indexed cancelledProposal);

    address public constant TREASURY = address(0xBEEF);
    address public constant ALICE = address(0xABCD);
    address public constant BOB = address(0xCAFE);

    function setUp() public {
        token = new TestToken("Test", "TST");
        // set default fee 30 BPS (0.3%) and treasury
        fees = new SRPFees(TREASURY, 30);
    }

    function test_setFeeBps_emits_and_reverts_on_high() public {
        // emit FeeUpdated when treasury sets
        vm.prank(TREASURY);
        vm.expectEmit(false, false, false, true);
        emit FeeUpdated(45);
        fees.setFeeBps(45);
        assertEq(fees.feeBps(), 45);

        // revert when too high
        vm.prank(TREASURY);
        vm.expectRevert();
        fees.setFeeBps(100);
    }

    function test_collectFee_reverts_on_insufficients() public {
        // choose base so computed fee exceeds ALICE balance
        uint256 baseForInsufficientBalance = 4000 ether; // fee = 4000*30/10000 = 12 ether
        uint256 base = 1000 ether;

        // mint less than fee and approve -> insufficient balance
        token.mint(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(address(fees), baseForInsufficientBalance);
        vm.prank(ALICE);
        vm.expectRevert();
        fees.collectFee(address(token), baseForInsufficientBalance);

        // mint enough but do not approve -> insufficient allowance
        token.mint(BOB, base);
        vm.prank(BOB);
        vm.expectRevert();
        fees.collectFee(address(token), base);
    }

    function test_proposeTreasury_reverts_on_zero_address() public {
        vm.prank(TREASURY);
        vm.expectRevert();
        fees.proposeTreasury(address(0));
    }

    function test_acceptTreasury_reverts_without_pending() public {
        vm.expectRevert();
        fees.acceptTreasury();
    }

    function test_proposeTreasury_only_treasury_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert();
        fees.proposeTreasury(BOB);
    }

    function test_cancelTreasuryProposal_only_treasury_reverts() public {
        // propose by treasury
        vm.prank(TREASURY);
        fees.proposeTreasury(ALICE);

        // non-treasury attempts to cancel
        vm.prank(BOB);
        vm.expectRevert();
        fees.cancelTreasuryProposal();
    }

    function test_setFeeBps_accepts_max() public {
        vm.prank(TREASURY);
        fees.setFeeBps(90);
        assertEq(fees.feeBps(), 90);
    }

    function test_calculateFee_rounding() public view {
        // small amounts round down
        assertEq(fees.calculateFee(1), 0);
        assertEq(fees.calculateFee(333), (333 * fees.feeBps()) / 10000);
    }

    function test_collectFee_reverts_on_reverting_token() public {
        RevertingToken rev = new RevertingToken("Rev", "REV");
        rev.mint(ALICE, 1000 ether);
        vm.prank(ALICE);
        rev.approve(address(fees), 1000 ether);
        vm.prank(ALICE);
        vm.expectRevert(bytes("RevertingToken: transferFrom reverted"));
        fees.collectFee(address(rev), 1000 ether);
    }

    function test_constructor_reverts_on_zero_treasury() public {
        vm.expectRevert();
        new SRPFees(address(0), 10);
    }

    function test_constructor_reverts_on_fee_too_high() public {
        vm.expectRevert();
        new SRPFees(TREASURY, 100); // > MAX_FEE_BPS (90)
    }

    function test_setFeeBps_only_treasury() public {
        // non-treasury cannot set
        vm.prank(ALICE);
        vm.expectRevert();
        fees.setFeeBps(10);

        // treasury can set
        vm.prank(TREASURY);
        fees.setFeeBps(50);
        assertEq(fees.feeBps(), 50);
    }

    function test_treasury_propose_accept_cancel_flow() public {
        // propose new treasury
        vm.prank(TREASURY);
        fees.proposeTreasury(ALICE);
        assertEq(fees.pendingTreasury(), ALICE);

        // only pending may accept
        vm.prank(BOB);
        vm.expectRevert();
        fees.acceptTreasury();

        // pending accepts
        vm.prank(ALICE);
        fees.acceptTreasury();
        assertEq(fees.treasury(), ALICE);
        assertEq(fees.pendingTreasury(), address(0));

        // new treasury can propose and cancel
        vm.prank(ALICE);
        fees.proposeTreasury(BOB);
        assertEq(fees.pendingTreasury(), BOB);

        vm.prank(ALICE);
        fees.cancelTreasuryProposal();
        assertEq(fees.pendingTreasury(), address(0));
    }

    function test_collectFee_transfers_and_emits() public {
        // mint tokens to ALICE and approve fees contract to pull
        uint256 base = 1000 ether;
        token.mint(ALICE, base);

        // calculate expected fee: coordination amount is passed as "amount" param
        uint256 expectedFee = (base * fees.feeBps()) / 10000;

        // ALICE approves fees contract
        vm.prank(ALICE);
        token.approve(address(fees), base);

        // expect FeeCollected event
        vm.expectEmit(true, true, true, true);
        emit FeeCollected(address(token), expectedFee, ALICE);

        // call collectFee as ALICE
        vm.prank(ALICE);
        uint256 feeAmount = fees.collectFee(address(token), base);
        assertEq(feeAmount, expectedFee);

        // treasury should have received fee
        assertEq(token.balanceOf(TREASURY), expectedFee);
    }

    function test_collectFee_no_transfer_when_fee_zero() public {
        // deploy fees with zero fee
        SRPFees zeroFees = new SRPFees(TREASURY, 0);
        uint256 base = 1000 ether;
        token.mint(ALICE, base);

        vm.prank(ALICE);
        token.approve(address(zeroFees), base);

        vm.expectEmit(true, true, true, true);
        emit FeeCollected(address(token), 0, ALICE);

        vm.prank(ALICE);
        uint256 feeAmount = zeroFees.collectFee(address(token), base);
        assertEq(feeAmount, 0);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_calculateFee_view() public {
        uint256 v = fees.calculateFee(10000);
        // feeBps == 30 → 10000 * 30 / 10000 = 30
        assertEq(v, 30);
    }

    function test_collectFee_reverts_on_zero_token() public {
        // token address zero should revert with the specific message
        vm.prank(ALICE);
        vm.expectRevert(bytes("Use WETH for ETH operations"));
        fees.collectFee(address(0), 1000);
    }

    function test_cancelTreasuryProposal_emits_when_no_pending() public {
        // ensure pending is zero initially
        assertEq(fees.pendingTreasury(), address(0));

        // expect TreasuryProposalCancelled with cancelledProposal == address(0)
        vm.prank(TREASURY);
        vm.expectEmit(true, true, true, true);
        emit TreasuryProposalCancelled(TREASURY, address(0));
        fees.cancelTreasuryProposal();
        assertEq(fees.pendingTreasury(), address(0));
    }
}
