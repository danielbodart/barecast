#!/usr/bin/env bun
// Initializes git submodules. In worktrees, shares the main repo's submodule
// object store via `git worktree add` (saves ~250MB per worktree).
import { $, SCRIPT_DIR, existsSync } from "./lib.ts";

const sentinels = [
    "packages/libdatachannel/CMakeLists.txt",
    "packages/svt-av1/CMakeLists.txt",
    "packages/wlroots/meson.build",
];

if (sentinels.every(p => existsSync(p))) process.exit(0);

const mainWorktree = (await $`git worktree list`.quiet()).text().split("\n")[0]?.split(/\s+/)[0];
const isWorktree = mainWorktree && mainWorktree !== SCRIPT_DIR;
const mainHasSubs = isWorktree
    && sentinels.every(p => existsSync(`${mainWorktree}/${p}`));

if (isWorktree && mainHasSubs) {
    console.log("Creating submodule worktrees from main repo...");
    for (const sentinel of sentinels) {
        const subPath = sentinel.split("/").slice(0, -1).join("/");
        if (existsSync(sentinel)) continue;
        const mainSub = `${mainWorktree}/${subPath}`;
        const commit = (await $`git -C ${mainSub} rev-parse HEAD`.quiet()).text().trim();
        await $`git -C ${mainSub} worktree add --detach ${SCRIPT_DIR}/${subPath} ${commit}`;
        // Recursive submodules under this submodule (e.g. libdatachannel/deps/*)
        const nested = (await $`git -C ${mainSub} submodule status`.quiet()).text().trim();
        if (nested) {
            for (const line of nested.split("\n")) {
                const [depCommit, depPath] = line.trim().split(/\s+/);
                await $`git -C ${mainSub}/${depPath} worktree add --detach ${SCRIPT_DIR}/${subPath}/${depPath} ${depCommit}`;
            }
        }
    }
} else {
    console.log("Initializing submodules...");
    await $`git submodule update --init --recursive`;
}
