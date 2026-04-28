// Shared helpers used by mise task scripts. These are intentionally tiny
// and side-effect-free where possible — orchestration belongs in mise.toml.
import { $ } from "bun";
import { existsSync } from "fs";

export const SCRIPT_DIR = (() => {
    const here = import.meta.dir;
    // scripts/ → repo root
    return here.endsWith("/scripts") ? here.slice(0, -"/scripts".length) : here;
})();

export const IS_LINUX = process.platform === "linux";
export const IS_MACOS = process.platform === "darwin";

export async function which(cmd: string): Promise<boolean> {
    const { exitCode } = await $`which ${cmd}`.quiet().nothrow();
    return exitCode === 0;
}

/** Compute version: 0.<commit-count>.<timestamp-or-run-number>. */
export async function version(): Promise<string> {
    const branch = process.env.GITHUB_REF_NAME
        || (await $`git rev-parse --abbrev-ref HEAD`.quiet()).text().trim();
    const buildNumber = process.env.GITHUB_RUN_NUMBER
        || new Date().toISOString().replace(/[-:T]/g, "").split(".")[0];
    const { exitCode, stdout } = await $`git rev-list --count ${branch}`.quiet().nothrow();
    const revisions = exitCode === 0 ? stdout.toString().trim() : "0";
    return `0.${revisions}.${buildNumber}`;
}

export { $, existsSync };
