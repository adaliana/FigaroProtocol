# Integration Guide

## Get ABIs
- Download prebuilt `Figaro.json` and `SRPFees.json` from the Assets section of the latest GitHub release.
- Alternatively, build locally and export via `forge inspect`.

## Approvals & Fees
- Before calling flows that require fees, approve the `SRPFees` collector for the exact token amount needed by your flow.
- Follow the same fee math as on-chain to present clear UX; see frontend examples if available.

## SRP Lifecycle
1. Create: submit SRP parameters; contract performs token probe; listen for `SrpCreated`.
2. Lock: move funds into escrow (batch variants supported).
3. Resolve: either `release` or `refund` by the appropriate party.

## Events & De-duplication
- Process `SrpStateChanged` with de-duplication key `(srpId, versionHash)` to achieve idempotent indexing.
- Persist the last seen `versionHash` per `srpId` to avoid double-processing in UI or indexer code.

## References
- Contracts: `src/Figaro.sol`, `src/SRPFees.sol`, `src/IMechanism.sol`.
- Tests: see `test/` for concrete examples of creation, lock, and resolve flows.
