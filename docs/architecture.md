# Architecture

## Contracts
- Figaro (src/Figaro.sol): CEI-first state machine that emits `SrpCreated` and `SrpStateChanged` as the SRP progresses.
- SRPFees (src/SRPFees.sol): Centralized fee math and `collectFee()` entrypoint with caps.
- IMechanism (src/IMechanism.sol): Optional hook to integrate auctions, reputation, or other selection mechanisms after SRP add.

## Data Flow
1. Create: caller submits SRP creation; contract performs a token probe to detect fee-on-transfer tokens; state is updated then events emitted.
2. Lock: funds moved into escrow according to CEI ordering; state changes precede transfers.
3. Resolve: release or refund; updates are reflected via `SrpStateChanged` with a new `versionHash`.

## Events & Versioning
- Consumers de-duplicate on `(srpId, versionHash)` where `versionHash = keccak256(abi.encodePacked(creationHash, uint256(newState), coordinationCapitalBalance))`.
- This ensures idempotent indexing in the presence of chain reorgs or repeated logs.

## Batch Flows
- Batch add/lock patterns reduce gas overhead and UI roundtrips; see tests for examples.
