// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SRPFees} from "./SRPFees.sol";
import {IMechanism} from "./IMechanism.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";

contract Figaro is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    enum State {
        Created,
        Locked,
        Released,
        Refunded,
        Cancelled
    }

    struct SrpData {
        address seller;
        address buyer;
        uint256 amount;
        address token;
        State state;
        uint256 coordinationCapitalBalance;
        bytes32 srpHash;
    }

    // =============================================================
    //                            EVENTS
    // =============================================================

    /**
     * @notice Emitted when an SRP is created (cryptographically linked into a process chain)
     * @dev Canonical creation event. Off-chain consumers should reconstruct
     * the creation hash (`srpHash`) using the exact field order below so they
     * can validate SRP chain integrity. The contract computes the creation
     * hash as:
     *
     *   creationHash = keccak256(abi.encodePacked(prevHash, seller, buyer, amount, token, totalProcessValue))
     *
     * Responsibilities:
     * - `SrpCreated`: immutable creation linkage emitted only at creation
     *   (create / add / addSrpSigned / sellerBatchAdd flows).
     * - `SrpStateChanged`: lifecycle updates, deltas, and balance snapshots.
     */
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

    /**
     * @notice Emitted when an SRP's state changes; includes a version hash for off-chain auditing
     * @dev Versioning and dedupe guidance:
     * - `versionHash` is computed at each state transition and mirrors contract
     *   usage: versionHash = keccak256(abi.encodePacked(creationHash, uint256(newState), coordinationCapitalBalance))
     * - Indexers should use (srpId, versionHash) as a primary dedupe key to
     *   detect duplicate emissions produced by dual-emission compatibility.
     * - For strict ordering or when dual-emits must be disambiguated, use
     *   (srpId, blockNumber, logIndex) in combination with the versionHash.
     *
     * `principal` is the indexed party most relevant for off-chain queries
     * (either the seller or the buyer depending on the flow).
     */
    event SrpStateChanged(
        uint256 indexed srpId,
        uint256 indexed processId,
        address indexed principal,
        address seller,
        address buyer,
        bytes32 prevCreationHash,
        bytes32 versionHash,
        State fromState,
        State toState,
        int256 delta,
        uint256 coordinationCapitalBalance,
        uint256 totalProcessValue
    );

    /**
     * @notice Emitted when a third party seller approves or revokes consent for a root seller
     */
    event AddSrpConsent(address indexed thirdPartySeller, address indexed rootSeller, bool approved);

    /**
     * @notice Emitted when a buyer places a per-SRP cleanup deposit at release
     */
    event CleanupDepositPlaced(
        uint256 indexed processId,
        address indexed token,
        uint256 perSrpDeposit,
        uint256 processCleanupTotalDeposit,
        address buyer
    );

    /**
     * @notice Emitted when an SRP is archived and storage deleted
     */
    event SrpArchived(
        uint256 indexed processId,
        uint256 indexed srpId,
        address seller,
        address buyer,
        uint256 amount,
        address token,
        uint256 totalProcessValue,
        State state,
        uint256 archivedAt
    );

    /**
     * @notice Emitted when a process is archived and caller is paid from cleanup deposit
     */
    event ProcessArchived(
        uint256 indexed processId, address indexed caller, address token, uint256[] srpIds, uint256 payout
    );

    // =============================================================
    //                            STORAGE
    // =============================================================

    uint256 public srpCount;
    uint256 public processCount;

    SRPFees public srpFees;

    mapping(uint256 => uint256[]) public processSrps;
    mapping(uint256 => SrpData) internal _srps;

    mapping(uint256 => uint256) public srpToProcessId;
    mapping(uint256 => uint256) public processLockedCount;

    // Per-SRP total process value (kept separate to preserve public getter shape)
    mapping(uint256 => uint256) public srpTotalProcessValue;
    // third party seller -> rootSeller -> approved
    mapping(address => mapping(address => bool)) public rootSellerThirdPartyConsent;

    // per-seller replay protection for signed payloads
    mapping(address => uint256) public sellerNonces;

    // Cleanup / archival bookkeeping (minimal subset)
    // Minimum bounty paid to callers who perform process cleanup.
    // Set to `1` (one smallest token unit) so the bounty is non-zero
    // and token-decimals-agnostic (works for any ERC-20 token).
    uint256 public minCleanupBounty = 1;
    // Archive delay is a fixed protocol constant.
    uint256 public constant ARCHIVE_DELAY_SECONDS = 7 days;

    // Maximum number of items processed in any batch loop. Hard limit to
    // ensure loops remain bounded regardless of gas usage across chains.
    uint256 public immutable MAX_BATCH_SIZE;

    mapping(uint256 => uint256) public processCleanupTotalDeposit;
    mapping(uint256 => uint256) public processPerSrpDeposit;
    mapping(uint256 => uint256) public processArchivableAt;

    // =============================================================
    //                           CONSTRUCTOR
    // =============================================================

    constructor(address _srpFees, uint256 _maxBatch) {
        require(_srpFees != address(0), "srpFees required");
        require(_maxBatch > 0, "maxBatch>0");
        srpFees = SRPFees(_srpFees);
        MAX_BATCH_SIZE = _maxBatch;
        srpCount = 1;
        processCount = 1;
    }

    // =============================================================
    //                           EXTERNAL FUNCTIONS
    // =============================================================

    /// @notice Create a new process with a root SRP and collect seller coordination capital + fee
    function createProcess(address buyer, uint256 amount, address token)
        external
        nonReentrant
        returns (uint256 processId, uint256 srpId)
    {
        address seller = msg.sender;
        require(buyer != address(0), "buyer required");
        require(buyer != seller, "seller==buyer");
        require(amount > 0, "amount>0");
        require(token != address(0), "token required");
        // create ids
        processId = processCount++;

        // Effects (CEI): create and register the root SRP with zero balance
        srpId = _createAndRegisterSrp(processId, seller, buyer, amount, token, amount);

        // Probe token behavior: perform a tiny transfer round-trip of 1 unit to
        // detect fee-on-transfer or other non-standard ERC-20 semantics. If the
        // token does not behave as a standard ERC-20, revert with a clear
        // diagnostic. This is a lightweight early-fail to preserve protocol
        // invariants (the contract requires exact transfer amounts).
        {
            IERC20 tokenIfc = IERC20(token);
            uint256 coordinationCapitalProbe = 2 * amount;
            uint256 feeProbe = srpFees.calculateFee(coordinationCapitalProbe);
            uint256 totalProbe = coordinationCapitalProbe + feeProbe;
            uint256 allowance = tokenIfc.allowance(seller, address(this));
            // Only probe when seller has at least 1 token and approved >= totalProbe + 1
            // so consuming 1 unit won't cause later `collect` calls to fail due
            // to allowance reduction.
            if (tokenIfc.balanceOf(seller) >= 1 && allowance >= totalProbe + 1) {
                uint256 preThis = tokenIfc.balanceOf(address(this));
                tokenIfc.safeTransferFrom(seller, address(this), 1);
                uint256 postThis = tokenIfc.balanceOf(address(this));
                uint256 actual = postThis - preThis;
                // deliberate equality check: this probe requires exact 1 unit to
                // detect fee-on-transfer/nonstandard ERC-20 tokens. Slither flags
                // strict equality here but this is an intentional protocol
                // invariant. Silence the detector on this line.
                // slither-disable-next-line incorrect-equality
                require(actual == 1, "token not supported: fee-on-transfer or nonstandard ERC20");
                // return the probe amount to the seller to avoid leaving dust
                if (actual > 0) {
                    tokenIfc.safeTransfer(seller, actual);
                }
            }
        }

        // Interactions: collect seller coordination capital + fee and record
        uint256 coordinationCapital = 2 * amount;
        _collectAndSetCoordination(srpId, token, seller, coordinationCapital);

        // Finalize: compute and emit creation events
        _finalizeSrpCreation(srpId, processId, 0, seller, buyer, token, amount, coordinationCapital);

        return (processId, srpId);
    }

    /// @notice Lock the root SRP: buyer deposits coordination capital + fee
    function lock(uint256 srpId) external nonReentrant {
        _onlyBuyer(srpId);
        _onlyInState(srpId, State.Created);

        uint256 buyerDeposit = 2 * _srps[srpId].amount;
        address token = _srps[srpId].token;
        uint256 feeAmount = srpFees.calculateFee(buyerDeposit);

        // Effects (CEI): update state and counters first
        State oldState = _srps[srpId].state;
        _srps[srpId].state = State.Locked;
        uint256 processId = srpToProcessId[srpId];
        processLockedCount[processId]++;

        // Interactions: collect fee -> treasury, and coordination capital -> contract
        _collectFeeAndCapital(token, msg.sender, buyerDeposit);

        // record deposited capital
        _srps[srpId].coordinationCapitalBalance += buyerDeposit;

        // Emit SrpStateChanged for Locked state (dual emission)
        bytes32 lockVersion = keccak256(
            abi.encodePacked(_srps[srpId].srpHash, uint256(State.Locked), _srps[srpId].coordinationCapitalBalance)
        );
        // principal = buyer for Lock (buyer-centric)
        emit SrpStateChanged(
            srpId,
            processId,
            _srps[srpId].buyer,
            _srps[srpId].seller,
            _srps[srpId].buyer,
            _srps[srpId].srpHash,
            lockVersion,
            oldState,
            State.Locked,
            int256(buyerDeposit),
            _srps[srpId].coordinationCapitalBalance,
            srpTotalProcessValue[srpId]
        );
    }

    /// @notice Release a process and place buyer-funded per-SRP cleanup deposits
    /// @dev Buyer pays `perSrpDeposit * srpCount` to this contract; each SRP is
    /// tagged with an archivable timestamp. This is a minimal port of the
    /// UnifiedSRP flow for cleanup deposits.
    function releaseProcessWithCleanupDeposit(uint256 processId, uint256 perSrpDeposit)
        external
        nonReentrant
        returns (uint256[] memory releasedSrps)
    {
        uint256[] storage srpIds = processSrps[processId];
        require(srpIds.length > 0, "no srps");

        // Only root buyer may call: buyer of the first/root SRP
        uint256 rootSrpId = srpIds[0];
        require(msg.sender == _srps[rootSrpId].buyer, "only root buyer");

        // Require deposit minimum
        require(perSrpDeposit >= minCleanupBounty, "deposit below minimum");

        // Validate and compute token, count and total deposit
        (address token, uint256 n, uint256 totalDeposit) = _validateAndComputeReleaseDeposit(processId, perSrpDeposit);

        // Perform release state transitions first (CEI): mark SRPs Released
        releasedSrps = new uint256[](n);
        uint256 totalBuyerRefund = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 srpId = srpIds[i];
            uint256 buyerRefund = _applyReleaseToSrp(processId, srpId);
            totalBuyerRefund += buyerRefund;
            releasedSrps[i] = srpId;
        }

        // Interactions & process bookkeeping
        _settleReleaseInteractions(processId, token, totalDeposit, totalBuyerRefund, perSrpDeposit);

        return releasedSrps;
    }

    /// @notice Release multiple processes in a single transaction and place per-SRP cleanup deposits
    /// @dev Buyer (root buyer of each process) calls this to release all SRPs in each process.
    /// Aggregates buyer refunds and collection of cleanup deposits into a single interaction
    /// for gas efficiency while preserving per-process archival bookkeeping.
    function batchRelease(uint256[] calldata processIds, uint256 perSrpDeposit)
        external
        nonReentrant
        returns (uint256 totalReleasedSrps)
    {
        require(processIds.length > 0, "empty batch");
        _requireBatchSize(processIds.length);

        // First pass: validate processes, ensure caller is root buyer for each,
        // tokens match across processes, and compute total SRPs and total deposit.
        address token = address(0);
        uint256 totalDeposit = 0;
        uint256 totalSrps = 0;

        for (uint256 i = 0; i < processIds.length; i++) {
            uint256 pid = processIds[i];
            uint256[] storage srpIds = processSrps[pid];
            require(srpIds.length > 0, "no srps");

            uint256 rootSrpId = srpIds[0];
            require(msg.sender == _srps[rootSrpId].buyer, "only root buyer");

            if (token == address(0)) {
                token = _srps[rootSrpId].token;
            } else {
                require(_srps[rootSrpId].token == token, "tokens must match");
            }

            uint256 n = srpIds.length;
            totalSrps += n;

            // guard against overflow and enforce minimum per-srp deposit
            require(perSrpDeposit >= minCleanupBounty, "deposit below minimum");
            uint256 procDeposit = perSrpDeposit * n;
            if (n != 0 && perSrpDeposit != 0 && procDeposit / n != perSrpDeposit) {
                revert("deposit overflow");
            }
            totalDeposit += procDeposit;
        }

        require(totalSrps > 0, "empty batch");
        _requireBatchSize(totalSrps);

        // Second pass: apply CEI release to every SRP across processes and
        // record per-process metadata. Aggregate total buyer refund.
        uint256 totalBuyerRefund = 0;
        for (uint256 i = 0; i < processIds.length; i++) {
            uint256 pid = processIds[i];
            uint256[] storage srpIds = processSrps[pid];
            uint256 n = srpIds.length;

            for (uint256 j = 0; j < n; j++) {
                uint256 srpId = srpIds[j];
                uint256 buyerRefund = _applyReleaseToSrp(pid, srpId);
                totalBuyerRefund += buyerRefund;
                totalReleasedSrps++;
            }

            // record process-level metadata (archival bookkeeping)
            processCleanupTotalDeposit[pid] = perSrpDeposit * n;
            processPerSrpDeposit[pid] = perSrpDeposit;
            processArchivableAt[pid] = block.timestamp + ARCHIVE_DELAY_SECONDS;

            emit CleanupDepositPlaced(pid, token, perSrpDeposit, processCleanupTotalDeposit[pid], msg.sender);
        }

        // Interactions: perform aggregated transfers once for efficiency
        if (totalBuyerRefund > 0) {
            IERC20(token).safeTransfer(msg.sender, totalBuyerRefund);
        }

        if (totalDeposit > 0) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), totalDeposit);
        }

        return totalReleasedSrps;
    }

    /// @notice Refund SRP - seller withdraws coordination capital + payment after buyer release
    /// @dev Only callable by the SRP seller when SRP is in Released state.
    function refund(uint256 srpId) external nonReentrant {
        // Access control
        _onlySeller(srpId);
        require(_srps[srpId].state == State.Released, "InvalidState");

        uint256 processId = srpToProcessId[srpId];
        State oldState = _srps[srpId].state;

        // Effects: mark as Refunded and clear stored deposited capital
        uint256 refundedAmount = _srps[srpId].coordinationCapitalBalance;
        _srps[srpId].state = State.Refunded;
        _srps[srpId].coordinationCapitalBalance = 0;

        // Interactions: transfer refund to seller
        if (refundedAmount > 0) {
            IERC20(_srps[srpId].token).safeTransfer(msg.sender, refundedAmount);
        }

        // Emit SrpStateChanged for Refunded state (dual emission)
        bytes32 refundVersion = keccak256(
            abi.encodePacked(_srps[srpId].srpHash, uint256(State.Refunded), _srps[srpId].coordinationCapitalBalance)
        );
        // principal = seller for Refund (seller-centric)
        emit SrpStateChanged(
            srpId,
            processId,
            _srps[srpId].seller,
            _srps[srpId].seller,
            _srps[srpId].buyer,
            _srps[srpId].srpHash,
            refundVersion,
            oldState,
            State.Refunded,
            -int256(refundedAmount),
            _srps[srpId].coordinationCapitalBalance,
            srpTotalProcessValue[srpId]
        );
    }

    /// @notice Refund multiple SRPs to their seller in a single transaction
    /// @dev Sellers call this to withdraw coordination capital for many SRPs.
    /// Performs a two-pass approach: validate and aggregate per-token totals,
    /// apply CEI state changes, then perform aggregated token transfers,
    /// and finally emit per-SRP `SrpStateChanged` events.
    function batchRefund(uint256[] calldata srpIds) external nonReentrant returns (uint256 totalRefunded) {
        require(srpIds.length > 0, "empty batch");
        _requireBatchSize(srpIds.length);

        // First pass: validate caller is seller for each SRP, state is Released,
        // and aggregate totals per token (naive O(n^2) unique-token accumulation,
        // acceptable due to MAX_BATCH_SIZE cap).
        address[] memory tokens = new address[](srpIds.length);
        uint256[] memory amounts = new uint256[](srpIds.length);
        uint256 unique = 0;

        for (uint256 i = 0; i < srpIds.length; i++) {
            uint256 srpId = srpIds[i];
            require(_srps[srpId].seller == msg.sender, "OnlySeller");
            require(_srps[srpId].state == State.Released, "InvalidState");

            address token = _srps[srpId].token;
            uint256 bal = _srps[srpId].coordinationCapitalBalance;

            bool found = false;
            for (uint256 j = 0; j < unique; j++) {
                if (tokens[j] == token) {
                    amounts[j] += bal;
                    found = true;
                    break;
                }
            }
            if (!found) {
                tokens[unique] = token;
                amounts[unique] = bal;
                unique++;
            }
        }

        // Effects (CEI): mark SRPs as Refunded and zero their stored balance
        // while collecting per-SRP data for event emission.
        uint256[] memory refundedAmounts = new uint256[](srpIds.length);
        for (uint256 i = 0; i < srpIds.length; i++) {
            uint256 srpId = srpIds[i];
            uint256 refunded = _srps[srpId].coordinationCapitalBalance;
            refundedAmounts[i] = refunded;

            _srps[srpId].state = State.Refunded;
            _srps[srpId].coordinationCapitalBalance = 0;
            totalRefunded += refunded;
        }

        // Interactions: perform aggregated transfers per token
        for (uint256 i = 0; i < unique; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            IERC20(tokens[i]).safeTransfer(msg.sender, amt);
        }

        // Emit per-SRP SrpStateChanged events mirroring single-`refund` shape
        for (uint256 i = 0; i < srpIds.length; i++) {
            uint256 srpId = srpIds[i];
            bytes32 refundVersion = keccak256(
                abi.encodePacked(_srps[srpId].srpHash, uint256(State.Refunded), _srps[srpId].coordinationCapitalBalance)
            );
            emit SrpStateChanged(
                srpId,
                srpToProcessId[srpId],
                _srps[srpId].seller,
                _srps[srpId].seller,
                _srps[srpId].buyer,
                _srps[srpId].srpHash,
                refundVersion,
                State.Released,
                State.Refunded,
                -int256(refundedAmounts[i]),
                _srps[srpId].coordinationCapitalBalance,
                srpTotalProcessValue[srpId]
            );
        }

        return totalRefunded;
    }

    /// @notice Cancel multiple SRPs in a single transaction and return coordination capital to sellers
    /// @dev Sellers call this to cancel many SRPs in `Created` state. Uses a two-pass
    /// approach: validate and aggregate per-token totals, apply CEI state changes,
    /// perform aggregated token transfers, and emit per-SRP `SrpStateChanged` events.
    function batchCancel(uint256[] calldata srpIds) external nonReentrant returns (uint256 totalCancelled) {
        require(srpIds.length > 0, "empty batch");
        _requireBatchSize(srpIds.length);

        // First pass: validate caller is seller for each SRP, state is Created,
        // and aggregate totals per token.
        address[] memory tokens = new address[](srpIds.length);
        uint256[] memory amounts = new uint256[](srpIds.length);
        uint256 unique = 0;

        for (uint256 i = 0; i < srpIds.length; i++) {
            uint256 srpId = srpIds[i];
            require(_srps[srpId].seller == msg.sender, "OnlySeller");
            require(_srps[srpId].state == State.Created, "InvalidState");

            address token = _srps[srpId].token;
            uint256 bal = _srps[srpId].coordinationCapitalBalance;

            bool found = false;
            for (uint256 j = 0; j < unique; j++) {
                if (tokens[j] == token) {
                    amounts[j] += bal;
                    found = true;
                    break;
                }
            }
            if (!found) {
                tokens[unique] = token;
                amounts[unique] = bal;
                unique++;
            }
        }

        // Effects (CEI): mark SRPs as Cancelled and zero their stored balance
        // while collecting per-SRP data for event emission.
        uint256[] memory cancelledAmounts = new uint256[](srpIds.length);
        for (uint256 i = 0; i < srpIds.length; i++) {
            uint256 srpId = srpIds[i];
            uint256 cancelled = _srps[srpId].coordinationCapitalBalance;
            cancelledAmounts[i] = cancelled;

            _srps[srpId].state = State.Cancelled;
            _srps[srpId].coordinationCapitalBalance = 0;
            totalCancelled += cancelled;
        }

        // Interactions: perform aggregated transfers per token
        for (uint256 i = 0; i < unique; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            IERC20(tokens[i]).safeTransfer(msg.sender, amt);
        }

        // Emit per-SRP SrpStateChanged events mirroring single-`cancel` shape
        for (uint256 i = 0; i < srpIds.length; i++) {
            uint256 srpId = srpIds[i];
            bytes32 cancelVersion = keccak256(
                abi.encodePacked(
                    _srps[srpId].srpHash, uint256(State.Cancelled), _srps[srpId].coordinationCapitalBalance
                )
            );
            emit SrpStateChanged(
                srpId,
                srpToProcessId[srpId],
                _srps[srpId].seller,
                _srps[srpId].seller,
                _srps[srpId].buyer,
                _srps[srpId].srpHash,
                cancelVersion,
                State.Created,
                State.Cancelled,
                -int256(cancelledAmounts[i]),
                _srps[srpId].coordinationCapitalBalance,
                srpTotalProcessValue[srpId]
            );
        }

        return totalCancelled;
    }

    /// @notice Cancel SRP - seller withdraws deposit before buyer locks (abort trade)
    /// @dev Only callable by the SRP seller when SRP is in Created state.
    function cancel(uint256 srpId) external nonReentrant {
        // Access control
        _onlySeller(srpId);
        require(_srps[srpId].state == State.Created, "InvalidState");

        uint256 processId = srpToProcessId[srpId];
        State oldState = _srps[srpId].state;

        uint256 cancelledAmount = _srps[srpId].coordinationCapitalBalance;
        require(cancelledAmount > 0, "ZeroCancelAmount");

        // Effects: mark as Cancelled and clear stored deposited capital
        _srps[srpId].state = State.Cancelled;
        _srps[srpId].coordinationCapitalBalance = 0;

        // Interactions: return coordination capital to seller
        if (cancelledAmount > 0) {
            IERC20(_srps[srpId].token).safeTransfer(msg.sender, cancelledAmount);
        }

        // Emit SrpStateChanged for Cancelled state (dual emission)
        bytes32 cancelVersion = keccak256(
            abi.encodePacked(_srps[srpId].srpHash, uint256(State.Cancelled), _srps[srpId].coordinationCapitalBalance)
        );
        // principal = seller for Cancel (seller-centric)
        emit SrpStateChanged(
            srpId,
            processId,
            _srps[srpId].seller,
            _srps[srpId].seller,
            _srps[srpId].buyer,
            _srps[srpId].srpHash,
            cancelVersion,
            oldState,
            State.Cancelled,
            -int256(cancelledAmount),
            _srps[srpId].coordinationCapitalBalance,
            srpTotalProcessValue[srpId]
        );
    }

    /// @notice Add a new SRP to an existing process (root-seller only)
    /// @dev Root seller adds a value-added SRP to a process whose root SRP is locked.
    ///
    /// Requirements:
    /// - Caller must be the root seller for `processId`.
    /// - The root SRP must already be `Locked`.
    /// - Third party seller must not be the process buyer or the root seller.
    /// - Third party seller must have approved the root seller.
    ///
    /// On success this function creates a new SRP, collects the third party seller's
    /// coordination capital and protocol fee, and emits `SrpAdded`.
    function addSrpToProcess(uint256 processId, address thirdPartySeller, uint256 amount)
        external
        nonReentrant
        returns (uint256 srpId)
    {
        // basic validations
        require(amount > 0, "amount>0");
        require(thirdPartySeller != address(0), "thirdPartySeller required");

        (
            uint256 rootSrpId,
            address rootBuyer,
            address rootSeller,
            address token,
            uint256 lastSrpId,
            uint256 previousTotal
        ) = _requireRootSellerAndLocked(processId);

        // Ensure we do not exceed per-process capacity when adding a child
        _requireProcessCapacity(processId, 1);

        _requireThirdPartyConsent(thirdPartySeller, rootSeller, rootBuyer);

        // compute progressive coordination capital
        uint256 totalValue = previousTotal + amount;
        uint256 coordinationCapital = _computeCoordinationCapital(totalValue);

        // Effects: create SRP and register to process
        srpId = _createAndRegisterSrp(processId, thirdPartySeller, rootBuyer, amount, token, totalValue);

        // Interactions: collect third party seller coordination capital + fee and record
        _collectAndSetCoordination(srpId, token, thirdPartySeller, coordinationCapital);

        // compute and emit linked hash and state-change for child SRP
        _finalizeSrpCreation(
            srpId, processId, lastSrpId, thirdPartySeller, rootBuyer, token, totalValue, coordinationCapital
        );
    }

    /// @notice Seller-side batch SRP addition: create SRPs and collect coordination capital
    /// @dev Root seller calls to add multiple SRPs in one atomic transaction.
    function sellerBatchAdd(uint256 processId, address[] calldata sellers, uint256[] calldata amounts)
        external
        nonReentrant
        returns (uint256[] memory srpIds)
    {
        uint256 n = sellers.length;
        require(n > 0, "empty batch");
        _requireBatchSize(n);
        require(n == amounts.length, "length mismatch");

        (
            uint256 rootSrpId,
            address rootBuyer,
            address rootSeller,
            address token,
            uint256 lastSrpId,
            uint256 previousTotal
        ) = _requireRootSellerAndLocked(processId);

        // Ensure adding `n` SRPs won't overflow the per-process capacity
        _requireProcessCapacity(processId, n);

        srpIds = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address seller = sellers[i];
            uint256 amount = amounts[i];
            require(amount > 0, "amount>0");

            _requireThirdPartyConsent(seller, rootSeller, rootBuyer);

            uint256 totalValue = previousTotal + amount;
            uint256 coordinationCapital = _computeCoordinationCapital(totalValue);

            // Effects: create SRP and register to process
            uint256 srpId = _createAndRegisterSrp(processId, seller, rootBuyer, amount, token, totalValue);

            // Interactions: collect seller coordination capital + fee and record
            _collectAndSetCoordination(srpId, token, seller, coordinationCapital);

            // compute and emit linked hash and state-change for this new SRP; link to previous
            _finalizeSrpCreation(srpId, processId, lastSrpId, seller, rootBuyer, token, totalValue, coordinationCapital);

            srpIds[i] = srpId;
            previousTotal = totalValue;
        }
    }

    /// @notice Create multiple processes each with a root SRP in a single transaction
    /// @dev Seller (`msg.sender`) creates multiple processes and pays coordination capital + fee per SRP.
    /// Uses CEI ordering: create storage entries first, then collect funds per-SRP.
    function batchCreateProcesses(address[] calldata buyers, uint256[] calldata amounts, address[] calldata tokens)
        external
        nonReentrant
        returns (uint256[] memory processIds, uint256[] memory srpIds)
    {
        uint256 n = buyers.length;
        require(n > 0, "empty batch");
        _requireBatchSize(n);
        require(amounts.length == n && tokens.length == n, "length mismatch");

        processIds = new uint256[](n);
        srpIds = new uint256[](n);

        // First pass: basic input validation
        for (uint256 i = 0; i < n; i++) {
            address buyer = buyers[i];
            require(buyer != address(0), "buyer required");
            require(buyer != msg.sender, "seller==buyer");
            uint256 amount = amounts[i];
            require(amount > 0, "amount>0");
            address token = tokens[i];
            require(token != address(0), "token required");
        }

        // Second pass: create processes and root SRPs (Effects/CEI)
        for (uint256 i = 0; i < n; i++) {
            uint256 processId = processCount++;
            processIds[i] = processId;

            // create root SRP with zero coordination balance
            uint256 srpId = _createAndRegisterSrp(processId, msg.sender, buyers[i], amounts[i], tokens[i], amounts[i]);
            srpIds[i] = srpId;

            // Emit creation events for this root SRP (coordinationCapital not yet collected)
            uint256 coordinationCapital = 2 * amounts[i];
            _finalizeSrpCreation(srpId, processId, 0, msg.sender, buyers[i], tokens[i], amounts[i], coordinationCapital);
        }

        // Interactions: collect coordination capital + fee for each SRP from the seller
        for (uint256 i = 0; i < n; i++) {
            uint256 srpId = srpIds[i];
            uint256 coordinationCapital = 2 * _srps[srpId].amount;
            _collectAndSetCoordination(srpId, _srps[srpId].token, msg.sender, coordinationCapital);
        }

        return (processIds, srpIds);
    }

    // Internal helper: create and register SRP struct and minimal bookkeeping
    function _createAndRegisterSrp(
        uint256 processId,
        address seller,
        address buyer,
        uint256 amount,
        address token,
        uint256 totalValue
    ) internal returns (uint256 srpId) {
        srpId = srpCount++;
        _srps[srpId] = SrpData({
            seller: seller,
            buyer: buyer,
            amount: amount,
            token: token,
            state: State.Created,
            coordinationCapitalBalance: 0,
            srpHash: bytes32(0)
        });
        srpTotalProcessValue[srpId] = totalValue;
        srpToProcessId[srpId] = processId;
        processSrps[processId].push(srpId);
    }

    // Internal helper: collect coordination capital + fee and update stored balance
    function _collectAndSetCoordination(uint256 srpId, address token, address payer, uint256 coordinationCapital)
        internal
        returns (uint256)
    {
        uint256 feeAmount = _collectFeeAndCapital(token, payer, coordinationCapital);
        _srps[srpId].coordinationCapitalBalance = coordinationCapital;
        return feeAmount;
    }

    // Internal helper: compute and emit creation events + state-change for SRP
    function _finalizeSrpCreation(
        uint256 srpId,
        uint256 processId,
        uint256 prevLastSrpId,
        address seller,
        address buyer,
        address token,
        uint256 totalValue,
        uint256 coordinationCapital
    ) internal {
        bytes32 prevHash = _srps[prevLastSrpId].srpHash;
        bytes32 creationHash =
            keccak256(abi.encodePacked(prevHash, seller, buyer, _srps[srpId].amount, token, totalValue));
        _srps[srpId].srpHash = creationHash;
        emit SrpCreated(srpId, processId, creationHash, prevLastSrpId, prevHash, seller, buyer, token, totalValue);

        bytes32 creationVersion =
            keccak256(abi.encodePacked(creationHash, uint256(State.Created), _srps[srpId].coordinationCapitalBalance));
        emit SrpStateChanged(
            srpId,
            processId,
            seller,
            seller,
            buyer,
            prevHash,
            creationVersion,
            State.Created,
            State.Created,
            int256(coordinationCapital),
            _srps[srpId].coordinationCapitalBalance,
            srpTotalProcessValue[srpId]
        );
    }

    /// @notice Add a single SRP authorized by an off-chain seller signature
    /// @dev Uses split helpers to avoid large stack frames. Supports optional
    /// ERC-2612-style `permit` calldata via `erc2612Permit`.
    ///
    /// NOTE: Static analysis (Slither `reentrancy-no-eth`) flags an external
    /// token call prior to a state write. This is an intentional design:
    /// - The function follows CEI ordering where effects are applied before
    ///   external token interactions when possible and uses a 1-unit token
    ///   probe elsewhere to detect fee-on-transfer tokens.
    /// - A runtime `nonReentrant` guard (OpenZeppelin ReentrancyGuard) protects
    ///   this function against nested reentrancy. Tests assert this behavior:
    ///   `test/ReentrancyRecorder.t.sol` and `test/ReentrancyPermit.t.sol` both
    ///   exercise a token-callback reentrancy attempt and observe the
    ///   `ReentrancyGuardReentrantCall()` revert.
    // slither-disable-next-line reentrancy-no-eth
    function addSrpSigned(IMechanism.AddSrpPayload calldata p, bytes calldata sellerSig, bytes calldata erc2612Permit)
        external
        nonReentrant
        returns (uint256 srpId)
    {
        require(p.amount > 0, "amount>0");
        require(block.timestamp <= p.deadline, "expired");

        // Ensure adding this signed SRP won't overflow the per-process capacity
        _requireProcessCapacity(p.processId, 1);

        (address token, address rootBuyer,, uint256 computedTotal) =
            _computeAndValidateContext(p.processId, p.seller, p.amount);

        // verify signature and consume nonce (delegated to helper)
        bool ok = verifyAddSrpPayload(p, address(this), sellerSig);
        require(ok, "invalid signature");
        _consumeSellerNonce(p.seller, p.nonce);

        // compute payment amounts
        uint256 coordinationCapital = 2 * computedTotal;
        uint256 feeAmount = srpFees.calculateFee(coordinationCapital);
        uint256 total = coordinationCapital + feeAmount;
        // Effects (CEI first): register SRP with zero balance
        uint256 prevLastSrpId = processSrps[p.processId][processSrps[p.processId].length - 1];
        srpId = _createAndRegisterSrp(p.processId, p.seller, rootBuyer, p.amount, token, computedTotal);

        // Finalize creation and emit events (reuses existing helper)
        _finalizeSrpCreation(
            srpId, p.processId, prevLastSrpId, p.seller, rootBuyer, token, computedTotal, coordinationCapital
        );
        // Interactions: call permit if provided, then collect fee and coordination capital
        // (effects were already applied above to minimize reentrancy window)
        callPermitIfPresent(token, p.seller, address(this), erc2612Permit);
        _collectAndSetCoordination(srpId, token, p.seller, coordinationCapital);

        return srpId;
    }

    /// @notice Add multiple signed SRPs in a single atomic transaction
    /// @dev Batch variant of `addSrpSigned`. Verifies each payload signature,
    /// consumes nonces, creates SRPs and collects coordination capital per SRP.
    /// Performs upfront capacity checks per-process to ensure atomicity.
    function addSrpSignedBatch(
        IMechanism.AddSrpPayload[] calldata payloads,
        bytes[] calldata sellerSigs,
        bytes[] calldata erc2612Permits
    ) external nonReentrant returns (uint256[] memory srpIds) {
        uint256 n = payloads.length;
        require(n > 0, "empty batch");
        _requireBatchSize(n);
        require(sellerSigs.length == n, "length mismatch sigs");
        require(erc2612Permits.length == n, "length mismatch permits");

        // First pass: validate basic payload invariants and count per-process additions
        uint256[] memory pids = new uint256[](n);
        uint256[] memory counts = new uint256[](n);
        uint256 unique = 0;
        for (uint256 i = 0; i < n; i++) {
            IMechanism.AddSrpPayload calldata p = payloads[i];
            require(p.amount > 0, "amount>0");
            require(block.timestamp <= p.deadline, "expired");

            // count occurrences of p.processId
            uint256 pid = p.processId;
            bool found = false;
            for (uint256 j = 0; j < unique; j++) {
                if (pids[j] == pid) {
                    counts[j]++;
                    found = true;
                    break;
                }
            }
            if (!found) {
                pids[unique] = pid;
                counts[unique] = 1;
                unique++;
            }
        }

        // Per-process capacity checks
        for (uint256 i = 0; i < unique; i++) {
            _requireProcessCapacity(pids[i], counts[i]);
        }

        // Second pass: process each payload (verify, consume nonce, create, collect)
        srpIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IMechanism.AddSrpPayload calldata p = payloads[i];

            (address token, address rootBuyer,, uint256 computedTotal) =
                _computeAndValidateContext(p.processId, p.seller, p.amount);

            // verify signature and consume nonce
            bool ok = verifyAddSrpPayload(p, address(this), sellerSigs[i]);
            require(ok, "invalid signature");
            _consumeSellerNonce(p.seller, p.nonce);

            uint256 coordinationCapital = 2 * computedTotal;

            uint256 prevLastSrpId = processSrps[p.processId][processSrps[p.processId].length - 1];

            uint256 srpId = _createAndRegisterSrp(p.processId, p.seller, rootBuyer, p.amount, token, computedTotal);

            _finalizeSrpCreation(
                srpId, p.processId, prevLastSrpId, p.seller, rootBuyer, token, computedTotal, coordinationCapital
            );

            // permit if present, then collect coordination capital + fee
            callPermitIfPresent(token, p.seller, address(this), erc2612Permits[i]);
            _collectAndSetCoordination(srpId, token, p.seller, coordinationCapital);

            srpIds[i] = srpId;
        }
    }

    /// @notice Lock all CREATED (non-root) SRPs across multiple processes in a single transaction
    /// @dev Buyer action. For each provided `processId` the root SRP MUST already be `Locked`.
    /// The call will collect and lock every SRP in `State.Created` within each process
    /// except the root SRP (index 0). All checks are performed first and the pull
    /// of the aggregated coordination capital + fee is done once for gas efficiency.
    /// Accepts an array of `processIds` and will lock all qualifying SRPs in those processes.
    function batchLock(uint256[] calldata processIds) external nonReentrant {
        // Collect SRPs to lock and compute total coordination capital; validates inputs
        (uint256[] memory srpIdsToLock, uint256 totalCoordinationCapital, address token) =
            _collectSrpsToLock(processIds);

        // Effects: lock all selected SRPs (CEI)
        for (uint256 i = 0; i < srpIdsToLock.length; i++) {
            _lockSrpInternal(srpIdsToLock[i]);
        }

        // Interactions: pull aggregated coordination capital + fee
        _collectFeeAndCapital(token, msg.sender, totalCoordinationCapital);

        // Effects-after-success: record buyer-side deposited capital in each SRP
        _recordBuyerDepositsForLockedSrps(srpIdsToLock);

        // Emit per-SRP events for all locked SRPs
        _emitLockedEvents(srpIdsToLock);
    }

    // Internal helper: gather SRP ids eligible for batchLock and compute totals
    function _collectSrpsToLock(uint256[] calldata processIds)
        internal
        view
        returns (uint256[] memory srpIdsToLock, uint256 totalCoordinationCapital, address token)
    {
        require(processIds.length > 0, "empty batch");
        _requireBatchSize(processIds.length);

        // derive buyer and token from the first process' root SRP
        uint256[] storage firstChain = processSrps[processIds[0]];
        require(firstChain.length > 0, "process missing");
        uint256 firstRoot = firstChain[0];
        address buyer = _srps[firstRoot].buyer;
        require(msg.sender == buyer, "OnlyBuyer");

        token = _srps[firstRoot].token;

        // First pass: ensure each process root is Locked and count child SRPs in Created state
        uint256 totalToLock = 0;
        for (uint256 i = 0; i < processIds.length; i++) {
            uint256 pid = processIds[i];
            uint256[] storage chain = processSrps[pid];
            require(chain.length > 0, "process missing");
            // require root SRP to be Locked for this process
            uint256 rootSrpId = chain[0];
            require(_srps[rootSrpId].state == State.Locked, "root not locked");
            // iterate children (skip index 0)
            for (uint256 j = 1; j < chain.length; j++) {
                uint256 srpId = chain[j];
                if (_srps[srpId].state == State.Created) {
                    if (_srps[srpId].buyer != buyer) revert("OnlyBuyer");
                    if (_srps[srpId].token != token) {
                        revert("tokens must match");
                    }
                    totalToLock++;
                }
            }
        }

        require(totalToLock > 0, "empty batch");
        _requireBatchSize(totalToLock);

        // Collect SRP ids to lock and compute total coordination capital
        srpIdsToLock = new uint256[](totalToLock);
        uint256 idx = 0;
        for (uint256 i = 0; i < processIds.length; i++) {
            uint256 pid = processIds[i];
            uint256[] storage chain = processSrps[pid];
            for (uint256 j = 1; j < chain.length; j++) {
                uint256 srpId = chain[j];
                if (_srps[srpId].state == State.Created) {
                    srpIdsToLock[idx++] = srpId;
                    totalCoordinationCapital += 2 * _srps[srpId].amount;
                }
            }
        }
    }

    // Internal helper: record deposited capital for each locked SRP
    function _recordBuyerDepositsForLockedSrps(uint256[] memory srpIdsToLock) internal {
        for (uint256 i = 0; i < srpIdsToLock.length; i++) {
            uint256 srpId = srpIdsToLock[i];
            _srps[srpId].coordinationCapitalBalance += 2 * _srps[srpId].amount;
        }
    }

    // Internal helper: emit SrpStateChanged for all locked SRPs
    function _emitLockedEvents(uint256[] memory srpIdsToLock) internal {
        for (uint256 i = 0; i < srpIdsToLock.length; i++) {
            uint256 srpId = srpIdsToLock[i];
            uint256 buyerDeposit = 2 * _srps[srpId].amount;

            bytes32 lockVersion = keccak256(
                abi.encodePacked(_srps[srpId].srpHash, uint256(State.Locked), _srps[srpId].coordinationCapitalBalance)
            );

            emit SrpStateChanged(
                srpId,
                srpToProcessId[srpId],
                _srps[srpId].buyer,
                _srps[srpId].seller,
                _srps[srpId].buyer,
                _srps[srpId].srpHash,
                lockVersion,
                State.Created,
                State.Locked,
                int256(buyerDeposit),
                _srps[srpId].coordinationCapitalBalance,
                srpTotalProcessValue[srpId]
            );
        }
    }

    /// @notice Lock root SRPs for multiple processes in a single transaction
    /// @dev Buyer of each root SRP calls this with `processIds`. Allows mixed tokens
    /// by aggregating per-token totals then performing per-token pulls.
    function batchLockRoots(uint256[] calldata processIds) external nonReentrant returns (uint256 totalLocked) {
        require(processIds.length > 0, "empty batch");
        _requireBatchSize(processIds.length);

        // Aggregate per-token totals (naive O(n^2) unique-token accumulation)
        address[] memory tokens = new address[](processIds.length);
        uint256[] memory amounts = new uint256[](processIds.length);
        uint256 unique = 0;

        // First pass: validate caller is buyer of each root SRP and state is Created
        for (uint256 i = 0; i < processIds.length; i++) {
            uint256 pid = processIds[i];
            uint256[] storage chain = processSrps[pid];
            require(chain.length > 0, "process missing");

            uint256 rootSrpId = chain[0];
            require(msg.sender == _srps[rootSrpId].buyer, "OnlyBuyer");
            require(_srps[rootSrpId].state == State.Created, "InvalidState");

            address token = _srps[rootSrpId].token;
            uint256 coord = 2 * _srps[rootSrpId].amount;

            bool found = false;
            for (uint256 j = 0; j < unique; j++) {
                if (tokens[j] == token) {
                    amounts[j] += coord;
                    found = true;
                    break;
                }
            }
            if (!found) {
                tokens[unique] = token;
                amounts[unique] = coord;
                unique++;
            }
        }

        require(unique > 0, "empty batch");

        // Effects (CEI): mark each root SRP Locked and increment process counters
        uint256[] memory roots = new uint256[](processIds.length);
        uint256 idx = 0;
        for (uint256 i = 0; i < processIds.length; i++) {
            uint256 pid = processIds[i];
            uint256 rootSrpId = processSrps[pid][0];
            _srps[rootSrpId].state = State.Locked;
            processLockedCount[pid]++;
            roots[idx++] = rootSrpId;
            totalLocked++;
        }

        // Interactions: perform aggregated pulls per token
        for (uint256 i = 0; i < unique; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            _collectFeeAndCapital(tokens[i], msg.sender, amt);
        }

        // Effects-after-success: record buyer-side deposited capital for each root
        for (uint256 i = 0; i < roots.length; i++) {
            uint256 srpId = roots[i];
            if (srpId == 0) continue;
            uint256 buyerDeposit = 2 * _srps[srpId].amount;
            _srps[srpId].coordinationCapitalBalance += buyerDeposit;
        }

        // Emit per-SRP SrpStateChanged events mirroring single-`lock` shape
        for (uint256 i = 0; i < roots.length; i++) {
            uint256 srpId = roots[i];
            if (srpId == 0) continue;

            bytes32 lockVersion = keccak256(
                abi.encodePacked(_srps[srpId].srpHash, uint256(State.Locked), _srps[srpId].coordinationCapitalBalance)
            );

            uint256 buyerDeposit = 2 * _srps[srpId].amount;
            emit SrpStateChanged(
                srpId,
                srpToProcessId[srpId],
                _srps[srpId].buyer,
                _srps[srpId].seller,
                _srps[srpId].buyer,
                _srps[srpId].srpHash,
                lockVersion,
                State.Created,
                State.Locked,
                int256(buyerDeposit),
                _srps[srpId].coordinationCapitalBalance,
                srpTotalProcessValue[srpId]
            );
        }

        return totalLocked;
    }

    /// @notice Archive completed process SRPs that have buyer-funded deposits and pay caller
    /// @dev Permissionless: requires each SRP.archivableAt != 0 and <= block.timestamp
    function archiveProcessSrpsWithDeposit(uint256 processId) external nonReentrant returns (uint256 archivedCount) {
        uint256[] storage srpIds = processSrps[processId];
        require(srpIds.length > 0, "no srps");
        _requireBatchSize(srpIds.length);

        address token = _srps[srpIds[0]].token;

        // Validate SRP terminal states and token consistency
        for (uint256 i = 0; i < srpIds.length; i++) {
            uint256 srpId = srpIds[i];
            State s = _srps[srpId].state;
            require(s == State.Refunded || s == State.Cancelled, "all srps must be terminal");
            require(_srps[srpId].token == token, "tokens must match");
        }

        // Ensure process-level archivable timestamp exists and has elapsed
        uint256 at = processArchivableAt[processId];
        require(at != 0 && block.timestamp >= at, "terminal timestamp missing");

        // Payout is the process-level total deposit
        uint256 payout = processCleanupTotalDeposit[processId];
        require(payout > 0, "no cleanup deposit");

        // Effects: archive SRPs
        for (uint256 i = 0; i < srpIds.length; i++) {
            uint256 srpId = srpIds[i];
            _emitAndDeleteSrp(srpId);
        }

        archivedCount = srpIds.length;

        // Delete process metadata and cleanup deposit bookkeeping
        delete processSrps[processId];
        delete processLockedCount[processId];
        delete processCleanupTotalDeposit[processId];
        delete processPerSrpDeposit[processId];
        delete processArchivableAt[processId];

        // Interactions: pay caller from contract-held deposits
        if (payout > 0) {
            IERC20(token).safeTransfer(msg.sender, payout);
        }

        emit ProcessArchived(processId, msg.sender, token, srpIds, payout);
        return archivedCount;
    }

    /// @notice Archive multiple processes' SRPs and pay caller from cleanup deposits
    /// @dev Permissionless batch variant of `archiveProcessSrpsWithDeposit`.
    /// Requires all processes to be archivable (archivable timestamp elapsed)
    /// and all SRPs terminal. Tokens must match across processes to allow
    /// aggregated payout in a single transfer.
    function batchArchiveProcesses(uint256[] calldata processIds)
        external
        nonReentrant
        returns (uint256 totalArchived)
    {
        require(processIds.length > 0, "empty batch");
        _requireBatchSize(processIds.length);

        address token = address(0);
        uint256 totalPayout = 0;
        uint256 totalSrps = 0;

        // First pass: validate processes and compute totals
        for (uint256 i = 0; i < processIds.length; i++) {
            uint256 pid = processIds[i];
            uint256[] storage srpIds = processSrps[pid];
            require(srpIds.length > 0, "no srps");

            // token consistency across processes
            address procToken = _srps[srpIds[0]].token;
            if (token == address(0)) {
                token = procToken;
            } else {
                require(procToken == token, "tokens must match");
            }

            // validate SRP terminal states and token consistency within process
            for (uint256 j = 0; j < srpIds.length; j++) {
                uint256 srpId = srpIds[j];
                State s = _srps[srpId].state;
                require(s == State.Refunded || s == State.Cancelled, "all srps must be terminal");
                require(_srps[srpId].token == token, "tokens must match");
            }

            // archivable timestamp must exist and have elapsed
            uint256 at = processArchivableAt[pid];
            require(at != 0 && block.timestamp >= at, "terminal timestamp missing");

            uint256 payout = processCleanupTotalDeposit[pid];
            require(payout > 0, "no cleanup deposit");

            totalPayout += payout;
            totalSrps += srpIds.length;
        }

        require(totalSrps > 0, "empty batch");
        _requireBatchSize(totalSrps);

        // Interactions: transfer aggregated payout to caller once (single token)
        if (totalPayout > 0) {
            IERC20(token).safeTransfer(msg.sender, totalPayout);
        }

        // Second pass: delete storage, emit per-SRP and per-process events
        for (uint256 i = 0; i < processIds.length; i++) {
            uint256 pid = processIds[i];
            uint256[] storage srpIds = processSrps[pid];
            uint256 n = srpIds.length;

            // copy ids to memory for ProcessArchived event
            uint256[] memory ids = new uint256[](n);
            for (uint256 j = 0; j < n; j++) {
                ids[j] = srpIds[j];
            }

            // Effects: emit SrpArchived and delete SRP storage
            for (uint256 j = 0; j < n; j++) {
                uint256 srpId = ids[j];
                _emitAndDeleteSrp(srpId);
            }

            uint256 payout = processCleanupTotalDeposit[pid];

            // Delete process metadata and cleanup deposit bookkeeping
            delete processSrps[pid];
            delete processLockedCount[pid];
            delete processCleanupTotalDeposit[pid];
            delete processPerSrpDeposit[pid];
            delete processArchivableAt[pid];

            emit ProcessArchived(pid, msg.sender, token, ids, payout);
            totalArchived += n;
        }

        return totalArchived;
    }

    // =============================================================
    //                           ADMIN / HELPERS
    // =============================================================

    // Internal helper: emit SrpArchived and delete SRP storage slots
    function _emitAndDeleteSrp(uint256 srpId) internal {
        uint256 processId = srpToProcessId[srpId];
        emit SrpArchived(
            processId,
            srpId,
            _srps[srpId].seller,
            _srps[srpId].buyer,
            _srps[srpId].amount,
            _srps[srpId].token,
            srpTotalProcessValue[srpId],
            _srps[srpId].state,
            block.timestamp
        );

        delete _srps[srpId];
        delete srpToProcessId[srpId];
    }

    // Internal helper: validate caller is root seller and root SRP is locked, return context
    function _requireRootSellerAndLocked(uint256 processId)
        internal
        view
        returns (
            uint256 rootSrpId,
            address rootBuyer,
            address rootSeller,
            address token,
            uint256 lastSrpId,
            uint256 previousTotal
        )
    {
        uint256[] storage srpChain = processSrps[processId];
        require(srpChain.length > 0, "process missing");

        rootSrpId = srpChain[0];
        rootBuyer = _srps[rootSrpId].buyer;
        rootSeller = _srps[rootSrpId].seller;

        require(msg.sender == rootSeller, "OnlyRootSeller");
        require(_srps[rootSrpId].state == State.Locked, "root not locked");

        token = _srps[rootSrpId].token;
        lastSrpId = srpChain[srpChain.length - 1];
        previousTotal = srpTotalProcessValue[lastSrpId];
    }

    // Internal helper: validate third-party seller identity and consent
    function _requireThirdPartyConsent(address seller, address rootSeller, address rootBuyer) internal view {
        require(seller != rootBuyer, "seller==buyer");
        require(seller != rootSeller, "seller==rootSeller");
        require(rootSellerThirdPartyConsent[seller][rootSeller], "root seller not approved by third party seller");
    }

    // Internal helper: compute coordination capital for a total value and validate
    function _computeCoordinationCapital(uint256 totalValue) internal pure returns (uint256) {
        uint256 coordinationCapital = 2 * totalValue;
        require(2 * totalValue == coordinationCapital, "coord math");
        return coordinationCapital;
    }

    /// @notice Collect fee and coordination capital from `payer` in `token`.
    /// @dev Centralized helper to reduce duplicated allowance/transfer logic.
    /// Returns the fee amount that was transferred to the treasury.
    ///
    /// Security: this helper enforces exact pre/post transfer balance equality
    /// for both the fee and coordination capital. This is intentional: the
    /// protocol rejects fee-on-transfer or otherwise nonstandard ERC-20 tokens
    /// to avoid silent fund loss and keep accounting simple. Callers should
    /// ensure the token is standard-compliant (see `createProcess` probe).
    function _collectFeeAndCapital(address token, address payer, uint256 coordinationCapital)
        internal
        returns (uint256)
    {
        uint256 feeAmount = srpFees.calculateFee(coordinationCapital);
        uint256 total = coordinationCapital + feeAmount;
        uint256 allowance = IERC20(token).allowance(payer, address(this));
        require(allowance >= total, "insufficient approval");

        IERC20 tokenIfc = IERC20(token);

        // snapshot pre-transfer balances for treasury and this contract
        uint256 preTreasury = tokenIfc.balanceOf(srpFees.treasury());
        uint256 preThis = tokenIfc.balanceOf(address(this));

        // transfer fee to treasury and verify exact received amount
        if (feeAmount > 0) {
            tokenIfc.safeTransferFrom(payer, srpFees.treasury(), feeAmount);
            uint256 postTreasury = tokenIfc.balanceOf(srpFees.treasury());
            uint256 actualFee = postTreasury - preTreasury;
            // deliberate equality check: ensure treasury received exact fee amount.
            // slither-disable-next-line incorrect-equality
            require(actualFee == feeAmount, "fee transfer mismatch");
        }

        // transfer coordination capital to contract and verify exact received amount
        if (coordinationCapital > 0) {
            tokenIfc.safeTransferFrom(payer, address(this), coordinationCapital);
            uint256 postThis = tokenIfc.balanceOf(address(this));
            uint256 actualCoord = postThis - preThis;
            // deliberate equality check: enforce exact coordination capital received.
            // slither-disable-next-line incorrect-equality
            require(actualCoord == coordinationCapital, "capital transfer mismatch");
        }

        return feeAmount;
    }

    // Internal helper: lock an SRP and increment process locked count
    function _lockSrpInternal(uint256 srpId) internal {
        _srps[srpId].state = State.Locked;
        uint256 processId = srpToProcessId[srpId];
        processLockedCount[processId]++;
    }

    /// @notice Third party seller approves or revokes an rootSeller
    /// to add SRPs on their behalf.
    /// @dev Third party sellers explicitly approve the rootSeller
    /// before the rootSeller may add SRPs that debit the third party
    /// seller's tokens.
    /// @param rootSeller The rootSeller address to approve or revoke
    /// @param approved True to approve, false to revoke
    function grantRootSellerConsent(address rootSeller, bool approved) external {
        rootSellerThirdPartyConsent[msg.sender][rootSeller] = approved;
        emit AddSrpConsent(msg.sender, rootSeller, approved);
    }

    /// @notice Batch grant or revoke consent for multiple root sellers
    /// @dev Third-party sellers call this to approve or revoke many root sellers
    /// in a single transaction. Mirrors `grantRootSellerConsent` behavior.
    function batchGrantRootSellerConsent(address[] calldata rootSellers, bool approved) external {
        require(rootSellers.length > 0, "empty batch");
        _requireBatchSize(rootSellers.length);

        for (uint256 i = 0; i < rootSellers.length; i++) {
            address rootSeller = rootSellers[i];
            rootSellerThirdPartyConsent[msg.sender][rootSeller] = approved;
            emit AddSrpConsent(msg.sender, rootSeller, approved);
        }
    }

    // NOTE: signature verification moved to FigaroSignedHelpers.verifyAddSrpPayload

    // Internal: consume seller nonce (replay protection)
    function _consumeSellerNonce(address seller, uint256 expected) internal {
        require(sellerNonces[seller] == expected, "nonce mismatch");
        unchecked {
            sellerNonces[seller] = sellerNonces[seller] + 1;
        }
    }

    // Internal: compute and validate process context for an AddSrpPayload
    function _computeAndValidateContext(uint256 processId, address seller, uint256 amount)
        internal
        view
        returns (address token, address rootBuyer, address rootSeller, uint256 computedTotal)
    {
        uint256[] storage srpChain = processSrps[processId];
        require(srpChain.length > 0, "process missing");

        uint256 rootSrpId = srpChain[0];
        rootBuyer = _srps[rootSrpId].buyer;
        rootSeller = _srps[rootSrpId].seller;

        require(_srps[rootSrpId].state == State.Locked, "root not locked");
        require(seller != rootBuyer, "seller==buyer");
        require(seller != rootSeller, "seller==rootSeller");
        require(rootSellerThirdPartyConsent[seller][rootSeller], "no consent");

        token = _srps[rootSrpId].token;
        uint256 lastSrpId = srpChain[srpChain.length - 1];
        uint256 previousTotal = srpTotalProcessValue[lastSrpId];
        computedTotal = previousTotal + amount;
    }

    // Compatibility getter: preserve previous public getter shape (6-tuple)
    function srps(uint256 srpId)
        public
        view
        returns (
            address seller,
            address buyer,
            uint256 amount,
            address token,
            State state,
            uint256 coordinationCapitalBalance
        )
    {
        SrpData storage s = _srps[srpId];
        return (s.seller, s.buyer, s.amount, s.token, s.state, s.coordinationCapitalBalance);
    }

    // =============================================================
    //                           SIGNED HELPERS
    // =============================================================

    bytes32 internal constant ADD_SRP_TYPEHASH = keccak256(
        "AddSrpPayload(uint256 processId,address seller,uint256 amount,address token,uint256 totalProcessValue,uint256 deadline,uint256 nonce,bytes metadata)"
    );

    function hashAddSrpPayload(IMechanism.AddSrpPayload calldata p) internal pure returns (bytes32) {
        bytes32 metaHash = keccak256(p.metadata);
        return keccak256(
            abi.encode(
                ADD_SRP_TYPEHASH,
                p.processId,
                p.seller,
                p.amount,
                p.token,
                p.totalProcessValue,
                p.deadline,
                p.nonce,
                metaHash
            )
        );
    }

    function verifySignatureMatches(
        address expected,
        bytes32 domainSeparator,
        bytes32 structHash,
        bytes memory signature
    ) internal view returns (bool) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Try ECDSA recover first
        address recovered = ECDSA.recover(digest, signature);
        if (recovered == expected) return true;

        // If expected is a contract, try EIP-1271 isValidSignature
        uint256 size;
        assembly {
            size := extcodesize(expected)
        }
        if (size == 0) return false;

        (bool ok, bytes memory ret) = expected.staticcall(abi.encodeWithSelector(0x1626ba7e, digest, signature));
        if (!ok || ret.length < 4) return false;
        // Defensive decode: load the first word of the return data which
        // should contain the 4-byte selector (padded). We use assembly to
        // avoid extra allocations; the assumptions are covered by unit tests.
        bytes4 result;
        assembly {
            result := mload(add(ret, 32))
        }
        return result == 0x1626ba7e;
    }

    function callPermitIfPresent(address token, address owner, address spender, bytes memory permit) internal {
        if (permit.length == 0) return;
        // Use OpenZeppelin `Address.functionCall` to surface revert reasons
        // when permit execution fails. Permits are optional; failure here
        // should revert the flow since callers expect permit to succeed
        // if provided.
        Address.functionCall(token, permit);
    }

    function verifyAddSrpPayload(
        IMechanism.AddSrpPayload calldata p,
        address verifyingContract,
        bytes memory signature
    ) internal view returns (bool) {
        bytes32 structHash = hashAddSrpPayload(p);

        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Figaro")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );

        return verifySignatureMatches(p.seller, domain, structHash, signature);
    }

    // Internal helper: validate tokens for a process and compute total deposit
    function _validateAndComputeReleaseDeposit(uint256 processId, uint256 perSrpDeposit)
        internal
        view
        returns (address token, uint256 n, uint256 totalDeposit)
    {
        uint256[] storage srpIds = processSrps[processId];
        require(srpIds.length > 0, "no srps");
        token = _srps[srpIds[0]].token;
        n = srpIds.length;
        _requireBatchSize(n);
        for (uint256 i = 0; i < n; i++) {
            require(_srps[srpIds[i]].token == token, "tokens must match");
        }
        totalDeposit = perSrpDeposit * n;
        if (n != 0 && perSrpDeposit != 0 && totalDeposit / n != perSrpDeposit) {
            revert("deposit overflow");
        }
    }

    // Internal helper: ensure adding `newChildren` SRPs does not exceed
    // the protocol's MAX_BATCH_SIZE when applied to the target process.
    // Uses the same revert string as other batch checks for consistency.
    function _requireProcessCapacity(uint256 processId, uint256 newChildren) internal view {
        uint256 currentTotal = processSrps[processId].length; // includes root SRP
        uint256 totalAfter = currentTotal + newChildren;
        require(totalAfter <= MAX_BATCH_SIZE, "batch too large");
    }

    // Internal helper: enforce batch size limits in one place for DRY
    function _requireBatchSize(uint256 n) internal view {
        require(n <= MAX_BATCH_SIZE, "batch too large");
    }

    // Internal helper: apply CEI effects for a single SRP release and emit event
    function _applyReleaseToSrp(uint256 processId, uint256 srpId) internal returns (uint256 buyerRefund) {
        require(_srps[srpId].state == State.Locked, "srp not locked");
        // accumulate buyer refund (1x amount per SRP)
        buyerRefund = _srps[srpId].amount;
        // Effects: mark released and deduct the buyer refund from stored coordination capital
        _srps[srpId].state = State.Released;
        _srps[srpId].coordinationCapitalBalance -= buyerRefund;

        // Emit SrpStateChanged per SRP for Released state
        bytes32 releaseVersion = keccak256(
            abi.encodePacked(_srps[srpId].srpHash, uint256(State.Released), _srps[srpId].coordinationCapitalBalance)
        );
        // principal = buyer for Release (buyer-centric)
        emit SrpStateChanged(
            srpId,
            processId,
            _srps[srpId].buyer,
            _srps[srpId].seller,
            _srps[srpId].buyer,
            _srps[srpId].srpHash,
            releaseVersion,
            State.Locked,
            State.Released,
            -int256(buyerRefund),
            _srps[srpId].coordinationCapitalBalance,
            srpTotalProcessValue[srpId]
        );
    }

    // Internal helper: settle interactions and record process-level metadata for release
    function _settleReleaseInteractions(
        uint256 processId,
        address token,
        uint256 totalDeposit,
        uint256 totalBuyerRefund,
        uint256 perSrpDeposit
    ) internal {
        // Effects: record process-level cleanup deposit metadata and archivable timestamp
        uint256 archivableAt = block.timestamp + ARCHIVE_DELAY_SECONDS;
        processCleanupTotalDeposit[processId] = totalDeposit;
        processPerSrpDeposit[processId] = perSrpDeposit;
        processArchivableAt[processId] = archivableAt;

        // Interactions: transfer buyer refund (1x amount per SRP) to the buyer (msg.sender)
        if (totalBuyerRefund > 0) {
            IERC20(token).safeTransfer(msg.sender, totalBuyerRefund);
        }

        // Interactions: collect buyer-funded cleanup deposit
        if (totalDeposit > 0) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), totalDeposit);
        }

        emit CleanupDepositPlaced(processId, token, perSrpDeposit, totalDeposit, msg.sender);
    }

    // =============================================================
    //                           ACCESS HELPERS
    // =============================================================

    function _onlyBuyer(uint256 srpId) internal view {
        if (_srps[srpId].buyer != msg.sender) revert("OnlyBuyer");
    }

    function _onlySeller(uint256 srpId) internal view {
        if (_srps[srpId].seller != msg.sender) revert("OnlySeller");
    }

    function _onlyInState(uint256 srpId, State expected) internal view {
        if (_srps[srpId].state != expected) revert("InvalidState");
    }
}
