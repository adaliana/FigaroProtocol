// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Figaro.sol";
import "../src/SRPFees.sol";
import "test/mocks/TestToken.sol";
import "test/mocks/RevertingToken.sol";
import "test/mocks/BuyerRevertingToken.sol";

contract FigaroLockTest is Test {
    Figaro figaro;
    SRPFees srpFees;
    TestToken token;

    address treasury = address(0xCAFE);
    address buyer = address(0xBEEF);
    address seller = address(0xABCD);
    address other = address(0xDEAD);

    uint256 public srpId;
    uint256 public processId;
    uint256 public amount = 1_000 ether;

    // Contract emits SrpStateChanged for lifecycle transitions (indexed srpId, processId, principal)
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

    // BuyerRevertingToken is provided from test/mocks/BuyerRevertingToken.sol

    function setUp() public {
        token = new TestToken("Test", "TST");
        token.mint(address(this), 10_000_000 ether);
        token.mint(buyer, 10_000_000 ether);
        token.mint(seller, 10_000_000 ether);

        srpFees = new SRPFees(treasury, 30);
        figaro = new Figaro(address(srpFees), 50);

        // seller (this) creates process/root SRP
        uint256 coordinationCapital = 2 * amount;
        uint256 fee = srpFees.calculateFee(coordinationCapital);
        uint256 total = coordinationCapital + fee;

        vm.prank(seller);
        token.approve(address(figaro), total);
        vm.prank(seller);
        (processId, srpId) = figaro.createProcess(buyer, amount, address(token));
    }

    function testLockHappyPathUpdatesStateAndBalances() public {
        uint256 buyerDeposit = 2 * amount;
        uint256 fee = srpFees.calculateFee(buyerDeposit);
        uint256 total = buyerDeposit + fee;

        // buyer approves Figaro
        vm.prank(buyer);
        token.approve(address(figaro), total);

        uint256 beforeFigaro = token.balanceOf(address(figaro));
        uint256 beforeTreasury = token.balanceOf(treasury);
        uint256 beforeBuyer = token.balanceOf(buyer);

        // buyer calls lock
        vm.prank(buyer);
        figaro.lock(srpId);

        // state updated
        (
            address sellerStored,
            address buyerStored,
            uint256 amountStored,
            address tokenStored,
            Figaro.State stateStored,
            uint256 coordCap
        ) = _readSrp(srpId);
        assertEq(uint256(stateStored), uint256(Figaro.State.Locked));
        // seller deposited 2x amount at creation and buyer deposits 2x amount on lock
        assertEq(coordCap, 4 * amount);

        // balances: contract should increase by buyerDeposit (seller already deposited earlier)
        assertEq(token.balanceOf(address(figaro)), beforeFigaro + buyerDeposit);
        // treasury increased by fee
        assertEq(token.balanceOf(treasury), beforeTreasury + fee);
        // buyer decreased by total
        assertEq(token.balanceOf(buyer), beforeBuyer - total);
        assertEq(buyerStored, buyer);
        assertEq(sellerStored, seller);
    }

    function testLockEmitsSrpLockEvent() public {
        uint256 buyerDeposit = 2 * amount;
        uint256 fee = srpFees.calculateFee(buyerDeposit);
        uint256 total = buyerDeposit + fee;

        vm.prank(buyer);
        token.approve(address(figaro), total);

        // Expect the lifecycle `SrpStateChanged` event for the lock (principal = buyer)
        vm.expectEmit(true, true, true, false);
        emit SrpStateChanged(
            srpId,
            processId,
            buyer,
            seller,
            buyer,
            bytes32(0), // prevCreationHash (not compared)
            bytes32(0), // versionHash (not compared)
            Figaro.State.Created,
            Figaro.State.Locked,
            int256(buyerDeposit),
            4 * amount,
            figaro.srpTotalProcessValue(srpId)
        );

        vm.prank(buyer);
        figaro.lock(srpId);
    }

    function testLockRevertsIfBuyerApprovedWrongToken() public {
        // buyer approves a different token instance
        TestToken otherToken = new TestToken("Other", "OTR");
        otherToken.mint(buyer, 1000 ether);

        vm.prank(buyer);
        otherToken.approve(address(figaro), 1000 ether);

        vm.prank(buyer);
        vm.expectRevert(bytes("insufficient approval"));
        figaro.lock(srpId);
    }

    function testLockAtomicityWithBuyerRevertingToken() public {
        // Deploy a token that will revert on buyer transferFrom
        BuyerRevertingToken btoken = new BuyerRevertingToken("BR", "BRT", buyer);
        btoken.mint(address(this), 10_000 ether);
        btoken.mint(buyer, 10_000 ether);

        // Create a new Figaro instance so we can create a SRP that uses btoken
        SRPFees fees = new SRPFees(treasury, 30);
        Figaro f2 = new Figaro(address(fees), 50);

        // Seller (this) creates a process using btoken
        btoken.approve(address(f2), 4 * amount);
        // createProcess will attempt to transferFrom seller -> fee/contract and should NOT revert
        // BuyerRevertingToken only reverts when `from == buyer`, so creation should succeed
        (uint256 p2, uint256 s2) = f2.createProcess(buyer, amount, address(btoken));

        // Now buyer will attempt to lock but btoken.transferFrom will revert for buyer
        vm.prank(buyer);
        btoken.approve(address(f2), 4 * amount);

        vm.prank(buyer);
        vm.expectRevert(bytes("BuyerRevertingToken: transferFrom reverted for buyer"));
        f2.lock(s2);

        // After revert, state must remain Created (CEI guarantees no state change)
        (,,,, Figaro.State st, uint256 unusedCap) = f2.srps(s2);
        assertEq(uint256(st), uint256(Figaro.State.Created));
    }

    function testProcessLockedCountAndBalanceInvariants() public {
        uint256 buyerDeposit = 2 * amount;
        uint256 fee = srpFees.calculateFee(buyerDeposit);
        uint256 total = buyerDeposit + fee;

        vm.prank(buyer);
        token.approve(address(figaro), total);

        vm.prank(buyer);
        figaro.lock(srpId);

        // processLockedCount should be 1
        assertEq(figaro.processLockedCount(processId), 1);

        // sum of coordinationCapitalBalance across SRPs in process equals expected
        (address s, address b, uint256 amt, address tkn, Figaro.State st, uint256 cap) = _readSrp(srpId);
        // seller deposit (2x) + buyer deposit (2x) = 4x amount
        assertEq(cap, 4 * amount);
    }

    function testLockRevertsWhenNotBuyer() public {
        // attempt lock from an unauthorized address
        vm.prank(other);
        vm.expectRevert(bytes("OnlyBuyer"));
        figaro.lock(srpId);
    }

    function testLockRevertsWhenNotCreated() public {
        // perform successful lock first
        uint256 buyerDeposit = 2 * amount;
        uint256 fee = srpFees.calculateFee(buyerDeposit);
        uint256 total = buyerDeposit + fee;
        vm.prank(buyer);
        token.approve(address(figaro), total);
        vm.prank(buyer);
        figaro.lock(srpId);

        // second lock should revert due to state
        vm.prank(buyer);
        vm.expectRevert(bytes("InvalidState"));
        figaro.lock(srpId);
    }

    function testLockRevertsOnInsufficientApproval() public {
        // buyer does not approve
        vm.prank(buyer);
        vm.expectRevert(bytes("insufficient approval"));
        figaro.lock(srpId);
    }

    function testLockEmitsExactVersionHash() public {
        uint256 buyerDeposit = 2 * amount;
        uint256 fee = srpFees.calculateFee(buyerDeposit);
        uint256 total = buyerDeposit + fee;

        // buyer approves Figaro
        vm.prank(buyer);
        token.approve(address(figaro), total);

        // compute expected creation hash (prevHash = 0) matching Figaro.createProcess packing
        bytes32 prevHash = bytes32(0);
        bytes32 creationHash = keccak256(abi.encodePacked(prevHash, seller, buyer, amount, address(token), amount));

        // expected coordination capital after lock: seller deposited 2*amount at creation
        // buyer deposits 2*amount on lock -> total 4*amount
        uint256 expectedCoord = 4 * amount;

        // expected version hash for Locked state
        bytes32 expectedVersion = keccak256(abi.encodePacked(creationHash, uint256(Figaro.State.Locked), expectedCoord));

        // Expect full event data to match (including non-indexed prevCreationHash and versionHash)
        vm.expectEmit(true, true, true, true);
        emit SrpStateChanged(
            srpId,
            processId,
            buyer,
            seller,
            buyer,
            creationHash,
            expectedVersion,
            Figaro.State.Created,
            Figaro.State.Locked,
            int256(buyerDeposit),
            expectedCoord,
            figaro.srpTotalProcessValue(srpId)
        );

        vm.prank(buyer);
        figaro.lock(srpId);
    }

    function testLockZeroFeePaysNoTreasury() public {
        // deploy SRPFees with zero fee and new Figaro instance
        SRPFees zeroFees = new SRPFees(treasury, 0);
        Figaro f = new Figaro(address(zeroFees), 50);

        // mint tokens to seller for this fresh Figaro flow and approve
        token.mint(seller, 1_000 ether);
        vm.prank(seller);
        token.approve(address(f), 4 * amount);

        // seller creates process on fresh Figaro
        vm.prank(seller);
        (uint256 p2, uint256 s2) = f.createProcess(buyer, amount, address(token));

        // buyer approves only coordination capital (fee is zero)
        uint256 buyerDeposit = 2 * amount;
        vm.prank(buyer);
        token.approve(address(f), buyerDeposit);

        uint256 beforeTreasury = token.balanceOf(zeroFees.treasury());
        vm.prank(buyer);
        f.lock(s2);
        uint256 afterTreasury = token.balanceOf(zeroFees.treasury());

        assertEq(afterTreasury, beforeTreasury);
    }

    function _readSrp(uint256 _srpId)
        internal
        view
        returns (
            address seller,
            address buyerAddr,
            uint256 amt,
            address tokenAddr,
            Figaro.State state,
            uint256 coordCap
        )
    {
        (seller, buyerAddr, amt, tokenAddr, state, coordCap) = figaro.srps(_srpId);
    }
}
