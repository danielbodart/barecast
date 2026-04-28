#!/usr/bin/env bun
// Post-build setup: symlink the zerocast binary into ~/.local/bin and
// ensure the user is in the groups needed for GPU + uinput access.
import { $, SCRIPT_DIR, IS_LINUX, IS_MACOS } from "./lib.ts";

const distBin = `${SCRIPT_DIR}/dist/bin`;

if (IS_LINUX) {
    console.log("Symlinking into ~/.local/bin...");
    await $`mkdir -p ~/.local/bin`;
    await $`ln -sf ${distBin}/zerocast ~/.local/bin/zerocast`;

    const { stdout } = await $`id -nG`.quiet();
    const groups = stdout.toString();
    for (const [group, reason] of [
        ["video", "GPU access"],
        ["input", "/dev/uinput access"],
    ] as const) {
        if (!groups.includes(group)) {
            console.log(`Adding user to ${group} group (${reason})...`);
            await $`sudo usermod -aG ${group} $USER`;
        }
    }

    const recordingsDir = `${SCRIPT_DIR}/recordings`;
    await $`mkdir -p ${recordingsDir}`;

    console.log("Setup complete.");
    console.log("  zerocast → ~/.local/bin/ (symlink)");
    console.log(`  recordings → ${recordingsDir}`);
    console.log("");
    console.log("To enable debug recording, set ZEROCAST_RECORD_DIR:");
    console.log(`  ZEROCAST_RECORD_DIR=${recordingsDir}`);
} else if (IS_MACOS) {
    console.log("Symlinking into ~/.local/bin...");
    await $`mkdir -p ~/.local/bin`;
    await $`ln -sf ${distBin}/zerocast ~/.local/bin/zerocast`;

    console.log("Setup complete.");
    console.log("  zerocast → ~/.local/bin/ (symlink)");
    console.log("");
    console.log("Ensure Screen Recording permission is granted in:");
    console.log("  System Settings → Privacy & Security → Screen Recording");
}
