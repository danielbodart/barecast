#!/usr/bin/env bun
// Writes zig-cc / zig-c++ shims under .zig-cache/bin/. cmake invokes these
// when building libdatachannel + SVT-AV1 so the C/C++ ABI matches Zig's
// linker (libc++).
import { $, SCRIPT_DIR, IS_LINUX } from "./lib.ts";

const dir = `${SCRIPT_DIR}/.zig-cache/bin`;
const { stdout } = await $`which zig`.quiet();
const zigPath = stdout.toString().trim();

await $`mkdir -p ${dir}`;
const archFlag = IS_LINUX ? " -march=x86_64_v3" : "";
await Bun.write(`${dir}/zig-cc`, `#!/bin/sh\nexec ${zigPath} cc${archFlag} "$@"\n`);
await Bun.write(`${dir}/zig-c++`, `#!/bin/sh\nexec ${zigPath} c++${archFlag} "$@"\n`);
await $`chmod +x ${dir}/zig-cc ${dir}/zig-c++`;
