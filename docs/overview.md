## Progressive Collateralization at a Glance

Figaro generalizes Vitalik’s Safe Remote Purchase (SRP) from a two-party escrow to an N-party coordination protocol. It does this by introducing staged collateral that scales with process phases. Each stage aligns incentives so that honest participation strictly dominates defection, even as more participants join.

- SRP roots: Familiar escrow semantics (lock → deliver/verify → release/refund) with explicit penalties for misbehavior.
- Progressive collateral: Participants post or maintain collateral according to stage rules, ensuring cooperation remains the rational choice.
- Multi-party ready: Collective actions (group buys, milestone funding, cooperative deliveries) can be encoded as SRPs without sacrificing SRP security.

## Why It Matters

- Credible commitments: Parties can coordinate without trusted intermediaries; griefing is bounded by collateral.
- Clear UX: State and transitions are explicit, evented, and deduplicated via `versionHash`.
- Flexible outcome selection: `IMechanism` lets you combine SRP with auctions, voting, or reputation without modifying the core state machine.
- Token-agnostic: Any ERC-20 works, including fee-on-transfer tokens detected via a 1-unit probe.

See docs/architecture.md for component-level details and docs/design-decisions.md for guarantees and threat model.

# Overview

Figaro is a minimal, CEI-first coordination protocol for peer-to-peer marketplaces. It standardizes how counterparties coordinate funds and state through a Service Request Process (SRP): create, lock (escrow), and finally release or refund.

Why it exists:
- Provide a simple, auditable state machine for escrow-like coordination.
- Make off-chain consumption reliable via versioned events and de-duplication.
- Keep integrations straightforward with a pull-based fee model and a single hook for mechanism extensions.

Highlights:
- Deterministic lifecycle events enable robust indexers and UIs.
- Batch-friendly flows keep gas costs reasonable at scale.
- Frontends mirror fee math and follow explicit approval patterns (no permit-first assumptions).

For an architectural walk-through, see docs/architecture.
