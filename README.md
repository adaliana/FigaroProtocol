## Why Figaro

- Strong incentives: Progressive collateralization extends Vitalik’s Safe Remote Purchase (SRP) from two-party escrow to N-party coordination while preserving the same game-theoretic security guarantees.
- Composable by design: Clean hook via `IMechanism` enables auctions, voting, reputation, oracles, and custom selection logic to run alongside SRP flows.
- Token-agnostic: Works with any ERC-20, including fee-on-transfer tokens. The protocol proactively probes and accounts for transfer taxes to avoid hidden loss.
- Event-first integrations: Deterministic versioning (`versionHash`) allows clients to de-duplicate and stream state safely.
- Verified behaviors: CEI-first ordering, reentrancy defenses, Foundry invariants, and TLA+ models cover core safety properties.

## Progressive Collateralization (SRP → Multi-party)

Figaro is inspired by Vitalik’s Safe Remote Purchase escrow but generalizes it to multi-party coordination without weakening incentives. Participants post collateral progressively across stages of a Shared Remote Process (SRP). The staged collateral curve deters strategic deviations at every step, keeping cooperation the rational equilibrium as group size grows. Practically, this lets you scale from bilateral escrow to collective actions (e.g., group buys, milestone funding, cooperative deliveries) while maintaining SRP’s intuitive safety.

Key properties:
- Incentive compatibility: At each stage, defections are strictly dominated by cooperation given posted collateral and unlock rules.
- Bounded griefing: Misbehavior is penalized by locked funds; honest parties are protected by escrowed coordination capital.
- Extensible rules: You can tailor stage transitions and selection logic via `IMechanism` without altering the SRP’s safety core.

See also: docs/design-decisions.md and docs/architecture.md for deeper mechanics, and formal-verification artifacts in the repository for model-level checks.

## Key Guarantees

- CEI-first sequencing: State transitions occur before external token transfers (`createProcess`, `lock`, `refund`, `release`), preventing classic reentrancy hazards.
- Cryptographic integrity: All transitions are finalized on-chain under Ethereum consensus; user intent is authenticated by EOA signatures; event versioning uses `keccak256` over state to produce a stable `versionHash` for clients.
- Formal assurance (pragmatic): TLA+ specifications exercise the SRP state machine and invariants; Foundry invariant tests and reentrancy suites enforce runtime properties in simulation. These checks improve confidence but do not replace rigorous audits.
- Fee transparency: Fees are pulled via `SRPFees.collectFee(token, amount)` after callers `approve()`; the 1-unit probe in `createProcess` detects fee-on-transfer tokens so tax slippage is handled explicitly.

## Composability

- Mechanism hook: `IMechanism` is invoked after SRP add-flows so you can plug in auctions, votes, reputation, or scoring. This keeps SRP simple while enabling rich, application-specific coordination.
- Event surface: Consumers subscribe to `SrpCreated`/`SrpStateChanged`, deduplicate by `(srpId, versionHash)`, and mirror fee math client-side for UX clarity.
- Frontend patterns: The example clients in `frontend/` demonstrate minimal HTML/JS patterns using `abi.js` and `approvals.js`.

## ERC-20 Token Agnosticism

Figaro supports any ERC-20 that adheres to the standard transfer semantics, and it includes a probe path to detect fee-on-transfer behavior. Integrators should:
- Use standard `approve()` prior to `collectFee()`.
- Mirror fee math on the client to present exact required approvals.
- Expect the 1-unit probe in `createProcess` to succeed for well-behaved tokens; taxed/nonstandard tokens are handled, not hidden.

## What You Can Build

- Trust-minimized marketplaces: SRP-backed escrows for digital goods, services, or cross-border transactions.
- Milestone-based funding: Progressive releases for grants, bounties, and R&D with refund guarantees on failure.
- Group purchases and coordination: Cooperative buying or provisioning that only executes if enough parties lock.
- DAO workflows: Guarded payouts, bounty claims, and contributor incentives with on-chain enforcement and off-chain signals.
- Pre-orders and commitments: Time- or condition-gated locks that minimize griefing and enable credible commitments.

Quick starts and deeper dives:
- Overview: docs/overview.md
- Architecture: docs/architecture.md
- Design Decisions & Guarantees: docs/design-decisions.md
- Integration Guide: docs/integration.md
- Security (Model, Lemmas, Proof Sketches): docs/security.md

