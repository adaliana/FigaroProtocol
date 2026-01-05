# Design Decisions

## CEI-first Ordering
All state changes occur before any external token transfer. This reduces reentrancy risk and keeps invariants simple to reason about.

## Pull-based Fees
Fees are collected via `SRPFees.collectFee()` after the caller grants allowance. This avoids surprising transfers and keeps approvals explicit in frontends.

## Token Probe on Create
`createProcess` sends a 1-unit probe to detect fee-on-transfer tokens. Incompatible tokens are rejected early to prevent accounting drift.

## Event Versioning
`versionHash` encodes the state transition and balance to provide idempotent, replay-safe event processing off-chain.

## Deterministic Tooling
Formatting is enforced in CI with a pinned Foundry version to ensure consistent diffs and reliable automated checks.

## Progressive Collateralization
We extend the two-party Safe Remote Purchase (SRP) pattern to N-party coordination by introducing staged collateral. At each stage, required collateral and unlock rules are set such that cooperation strictly dominates unilateral defection. This preserves SRP’s intuitive safety while enabling collective actions (group buys, milestone funding, cooperative deliveries).

## Key Guarantees (Pragmatic)
- CEI-first sequencing: State is committed before external transfers.
- Reentrancy resistance: State-first transitions and targeted tests reduce attack surface.
- Fee transparency: Pull-model fees and explicit approvals avoid surprise transfers.
- Token agnosticism: A 1-unit probe detects fee-on-transfer behavior; fee math is mirrored client-side.
- Deterministic indexing: `(srpId, versionHash)` de-duplicates events for clients and indexers.

## Threat Model & Assumptions
- L1/L2 consensus provides finality; adversaries cannot reorder finalized blocks.
- ERC-20 tokens follow their stated semantics; fee-on-transfer is explicitly detected.
- Users control EOAs or smart-account keys; transactions represent user intent.
- Collateral is economically meaningful for participants (otherwise incentives degrade).

## Formal Verification Scope
We maintain TLA+ models for simplified SRP behaviors and run TLC simulations plus Foundry invariant tests. These artifacts increase confidence in safety properties (no unexpected unlocks, conservation constraints, orderly state transitions). They do not constitute a full formal proof of the entire implementation and should be complemented with audits and continuous fuzzing.
