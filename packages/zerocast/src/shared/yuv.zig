//! RGBA → I420 YUV color conversion.
//!
//! Uses BT.709 limited range (Y ∈ [16,235], UV ∈ [16,240]) so the output
//! matches the color metadata the SVT-AV1 backend declares in the
//! bitstream (see svt_backend.zig T-013 wiring). Chroma is 2×2 averaged
//! for 4:2:0 subsampling.
//!
//! Fixed-point integer math; no floats, no SIMD intrinsics. The
//! per-pixel cost is acceptable for <=1080p on modern CPUs — this path
//! is the software-encoder fallback, not the hot path. If it ever needs
//! to go faster, libyuv is the canonical drop-in.
//!
//! Coefficients come from ITU-R BT.709:
//!   Y'  = 0.2126 R + 0.7152 G + 0.0722 B     → limited-range scale by 219/255
//!   Cb' = -0.1146 R - 0.3854 G + 0.5    B    → scaled by 224/255, +128
//!   Cr' = 0.5    R - 0.4542 G - 0.0458 B     → scaled by 224/255, +128
//! Scaled into 1/256 integers below; rounding via +128 before >>8.

const std = @import("std");

pub const Error = error{
    OddDimensions,
    SourceTooSmall,
    DestinationTooSmall,
};

/// Byte size of an I420 buffer covering `width × height`.
/// Luma (w*h) + U (w/2 * h/2) + V (w/2 * h/2).
pub fn i420Size(width: u32, height: u32) usize {
    const luma = @as(usize, width) * height;
    const chroma = @as(usize, width / 2) * (height / 2);
    return luma + 2 * chroma;
}

