const std = @import("std");

/// barecast-kms: Privileged KMS capture helper.
///
/// Runs with CAP_SYS_ADMIN file capability. Opens /dev/dri/card0, enumerates
/// planes via DRM ioctls, exports framebuffer DMA-BUF fds, and sends them
/// to the unprivileged parent process over a Unix socketpair via SCM_RIGHTS.
///
/// This binary is intentionally minimal — no networking, no encoding, no
/// complex logic. The smaller the CAP_SYS_ADMIN surface area, the better.

pub fn main() void {
    std.debug.print("barecast-kms: privileged KMS helper (not yet implemented)\n", .{});
}
