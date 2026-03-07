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
        const mainWorktree = (await $`git worktree list`.quiet()).text().split("\n")[0]?.split(/\s+/)[0];
        const mainSubmodule = mainWorktree ? `${mainWorktree}/libdatachannel` : null;
        const isWorktree = mainSubmodule && mainWorktree !== SCRIPT_DIR;
        if (isWorktree && existsSync(`${mainSubmodule}/CMakeLists.txt`)) {
            // In a worktree, use `git worktree add` on each submodule instead of cloning.
            // This shares the object store with the main repo's submodules (~250MB saved).
            console.log("Creating submodule worktrees from main repo...");
            const submodules = (await $`git -C ${mainSubmodule} submodule status`.quiet())
                .text().trim().split("\n").map(line => line.trim().split(/\s+/));
            const commit = (await $`git -C ${mainSubmodule} rev-parse HEAD`.quiet()).text().trim();
            await $`git -C ${mainSubmodule} worktree add --detach ${SCRIPT_DIR}/libdatachannel ${commit}`;
            for (const [depCommit, depPath] of submodules) {
                await $`git -C ${mainSubmodule}/${depPath} worktree add --detach ${SCRIPT_DIR}/libdatachannel/${depPath} ${depCommit}`;
            }

        } else {
            console.log("Initializing submodules...");
            await $`git submodule update --init --recursive`;
        }
    }
}

async function ensureDeps() {
    const missing: string[] = [];

    if (!await which("pkg-config")) missing.push("pkg-config");

    // libdrm (needed by zerocast-kms helper)
    const { exitCode: drmCheck } = await $`pkg-config --exists libdrm`.quiet().nothrow();
    if (drmCheck !== 0) missing.push("libdrm-dev");

    // EGL (needed by zerocast for DMA-BUF import)
    const { exitCode: eglCheck } = await $`pkg-config --exists egl`.quiet().nothrow();
    if (eglCheck !== 0) missing.push("libegl-dev");

    // OpenSSL (needed by libdatachannel)
    const { exitCode: sslCheck } = await $`pkg-config --exists openssl`.quiet().nothrow();
    if (sslCheck !== 0) missing.push("libssl-dev");

    // X11 + GL (needed by nvfbc module for GLX context)
    const { exitCode: x11Check } = await $`pkg-config --exists x11`.quiet().nothrow();
    if (x11Check !== 0) missing.push("libx11-dev");
    const { exitCode: glCheck } = await $`pkg-config --exists gl`.quiet().nothrow();
    if (glCheck !== 0) missing.push("libgl-dev");

    // XTEST (needed by xtest_input for app sharing)
    const { exitCode: xtstCheck } = await $`pkg-config --exists xtst`.quiet().nothrow();
    if (xtstCheck !== 0) missing.push("libxtst-dev");

    // cmake (needed to build libdatachannel)
    if (!await which("cmake")) missing.push("cmake");

    // shellcheck (needed by lint)
    if (!await which("shellcheck")) missing.push("shellcheck");

    // binutils (readelf + objdump, needed by dist validation)
    if (!await which("objdump")) missing.push("binutils");

    if (missing.length > 0) {
        console.log(`Installing missing packages: ${missing.join(", ")}`);
        await $`sudo apt install -y ${missing}`;
    }
}

