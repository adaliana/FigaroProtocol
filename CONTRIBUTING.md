Contributing Guide

Thanks for your interest in contributing to Figaro Protocol!

Quick start
- Use macOS or Linux with Foundry installed.
- Solidity version is pinned in foundry.toml (0.8.30).
- Dependencies are vendored in `lib/` and installed via `forge install`.

Setup
```bash
# Install Foundry toolchain
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge --version
forge clean
rm -rf lib && forge install --no-commit foundry-rs/forge-std@v1.9.6 OpenZeppelin/openzeppelin-contracts@v5.0.2

# Build & test
forge build
forge test -vv
```

Coding conventions
- Preserve CEI ordering in all state/transfer interactions.
- Do not change event shapes or state semantics without updating tests and docs.
- Keep changes minimal and localized; avoid renaming core contracts or tests.
- Use `forge fmt` for formatting.

PR checklist
- `forge fmt` applied (or `forge fmt --check` passes).
- `forge build` and `forge test` pass.
- If ABI-impacting changes, update ABIs and README instructions.
- Consider updating the GitHub Release if user-facing.

Security
- Report vulnerabilities privately; see SECURITY.md.

License
- MIT. By contributing, you agree your contributions are licensed under the repository license.
