#!/usr/bin/env ./bootstrap.sh
import { $ } from "bun";
import { existsSync } from "fs";

process.env.FORCE_COLOR = "1";

const SCRIPT_DIR = import.meta.dir;
const IS_LINUX = process.platform === "linux";
const IS_MACOS = process.platform === "darwin";

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

async function ensureLinuxDeps() {
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

    // Wayland + wlroots deps (needed by compositor module)
    const { exitCode: waylandCheck } = await $`pkg-config --exists wayland-server`.quiet().nothrow();
    if (waylandCheck !== 0) missing.push("libwayland-dev");
    const { exitCode: gbmCheck } = await $`pkg-config --exists gbm`.quiet().nothrow();
    if (gbmCheck !== 0) missing.push("libgbm-dev");
    const { exitCode: xkbCheck } = await $`pkg-config --exists xkbcommon`.quiet().nothrow();
    if (xkbCheck !== 0) missing.push("libxkbcommon-dev");
    const { exitCode: pixmanCheck } = await $`pkg-config --exists pixman-1`.quiet().nothrow();
    if (pixmanCheck !== 0) missing.push("libpixman-1-dev");
    const { exitCode: glesCheck } = await $`pkg-config --exists glesv2`.quiet().nothrow();
    if (glesCheck !== 0) missing.push("libgles-dev");

    // VA-API (needed by vaapi encoder)
    const { exitCode: vaCheck } = await $`pkg-config --exists libva`.quiet().nothrow();
    if (vaCheck !== 0) missing.push("libva-dev");
    const { exitCode: vaDrmCheck } = await $`pkg-config --exists libva-drm`.quiet().nothrow();
    if (vaDrmCheck !== 0) missing.push("libva-dev");

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

async function ensureMacosDeps() {
    const missing: string[] = [];

    if (!await which("cmake")) missing.push("cmake");
    if (!await which("pkg-config")) missing.push("pkg-config");
    if (!await which("shellcheck")) missing.push("shellcheck");

    // OpenSSL (needed by libdatachannel)
    const { exitCode: sslCheck } = await $`pkg-config --exists openssl`.quiet().nothrow();
    if (sslCheck !== 0) missing.push("openssl");

    if (missing.length > 0) {
        if (!await which("brew")) {
            throw new Error("Homebrew is required on macOS. Install from https://brew.sh");
        }
        console.log(`Installing missing packages: ${missing.join(", ")}`);
        await $`brew install ${missing}`;
    }

    // Ensure pkg-config can find Homebrew's OpenSSL
    const opensslPrefix = (await $`brew --prefix openssl`.quiet().nothrow()).text().trim();
    if (opensslPrefix && existsSync(`${opensslPrefix}/lib/pkgconfig`)) {
        process.env.PKG_CONFIG_PATH = `${opensslPrefix}/lib/pkgconfig${process.env.PKG_CONFIG_PATH ? `:${process.env.PKG_CONFIG_PATH}` : ""}`;
    }
}

async function ensureDeps() {
    if (IS_LINUX) return ensureLinuxDeps();
    if (IS_MACOS) return ensureMacosDeps();
    throw new Error(`Unsupported platform: ${process.platform}`);
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
    const cpuFlag = IS_LINUX ? ["-Dcpu=x86_64_v3"] : [];
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSafe ${cpuFlag}`;
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
    const archFlag = IS_LINUX ? " -march=x86_64_v3" : "";
    await Bun.write(`${dir}/zig-cc`, `#!/bin/sh\nexec ${zigPath} cc${archFlag} "$@"\n`);
    await Bun.write(`${dir}/zig-c++`, `#!/bin/sh\nexec ${zigPath} c++${archFlag} "$@"\n`);
    await $`chmod +x ${dir}/zig-cc ${dir}/zig-c++`;
}

export async function clean() {
    await $`rm -rf dist/bin .zig-cache`;
    console.log("Cleaned.");
}

export async function test() {
    await $`zig build test`;
}

async function compositorTest() {
    await $`zig build compositor-test -- 2>&1`;
}

export async function lint() {
    await $`zig build analyze`;
    await $`shellcheck bootstrap.sh`;
}

export async function setup() {
    await build();
    const distBin = `${SCRIPT_DIR}/dist/bin`;

    if (IS_LINUX) {
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
        ] as const) {
            if (!groups.includes(group)) {
                console.log(`Adding user to ${group} group (${reason})...`);
                await $`sudo usermod -aG ${group} $USER`;
            }
        }

        // Set capabilities on zerocast-kms
        console.log("Setting capabilities on zerocast-kms...");
        await $`sudo setcap cap_sys_admin+ep ${distBin}/zerocast-kms`;

        // Allow passwordless sudo for setcap on zerocast-kms.
        const user = (await $`whoami`.quiet()).text().trim();
        const sudoersRule = `${user} ALL=(root) NOPASSWD: /usr/sbin/setcap cap_sys_admin+ep *`;
        console.log("Installing sudoers rule for passwordless helper updates...");
        await $`echo ${sudoersRule} | sudo tee /etc/sudoers.d/zerocast > /dev/null`;
        await $`sudo chmod 440 /etc/sudoers.d/zerocast`;

        // Create recordings directory (for debug recording)
        const recordingsDir = `${SCRIPT_DIR}/recordings`;
        await $`mkdir -p ${recordingsDir}`;

        console.log("Setup complete.");
        console.log("  zerocast, zerocast-kms → ~/.local/bin/ (symlinks)");
        console.log(`  recordings → ${recordingsDir}`);
        console.log("");
        console.log("To enable debug recording, set ZEROCAST_RECORD_DIR:");
        console.log(`  ZEROCAST_RECORD_DIR=${recordingsDir}`);
    } else if (IS_MACOS) {
        // Symlink into ~/.local/bin
        console.log("Symlinking into ~/.local/bin...");
        await $`mkdir -p ~/.local/bin`;
        await $`ln -sf ${distBin}/zerocast ~/.local/bin/zerocast`;

        console.log("Setup complete.");
        console.log("  zerocast → ~/.local/bin/ (symlink)");
        console.log("");
        console.log("Ensure Screen Recording permission is granted in:");
        console.log("  System Settings → Privacy & Security → Screen Recording");
    }
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
    if (IS_LINUX) {
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
    }

    // Copy dist scripts into tarball staging area
    for (const script of ["install.sh", "zerocast-update.sh", "zerocast-apply-update.sh", "zerocast-rollback.sh"]) {
        if (existsSync(`dist/${script}`)) continue;
        await $`cp dist-src/${script} dist/${script}`.nothrow();
    }

    const ver = await version();
    await Bun.write("dist/VERSION", ver);

    const arch = IS_MACOS ? "arm64" : "x86_64";
    const os = IS_MACOS ? "macos" : "linux";
    const tarball = `zerocast-${os}-${arch}.tar.gz`;
    await $`tar -czf ${tarball} -C dist bin/ VERSION install.sh zerocast-update.sh zerocast-apply-update.sh zerocast-rollback.sh`;
    await $`sha256sum ${tarball} > ${tarball}.sha256`.nothrow(); // sha256sum may not exist on macOS
    if (IS_MACOS) await $`shasum -a 256 ${tarball} > ${tarball}.sha256`.nothrow();
    console.log(`Tarball: ${tarball} (v${ver})`);
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
    const cpuFlag = IS_LINUX ? ["-Dcpu=x86_64_v3"] : [];
    await $`zig build --prefix dist -Dversion=${ver} -Doptimize=ReleaseSmall ${cpuFlag}`;
    await dist();

    // Worker: install deps, build viewer TS, deploy to production
    console.log("Deploying worker to production...");
    await $`cd worker && bun install`;
    await workerBuild(true);
    await $`cd worker && bun run wrangler deploy --env production`;

    // GitHub release
    if (process.env.GH_TOKEN) {
        const commitMsg = (await $`git log -1 --format=%B`.quiet()).text().trim();
        const arch = IS_MACOS ? "arm64" : "x86_64";
        const os = IS_MACOS ? "macos" : "linux";
        const tarball = `zerocast-${os}-${arch}.tar.gz`;
        console.log(`Creating release v${ver}...`);
        await $`gh release create v${ver} ${tarball} ${tarball}.sha256 --title v${ver} --notes ${commitMsg}`;
    }
}

