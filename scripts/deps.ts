#!/usr/bin/env bun
// Installs missing system packages required to build zerocast.
// Idempotent — only invokes the package manager when something is missing.
import { $, IS_LINUX, IS_MACOS, which, existsSync } from "./lib.ts";

async function ensureLinuxDeps() {
    const missing: string[] = [];
    if (!await which("pkg-config")) missing.push("pkg-config");

    const pkgs: Array<[string, string]> = [
        ["libdrm", "libdrm-dev"],
        ["egl", "libegl-dev"],
        ["openssl", "libssl-dev"],
        ["wayland-server", "libwayland-dev"],
        ["gbm", "libgbm-dev"],
        ["xkbcommon", "libxkbcommon-dev"],
        ["pixman-1", "libpixman-1-dev"],
        ["glesv2", "libgles-dev"],
        ["libva", "libva-dev"],
        ["libva-drm", "libva-dev"],
    ];
    for (const [probe, pkg] of pkgs) {
        const { exitCode } = await $`pkg-config --exists ${probe}`.quiet().nothrow();
        if (exitCode !== 0 && !missing.includes(pkg)) missing.push(pkg);
    }

    if (!await which("cmake")) missing.push("cmake");
    if (!await which("shellcheck")) missing.push("shellcheck");
    if (!await which("objdump")) missing.push("binutils");

    if (missing.length > 0) {
        console.log(`Installing missing packages: ${missing.join(", ")}`);
        await $`sudo apt install -y ${missing}`;
    }
}

async function ensureMacosDeps() {
    const missing: string[] = [];
    if (!await which("cmake")) missing.push("cmake");
    if (!await which("pkg-config")) missing.push("pkg-config");
    if (!await which("shellcheck")) missing.push("shellcheck");

    const { exitCode: sslCheck } = await $`pkg-config --exists openssl`.quiet().nothrow();
    if (sslCheck !== 0) missing.push("openssl");

    if (missing.length > 0) {
        if (!await which("brew")) {
            throw new Error("Homebrew is required on macOS. Install from https://brew.sh");
        }
        console.log(`Installing missing packages: ${missing.join(", ")}`);
        await $`brew install ${missing}`;
    }

    const opensslPrefix = (await $`brew --prefix openssl`.quiet().nothrow()).text().trim();
    if (opensslPrefix && existsSync(`${opensslPrefix}/lib/pkgconfig`)) {
        process.env.PKG_CONFIG_PATH = `${opensslPrefix}/lib/pkgconfig${process.env.PKG_CONFIG_PATH ? `:${process.env.PKG_CONFIG_PATH}` : ""}`;
    }
}

if (IS_LINUX) await ensureLinuxDeps();
else if (IS_MACOS) await ensureMacosDeps();
else throw new Error(`Unsupported platform: ${process.platform}`);
