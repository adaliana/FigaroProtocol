# Security Guarantees and Proof Sketches

This document captures the protocol's security model, core properties, and proof sketches for the guarantees Figaro aims to provide. It is a practitioner-friendly complement to the formal artifacts (Foundry invariants and TLA+ models) and does not constitute a complete mechanized proof.

## Table of Contents
- Scope and Audience
- Reading Guide & Assurance Levels
- SRP Primer (Background)
- Model and Assumptions
- Adversary Model
- Verification Process & Artifacts
- Properties (Targets)
- Attack Surfaces & Mitigations
- Lemmas and Proof Sketches
- Theorem (Equilibrium of Cooperation Across Stages)
- Parameterization Guidance (Practical)
- Composability & Integration Risks
- Mapping to Implementation and Tests
- Reporting Security Issues
- References
- Quick Checklists (Auditor / Integrator)
- Diagram: SRP State and Hook Boundary
- Limitations and Out-of-Scope
- Future Work

## Scope and Audience
- Focus: Safety, incentive alignment, and protocol-level correctness under stated assumptions.
- Audience: Engineers, auditors, and integrators evaluating Figaro's trust and failure modes.

## Reading Guide & Assurance Levels
- Purpose: Provide actionable security expectations and the reasoning behind them.
- Assurance: This is a proof-sketch document that complements testing and formal models. It is not a fully mechanized proof.

## SRP Primer (Background)
Safe Remote Purchase (SRP) is a two-party escrow pattern popularized in early Ethereum examples: a buyer and a seller both post funds so that delivery-and-acceptance is the unique rational path. Misbehavior (no delivery, bad delivery, or unfair claims) is deterred by forfeiting deposits.

- Parties: buyer (B) and seller (S).
- Deposits: B escrows the price; S posts a deposit. The losing side forfeits deposit upon misbehavior.
- Flow: create → lock/ship → confirm/receive → release or refund.
- Incentive effect: For properly chosen deposits, unilateral deviation yields lower utility than cooperation.

Figaro extends SRP to N-party coordination via progressive collateralization: participants post stage-dependent collateral $C_k$ so that at each stage $k$, the penalty $P_k$ for deviating dominates any short-term gain $G_k$. This preserves SRP’s incentive compatibility in multi-party settings, and Figaro keeps the core state machine simple while exposing a composable hook (`IMechanism`) and token-agnostic handling (including fee-on-transfer probes).

## Model and Assumptions
- Network: Ethereum (or EVM-compatible) chain provides execution, ordering, and finality. Liveness depends on the underlying chain.
- Cryptography: Collision resistance of `keccak256`; signature schemes authenticate user intent.
- Tokens: ERC-20 semantics with potential fee-on-transfer (FOT). Nonstandard behaviors are probed and handled conservatively.
- Accounts: EOAs or smart accounts control keys; transactions reflect user intent.
- Economics: Posted collateral is economically meaningful; rational participants prefer higher expected utility.

## Adversary Model
- Byzantine participants: May deviate arbitrarily, attempt reentrancy, withhold messages, or front-run.
- External attackers: Observe mempool, attempt MEV strategies, DoS attempts, or exploit token quirks.
- Rational deviators: Seek to maximize payoff; will deviate if profitable after penalties.

## Notation and Glossary
- $E_t$: Escrow balance at time $t$.
- $F_t$: Cumulative collected fees by time $t$.
- $T_t$: Cumulative token taxes (fee-on-transfer) by time $t$.
- $D$: Total initial deposits.
- $R_t$: Cumulative released amount by time $t$.
- $C_k$: Collateral posted at stage $k$.
- $P_k$: Penalty at stage $k$ (typically forfeiture of $C_k$ plus loss of future upside).
- $G_k$: Short-term gain from deviating at stage $k$.
- $U_k$: Utility from cooperating at stage $k$ under honest progress.
- $\epsilon$: Slack/margin term for strict dominance.
- SRP: Safe Remote Purchase — two-party escrow pattern generalized by Figaro.
- FOT: Fee-on-transfer token.

## Verification Process & Artifacts
- Testing: Foundry unit tests for create/lock/release/refund and batch flows.
- Invariants: Property-based tests for conservation, orderly transitions, and reentrancy resistance.
- Fuzzing: Differential/property fuzzing to explore edge cases.
- Static analysis: Slither and linters for common patterns.
- Formal modeling: TLA+ models and TLC simulation traces when included; scoped assurance, not end-to-end proofs.

## Properties (Targets)
- Safety: No unauthorized release of escrowed funds.
- Conservation: Total assets conserved up to explicit fees and taxes (when applicable).
- State Integrity: Transitions are single-step and CEI-first; no reentrancy-induced state corruption.
- Idempotent Indexing: Off-chain consumers can de-duplicate state via `(srpId, versionHash)`.
- Incentive Compatibility (IC): At each stage, cooperation strictly dominates unilateral defection given configured collateral.
- Bounded Griefing: Misbehavior is penalized by forfeiture; honest participants are not made worse off beyond posted bounds.
- Conditional Liveness: Progress occurs when required parties act within time/condition windows; chain halts and persistent DoS excluded.

