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
