#!/usr/bin/env bun
// CI-only: creates a GitHub release from the freshly-built tarball. Skips
// silently if GH_TOKEN is unset (so it's safe to wire into local `ci` too).
import { $, IS_MACOS, version } from "./lib.ts";

if (!process.env.GH_TOKEN) {
    console.log("GH_TOKEN unset — skipping release.");
    process.exit(0);
}

const ver = await version();
const commitMsg = (await $`git log -1 --format=%B`.quiet()).text().trim();
const arch = IS_MACOS ? "arm64" : "x86_64";
const os = IS_MACOS ? "macos" : "linux";
const tarball = `zerocast-${os}-${arch}.tar.gz`;
console.log(`Creating release v${ver}...`);
await $`gh release create v${ver} ${tarball} ${tarball}.sha256 --title v${ver} --notes ${commitMsg}`;
