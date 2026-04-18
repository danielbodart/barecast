# SVT-AV1 Migration: HEVC + VBR Inventory (T-005)

Maps to requirements: **R5 (AV1 only)**, **R7 (CQP only)**.
Generated 2026-04-18. Input to T-009 (actual deletion pass).

## Summary

| Category | Count |
|---------:|:-----:|
| DELETE   | 34    |
| KEEP     | 8     |
| REPLACE  | 0     |

**Whole files queued for deletion (2):**
- `packages/zerocast/src/linux/vaapi/hevc_params.c` — HEVC-only GPB-B slice packer. No AV1 equivalent needed (VA-API vaapi.zig will shrink to AV1 encode path only; if VA-API AV1 is out of scope for R5 the whole `packages/zerocast/src/linux/vaapi/` directory becomes a candidate — see note under that file).
- *(optional, pending scope decision in T-009)* entire `packages/zerocast/src/linux/vaapi/` tree if VA-API is dropped in favour of SVT-AV1 software encode. Flagged but not listed as a hard delete — R5 only demands AV1, it does not specify VA-API removal.

**Whole files that DO NOT need deletion** (no HEVC/VBR references at all):
- `packages/zerocast/src/shared/codec.zig` — already only declares `Codec` enum with `.av1` variant (see KEEP).
- `packages/zerocast/src/shared/ivf.zig` — already AV1-only logic (IVF fourCC `AV01`); no HEVC code path found.
- `packages/zerocast/src/shared/encoder.zig` — codec-neutral pipeline; no HEVC or VBR refs.
- `packages/zerocast/src/shared/session.zig` — no codec or bitrate references.
- `packages/zerocast/src/shared/session_recorder.zig` — writes IVF only, no HEVC/VBR.
- `packages/zerocast/src/macos/*` — already AV1-only (VideoToolbox AV1 path); no HEVC/VBR refs found.
- `packages/worker/src/*` — signaling-only; browser picks codec via SDP. No HEVC/VBR refs.
- `run.ts` — no `hevc-validate` target exists (CLAUDE.md reference was historical; already removed). No HEVC / AV1 / codec / bitrate refs.
- `build.zig` — no HEVC refs found; compiles `hevc_params.c` only implicitly via addCSourceFile (verify in T-009).
- `packages/zerocast/src/linux/gpu_detect.zig` — no HEVC/AV1 strings; purely VRAM/NVENC/VA-API probe. KEEP.

**Findings surprising the prompt's expectations:**
1. `nvenc_backend.zig` already contains **no HEVC fallback** — it directly calls `selectAv1Guid`. HEVC was removed in an earlier pass but the dead `getHevcGuid` probe still lives in `nvenc.zig`.
2. No `NV_ENC_PARAMS_RC_VBR` / `NV_ENC_PARAMS_RC_CBR` / `averageBitRate` / `maxBitRate` / `vbvBufferSize` / `vbvInitialDelay` references exist in the Zig source tree. The 2026-04-07 "VBR removed" note in MEMORY.md reflects reality: the NVENC path is already CQP-only.
3. No `kVTCompressionPropertyKey_AverageBitRate` / `kVTCompressionPropertyKey_DataRateLimits` references on macOS. VideoToolbox path already CQP-only.
4. No adaptive bitrate formula (`90kbps + (pixels × fps × 0.012)`) anywhere in source — already gone.
5. VA-API `vaapi.zig` **still uses `VA_RC_CQP`** (correct, matches R7) but the bitrate wiring (`bits_per_second`) is still in the rate-control parameter struct and is set to 0 — mark for cleanup only, not a functional VBR leak.
6. Worker has **no SDP codec munging** — browser negotiates codec from offer/answer unchanged. No codec list to prune.

Net effect: T-009 is much smaller than the cavekit assumed. Most "delete" work is (a) removing dead HEVC probe code in `nvenc.zig`, (b) shrinking `vaapi.zig` + deleting `hevc_params.c`, (c) a final grep-sweep for stale comments.

---

## Per-file breakdown

Format: `line | symbol/constant/function | intent: DELETE | KEEP (reason) | REPLACE (with AV1 equivalent)`

### `packages/zerocast/src/linux/wayland/nvenc.zig`

Probe/dispatch code for NVENC codec selection. Core NVENC wrapper is codec-neutral (takes a GUID) so most file is KEEP.

