#!/usr/bin/env bun
// Prints the computed version string to stdout. Used by mise tasks that
// need to pass -Dversion=... to zig build.
import { version } from "./lib.ts";
console.log(await version());
