const std = @import("std");
const build_options = @import("build_options");

pub fn main() void {
    std.debug.print("barecast v{s}\n", .{build_options.version});
}

test "placeholder" {
    try std.testing.expect(true);
}
