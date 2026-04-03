const std = @import("std");

/// Parses OSC 0 and OSC 2 escape sequences from a PTY byte stream to extract
/// terminal title changes. Handles sequences split across multiple read() calls.
///
/// OSC format: ESC ] Ps ; Pt BEL   (or ESC ] Ps ; Pt ESC \)
///   Ps = 0 (icon name + title) or 2 (title only)
///   Pt = title string
///   BEL = 0x07, ST = ESC \ (0x1B 0x5C)
pub const OscParser = struct {
    const MAX_TITLE: usize = 200;

    state: State = .normal,
    title_buf: [MAX_TITLE]u8 = undefined,
    title_len: usize = 0,
    ps_val: u8 = 0, // accumulated parameter (0 or 2)

    const State = enum {
        normal,
        esc, // got ESC
        osc_ps, // got ESC ], reading parameter digits
        osc_ignore, // OSC but not type 0 or 2, skip until terminator
        osc_string, // collecting title bytes
        esc_in_string, // got ESC inside osc_string (potential ST)
        esc_in_ignore, // got ESC inside osc_ignore (potential ST)
    };

    /// Feed a chunk of PTY output. Returns the title string if a complete
    /// OSC 0 or OSC 2 sequence was found, or null if not.
    /// Only returns the first complete title per feed() call.
    pub fn feed(self: *OscParser, data: []const u8) ?[]const u8 {
        for (data) |byte| {
            switch (self.state) {
                .normal => {
                    if (byte == 0x1B) self.state = .esc;
                },
                .esc => {
                    if (byte == ']') {
                        self.state = .osc_ps;
                        self.ps_val = 0;
                        self.title_len = 0;
                    } else {
                        self.state = .normal;
                    }
                },
                .osc_ps => {
                    if (byte >= '0' and byte <= '9') {
                        self.ps_val = self.ps_val *| 10 +| (byte - '0');
                    } else if (byte == ';') {
                        if (self.ps_val == 0 or self.ps_val == 2) {
                            self.state = .osc_string;
                        } else {
                            self.state = .osc_ignore;
                        }
                    } else if (byte == 0x07 or byte == 0x1B) {
                        // Malformed: terminated before semicolon
                        self.state = .normal;
                    } else {
                        self.state = .osc_ignore;
                    }
                },
                .osc_ignore => {
                    if (byte == 0x07) {
                        self.state = .normal;
                    } else if (byte == 0x1B) {
                        self.state = .esc_in_ignore;
                    }
                },
                .esc_in_ignore => {
                    self.state = if (byte == '\\') .normal else .osc_ignore;
                },
                .osc_string => {
                    if (byte == 0x07) {
                        // BEL terminator — title complete
                        self.state = .normal;
                        return self.title_buf[0..self.title_len];
                    } else if (byte == 0x1B) {
                        self.state = .esc_in_string;
                    } else if (byte < 0x20) {
                        // Control character in title — reject
                        self.state = .osc_ignore;
                    } else if (self.title_len < MAX_TITLE) {
                        self.title_buf[self.title_len] = byte;
                        self.title_len += 1;
                    } else {
                        // Title too long — abandon
                        self.state = .osc_ignore;
                    }
                },
                .esc_in_string => {
                    if (byte == '\\') {
                        // ST terminator — title complete
                        self.state = .normal;
                        return self.title_buf[0..self.title_len];
                    }
                    // ESC was literal — append it and continue
                    if (self.title_len < MAX_TITLE) {
                        self.title_buf[self.title_len] = 0x1B;
                        self.title_len += 1;
                    }
                    if (byte == 0x07) {
                        self.state = .normal;
                        return self.title_buf[0..self.title_len];
                    }
                    if (byte < 0x20) {
                        self.state = .osc_ignore;
                    } else if (self.title_len < MAX_TITLE) {
                        self.title_buf[self.title_len] = byte;
                        self.title_len += 1;
                        self.state = .osc_string;
                    } else {
                        self.state = .osc_ignore;
                    }
                },
            }
        }
        return null;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "OSC 0 with BEL terminator" {
    var p = OscParser{};
    const title = p.feed("\x1b]0;my title\x07rest of output");
    try std.testing.expectEqualSlices(u8, "my title", title.?);
}

test "OSC 2 with BEL terminator" {
    var p = OscParser{};
    const title = p.feed("\x1b]2;window title\x07");
    try std.testing.expectEqualSlices(u8, "window title", title.?);
}

test "OSC 2 with ST terminator" {
    var p = OscParser{};
    const title = p.feed("\x1b]2;title here\x1b\\more data");
    try std.testing.expectEqualSlices(u8, "title here", title.?);
}

test "split across chunks" {
    var p = OscParser{};
    try std.testing.expect(p.feed("\x1b]0;hel") == null);
    const title = p.feed("lo world\x07");
    try std.testing.expectEqualSlices(u8, "hello world", title.?);
}

test "split at ESC" {
    var p = OscParser{};
    try std.testing.expect(p.feed("\x1b") == null);
    try std.testing.expect(p.feed("]2;ti") == null);
    const title = p.feed("tle\x07");
    try std.testing.expectEqualSlices(u8, "title", title.?);
}

test "non-title OSC ignored" {
    var p = OscParser{};
    try std.testing.expect(p.feed("\x1b]4;rgb:ff/00/00\x07") == null);
}

test "no OSC in normal text" {
    var p = OscParser{};
    try std.testing.expect(p.feed("hello world\n$ ") == null);
}

test "bash prompt title" {
    var p = OscParser{};
    // Typical bash PROMPT_COMMAND output
    const title = p.feed("\x1b]0;dan@host: ~/src\x07$ ");
    try std.testing.expectEqualSlices(u8, "dan@host: ~/src", title.?);
}

test "empty title" {
    var p = OscParser{};
    const title = p.feed("\x1b]0;\x07");
    try std.testing.expectEqualSlices(u8, "", title.?);
}

test "title with special chars" {
    var p = OscParser{};
    const title = p.feed("\x1b]2;nvim ~/foo.ts [+]\x07");
    try std.testing.expectEqualSlices(u8, "nvim ~/foo.ts [+]", title.?);
}

test "multiple titles returns first" {
    var p = OscParser{};
    const title = p.feed("\x1b]0;first\x07\x1b]0;second\x07");
    try std.testing.expectEqualSlices(u8, "first", title.?);
}

test "control chars in title rejected" {
    var p = OscParser{};
    // Title containing a newline — should be rejected
    try std.testing.expect(p.feed("\x1b]0;bad\ntitle\x07") == null);
}

test "title at max length" {
    var p = OscParser{};
    // Header: \x1b]0; = 4 bytes, then 200 title bytes, then \x07
    var buf: [205]u8 = undefined;
    buf[0] = 0x1b;
    buf[1] = ']';
    buf[2] = '0';
    buf[3] = ';';
    @memset(buf[4..204], 'x'); // 200 bytes of title
    buf[204] = 0x07;
    const title = p.feed(&buf);
    try std.testing.expect(title != null);
    try std.testing.expectEqual(@as(usize, 200), title.?.len);
}

test "title over max length abandoned" {
    var p = OscParser{};
    // Header: 4 bytes, then 201 title bytes, then \x07
    var buf: [206]u8 = undefined;
    buf[0] = 0x1b;
    buf[1] = ']';
    buf[2] = '0';
    buf[3] = ';';
    @memset(buf[4..205], 'y'); // 201 bytes — over limit
    buf[205] = 0x07;
    try std.testing.expect(p.feed(&buf) == null);
}
