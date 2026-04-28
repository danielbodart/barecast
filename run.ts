#!/usr/bin/env ./bootstrap.sh
// Convenience wrapper around `mise run`. mise (.mise.toml) is the actual
// build engine — it handles dependency ordering, parallelism, and
// skip-if-fresh. This script keeps the familiar `./run.ts <cmd>` surface
// so users don't need to learn mise.
//
// Anything not explicitly mapped below is forwarded straight through, so
// `./run.ts <task> <args>` works for any task in .mise.toml.
import { spawn } from "bun";

process.env.FORCE_COLOR = "1";

// Aliases: short developer-facing name → mise task name. mise tasks use
// `:` to namespace (libs:datachannel, worker:build); we keep the legacy
// hyphenated names available as a courtesy.
const aliases: Record<string, string> = {
    "rebuild-libs": "libs",
    "worker-dev": "worker:dev",
    "worker-deploy": "worker:deploy",
    "worker-promote": "worker:promote",
};

const command = process.argv[2] || "dev";
const args = process.argv.slice(3);
const task = aliases[command] ?? command;

if (command === "--help" || command === "-h" || command === "help") {
    console.log("Usage: ./run.ts <task> [args...]");
    console.log("");
    console.log("Common tasks:");
    console.log("  dev          build + lint + test (default)");
    console.log("  build        build the zerocast binary");
    console.log("  test         run unit + property tests");
    console.log("  lint         static analysis + shellcheck");
    console.log("  clean        delete build outputs");
    console.log("  setup        first-time setup (build + symlink + groups)");
    console.log("  ci           full CI pipeline");
    console.log("  integration  end-to-end recording test (requires GPU)");
    console.log("  worker:dev   run worker locally on :8787");
    console.log("");
    console.log("List all tasks:    mise tasks");
    console.log("Show dep graph:    mise tasks deps <task>");
    process.exit(0);
}

const proc = spawn(["mise", "run", task, ...args], {
    stdio: ["inherit", "inherit", "inherit"],
});
const code = await proc.exited;
process.exit(code);