/** In a worktree, copy pre-built cmake libs from the main repo to avoid a full rebuild. */
async function ensureCmakeLibs() {
    if (existsSync(".zig-cache/cmake/libdatachannel.a")) return;
    const mainWorktree = (await $`git worktree list`.quiet()).text().split("\n")[0]?.split(/\s+/)[0];
    if (!mainWorktree || mainWorktree === SCRIPT_DIR) return;
    const mainCmake = `${mainWorktree}/.zig-cache/cmake`;
    if (!existsSync(`${mainCmake}/libdatachannel.a`)) return;
    console.log("Copying pre-built static libs from main repo...");
    await $`cp -r ${mainCmake} .zig-cache/cmake`;
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
    await ensureCmakeLibs();
    const ver = await version();
    console.log(`Building v${ver}...`);
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe -Dcpu=x86_64_v3`;
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
    await Bun.write(`${dir}/zig-cc`, `#!/bin/sh\nexec ${zigPath} cc -march=x86-64-v3 "$@"\n`);
    await Bun.write(`${dir}/zig-c++`, `#!/bin/sh\nexec ${zigPath} c++ -march=x86-64-v3 "$@"\n`);
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
    const distBin = `${SCRIPT_DIR}/dist/bin`;

    // Symlink unprivileged binaries into ~/.local/bin
    console.log("Symlinking into ~/.local/bin...");
    await $`mkdir -p ~/.local/bin`;
    await $`ln -sf ${distBin}/zerocast ~/.local/bin/zerocast`;
    await $`ln -sf ${distBin}/zerocast-kms ~/.local/bin/zerocast-kms`;

    // Ensure user is in required groups
    const { stdout } = await $`id -nG`.quiet();
    const groups = stdout.toString();
    for (const [group, reason] of [
        ["video", "GPU access"],
        ["input", "/dev/uinput access"],
        ["tty", "VT access for headless Xorg"],
    ] as const) {
        if (!groups.includes(group)) {
            console.log(`Adding user to ${group} group (${reason})...`);
            await $`sudo usermod -aG ${group} $USER`;
        }
    }

    // Set capabilities on zerocast-kms
    console.log("Setting capabilities on zerocast-kms...");
    await $`sudo setcap cap_sys_admin+ep ${distBin}/zerocast-kms`;

    // Install setuid helper to /usr/local/bin (must be on a non-nosuid filesystem).
    // Home directories on eCryptfs/overlayfs ignore setuid bits.
    console.log("Installing zerocast-xorg to /usr/local/bin (setuid root)...");
    await $`sudo cp ${distBin}/zerocast-xorg /usr/local/bin/zerocast-xorg`;
    await $`sudo chown root:root /usr/local/bin/zerocast-xorg`;
    await $`sudo chmod u+s /usr/local/bin/zerocast-xorg`;

    // Allow passwordless sudo for auto-update of privileged helpers.
    // The apply-update script runs as ExecStartPre (unprivileged) and
    // needs to copy the xorg helper + set capabilities without prompting.
    const user = (await $`whoami`.quiet()).text().trim();
    const sudoersRule = `${user} ALL=(root) NOPASSWD: /usr/bin/cp * /usr/local/bin/zerocast-xorg, /usr/bin/chown root\\:root /usr/local/bin/zerocast-xorg, /usr/bin/chmod u+s /usr/local/bin/zerocast-xorg, /usr/sbin/setcap cap_sys_admin+ep *`;
    console.log("Installing sudoers rule for passwordless helper updates...");
    await $`echo ${sudoersRule} | sudo tee /etc/sudoers.d/zerocast > /dev/null`;
    await $`sudo chmod 440 /etc/sudoers.d/zerocast`;

    console.log("Setup complete.");
    console.log("  zerocast, zerocast-kms → ~/.local/bin/ (symlinks)");
    console.log("  zerocast-xorg → /usr/local/bin/ (setuid root)");
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
    const { stdout: rpathOut } = await $`readelf -d dist/bin/zerocast 2>/dev/null`.quiet();
    const rpathLines = rpathOut.toString().split("\n").filter(l => l.includes("RUNPATH") || l.includes("RPATH"));
    const absolutePaths = rpathLines.filter(l => !l.includes("$ORIGIN") && /\/[a-zA-Z]/.test(l));
    if (absolutePaths.length > 0) {
        console.error("ERROR: binary has hardcoded absolute RUNPATH:");
        absolutePaths.forEach(l => console.error(`  ${l.trim()}`));
        process.exit(1);
    }

    // Validate no AVX-512 instructions (must be portable to x86_64_v3)
    const { stdout: objdumpOut } = await $`objdump -d dist/bin/zerocast | grep -c 'zmm\\|%k[0-7],'`.quiet().nothrow();
    const avx512Count = parseInt(objdumpOut.toString().trim()) || 0;
    if (avx512Count > 0) {
        console.error(`ERROR: binary contains ${avx512Count} AVX-512 instructions (not portable)`);
        process.exit(1);
    }

    // Copy dist scripts into tarball staging area
    for (const script of ["install.sh", "zerocast-update.sh", "zerocast-apply-update.sh", "zerocast-rollback.sh"]) {
        if (existsSync(`dist/${script}`)) continue;
        await $`cp dist-src/${script} dist/${script}`.nothrow();
    }

    const ver = await version();
    await Bun.write("dist/VERSION", ver);
    await $`tar -czf zerocast-linux-x86_64.tar.gz -C dist bin/ VERSION install.sh zerocast-update.sh zerocast-apply-update.sh zerocast-rollback.sh`;
    await $`sha256sum zerocast-linux-x86_64.tar.gz > zerocast-linux-x86_64.tar.gz.sha256`;
    console.log(`Tarball: zerocast-linux-x86_64.tar.gz (v${ver})`);
}

