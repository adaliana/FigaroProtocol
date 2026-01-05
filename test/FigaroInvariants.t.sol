// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Figaro.sol";
import "../src/SRPFees.sol";
import "test/mocks/TestToken.sol";

contract FigaroInvariants is Test {
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

    function setUpBase() internal {
        token = new TestToken("Test", "TST");
        token.mint(address(this), 10_000_000 ether);
        token.mint(buyer, 10_000_000 ether);
        token.mint(seller, 10_000_000 ether);

        srpFees = new SRPFees(treasury, 30);
        figaro = new Figaro(address(srpFees), 50);

        // seller creates process/root SRP
        uint256 coordinationCapital = 2 * amount;
        uint256 fee = srpFees.calculateFee(coordinationCapital);
        uint256 total = coordinationCapital + fee;

        vm.prank(seller);
        token.approve(address(figaro), total);
        vm.prank(seller);
        (processId, srpId) = figaro.createProcess(buyer, amount, address(token));
    }

    function testCoordinationCapitalLifecycle() public {
        setUpBase();

        // after create: stored coordination capital == 2x amount
        (,,,,, uint256 capAfterCreate) = figaro.srps(srpId);
        assertEq(capAfterCreate, 2 * amount);

        // buyer locks
        uint256 buyerDeposit = 2 * amount;
        uint256 fee = srpFees.calculateFee(buyerDeposit);
        uint256 total = buyerDeposit + fee;
        vm.prank(buyer);
        token.approve(address(figaro), total);
        vm.prank(buyer);
        figaro.lock(srpId);

        // after lock: stored coordination capital == 4x amount (seller 2x + buyer 2x)
        (,,,,, uint256 capAfterLock) = figaro.srps(srpId);
        assertEq(capAfterLock, 4 * amount);

        // buyer releases (place small cleanup deposit)
        uint256 perSrpDeposit = 1 ether;
        uint256 totalDeposit = perSrpDeposit * 1;
        vm.prank(buyer);
        token.approve(address(figaro), totalDeposit);
        vm.prank(buyer);
        figaro.releaseProcessWithCleanupDeposit(processId, perSrpDeposit);

        // after release: stored coordination capital == 3x amount (4A - refunded A)
        (,,,,, uint256 capAfterRelease) = figaro.srps(srpId);
        assertEq(capAfterRelease, 3 * amount);

        // seller refunds
        uint256 beforeSeller = token.balanceOf(seller);
        vm.prank(seller);
        figaro.refund(srpId);

        // after refund: stored coordination capital cleared and seller received 3x amount
        (,,,,, uint256 capAfterRefund) = figaro.srps(srpId);
        assertEq(capAfterRefund, 0);
        assertEq(token.balanceOf(seller), beforeSeller + 3 * amount);
    }

    function testRoleLifecycleInvariant() public {
        setUpBase();

        // Only seller may cancel in Created state
        vm.prank(other);
        vm.expectRevert();
        figaro.cancel(srpId);

        // buyer can lock
        uint256 buyerDeposit = 2 * amount;
        uint256 fee = srpFees.calculateFee(buyerDeposit);
        uint256 total = buyerDeposit + fee;
        vm.prank(buyer);
        token.approve(address(figaro), total);
        vm.prank(buyer);
        figaro.lock(srpId);

        // only non-root buyer cannot call release
        vm.prank(other);
        vm.expectRevert(bytes("only root buyer"));
        figaro.releaseProcessWithCleanupDeposit(processId, 0);

        // release as buyer with required non-zero per-SRP cleanup deposit
        uint256 perSrpDeposit = 1;
        vm.prank(buyer);
        token.approve(address(figaro), perSrpDeposit);
        vm.prank(buyer);
        figaro.releaseProcessWithCleanupDeposit(processId, perSrpDeposit);

        // after release only seller may refund
        vm.prank(other);
        vm.expectRevert();
        figaro.refund(srpId);

        vm.prank(seller);
        figaro.refund(srpId);
    }
}