## Attack Surfaces & Mitigations
- Reentrancy: Mitigated by CEI-first state updates; tests exercise reentrant paths.
- ERC-20 quirks: Fee-on-transfer detected via 1-unit probe; fees pulled explicitly to avoid hidden transfers.
- Allowances: Frontends should compute exact approvals and minimize scopes.
- MEV/front-running: Avoid single-tx races where ordering changes value; SRP flows assume transparent ordering.
- Mechanism hook (`IMechanism`): Treat as untrusted; SRP invariants must not depend on hook success.
- Denial of service: Hook failures must not wedge SRP progress; keep core paths independent.

## Lemmas and Proof Sketches

### Lemma 1: CEI Ordering Prevents Reentrancy Corruption
- Claim: Because state transitions precede external token transfers, a reentrant call observes post-transition state and cannot violate safety invariants dependent on pre-transition assumptions.
- Sketch: For a flow `f` with internal transition `T` and transfer `X`, the execution order is `T` then `X`. Any reentrant `f'` triggered by `X` will see the updated state from `T`, so guards for `f'` fail if they rely on pre-`T` conditions. This closes common reentrancy windows.

### Lemma 2: Version Hash Uniqueness for Off-chain Deduplication
- Claim: `versionHash = keccak256(creationHash, state, balance)` is unique for distinct post-states under collision resistance.
- Sketch: If two distinct states `(s1, b1) \ne (s2, b2)` produced the same hash, this would imply a collision in `keccak256` over different encodings, contradicting the collision-resistance assumption.

### Lemma 3: Conservation of Escrowed Value (Up To Fees/Taxes)
- Claim: Let $E_t$ be escrow balance at time $t$, $F_t$ collected fees, and $T_t$ token taxes (FOT). Then for initial deposits $D$, $E_t + F_t + T_t = D - R_t$ where $R_t$ is cumulative released amount.
- Sketch: Each transition preserves the accounting identity: deposits increase $E$, releases decrease $E$ and increase $R$, fees increase $F$, FOT events increase $T$. No hidden transfers occur due to pull-fee model and explicit probes.

### Lemma 4: FOT Detection via Probe
- Claim: A 1-unit probe in `createProcess` detects fee-on-transfer tokens by comparing sent vs received amounts, enabling explicit handling.
- Sketch: For standard ERC-20, net received equals 1. For FOT tokens, net received equals $1 - \tau$ with tax $\tau > 0$. Mismatch flags nonstandard behavior; flows adjust or reject to avoid silent slippage.

### Lemma 5: Incentive Compatibility via Progressive Collateralization
- Setup: At stage $k$, a participant posts collateral $C_k$ and expects payoff $U_k$ if cooperating. A defection incurs penalty $P_k$ (loss of posted collateral and opportunity) and may yield short-term gain $G_k$.
- Claim: If $U_k - \epsilon \ge G_k - P_k$ for some $\epsilon \ge 0$, cooperation strictly dominates defection. Choosing $C_k$ and rules so that $P_k > G_k$ yields $U_k - \epsilon > G_k - P_k$.
- Sketch: Configure stage parameters so that any unilateral deviation burns at least as much value (via forfeiture and exclusion from future release) as could be gained by deviating. Backward induction across stages preserves IC.

## Theorem (Equilibrium of Cooperation Across Stages)
- Statement: Under Lemma 5 conditions for all stages and participants, the strategy profile “cooperate at each stage” forms a subgame perfect equilibrium.
- Sketch: Apply backward induction from the final stage, where deviation yields strictly lower utility due to $P_k$. Given rational agents and common knowledge of penalties, cooperation is optimal at the last stage; inductively, optimality propagates to all prior stages.

## Assurance Matrix (Property → Evidence)

| Property | Enforcement | Evidence/Artifacts |
|---|---|---|
| Safety (no unauthorized release) | CEI-first transitions; guarded state machine | tests/ (release/refund suites), reentrancy tests |
| Conservation (funds accounting) | Explicit accounting and invariant checks | tests/ invariants; docs lemmas; Echidna/Foundry fuzz (if configured) |
| State integrity (no reentrancy corruption) | State-before-transfer; no external calls pre-commit | tests/ reentrancy; code review of external call sites |
| Idempotent indexing | `versionHash` over post-state | event consumer guidance; tests verifying hash updates |
| Incentive compatibility | Progressive collateralization and penalties | design rationale; parameter guidance; application-level configs |
| Bounded griefing | Forfeiture of $C_k$; exclusion from future releases | tests covering deviation scenarios; mechanism integration review |
| Conditional liveness | Time/condition windows; independent core progress | tests for timeouts/paths; mechanism failure handling |