// ─── Integration test (requires GPU on Linux, Screen Recording on macOS) ──

export async function integration() {
    await build();
    const testFile = "/tmp/zerocast-test.ivf";
    console.log("Capturing 3s to video...");
    await $`timeout 10 dist/bin/zerocast --record ${testFile} 3`.nothrow();

    if (!existsSync(testFile)) {
        console.error("ERROR: recording file was not created");
        process.exit(1);
    }

    // Validate with ffprobe
    console.log("Validating with ffprobe...");
    const { stdout } = await $`ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,nb_read_frames -count_frames -of csv=p=0 ${testFile}`.quiet();
    const parts = stdout.toString().trim().split(",");
    const codec = parts[0];
    const frames = parseInt(parts[1]) || 0;

    const validCodecs = ["av1", "hevc"];
    if (!validCodecs.includes(codec)) {
        console.error(`ERROR: expected codec av1 or hevc, got ${codec}`);
        process.exit(1);
    }
    if (frames < 10) {
        console.error(`ERROR: expected >= 10 frames, got ${frames}`);
        process.exit(1);
    }

    await $`rm -f ${testFile}`;
    console.log(`Integration test passed: ${codec}, ${frames} frames`);
}

/// Validate HEVC bitstream: record raw .h265, remux to MP4, check for decode errors.
/// Requires: ffmpeg, ffprobe, and a running daemon with Intel GPU.
/// Usage: ZEROCAST_RECORD_DIR=/tmp/zerocast-rec ./run.ts hevc-validate <h265-file>
///   or:  ./run.ts hevc-validate  (uses first .h265 in ZEROCAST_RECORD_DIR)
export async function hevcValidate() {
    if (!await which("ffmpeg")) { console.log("SKIP: ffmpeg not found"); return; }
    if (!await which("ffprobe")) { console.log("SKIP: ffprobe not found"); return; }

    const arg = process.argv[3];
    const recordDir = process.env.ZEROCAST_RECORD_DIR || "/tmp/zerocast-rec";
    let h265File = arg;

    if (!h265File) {
        const { stdout } = await $`ls -t ${recordDir}/*.h265 2>/dev/null`.quiet().nothrow();
        h265File = stdout.toString().trim().split("\n")[0];
        if (!h265File) {
            console.error(`ERROR: no .h265 files found in ${recordDir}`);
            console.error("Record first: ZEROCAST_RECORD_DIR=/tmp/zerocast-rec dist/bin/zerocast daemon");
            process.exit(1);
        }
    }

    if (!existsSync(h265File)) {
        console.error(`ERROR: file not found: ${h265File}`);
        process.exit(1);
    }

    console.log(`Validating: ${h265File}`);
    const mp4File = "/tmp/zerocast-hevc-test.mp4";

    // Remux to MP4 (first 5 seconds)
    await $`ffmpeg -y -f hevc -framerate 30 -i ${h265File} -c copy -t 5 ${mp4File}`.quiet();

    // Check for decode errors with ffprobe
    const probeResult = await $`ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,nb_read_frames -count_frames -of csv=p=0 ${mp4File}`.quiet();
    const parts = probeResult.stdout.toString().trim().split(",");
    const codec = parts[0];
    const frames = parseInt(parts[1]) || 0;

    if (codec !== "hevc") {
        console.error(`ERROR: expected codec hevc, got ${codec}`);
        process.exit(1);
    }
    if (frames < 10) {
        console.error(`ERROR: expected >= 10 frames, got ${frames}`);
        process.exit(1);
    }

    // Decode all frames and check for errors (ffmpeg -v error prints nothing on success)
    const decodeResult = await $`ffmpeg -v error -i ${mp4File} -f null - 2>&1`.quiet().nothrow();
    // Filter out non-monotonic DTS warnings (harmless remux artifact from raw .h265)
    const errors = decodeResult.stdout.toString().trim().split("\n")
        .filter(l => l.trim().length > 0 && !l.includes("non monotonically increasing dts") && !l.includes("Last message repeated"))
        .join("\n");
    if (errors.length > 0) {
        console.error(`ERROR: decode errors:\n${errors}`);
        process.exit(1);
    }

    await $`rm -f ${mp4File}`;
    console.log(`HEVC validation passed: ${codec}, ${frames} frames, 0 decode errors`);
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
    "compositor-test": compositorTest,
    "rebuild-libs": rebuildLibs, "hevc-validate": hevcValidate,
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
