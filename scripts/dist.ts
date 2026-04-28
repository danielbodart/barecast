#!/usr/bin/env bun
// Packages the build output into a release tarball. On Linux, validates
// RUNPATH and AVX-512 portability before packaging.
import { $, IS_LINUX, IS_MACOS, version, existsSync } from "./lib.ts";

if (IS_LINUX) {
    const { stdout: rpathOut } = await $`readelf -d dist/bin/zerocast 2>/dev/null`.quiet();
    const rpathLines = rpathOut.toString().split("\n").filter(l => l.includes("RUNPATH") || l.includes("RPATH"));
    const absolutePaths = rpathLines.filter(l => !l.includes("$ORIGIN") && /\/[a-zA-Z]/.test(l));
    if (absolutePaths.length > 0) {
        console.error("ERROR: binary has hardcoded absolute RUNPATH:");
        absolutePaths.forEach(l => console.error(`  ${l.trim()}`));
        process.exit(1);
    }

    const { stdout: objdumpOut } = await $`objdump -d dist/bin/zerocast | grep -c 'zmm\\|%k[0-7],'`.quiet().nothrow();
    const avx512Count = parseInt(objdumpOut.toString().trim()) || 0;
    if (avx512Count > 0) {
        console.error(`ERROR: binary contains ${avx512Count} AVX-512 instructions (not portable)`);
        process.exit(1);
    }
}

for (const script of ["install.sh", "zerocast-update.sh", "zerocast-apply-update.sh", "zerocast-rollback.sh"]) {
    if (existsSync(`dist/${script}`)) continue;
    await $`cp dist-src/${script} dist/${script}`.nothrow();
}

const ver = await version();
await Bun.write("dist/VERSION", ver);

const arch = IS_MACOS ? "arm64" : "x86_64";
const os = IS_MACOS ? "macos" : "linux";
const tarball = `zerocast-${os}-${arch}.tar.gz`;
await $`tar -czf ${tarball} -C dist bin/ VERSION install.sh zerocast-update.sh zerocast-apply-update.sh zerocast-rollback.sh`;
await $`sha256sum ${tarball} > ${tarball}.sha256`.nothrow();
if (IS_MACOS) await $`shasum -a 256 ${tarball} > ${tarball}.sha256`.nothrow();
console.log(`Tarball: ${tarball} (v${ver})`);
