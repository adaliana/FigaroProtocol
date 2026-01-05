# Figaro Protocol

[![CI](https://github.com/adaliana/FigaroProtocol/actions/workflows/ci.yml/badge.svg)](https://github.com/adaliana/FigaroProtocol/actions/workflows/ci.yml)

The Figaro Protocol provides cryptoeconomic coordination primitives for peer-to-peer marketplaces.

This repository contains protocol source code and tests only.

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

## License
MIT — see `LICENSE`.
