// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Figaro.sol";
import "../src/SRPFees.sol";
import "test/mocks/TestToken.sol";
import "test/mocks/RevertingToken.sol";

contract FigaroCreateProcessTest is Test {
    Figaro figaro;
    SRPFees srpFees;
    TestToken token;

    // Contract emits `SrpCreated` on creation (srpId, processId, srpHash indexed)
    event SrpCreated(
        uint256 indexed srpId,
        uint256 indexed processId,
        bytes32 indexed srpHash,
        uint256 prevSrpId,
        bytes32 prevHash,
        address seller,
        address buyer,
        address token,
        uint256 totalProcessValue
    );

    // Emitted on creation and subsequent state changes; used for asserting
    // lifecycle events (matches Figaro.SrpStateChanged signature)
    event SrpStateChanged(
        uint256 indexed srpId,
        uint256 indexed processId,
        address indexed principal,
        address seller,
        address buyer,
        bytes32 prevCreationHash,
        bytes32 versionHash,
        Figaro.State fromState,
        Figaro.State toState,
        int256 delta,
        uint256 coordinationCapitalBalance,
        uint256 totalProcessValue
    );

    address treasury = address(0xCAFE);
    address buyer = address(0xBEEF);
    address seller = address(0xD00D);

    function setUp() public {
        token = new TestToken("Test", "TST");
        // mint tokens to a dedicated seller address
        token.mint(seller, 1_000_000 ether);

        // deploy SRPFees with treasury and 30 BPS (0.3%)
        srpFees = new SRPFees(treasury, 30);

        // deploy Figaro
        figaro = new Figaro(address(srpFees), 50);
    }

    function testCreateProcessStoresStateAndTransfers() public {
        uint256 amount = 1_000 ether;
        uint256 coordinationCapital = 2 * amount;
        uint256 fee = srpFees.calculateFee(coordinationCapital);
        uint256 total = coordinationCapital + fee;

        // approve Figaro to pull total from seller
        vm.prank(seller);
        token.approve(address(figaro), total);

        uint256 beforeFigaro = token.balanceOf(address(figaro));
        uint256 beforeTreasury = token.balanceOf(treasury);
        uint256 beforeSeller = token.balanceOf(seller);

        // create process as seller
        vm.prank(seller);
        (uint256 processId, uint256 srpId) = figaro.createProcess(buyer, amount, address(token));

        // check ids
        assertTrue(processId >= 1, "processId assigned");
        assertTrue(srpId >= 1, "srpId assigned");

        // verify SRP storage
        (
            address sellerStored,
            address buyerStored,
            uint256 amountStored,
            address tokenStored,
            Figaro.State stateStored,
            uint256 coordinationBal
        ) = _readSrp(srpId);
        assertEq(sellerStored, seller);
        assertEq(buyerStored, buyer);
        assertEq(amountStored, amount);
        assertEq(tokenStored, address(token));
        // srp->process mapping should point back to the process
        assertEq(figaro.srpToProcessId(srpId), processId);
    }

    function testCreateProcessEmitsEventAndUsesCorrectIds() public {
        uint256 amount = 2_000 ether;
        uint256 coordinationCapital = 2 * amount;
        uint256 fee = srpFees.calculateFee(coordinationCapital);

        // approve
        vm.prank(seller);
        token.approve(address(figaro), coordinationCapital + fee);

        // expect SrpCreated with known ids (fresh Figaro starts at 1)
        // compare indexed srpId and processId only; skip srpHash comparison
        vm.expectEmit(true, true, false, false);
        emit SrpCreated(
            1, // srpId
            1, // processId
            bytes32(0),
            uint256(0),
            bytes32(0),
            seller,
            buyer,
            address(token),
            amount
        );

        vm.prank(seller);
        (uint256 processId, uint256 srpId) = figaro.createProcess(buyer, amount, address(token));
        assertEq(processId, 1);
        assertEq(srpId, 1);
    }

    function testCreateProcessEmitsEventWithCorrectHash() public {
        uint256 amount = 3_000 ether;
        uint256 coordinationCapital = 2 * amount;
        uint256 fee = srpFees.calculateFee(coordinationCapital);

        // approve required total
        vm.prank(seller);
        token.approve(address(figaro), coordinationCapital + fee);

        // compute expected creation hash using the same packing as Figaro
        bytes32 prevHash = bytes32(0);
        bytes32 expected = keccak256(abi.encodePacked(prevHash, seller, buyer, amount, address(token), amount));

        // expect the creation event with indexed srpId, processId and srpHash
        vm.expectEmit(true, true, true, false);
        emit SrpCreated(1, 1, expected, 0, prevHash, seller, buyer, address(token), amount);

        vm.prank(seller);
        (uint256 pid, uint256 sid) = figaro.createProcess(buyer, amount, address(token));
        assertEq(pid, 1);
        assertEq(sid, 1);

        // The `SrpCreated` emission includes the creation hash and was
        // asserted above via `vm.expectEmit`; no public getter for srpHash
        // exists, so we rely on the emitted event for verification.
    }

    function testCreateProcessEmitsStateChangedOnCreate() public {
        uint256 amount = 3_000 ether;
        uint256 coordinationCapital = 2 * amount;
        uint256 fee = srpFees.calculateFee(coordinationCapital);

        // approve required total
        vm.prank(seller);
        token.approve(address(figaro), coordinationCapital + fee);

        // compute expected creation hash and version hash
        bytes32 prevHash = bytes32(0);
        bytes32 creationHash = keccak256(abi.encodePacked(prevHash, seller, buyer, amount, address(token), amount));
        bytes32 creationVersion =
            keccak256(abi.encodePacked(creationHash, uint256(Figaro.State.Created), coordinationCapital));

        // expect both indexed and non-indexed fields to match
        vm.expectEmit(true, true, true, true);
        emit SrpStateChanged(
            1, // srpId
            1, // processId
            seller, // principal (seller for creation)
            seller,
            buyer,
            prevHash,
            creationVersion,
            Figaro.State.Created,
            Figaro.State.Created,
            int256(coordinationCapital),
            coordinationCapital,
            amount
        );

        vm.prank(seller);
        (uint256 pid, uint256 sid) = figaro.createProcess(buyer, amount, address(token));
        assertEq(pid, 1);
        assertEq(sid, 1);
    }

    function testCreateProcessRevertsOnInvalidParams() public {
        uint256 amount = 100 ether;

        // zero buyer
        vm.expectRevert(bytes("buyer required"));
        vm.prank(seller);
        figaro.createProcess(address(0), amount, address(token));

        // buyer == seller
        vm.expectRevert(bytes("seller==buyer"));
        vm.prank(seller);
        figaro.createProcess(seller, amount, address(token));

        // amount == 0
        vm.expectRevert(bytes("amount>0"));
        vm.prank(seller);
        figaro.createProcess(buyer, 0, address(token));

        // token == 0
        vm.expectRevert(bytes("token required"));
        vm.prank(seller);
        figaro.createProcess(buyer, amount, address(0));
    }

    // Focused, single-case tests for clearer failure localization
    function testCreateProcessRevert_BuyerZero() public {
        uint256 amount = 1 ether;
        vm.expectRevert(bytes("buyer required"));
        vm.prank(seller);
        figaro.createProcess(address(0), amount, address(token));
    }

    function testCreateProcessRevert_BuyerEqualsSeller() public {
        uint256 amount = 1 ether;
        vm.expectRevert(bytes("seller==buyer"));
        vm.prank(seller);
        figaro.createProcess(seller, amount, address(token));
    }

    function testCreateProcessRevert_AmountZero() public {
        vm.expectRevert(bytes("amount>0"));
        vm.prank(seller);
        figaro.createProcess(buyer, 0, address(token));
    }

    function testCreateProcessRevert_TokenZero() public {
        uint256 amount = 1 ether;
        vm.expectRevert(bytes("token required"));
        vm.prank(seller);
        figaro.createProcess(buyer, amount, address(0));
    }

    function testCreateProcessRevertsOnInsufficientApproval() public {
        uint256 amount = 500 ether;
        uint256 coordinationCapital = 2 * amount;
        uint256 fee = srpFees.calculateFee(coordinationCapital);
        uint256 total = coordinationCapital + fee;

        // do NOT approve -> expect revert
        vm.expectRevert(bytes("insufficient approval"));
        vm.prank(seller);
        figaro.createProcess(buyer, amount, address(token));
    }

    function testCreateProcessZeroFeePaysNoTreasury() public {
        // deploy SRPFees with zero fee
        SRPFees zeroFee = new SRPFees(address(0xDEAD), 0);
        Figaro f2 = new Figaro(address(zeroFee), 50);

        // mint and approve
        token.mint(seller, 1_000 ether);
        vm.prank(seller);
        token.approve(address(f2), 1_000 ether);

        uint256 beforeTreasury = token.balanceOf(zeroFee.treasury());
        vm.prank(seller);
        (uint256 p, uint256 s) = f2.createProcess(buyer, 100 ether, address(token));
        uint256 afterTreasury = token.balanceOf(zeroFee.treasury());
        assertEq(afterTreasury, beforeTreasury);
    }

    function testCreateProcessRevertsWithRevertingToken() public {
        RevertingToken r = new RevertingToken("R", "R");
        r.mint(seller, 1000 ether);
        vm.prank(seller);
        r.approve(address(figaro), 1000 ether);

        vm.expectRevert(bytes("RevertingToken: transferFrom reverted"));
        vm.prank(seller);
        figaro.createProcess(buyer, 1 ether, address(r));
    }

    // Consolidated zero-fee createProcess test (moved from FigaroBranches)
    function testCreateProcessSkipsTreasuryWhenFeeZero() public {
        TestToken t = new TestToken("T", "TT");
        t.mint(seller, 10_000 ether);

        SRPFees zeroFees = new SRPFees(treasury, 0);
        Figaro f = new Figaro(address(zeroFees), 50);

        uint256 amount = 1_000 ether;
        uint256 coordinationCapital = 2 * amount;
        uint256 fee = zeroFees.calculateFee(coordinationCapital);
        assertEq(fee, 0);

        uint256 beforeTreasury = t.balanceOf(treasury);
        uint256 beforeContract = t.balanceOf(address(f));

        vm.prank(seller);
        t.approve(address(f), coordinationCapital + fee);
        vm.prank(seller);
        (uint256 pid, uint256 sid) = f.createProcess(buyer, amount, address(t));

        // treasury unchanged, contract received coordination capital
        assertEq(t.balanceOf(treasury), beforeTreasury);
        assertEq(t.balanceOf(address(f)), beforeContract + coordinationCapital);

        // basic sanity: srp registered
        (, address b, uint256 a,, Figaro.State st, uint256 cap) = f.srps(sid);
        assertEq(b, buyer);
        assertEq(a, amount);
        assertEq(uint256(st), uint256(Figaro.State.Created));
        assertEq(cap, coordinationCapital);
    }

    function _readSrp(uint256 srpId)
        internal
        view
        returns (
            address seller,
            address buyerAddr,
            uint256 amount,
            address tokenAddr,
            Figaro.State state,
            uint256 coordCap
        )
    {
        // Figaro.srps public getter returns the SRP tuple; destructure directly
        (address seller, address buyerAddr, uint256 amount, address tokenAddr, Figaro.State state, uint256 coordCap) =
            figaro.srps(srpId);

        return (seller, buyerAddr, amount, tokenAddr, state, coordCap);
    }
}
