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

## Composability Pathways

- Mechanism hook: After SRP add flows, Figaro invokes `IMechanism` so integrators can apply auctions, voting, reputation weighting, or custom selection without modifying the core.
- Event surface: Indexers/frontends subscribe to `SrpCreated` and `SrpStateChanged`, mirroring state by `(srpId, versionHash)` for deterministic sync.
- Frontend parity: Mirror fee math client-side to compute exact `approve()` amounts; minimal examples live under `frontend/`.

## Token-Agnostic ERC-20 Handling

- Probe defense: `createProcess` performs a 1-unit probe to detect fee-on-transfer tokens and avoid hidden tax slippage.
- Pull fees: `SRPFees.collectFee(token, amount)` requires prior `approve()`; no implicit transfers.
- Nonstandard tokens: Fee-on-transfer and taxed tokens are supported explicitly; UX should surface required approvals and potential tax.