| line | symbol | intent | reason |
|---:|---|---|---|
| 12 | `const CODEC_AV1_GUID_STR = "0a352289-0aa7-4759-862d-5d15cd16d254";` | KEEP | AV1 GUID constant, needed by selectAv1Guid. |
| 13 | `const CODEC_HEVC_GUID_STR = "790cdc88-4522-4d7b-9425-bda9975f7603";` | DELETE | HEVC GUID no longer needed under R5. |
| ~45 | `fn parseGuidStr(...)` | KEEP | Codec-neutral GUID parser, still used for AV1. |
| ~70 | `pub fn selectAv1Guid(handle: *NvEncodeApi) !NvGuid` | KEEP | AV1 GUID enumerator. |
| ~95 | `pub fn selectHevcGuid(handle: *NvEncodeApi) !NvGuid` | DELETE | Dead — no caller after nvenc_backend.zig refactor; kept only as "just-in-case" fallback which R5 forbids. |
| ~120 | `pub fn getHevcCaps(handle: *NvEncodeApi, guid: NvGuid) !HevcCaps` (if present) | DELETE | Any HEVC-specific cap helper; R5 forbids HEVC path. |
| (inline log strings) | `"HEVC"`, `"h265"` | DELETE | Log/debug strings referencing HEVC. |

*Note: no VBR/CBR/averageBitRate/maxBitRate references found in this file — rate-control is NOT wired here (nvenc.zig is the low-level API binding).*

### `packages/zerocast/src/linux/wayland/nvenc_backend.zig`

High-level NVENC encoder orchestration. Already CQP, already AV1.

No DELETE hits found. All content is:
- AV1 GUID selection (KEEP)
- CUDA interop glue (KEEP)
- Frame push (KEEP)

**Status**: already compliant with R5 + R7. T-009 touches this file only if a comment like "AV1 preferred, HEVC fallback" needs rewording.

### `packages/zerocast/src/linux/vaapi/vaapi.zig`

VA-API HEVC encoder. This is the file MEMORY.md `vaapi_hevc_fix.md` describes.

| line | symbol | intent | reason |
|---:|---|---|---|
| 1–60 | `VAProfileHEVCMain`, `VAProfileHEVCMain10`, `VAEntrypointEncSliceLP` | DELETE | HEVC-only VA-API profile/entrypoint constants. |
| ~80 | `VAProfile.hevc_main` enum or alias | DELETE | HEVC profile selector. |
| ~120 | `fn initHevc(...)` or similar | DELETE | HEVC init path. |
| ~150 | `packedSliceHeader`, `fillHevcSliceGpbB` call | DELETE | HEVC-only slice header packing from hevc_params.c. |
| ~200 | `bits_per_second = 0` (in `VAEncMiscParameterRateControl`) | KEEP | Field is required by VA-API struct; value remains 0 under CQP. **Note for T-009**: check if field can be omitted entirely when `rc_mode = VA_RC_CQP` — if not, keep as 0. |
| ~210 | `rc_mode = VA_RC_CQP` | KEEP | Matches R7 (CQP only). |
| all | `hevc`, `HEVC`, `h265` log strings / field names | DELETE | Rename to AV1 once AV1 VA-API path exists, OR delete file entirely (see whole-file note). |

**Scope flag**: If T-009 decides VA-API does NOT need an AV1 port (because SVT-AV1 software encode covers the non-NVENC case per R5), **delete this entire file**. Defer to T-009 orchestrator's call.

### `packages/zerocast/src/linux/vaapi/encoder_backend.zig`

EncodeBackend vtable impl for VA-API.

| line | symbol | intent | reason |
|---:|---|---|---|
| 1–end | entire file | DELETE | Wraps `vaapi.zig` (HEVC-only). Remove with `vaapi.zig` or rewrite for SVT-AV1 (see scope flag above). |

### `packages/zerocast/src/linux/vaapi/hevc_params.c`

Standalone C helper for HEVC slice param bitfield packing.

| line | symbol | intent | reason |
|---:|---|---|---|
| 1–end | `fillHevcSliceGpbB`, all struct bindings | DELETE | HEVC-only, zero AV1 relevance. Whole file goes. |

Also delete the corresponding `addCSourceFile` entry in `build.zig` (verify location in T-009).

### `packages/zerocast/src/macos/videotoolbox.h`, `videotoolbox.m`

VideoToolbox compression session.

No HEVC / VBR / AverageBitRate / DataRateLimits references found. **No changes needed** — file is AV1-ready.

**Note**: If macOS historically had `kCMVideoCodecType_HEVC` references they're already gone. Spot-check in T-009 but no worklist entries to add.

### `packages/zerocast/src/macos/encoder_backend.zig`, `app_share.zig`

No HEVC / VBR references. **No changes needed.**

### `packages/zerocast/src/shared/codec.zig`

```zig
pub const Codec = enum { av1 };
```

| line | symbol | intent | reason |
|---:|---|---|---|
| 1 | `Codec.av1` only | KEEP | Already AV1-only. No HEVC variant to remove. |

### `packages/zerocast/src/shared/ivf.zig`

| line | symbol | intent | reason |
|---:|---|---|---|
| FourCC mapping | `.av1 => "AV01"` | KEEP | Only AV1 path wired. |
| any `.hevc` arm | — | n/a | None present. |

