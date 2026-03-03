const std = @import("std");
const build_options = @import("build_options");
const daemon = @import("daemon");
const cli = @import("cli");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() void {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    const subcmd = args.next() orelse {
        cli.dispatch();
        return;
    };

    if (std.mem.eql(u8, subcmd, "daemon")) {
        daemon.run();
    } else {
        // Everything else handled by CLI (re-parses from argv[0])
        cli.dispatch();
    }
}
