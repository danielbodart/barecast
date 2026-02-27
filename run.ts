#!/usr/bin/env ./bootstrap.sh
import { $ } from "bun";

process.env.FORCE_COLOR = "1";

const SCRIPT_DIR = import.meta.dir;

// ─── Helpers ───────────────────────────────────────────────────────────────

async function which(cmd: string): Promise<boolean> {
    const { exitCode } = await $`which ${cmd}`.quiet().nothrow();
    return exitCode === 0;
}

// ─── Prerequisites ─────────────────────────────────────────────────────────

async function ensureDeps() {
    const missing: string[] = [];

    if (!await which("pkg-config")) missing.push("pkg-config");

    // libdrm (needed by barecast-kms helper)
    const { exitCode: drmCheck } = await $`pkg-config --exists libdrm`.quiet().nothrow();
    if (drmCheck !== 0) missing.push("libdrm-dev");

    // EGL (needed by barecast for DMA-BUF import)
    const { exitCode: eglCheck } = await $`pkg-config --exists egl`.quiet().nothrow();
    if (eglCheck !== 0) missing.push("libegl-dev");

    if (missing.length > 0) {
        console.log(`Installing missing packages: ${missing.join(", ")}`);
        await $`sudo apt install -y ${missing}`;
    }
}

// ─── Version ────────────────────────────────────────────────────────────────

async function version(): Promise<string> {
    const branch = process.env.GITHUB_REF_NAME
        || (await $`git rev-parse --abbrev-ref HEAD`.quiet()).text().trim();
    const buildNumber = process.env.GITHUB_RUN_NUMBER
        || new Date().toISOString().replace(/[-:T]/g, '').split('.')[0];
    const { exitCode, stdout } = await $`git rev-list --count ${branch}`.quiet().nothrow();
    const revisions = exitCode === 0 ? stdout.toString().trim() : "0";
    return `0.${revisions}.${buildNumber}`;
}

// ─── Commands ──────────────────────────────────────────────────────────────

export async function build() {
    await ensureDeps();
    const ver = await version();
    console.log(`Building v${ver}...`);
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe`;
}

export async function clean() {
    await $`rm -rf dist/bin .zig-cache`;
    console.log("Cleaned.");
}

export async function test() {
    await $`zig build test`;
}

export async function lint() {
    await $`zig build analyze`;
    await $`shellcheck bootstrap.sh`;
}

export async function setup() {
    await build();
    console.log("Installing barecast...");
    await $`sudo install -m 755 dist/bin/barecast /usr/local/bin/barecast`;
    await $`sudo install -m 755 dist/bin/barecast-kms /usr/local/bin/barecast-kms`;
    await $`sudo setcap cap_sys_admin+ep /usr/local/bin/barecast-kms`;

    // Ensure user is in video group
    const { stdout } = await $`id -nG`.quiet();
    if (!stdout.toString().includes("video")) {
        console.log("Adding user to video group...");
        await $`sudo usermod -aG video $USER`;
        console.log("NOTE: Log out and back in for video group to take effect.");
    }

    console.log("Setup complete.");
}

/** Default target: build + lint + unit tests. */
export async function dev() {
    await build();
    console.log("Running static analysis...");
    await $`zig build analyze`;
    console.log("Running unit + property tests...");
    await $`zig build test`;
}

export async function dist() {
    const ver = await version();
    await Bun.write("dist/VERSION", ver);
    await $`tar -czf barecast-linux-x86_64.tar.gz -C dist bin/ VERSION`;
    await $`sha256sum barecast-linux-x86_64.tar.gz > barecast-linux-x86_64.tar.gz.sha256`;
    console.log(`Tarball: barecast-linux-x86_64.tar.gz (v${ver})`);
}

export async function ci() {
    const ver = await version();
    console.log("Running static analysis...");
    await $`zig build analyze`;
    console.log("Running tests...");
    await $`zig build test`;
    console.log(`Building v${ver}...`);
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe`;
    await dist();
    if (process.env.GH_TOKEN) {
        const commitMsg = (await $`git log -1 --format=%B`.quiet()).text().trim();
        console.log(`Creating release v${ver}...`);
        await $`gh release create v${ver} barecast-linux-x86_64.tar.gz barecast-linux-x86_64.tar.gz.sha256 --title v${ver} --notes ${commitMsg}`;
    }
}

// ─── Worker commands ───────────────────────────────────────────────────────

export async function workerDev() {
    await $`cd worker && bun run wrangler dev --port 8787`;
}

export async function workerDeploy() {
    await $`cd worker && bun run wrangler deploy`;
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function printVersion() {
    console.log(await version());
}

const commands: Record<string, Function> = {
    dev, build, clean, setup, test, lint, dist, ci, version: printVersion,
    "worker-dev": workerDev,
    "worker-deploy": workerDeploy,
};

const command = process.argv[2] || "dev";
const args = process.argv.slice(3);

const fn = commands[command];
if (fn) {
    try {
        await fn(...args);
    } catch (e: any) {
        console.error(`Command failed: ${command}`, ...args);
        console.error(e.message || e);
        process.exit(1);
    }
} else {
    console.error(`Unknown command: ${command}`);
    console.error(`Available: ${Object.keys(commands).join(", ")}`);
    process.exit(1);
}
