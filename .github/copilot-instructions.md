Figaro Protocol — Copilot Guidance (concise, actionable)

Big picture architecture
- Core contracts: `src/Figaro.sol` (CEI state machine with `SrpCreated`/`SrpStateChanged`), `src/SRPFees.sol` (fee math + `collectFee()`), `src/IMechanism.sol` (selection mechanism callback after SRP add).
- Event-driven consumers: consumers de-duplicate stream updates via `(srpId, versionHash)`.
- Formal verification: `formal-verification/` holds TLA+ specs; traces and reports live under `analysis/tla/`.
- Tests: `test/` has granular Foundry suites for core flows (lock/refund/release, batch operations, fees, reentrancy, invariants).

Quick dev loop
- Local node: `anvil --port 8545`
- Tests: `forge test`
- Build/format: `forge build` and `forge fmt`
- Coverage/analysis (optional): `scripts/run_foundry_coverage.sh`, `scripts/run_tlc.sh`

Project-specific conventions (must preserve)
- CEI-first ordering: update internal state before any external token transfer (`createProcess`, `lock`, `refund`).
- Token probe: `createProcess` sends a 1-unit probe to detect fee-on-transfer tokens — preserve this behavior.
- Fee pull model: fees are pulled via `SRPFees.collectFee(token, amount)`; callers must `approve` before flows.
- Event versioning: `versionHash = keccak256(abi.encodePacked(creationHash, uint256(newState), coordinationCapitalBalance))`; consumers de-duplicate with `(srpId, versionHash)`.

Files to read first
- Contracts: `src/Figaro.sol`, `src/SRPFees.sol`, `src/IMechanism.sol`
- Tests: `test/FigaroLock.t.sol`, `test/FigaroRelease.t.sol`, `test/FigaroCreateProcess.t.sol`, `test/SRPFees.t.sol`
- Invariants: `test/FigaroInvariants.t.sol`
- Formal specs: `formal-verification/README.md`, `formal-verification/FigaroProtocol_Simple.tla`

Editing & testing rules
- Keep changes minimal/localized; never break CEI ordering where state and transfers interact.
- Changing event shapes, ABI, or state semantics requires updating tests and TLA+ specs.
- Do not rename core tests/contracts; add `_v2` or timestamp suffix for alternates.
- Do not modify `test/FigaroInvariants.t.sol` without explicit approval.

Integration patterns
- Mechanism hook: `IMechanism` is called after SRP add flows — integrate auctions/voting/reputation via this callback.
- ABI consumption: publish JSON ABIs under `artifacts/abi/`; events are the primary integration surface.

Repo hygiene
- Do not commit analyzer outputs outside `analysis/`; CI artifacts upload from `analysis/*`.
