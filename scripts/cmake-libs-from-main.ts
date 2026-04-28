#!/usr/bin/env bun
// In a worktree, copy pre-built static libs from the main repo's cache to
// avoid multi-minute rebuilds. No-op outside worktrees or if libs are
// already present.
import { $, SCRIPT_DIR, existsSync } from "./lib.ts";

const mainWorktree = (await $`git worktree list`.quiet()).text().split("\n")[0]?.split(/\s+/)[0];
if (!mainWorktree || mainWorktree === SCRIPT_DIR) process.exit(0);

// libdatachannel (cmake build dir lives under .zig-cache/cmake)
if (!existsSync(".zig-cache/cmake/libdatachannel.a")) {
    const mainCmake = `${mainWorktree}/.zig-cache/cmake`;
    if (existsSync(`${mainCmake}/libdatachannel.a`)) {
        console.log("Copying libdatachannel from main repo...");
        await $`mkdir -p .zig-cache`;
        await $`cp -r ${mainCmake} .zig-cache/cmake`;
    }
}

// SVT-AV1 (cmake writes the static lib into the source tree's Bin/)
if (!existsSync("packages/svt-av1/Bin/Release/libSvtAv1Enc.a")) {
    const mainSvt = `${mainWorktree}/packages/svt-av1/Bin/Release/libSvtAv1Enc.a`;
    if (existsSync(mainSvt)) {
        console.log("Copying SVT-AV1 lib from main repo...");
        await $`mkdir -p packages/svt-av1/Bin/Release`;
        await $`cp ${mainSvt} packages/svt-av1/Bin/Release/`;
    }
}