export async function install() {
    await build();
    // Copy dist scripts alongside binaries
    for (const script of ["install.sh", "zerocast-update.sh", "zerocast-apply-update.sh", "zerocast-rollback.sh"]) {
        await $`cp dist/${script} dist/${script}`.nothrow();
    }
    console.log("Running installer...");
    await $`bash dist/install.sh`;
}

export async function ci() {
    await ensureDeps();
    await ensureSubmodule();

    // Build libdatachannel static libs if not cached
    if (!existsSync(".zig-cache/cmake/libdatachannel.a")) {
        await ensureZigCcWrappers();
        console.log("Building libdatachannel static libs...");
        await $`zig build rebuild-libs`;
    }

    const ver = await version();

    console.log("Running static analysis...");
    await $`zig build analyze`;
    await $`shellcheck bootstrap.sh`;

    console.log("Running tests...");
    await $`zig build test`;

    console.log(`Building v${ver}...`);
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe -Dcpu=x86_64_v3`;
    await dist();

    // Worker: install deps, build viewer TS, deploy to production
    console.log("Deploying worker to production...");
    await $`cd worker && bun install`;
    await workerBuild(true);
    await $`cd worker && bun run wrangler deploy --env production`;

    // GitHub release
    if (process.env.GH_TOKEN) {
        const commitMsg = (await $`git log -1 --format=%B`.quiet()).text().trim();
        console.log(`Creating release v${ver}...`);
        await $`gh release create v${ver} zerocast-linux-x86_64.tar.gz zerocast-linux-x86_64.tar.gz.sha256 --title v${ver} --notes ${commitMsg}`;
    }
}

// ─── Integration test (requires GPU) ──────────────────────────────────────

export async function integration() {
    await build();
    const testFile = "/tmp/zerocast-test.ivf";
    console.log("Capturing 3s to IVF...");
    await $`timeout 10 dist/bin/zerocast --record ${testFile} 3`.nothrow();

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
    await $`bun build worker/src/terminal-viewer.ts --outdir worker/public --target=browser ${flags}`;
    await $`bun build worker/src/hub.ts --outdir worker/public --target=browser ${flags}`;
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

export async function workerPromote() {
    await workerBuild(true);
    await $`cd worker && bun run wrangler deploy --env production`;
}

// ─── Command dispatch ──────────────────────────────────────────────────────

async function printVersion() {
    console.log(await version());
}

const commands: Record<string, Function> = {
    dev, build, clean, setup, test, lint, dist, ci, integration, install, version: printVersion,
    "rebuild-libs": rebuildLibs,
    "worker-dev": workerDev,
    "worker-deploy": workerDeploy,
    "worker-promote": workerPromote,
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
