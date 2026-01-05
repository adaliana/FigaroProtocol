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

## ERC-20 Token Agnosticism
- Probe behavior: `createProcess` sends a 1-unit probe to detect fee-on-transfer (FOT) tokens; this avoids silent tax slippage.
- Approvals: Always `approve()` the `SRPFees` contract before calling flows that pull fees via `collectFee(token, amount)`.
- Client math: Mirror on-chain fee math to compute the exact approval amount; for FOT tokens, present expected received/paid values explicitly.

## Mechanism Hook (`IMechanism`)
- Use the hook to run auctions, voting, reputation weighting, or oracle checks after SRP add flows.
- Keep SRP core unchanged; encode your selection logic in a separate contract implementing `IMechanism` and wire it at deployment or via configuration.

## Example Patterns
- Milestone Grants: Multiple `lock`/`release` phases; if a milestone fails, trigger `refund` for remaining capital.
- Group Buy: Accept N participant locks; only `release` if a quorum/threshold is reached; otherwise `refund` all.
- Bounty Escrow: DAO locks funds; upon verified delivery (via mechanism or multisig), `release` to the solver; else `refund` to treasury.
- Preorders: Collect deposits, then either ship (release) or cancel (refund) with bounded griefing.

## References
- Contracts: `src/Figaro.sol`, `src/SRPFees.sol`, `src/IMechanism.sol`.
- Tests: see `test/` for concrete examples of creation, lock, and resolve flows.
