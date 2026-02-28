#!/usr/bin/env ./bootstrap.sh
import { $ } from "bun";
import { existsSync } from "fs";

process.env.FORCE_COLOR = "1";

const SCRIPT_DIR = import.meta.dir;

// ─── Helpers ───────────────────────────────────────────────────────────────

async function which(cmd: string): Promise<boolean> {
    const { exitCode } = await $`which ${cmd}`.quiet().nothrow();
    return exitCode === 0;
}

// ─── Prerequisites ─────────────────────────────────────────────────────────

async function ensureSubmodule() {
    if (!existsSync("libdatachannel/CMakeLists.txt")) {
        console.log("Initializing submodules...");
        await $`git submodule update --init --recursive`;
    }
}

async function ensureDeps() {
    const missing: string[] = [];

    if (!await which("pkg-config")) missing.push("pkg-config");

    // libdrm (needed by barecast-kms helper)
    const { exitCode: drmCheck } = await $`pkg-config --exists libdrm`.quiet().nothrow();
    if (drmCheck !== 0) missing.push("libdrm-dev");

    // EGL (needed by barecast for DMA-BUF import)
    const { exitCode: eglCheck } = await $`pkg-config --exists egl`.quiet().nothrow();
    if (eglCheck !== 0) missing.push("libegl-dev");

    // OpenSSL (needed by libdatachannel)
    const { exitCode: sslCheck } = await $`pkg-config --exists openssl`.quiet().nothrow();
    if (sslCheck !== 0) missing.push("libssl-dev");

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
    await ensureSubmodule();
    const ver = await version();
    console.log(`Building v${ver}...`);
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe`;
}

export async function rebuildLibs() {
    await ensureDeps();
    await ensureSubmodule();
    await ensureZigCcWrappers();
    console.log("Building libdatachannel static libs...");
    await $`zig build rebuild-libs`;
    console.log("Done. Static libs in .zig-cache/cmake/");
}

/** Create zig cc/c++ wrapper scripts for cmake. These ensure libdatachannel
 *  is built with libc++ ABI, matching Zig's native linker. */
async function ensureZigCcWrappers() {
    const dir = `${SCRIPT_DIR}/.zig-cache/bin`;
    const { stdout } = await $`which zig`.quiet();
    const zigPath = stdout.toString().trim();
    await $`mkdir -p ${dir}`;
    await Bun.write(`${dir}/zig-cc`, `#!/bin/sh\nexec ${zigPath} cc "$@"\n`);
    await Bun.write(`${dir}/zig-c++`, `#!/bin/sh\nexec ${zigPath} c++ "$@"\n`);
    await $`chmod +x ${dir}/zig-cc ${dir}/zig-c++`;
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
    // Validate no absolute RUNPATH (must be $ORIGIN or empty)
    const { stdout: rpathOut } = await $`readelf -d dist/bin/barecast 2>/dev/null`.quiet();
    const rpathLines = rpathOut.toString().split("\n").filter(l => l.includes("RUNPATH") || l.includes("RPATH"));
    const absolutePaths = rpathLines.filter(l => !l.includes("$ORIGIN") && /\/[a-zA-Z]/.test(l));
    if (absolutePaths.length > 0) {
        console.error("ERROR: binary has hardcoded absolute RUNPATH:");
        absolutePaths.forEach(l => console.error(`  ${l.trim()}`));
        process.exit(1);
    }

    // Validate no AVX-512 instructions (must be portable to x86_64_v3)
    const { stdout: objdumpOut } = await $`objdump -d dist/bin/barecast | grep -c 'zmm\\|%k[0-7],'`.quiet().nothrow();
    const avx512Count = parseInt(objdumpOut.toString().trim()) || 0;
    if (avx512Count > 0) {
        console.error(`ERROR: binary contains ${avx512Count} AVX-512 instructions (not portable)`);
        process.exit(1);
    }

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

// ─── Integration test (requires GPU) ──────────────────────────────────────

export async function integration() {
    await build();
    const testFile = "/tmp/barecast-test.ivf";
    console.log("Capturing 3s to IVF...");
    await $`timeout 10 dist/bin/barecast --record ${testFile} 3`.nothrow();

    if (!existsSync(testFile)) {
        console.error("ERROR: IVF file was not created");
        process.exit(1);
    }

    // Validate with ffprobe
    console.log("Validating with ffprobe...");
    const { stdout } = await $`ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,nb_read_frames -count_frames -of csv=p=0 ${testFile}`.quiet();
    const parts = stdout.toString().trim().split(",");
    const codec = parts[0];
    const frames = parseInt(parts[1]) || 0;

    if (codec !== "av1") {
        console.error(`ERROR: expected codec av1, got ${codec}`);
        process.exit(1);
    }
    if (frames < 10) {
        console.error(`ERROR: expected >= 10 frames, got ${frames}`);
        process.exit(1);
    }

    await $`rm -f ${testFile}`;
    console.log(`Integration test passed: ${codec}, ${frames} frames`);
}

// ─── Worker commands ───────────────────────────────────────────────────────

async function workerBuild(minify = false) {
    console.log("Building viewer TypeScript...");
    const flags = minify ? ["--minify"] : [];
    await $`bun build worker/src/viewer.ts --outdir worker/public --target=browser ${flags}`;
    await $`bun build worker/src/install.ts --outdir worker/public --target=browser ${flags}`;
    await $`bun build worker/src/sw.ts --outdir worker/public --target=browser ${flags}`;
}

export async function workerDev() {
    await workerBuild();
    await $`cd worker && bun run wrangler dev --port 8787`;
}

export async function workerDeploy() {
    await workerBuild(true);
    await $`cd worker && bun run wrangler deploy`;
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function printVersion() {
    console.log(await version());
}

const commands: Record<string, Function> = {
    dev, build, clean, setup, test, lint, dist, ci, integration, version: printVersion,
    "rebuild-libs": rebuildLibs,
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