# Figaro Protocol

[![CI](https://github.com/adaliana/FigaroProtocol/actions/workflows/ci.yml/badge.svg)](https://github.com/adaliana/FigaroProtocol/actions/workflows/ci.yml)

Figaro is a CEI-first coordination protocol for peer‑to‑peer marketplaces. It standardizes the SRP (Service Request Process) lifecycle—create, lock, release/refund—enforces a pull‑based fee model, and emits versioned events that make off‑chain indexing robust and idempotent.

This repository contains the core contracts, tests, and minimal automation to build, test, and publish ABIs.

## Quick Dev Loop
- Start a local node: `anvil --port 8545`
- Build: `forge build`
- Run tests: `forge test`

### Local Setup
- Install deps once: `forge install foundry-rs/forge-std@v1.9.6 OpenZeppelin/openzeppelin-contracts@v5.0.2`
- Format code: `forge fmt` (CI enforces `forge fmt --check`)
- Foundry pinned in CI: v1.4.3 for consistent formatting

## Architecture
- CEI-first state machine in `src/Figaro.sol` with lifecycle events `SrpCreated` and `SrpStateChanged`.
- Fee model in `src/SRPFees.sol` with hard cap `MAX_FEE_BPS` and `collectFee()`.
- Mechanism integration via `src/IMechanism.sol` callback (`AddSrpPayload`).

### Core Concepts
- SRP lifecycle: create → lock (escrow) → release/refund. Batch flows are supported for efficiency.
- CEI-first ordering: internal state updates always precede external token transfers.
- Fee pull model: fees are collected via `SRPFees.collectFee()` after the caller grants allowance (no permit-first).
- Token probe: `createProcess` performs a 1-unit probe to detect fee-on-transfer tokens and reject incompatible tokens early.
- Event versioning/dedupe: consumers de-duplicate using `(srpId, versionHash)`, where `versionHash = keccak256(abi.encodePacked(creationHash, uint256(newState), coordinationCapitalBalance))`.
- Mechanism hook: `IMechanism` is notified after SRP add flows to integrate auctions/voting/reputation systems.

### Contracts
- `src/Figaro.sol`: Core state machine and SRP lifecycle events.
- `src/SRPFees.sol`: Fee math, caps, and `collectFee()` entrypoint.
- `src/IMechanism.sol`: Hook interface for mechanism integrations.

### Events and Off-chain Dedupe
Indexers should de-duplicate lifecycle events using `(srpId, versionHash)`, where `versionHash = keccak256(abi.encodePacked(creationHash, uint256(newState), coordinationCapitalBalance))`.

## Tests
Representative suites:
- Creation/Lock/Release: `test/FigaroCreateProcess.t.sol`, `test/FigaroLock.t.sol`, `test/FigaroRelease.t.sol`
- Fees/Governance: `test/SRPFees.t.sol`
- Lifecycle invariants: `test/FigaroInvariants.t.sol`

Mocks: `test/mocks/` (standard ERC20, reverting tokens, reentrant token).

## ABIs
After build, export ABIs for consumers:
```bash
forge inspect src/Figaro.sol:Figaro abi > artifacts/abi/Figaro.json
forge inspect src/SRPFees.sol:SRPFees abi > artifacts/abi/SRPFees.json
```

Prebuilt ABI JSONs are attached to each GitHub release under Assets (e.g., v1.0.1), so integrators can download without building locally.

## Integration Quickstart
- Get ABIs: download from GitHub Releases Assets (see above), or generate locally.
- Approvals: before flows that collect fees, grant ERC20 allowance to the `SRPFees` collector per your token amount.
- Consume events: de-duplicate with `(srpId, versionHash)` for idempotent indexing and state mirrors.
- See docs/integration for end-to-end steps and examples.

## Security & Stability
- CEI-first design and explicit non-reentrancy patterns in critical paths.
- CI enforces formatting (`forge fmt --check`) and runs build/tests on each PR.
- See SECURITY.md for responsible disclosure and scope.

## Further Reading
- docs/overview: what the protocol is and why it exists
- docs/architecture: contracts, data flow, and events
- docs/design-decisions: CEI-first, fee pull, token probe, event versioning
- docs/integration: step-by-step integration and event consumption

## License
MIT — see `LICENSE`.
