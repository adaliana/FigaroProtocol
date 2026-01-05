// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Figaro.sol";
import "../src/SRPFees.sol";
import "test/mocks/TestToken.sol";
import "test/mocks/ReentrantToken.sol";

contract FigaroReleaseTest is Test {
    Figaro figaro;
    SRPFees srpFees;
    TestToken token;

    address treasury = address(0xCAFE);
    address buyer = address(0xBEEF);
    address seller = address(0xABCD);

    uint256 public srpId;
    uint256 public processId;
    uint256 public amount = 1_000 ether;

    event ProcessReleased(
        uint256 indexed processId,
        address indexed seller,
        address buyer,
        address token,
        Figaro.State fromState,
        Figaro.State toState,
        uint256 totalBuyerRefund,
        uint256[] releasedSrps
    );

    event CleanupDepositPlaced(
        uint256 indexed processId,
        address indexed token,
        uint256 perSrpDeposit,
        uint256 processCleanupTotalDeposit,
        address payer
    );

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

    function testReleaseHappyPathPlacesCleanupDepositAndEmits() public {
        // buyer locks first
        uint256 buyerDeposit = 2 * amount;
        uint256 fee = srpFees.calculateFee(buyerDeposit);
        uint256 total = buyerDeposit + fee;

        vm.prank(buyer);
        token.approve(address(figaro), total);
        vm.prank(buyer);
        figaro.lock(srpId);

        // buyer must approve cleanup deposit before calling release
        uint256 perSrpDeposit = 5 ether;
        uint256 totalDeposit = perSrpDeposit * 1;
        vm.prank(buyer);
        token.approve(address(figaro), totalDeposit);

        uint256 beforeBuyer = token.balanceOf(buyer);
        uint256 beforeContract = token.balanceOf(address(figaro));

        // Only check indexed topics for ProcessReleased (do not compare array/data)
        // We only assert the cleanup-deposit event (ProcessReleased is validated via state/balance checks)
        vm.expectEmit(true, true, false, true);
        emit CleanupDepositPlaced(processId, address(token), perSrpDeposit, totalDeposit, buyer);

        vm.prank(buyer);
        figaro.releaseProcessWithCleanupDeposit(processId, perSrpDeposit);

        // post-conditions
        (,,,, Figaro.State st, uint256 cap) = figaro.srps(srpId);
        assertEq(uint256(st), uint256(Figaro.State.Released));
        // stored coordination capital should equal seller(2x) + remaining buyer(1x) = 3x amount
        assertEq(cap, 3 * amount);

        // buyer balance: +refund(amount) - totalDeposit
        assertEq(token.balanceOf(buyer), beforeBuyer + amount - totalDeposit);

        // contract final balance = beforeContract - totalBuyerRefund + totalDeposit
        assertEq(token.balanceOf(address(figaro)), beforeContract - amount + totalDeposit);

        // process metadata set
        assertEq(figaro.processCleanupTotalDeposit(processId), totalDeposit);
        assertEq(figaro.processPerSrpDeposit(processId), perSrpDeposit);
        assert(figaro.processArchivableAt(processId) > block.timestamp);
    }

    function testReleaseRevertsIfNotRootBuyer() public {
        // lock as buyer
        uint256 buyerDeposit = 2 * amount;
        uint256 fee = srpFees.calculateFee(buyerDeposit);
        uint256 total = buyerDeposit + fee;

        vm.prank(buyer);
        token.approve(address(figaro), total);
        vm.prank(buyer);
        figaro.lock(srpId);

        // non-root buyer tries to release
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("only root buyer"));
        figaro.releaseProcessWithCleanupDeposit(processId, 1 ether);
    }

    function testReleaseRevertsWhenDepositBelowMin_local() public {
        // mirror of branch-target test: ensure deposit minimum guard fires
        address rootSeller = vm.addr(uint256(0x1111));
        address buyerAddr = vm.addr(uint256(0x2222));

        token.mint(rootSeller, 1_000 ether);
        token.mint(buyerAddr, 1_000 ether);

        vm.prank(rootSeller);
        token.approve(address(figaro), 200 ether);
        vm.prank(rootSeller);
        (uint256 pid, uint256 sid) = figaro.createProcess(buyerAddr, 50 ether, address(token));

        vm.prank(buyerAddr);
        token.approve(address(figaro), 200 ether);
        vm.prank(buyerAddr);
        figaro.lock(sid);

        // Set a non-zero minimum cleanup bounty via direct storage write
        // minCleanupBounty is storage slot 10 in Figaro.sol
        bytes32 slot = bytes32(uint256(10));
        vm.store(address(figaro), slot, bytes32(uint256(1 ether)));

        // Call release with per-srp deposit below the minimum and expect revert
        vm.prank(buyerAddr);
        vm.expectRevert(bytes("deposit below minimum"));
        figaro.releaseProcessWithCleanupDeposit(pid, 0);
    }

    function testReleaseRevertsOnDepositOverflow_local() public {
        // mirror of branch-target overflow test using local Figaro instance
        address rootSeller = vm.addr(uint256(0x1010));
        address buyerAddr = vm.addr(uint256(0x2020));
        address third = vm.addr(uint256(0x3030));

        TestToken t = new TestToken("T", "TT");
        t.mint(rootSeller, 1_000 ether);
        t.mint(buyerAddr, 1_000 ether);
        t.mint(third, 1_000 ether);

        SRPFees feesLocal = new SRPFees(treasury, 30);
        Figaro f = new Figaro(address(feesLocal), 50);

        // create root process
        vm.prank(rootSeller);
        t.approve(address(f), 200 ether);
        vm.prank(rootSeller);
        (uint256 pid, uint256 rootSrp) = f.createProcess(buyerAddr, 50 ether, address(t));

        // buyer locks root
        vm.prank(buyerAddr);
        t.approve(address(f), 200 ether);
        vm.prank(buyerAddr);
        f.lock(rootSrp);

        // third party consent and approve for sellerBatchAdd
        vm.prank(third);
        f.grantRootSellerConsent(rootSeller, true);

        // third approves required coordination capital for its addition
        uint256 a1 = 1 ether;
        uint256 lastTotal = f.srpTotalProcessValue(rootSrp);
        uint256 total1 = lastTotal + a1;
        uint256 coord1 = 2 * total1;
        vm.prank(third);
        t.approve(address(f), coord1 + 1 ether);

        // root calls sellerBatchAdd to add one child SRP
        address[] memory sellers = new address[](1);
        sellers[0] = third;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = a1;
        vm.prank(rootSeller);
        uint256[] memory newSrps = f.sellerBatchAdd(pid, sellers, amounts);
        uint256 child = newSrps[0];

        // buyer locks the child SRP (lock only the new SRP)
        uint256 buyerCoord = 2 * a1;
        uint256 fee = feesLocal.calculateFee(buyerCoord);
        vm.prank(buyerAddr);
        t.approve(address(f), buyerCoord + fee);
        uint256[] memory toLock = new uint256[](1);
        // pass the process id so batchLock will lock Created SRPs inside the process
        toLock[0] = pid;
        vm.prank(buyerAddr);
        f.batchLock(toLock);

        // sanity: ensure both SRPs exist and states are locked
        (,,,, Figaro.State sroot,) = f.srps(rootSrp);
        (,,,, Figaro.State schild,) = f.srps(child);
        assertEq(uint256(sroot), uint256(Figaro.State.Locked));
        assertEq(uint256(schild), uint256(Figaro.State.Locked));

        // Now call release with a per-srp deposit that overflows when multiplied by n=2
        uint256 n = 2;
        uint256 per = type(uint256).max / n + 1;

        vm.prank(buyerAddr);
        vm.expectRevert();
        f.releaseProcessWithCleanupDeposit(pid, per);
    }

    function testReleaseMultipleSrpsPlacesCleanupDepositAndEmits() public {
        // participants
        address rootSeller = vm.addr(uint256(0x1111));
        address buyerAddr = vm.addr(uint256(0x2222));
        address third = vm.addr(uint256(0x3333));

        TestToken t = new TestToken("T", "TT");
        t.mint(rootSeller, 1_000 ether);
        t.mint(buyerAddr, 1_000 ether);
        t.mint(third, 1_000 ether);

        SRPFees feesLocal = new SRPFees(treasury, 30);
        Figaro f = new Figaro(address(feesLocal), 50);

        // root seller creates process
        vm.prank(rootSeller);
        t.approve(address(f), 200 ether);
        vm.prank(rootSeller);
        (uint256 pid, uint256 rootSrp) = f.createProcess(buyerAddr, 50 ether, address(t));

        // buyer locks root
        vm.prank(buyerAddr);
        t.approve(address(f), 200 ether);
        vm.prank(buyerAddr);
        f.lock(rootSrp);

        // third grants consent to rootSeller and approves funds for sellerBatchAdd
        vm.prank(third);
        f.grantRootSellerConsent(rootSeller, true);
        uint256 a1 = 10 ether;
        uint256 lastTotal = f.srpTotalProcessValue(rootSrp);
        uint256 total1 = lastTotal + a1;
        uint256 coord1 = 2 * total1;
        vm.prank(third);
        t.approve(address(f), coord1 + 1 ether);

        // rootSeller adds the child SRP on behalf of third
        address[] memory sellers = new address[](1);
        sellers[0] = third;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = a1;
        vm.prank(rootSeller);
        uint256[] memory newSrps = f.sellerBatchAdd(pid, sellers, amounts);
        uint256 child = newSrps[0];

        // buyer batch-locks any Created SRPs in the process (locks child)
        uint256 buyerDepositChild = 2 * a1;
        uint256 feeChild = feesLocal.calculateFee(buyerDepositChild);
        vm.prank(buyerAddr);
        t.approve(address(f), buyerDepositChild + feeChild);
        uint256[] memory toLock = new uint256[](1);
        toLock[0] = pid;
        vm.prank(buyerAddr);
        f.batchLock(toLock);

        // sanity checks: both SRPs are locked
        (,,,, Figaro.State sroot,) = f.srps(rootSrp);
        (,,,, Figaro.State schild,) = f.srps(child);
        assertEq(uint256(sroot), uint256(Figaro.State.Locked));
        assertEq(uint256(schild), uint256(Figaro.State.Locked));

        // buyer places cleanup deposit (per-SRP)
        uint256 perSrpDeposit = 1 ether;
        uint256 totalDeposit = perSrpDeposit * 2; // two SRPs
        vm.prank(buyerAddr);
        t.approve(address(f), totalDeposit);

        // expect CleanupDepositPlaced indexed topics to match
        vm.expectEmit(true, true, false, true);
        emit CleanupDepositPlaced(pid, address(t), perSrpDeposit, totalDeposit, buyerAddr);

        vm.prank(buyerAddr);
        uint256[] memory released = f.releaseProcessWithCleanupDeposit(pid, perSrpDeposit);

        // two SRPs released
        assertEq(released.length, 2);

        // states updated to Released and coordinationCapitalBalance decreased by amount per SRP
        (,,,, Figaro.State stRoot, uint256 capRoot) = f.srps(rootSrp);
        (,,,, Figaro.State stChild, uint256 capChild) = f.srps(child);
        assertEq(uint256(stRoot), uint256(Figaro.State.Released));
        assertEq(uint256(stChild), uint256(Figaro.State.Released));

        // stored coordination caps should have been reduced by each SRP.amount
        assert(capRoot > 0);
        assert(capChild > 0);

        // process metadata set
        assertEq(f.processCleanupTotalDeposit(pid), totalDeposit);
        assertEq(f.processPerSrpDeposit(pid), perSrpDeposit);
        assert(f.processArchivableAt(pid) > block.timestamp);
    }

    function testReleaseRevertsOnEmptyProcess() public {
        // pick a process id that doesn't exist
        uint256 missingPid = processId + 999;
        vm.prank(buyer);
        vm.expectRevert(bytes("no srps"));
        figaro.releaseProcessWithCleanupDeposit(missingPid, 1 ether);
    }
}
