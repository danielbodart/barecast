#!/usr/bin/env bun
// Bundles the worker's browser-side TypeScript entry points. Pass --minify
// to produce production builds.
import { $ } from "./lib.ts";

const minify = process.argv.includes("--minify");
const flags = minify ? ["--minify"] : [];
const entries = ["viewer", "terminal-viewer", "hub", "install", "sw"];
console.log(`Building viewer TypeScript${minify ? " (minified)" : ""}...`);
for (const e of entries) {
    await $`bun build packages/worker/src/${e}.ts --outdir packages/worker/public --target=browser ${flags}`;
}