/// Convert a tightly packed RGBA8888 buffer to I420 YUV with BT.709
/// limited range signalling. Width and height must both be even (4:2:0
/// subsampling needs even dimensions).
///
/// `rgba` length must be at least width*height*4.
/// `out` length must be at least `i420Size(width, height)`.
pub fn rgbaToI420Bt709Limited(
    rgba: []const u8,
    width: u32,
    height: u32,
    out: []u8,
) Error!void {
    if (width % 2 != 0 or height % 2 != 0) return Error.OddDimensions;

    const luma_len = @as(usize, width) * height;
    const chroma_w = width / 2;
    const chroma_h = height / 2;
    const chroma_len = @as(usize, chroma_w) * chroma_h;

    if (rgba.len < luma_len * 4) return Error.SourceTooSmall;
    if (out.len < luma_len + 2 * chroma_len) return Error.DestinationTooSmall;

    const y_plane = out[0..luma_len];
    const u_plane = out[luma_len..][0..chroma_len];
    const v_plane = out[luma_len + chroma_len ..][0..chroma_len];

    // Luma pass — every pixel.
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        const row_out = @as(usize, y) * width;
        while (x < width) : (x += 1) {
            const idx = (row_out + x) * 4;
            const r: i32 = rgba[idx + 0];
            const g: i32 = rgba[idx + 1];
            const b: i32 = rgba[idx + 2];
            // 47/256 ≈ 0.1826  157/256 ≈ 0.6142  16/256 ≈ 0.0620
            const yv = ((47 * r + 157 * g + 16 * b + 128) >> 8) + 16;
            y_plane[row_out + x] = @intCast(std.math.clamp(yv, 16, 235));
        }
    }

    // Chroma pass — 2×2 average then convert.
    var cy: u32 = 0;
    while (cy < chroma_h) : (cy += 1) {
        var cx: u32 = 0;
        while (cx < chroma_w) : (cx += 1) {
            const x0 = cx * 2;
            const y0 = cy * 2;
            const p0 = (@as(usize, y0) * width + x0) * 4;
            const p1 = (@as(usize, y0) * width + x0 + 1) * 4;
            const p2 = (@as(usize, y0 + 1) * width + x0) * 4;
            const p3 = (@as(usize, y0 + 1) * width + x0 + 1) * 4;

            const r: i32 = (@as(i32, rgba[p0 + 0]) + rgba[p1 + 0] + rgba[p2 + 0] + rgba[p3 + 0] + 2) >> 2;
            const g: i32 = (@as(i32, rgba[p0 + 1]) + rgba[p1 + 1] + rgba[p2 + 1] + rgba[p3 + 1] + 2) >> 2;
            const b: i32 = (@as(i32, rgba[p0 + 2]) + rgba[p1 + 2] + rgba[p2 + 2] + rgba[p3 + 2] + 2) >> 2;

            // -26/256 ≈ -0.1016  -87/256 ≈ -0.3398  112/256 ≈ 0.4375
            const u = ((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128;
            // 112/256 ≈ 0.4375  -102/256 ≈ -0.3984  -10/256 ≈ -0.0391
            const v = ((112 * r - 102 * g - 10 * b + 128) >> 8) + 128;

            const cidx = @as(usize, cy) * chroma_w + cx;
            u_plane[cidx] = @intCast(std.math.clamp(u, 16, 240));
            v_plane[cidx] = @intCast(std.math.clamp(v, 16, 240));
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

test "i420Size: 2x2" {
    try std.testing.expectEqual(@as(usize, 4 + 1 + 1), i420Size(2, 2));
}

test "i420Size: 320x240" {
    try std.testing.expectEqual(@as(usize, 320 * 240 + 2 * 160 * 120), i420Size(320, 240));
}

test "rgbaToI420: rejects odd dimensions" {
    var src: [4]u8 = .{ 0, 0, 0, 0 };
    var dst: [4]u8 = undefined;
    try std.testing.expectError(Error.OddDimensions, rgbaToI420Bt709Limited(&src, 1, 2, &dst));
    try std.testing.expectError(Error.OddDimensions, rgbaToI420Bt709Limited(&src, 2, 1, &dst));
}

test "rgbaToI420: rejects undersized destination" {
    var src: [16]u8 = .{0} ** 16; // 2x2 RGBA
    var dst: [5]u8 = undefined; // need 6
    try std.testing.expectError(Error.DestinationTooSmall, rgbaToI420Bt709Limited(&src, 2, 2, &dst));
}

test "rgbaToI420: pure black → minimum limited-range Y, neutral chroma" {
    // 2x2 all black
    var src = [_]u8{0} ** 16;
    // RGBA layout: (R, G, B, A) per pixel — set A to 255 but conversion ignores
    var i: usize = 3;
    while (i < src.len) : (i += 4) src[i] = 255;

    var dst = [_]u8{0} ** 6;
    try rgbaToI420Bt709Limited(&src, 2, 2, &dst);

    // Y: black → 16 (limited range floor)
    try std.testing.expectEqual(@as(u8, 16), dst[0]);
    try std.testing.expectEqual(@as(u8, 16), dst[1]);
    try std.testing.expectEqual(@as(u8, 16), dst[2]);
    try std.testing.expectEqual(@as(u8, 16), dst[3]);
    // UV: black → 128 (neutral)
    try std.testing.expectEqual(@as(u8, 128), dst[4]);
    try std.testing.expectEqual(@as(u8, 128), dst[5]);
}

test "rgbaToI420: pure white → maximum limited-range Y, neutral chroma" {
    var src = [_]u8{255} ** 16;
    var dst = [_]u8{0} ** 6;
    try rgbaToI420Bt709Limited(&src, 2, 2, &dst);

    // Y: white → 235 (limited range ceiling, within rounding tolerance)
    for (dst[0..4]) |yv| {
        try std.testing.expect(yv >= 234 and yv <= 235);
    }
    // UV: white → 128 (neutral)
    try std.testing.expect(dst[4] >= 127 and dst[4] <= 129);
    try std.testing.expect(dst[5] >= 127 and dst[5] <= 129);
}

test "rgbaToI420: saturated red produces expected Cr bias" {
    // Pure red should push Cr high (R-biased) and Cb low (B-absent).
    var src = [_]u8{0} ** 16;
    var p: usize = 0;
    while (p < src.len) : (p += 4) {
        src[p + 0] = 255; // R
        src[p + 3] = 255; // A
    }
    var dst = [_]u8{0} ** 6;
    try rgbaToI420Bt709Limited(&src, 2, 2, &dst);

    // Cr > 128 (red-leaning), Cb < 128 (no blue)
    try std.testing.expect(dst[5] > 128);
    try std.testing.expect(dst[4] < 128);
    // BT.709 Cr for pure red ≈ 240 in limited range (top of 16–240 span)
    try std.testing.expect(dst[5] >= 230);
}

test "rgbaToI420: 4x4 gradient stays within legal limited-range" {
    // 4x4 gradient pattern — every output byte must be inside the
    // limited-range legal bands for Y and Cb/Cr.
    const w: u32 = 4;
    const h: u32 = 4;
    var src: [w * h * 4]u8 = undefined;
    for (0..h) |row| {
        for (0..w) |col| {
            const i = (row * w + col) * 4;
            src[i + 0] = @intCast((col * 64) % 256);
            src[i + 1] = @intCast((row * 64) % 256);
            src[i + 2] = @intCast(((col + row) * 32) % 256);
            src[i + 3] = 255;
        }
    }
    var dst: [w * h + 2 * (w / 2) * (h / 2)]u8 = undefined;
    try rgbaToI420Bt709Limited(&src, w, h, &dst);

    const luma_len = w * h;
    const chroma_len = (w / 2) * (h / 2);
    for (dst[0..luma_len]) |yv| try std.testing.expect(yv >= 16 and yv <= 235);
    for (dst[luma_len .. luma_len + 2 * chroma_len]) |cv| try std.testing.expect(cv >= 16 and cv <= 240);
}
