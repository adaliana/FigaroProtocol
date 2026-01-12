# @adaliana/figaro-abis

Prebuilt ABIs for the Figaro protocol contracts.

- Contracts: Figaro, SRPFees
- Files: dist/abi/Figaro.json, dist/abi/SRPFees.json (Foundry artifact JSONs with an `abi` array)

## Build

This package expects to live inside the FigaroProtocol repo (monorepo style).

```
# from packages/figaro-abis
npm run build
# outputs to dist/abi/
```

## Publish

```
npm version patch
npm publish --access public
```

## Consume

- Direct file import
- Or via client sync scripts that expect either a pure `abi` array or an object with `abi` field.

Example (external sync):
```
ABIS_PACKAGE=@adaliana/figaro-abis \
ABIS_PACKAGE_FIGARO=dist/abi/Figaro.json \
ABIS_PACKAGE_SRPFEES=dist/abi/SRPFees.json \
node scripts/sync-abis.js
```