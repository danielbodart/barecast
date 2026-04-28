#!/usr/bin/env bun
// Captures 3s of video with the freshly-built binary, then validates the
// IVF output with ffprobe (codec + frame count). Requires GPU.
import { $, existsSync } from "./lib.ts";

const testFile = "/tmp/zerocast-test.ivf";
console.log("Capturing 3s to video...");
await $`timeout 10 dist/bin/zerocast --record ${testFile} 3`.nothrow();

if (!existsSync(testFile)) {
    console.error("ERROR: recording file was not created");
    process.exit(1);
}

console.log("Validating with ffprobe...");
const { stdout } = await $`ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,nb_read_frames -count_frames -of csv=p=0 ${testFile}`.quiet();
const parts = stdout.toString().trim().split(",");
const codec = parts[0];
const frames = parseInt(parts[1] || "0") || 0;

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