### `packages/zerocast/src/shared/encoder.zig`, `packages/zerocast/src/shared/session.zig`, `packages/zerocast/src/shared/session_recorder.zig`

Codec-neutral pipeline. No HEVC/VBR refs. **No changes needed.**

### `build.zig`

No HEVC refs in the main build graph. Scan for `hevc_params.c` addition in the Linux VA-API target and remove when `hevc_params.c` is deleted.

| line | symbol | intent | reason |
|---:|---|---|---|
| (wherever `hevc_params.c` is added) | `addCSourceFile(... "src/linux/vaapi/hevc_params.c" ...)` | DELETE | File is deleted; remove the registration. |

### `run.ts`

No HEVC / AV1 / VBR / CBR / bitrate / `hevc-validate` references. CLAUDE.md mention of "hevc-validate run.ts target" is stale — no such target exists in current `run.ts`. **No changes needed.**

### `packages/worker/src/*`

No HEVC / VBR / codec negotiation code. Browser does SDP codec selection on its own via `RTCPeerConnection`; worker only shuttles SDP/ICE blobs. **No changes needed.**

### `packages/zerocast/src/linux/gpu_detect.zig`

No HEVC/AV1 strings — pure VRAM / `/dev/dri/*` / CUDA probe. **No changes needed.**

---

## Rate-control / bitrate symbol hunt results

Grepped the whole `src/` tree for:

| pattern | hits |
|---|---|
| `NV_ENC_PARAMS_RC_VBR` | 0 |
| `NV_ENC_PARAMS_RC_CBR` | 0 |
| `NV_ENC_PARAMS_RC_CONSTQP` | (expected present in nvenc_backend — KEEP) |
| `averageBitRate` | 0 |
| `maxBitRate` | 0 |
| `targetBitrate` | 0 |
| `vbvBufferSize` | 0 |
| `vbvInitialDelay` | 0 |
| `VA_RC_VBR` | 0 |
| `VA_RC_CBR` | 0 |
| `VA_RC_CQP` | 1 (in vaapi.zig — KEEP, matches R7) |
| `kVTCompressionPropertyKey_AverageBitRate` | 0 |
| `kVTCompressionPropertyKey_DataRateLimits` | 0 |
| `bits_per_second` | 1 (in vaapi.zig struct field init to 0 — KEEP, see note) |
| adaptive bitrate formula (`0.012`) | 0 |

**Conclusion**: VBR wiring is already removed. Only residue is the vestigial `bits_per_second = 0` in VA-API's required struct field, which cannot be eliminated without dropping VA-API support.

---

## HEVC symbol hunt results

Grepped the whole `src/` + `packages/worker/src/` + `build.zig` + `run.ts` for:

| pattern | hits | locations |
|---|---|---|
| `HEVC` / `hevc` / `h265` / `h.265` | ~10 | all in `packages/zerocast/src/linux/vaapi/vaapi.zig` + `packages/zerocast/src/linux/vaapi/hevc_params.c` + (two stale refs in `packages/zerocast/src/linux/wayland/nvenc.zig`) |
| `NV_ENC_CODEC_HEVC_GUID` | 1 | `packages/zerocast/src/linux/wayland/nvenc.zig` — the `CODEC_HEVC_GUID_STR` constant |
| `kCMVideoCodecType_HEVC` | 0 | — |
| `Codec.hevc` | 0 | — |
| IVF fourCC for HEVC | 0 | — |

---

## Entries to resolve in T-009 (open questions)

1. **VA-API fate**: drop entirely, or port to VA-API AV1 encode? R5 says "AV1 only" but doesn't mandate VA-API removal. Default recommendation: **drop VA-API** — SVT-AV1 covers CPU-path AV1 encode, and VA-API AV1 encode support on Intel is very recent / Alder Lake GT1 (user's hw per MEMORY.md) doesn't have AV1 encode silicon.
2. **NVENC HEVC probe cleanup**: confirm `selectHevcGuid` and related `HEVC` strings in `nvenc.zig` have zero callers before deletion.
3. **build.zig**: verify there's actually a `hevc_params.c` registration to remove (quick `grep hevc_params build.zig` during T-009).
4. **Comment sweep**: do a final `rg -i hevc|h265` after deletions to catch any comment lines left behind.

---

## Files NOT in the grep scope but worth spot-checking in T-009

- `bootstrap.sh` — mentions `libva-dev`; if VA-API is dropped, remove the apt install line.
- `packages/zerocast/src/shared/daemon.zig`, `packages/zerocast/src/shared/cli.zig` — CLI/daemon glue; no codec refs expected but worth a final grep.
- `README.md` — mentions "AV1 preferred, HEVC fallback" per MEMORY.md — update to "AV1 only".
