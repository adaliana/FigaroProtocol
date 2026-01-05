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