## Parameterization Guidance (Practical)
- Collateral sizing: choose $C_k$ so $P_k \approx C_k$ (plus loss of future upside) and require $C_k \ge G_k + \delta$ for margin $\delta > 0$.
- Fee visibility: expose exact fee amounts and approval requirements in UX; prefer minimal allowances.
- Timing windows: define stage windows that balance liveness with griefing resistance.
- Batch limits: ensure batches fit block gas; partial successes must preserve conservation.

Example: if a deviator could gain $G_k = 5$ units by skipping delivery, set $C_k \ge 6$ so $P_k > G_k$, and exclude deviators from future releases.

## Composability & Integration Risks
- Hook isolation: `IMechanism` should be sandboxed; failures treated as no-ops for safety.
- Oracles: sanitize and bound trust; oracle failures must not unlock funds.
- Upgrades/governance: if present, constrain authority over core invariants; use timelocks and transparent proposals.

## Mapping to Implementation and Tests
- CEI-first: See core flows in `src/Figaro.sol` (create, lock, refund, release) with state updates preceding token transfers.
- Fee model: `SRPFees.collectFee()` implements pull-based fee collection; callers must `approve()` first.
- Eventing: `SrpCreated`/`SrpStateChanged` include `versionHash` for de-duplication.
- Tests: Foundry suites cover lock/refund/release, batch operations, fee handling, reentrancy, and invariants (see `test/`).
- Formal: TLA+ modules capture the SRP state machine and are exercised via TLC; invariants are mirrored in Foundry where practical.

## Reporting Security Issues
Please follow the responsible disclosure process in [SECURITY.md](../SECURITY.md). Do not open public issues for suspected vulnerabilities.

## References
- Safe Remote Purchase (SRP) background: https://docs.soliditylang.org/en/latest/introduction-to-smart-contracts.html#safe-remote-purchase

## Quick Checklists

### Auditor Checklist
- CEI-first: Verify `create`, `lock`, `refund`, `release` update state before any external ERC-20 transfer.
- Reentrancy paths: Confirm no external callbacks pre-commit; ensure tests cover reentrant attempts across flows and `IMechanism`.
- Conservation: Trace accounting identity across deposits, releases, fees, and FOT deltas; confirm invariant tests enforce it.
- Versioning: Validate `versionHash` construction and uniqueness assumptions; consumers can de-duplicate via `(srpId, versionHash)`.
- Fee model: Confirm pull-based `SRPFees.collectFee()` and matching math in examples; no implicit transfers.
- Probe: Ensure 1-unit probe executes on create and failure modes are safe for nonstandard tokens.
- Hooks: Treat `IMechanism` as untrusted; SRP safety must not depend on hook success or atomicity.
- Access/governance: If any admin or upgrade surface exists, ensure it cannot alter core invariants without timelocks/review.

### Integrator Preflight
- Tokens: Test the 1-unit probe with your ERC-20 (including FOT) on a testnet.
- Approvals: Mirror on-chain fee math; request the exact allowance needed; prefer minimal, scoped approvals.
- Events: De-duplicate by `(srpId, versionHash)`; persist the last seen hash per process.
- Batching: Keep batch sizes within gas limits; handle partial failures without breaking conservation.
- Hooks: If using `IMechanism`, isolate failures and avoid making core SRP progress depend on hook outcomes.
- Liveness: Define time/condition windows that fit your UX; surface timeouts and retry paths.
- Testing: Run end-to-end flows (create → lock → release/refund) on a testnet with your token set.

## Diagram: SRP State and Hook Boundary

```mermaid
flowchart LR
		A[createProcess] -->|state commit| S1((Created))
		S1 -->|lock| S2((Locked))
		S2 -->|release| S3((Released))
		S2 -->|refund| S4((Refunded))

		subgraph Hooks
			H[IMechanism callback\n(after SRP add)]
		end
		A -.invokes .-> H

		subgraph Tokens
			F[SRPFees.collectFee]\n(pull-fee)
			T[ERC-20 any token\nFOT supported via probe]
		end
		A --> F --> T

		classDef core fill:#e6f7ff,stroke:#1890ff,color:#000
		class S1,S2,S3,S4 core
```

## Limitations and Out-of-Scope
- Full mechanized proofs: This document provides proof sketches, not machine-checked proofs.
- Economic parameters: Improper collateral settings ($P_k$ too small) can weaken incentives.
- Liveness under MEV/DoS: Adversarial network conditions may delay progression; economic/time-based mitigations are application-specific.
- Token pathologies: Tokens violating ERC-20 semantics beyond FOT may still be incompatible.

## Future Work
- Mechanize selective properties in a proof assistant and expand TLA+ coverage.
- Add quantitative guidance on choosing $C_k$ and $P_k$ under specific risk models.
- Extend invariants to cover more batch and partial-participation scenarios.
