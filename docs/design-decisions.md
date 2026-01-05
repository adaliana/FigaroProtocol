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
