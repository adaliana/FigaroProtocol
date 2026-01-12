#!/usr/bin/env node
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function sh(cmd, opts = {}) {
    console.log(`[build] $ ${cmd}`);
    execSync(cmd, { stdio: 'inherit', ...opts });
}

function ensureDir(p) {
    if (!fs.existsSync(p)) fs.mkdirSync(p, { recursive: true });
}

(function main() {
    // Repo root is two levels up from this script: packages/figaro-abis/scripts
    const repoRoot = path.resolve(__dirname, '..', '..', '..');
    const outDir = path.join(repoRoot, 'out');
    const distDir = path.resolve(__dirname, '..', 'dist', 'abi');
    ensureDir(distDir);

    // Ensure artifacts exist
    sh('forge build', { cwd: repoRoot });

    // Copy artifact JSONs (full Foundry artifacts containing abi arrays)
    const sources = [
        { src: path.join(outDir, 'Figaro.sol', 'Figaro.json'), name: 'Figaro.json' },
        { src: path.join(outDir, 'SRPFees.sol', 'SRPFees.json'), name: 'SRPFees.json' },
    ];

    for (const s of sources) {
        if (!fs.existsSync(s.src)) {
            console.error(`[build] Missing artifact: ${s.src}`);
            process.exit(1);
        }
        const dst = path.join(distDir, s.name);
        fs.copyFileSync(s.src, dst);
        console.log(`[build] Wrote ${dst}`);
    }

    console.log('[build] ABI export complete.');
})();
