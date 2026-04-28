#!/usr/bin/env bun
// Post-build setup: symlink binaries into ~/.local/bin, ensure user is in
// required groups, and grant CAP_SYS_ADMIN to zerocast-kms (Linux only).
import { $, SCRIPT_DIR, IS_LINUX, IS_MACOS } from "./lib.ts";

const distBin = `${SCRIPT_DIR}/dist/bin`;

if (IS_LINUX) {
    console.log("Symlinking into ~/.local/bin...");
    await $`mkdir -p ~/.local/bin`;
    await $`ln -sf ${distBin}/zerocast ~/.local/bin/zerocast`;
    await $`ln -sf ${distBin}/zerocast-kms ~/.local/bin/zerocast-kms`;

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

    console.log("Setting capabilities on zerocast-kms...");
    await $`sudo setcap cap_sys_admin+ep ${distBin}/zerocast-kms`;

    const user = (await $`whoami`.quiet()).text().trim();
    const sudoersRule = `${user} ALL=(root) NOPASSWD: /usr/sbin/setcap cap_sys_admin+ep *`;
    console.log("Installing sudoers rule for passwordless helper updates...");
    await $`echo ${sudoersRule} | sudo tee /etc/sudoers.d/zerocast > /dev/null`;
    await $`sudo chmod 440 /etc/sudoers.d/zerocast`;

    const recordingsDir = `${SCRIPT_DIR}/recordings`;
    await $`mkdir -p ${recordingsDir}`;

    console.log("Setup complete.");
    console.log("  zerocast, zerocast-kms → ~/.local/bin/ (symlinks)");
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
