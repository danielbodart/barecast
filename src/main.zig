const std = @import("std");
const build_options = @import("build_options");
const NvFbc = @import("nvfbc").NvFbc;

pub fn main() void {
    std.debug.print("barecast v{s}\n", .{build_options.version});

    var fbc = NvFbc.init() catch return;
    defer fbc.deinit();

    const frame = fbc.grabFrame() catch return;
    std.debug.print("NvFBC frame: texture={}, {}x{}, new={}\n", .{
        frame.texture_id, frame.width, frame.height, frame.is_new,
    });
}

test "placeholder" {
    try std.testing.expect(true);
}
