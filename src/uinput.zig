const std = @import("std");
const posix = std.posix;
const keymap = @import("keymap");

const log = std.log.scoped(.uinput);

// ── Linux input event constants ──────────────────────────────────────────

const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_REL: u16 = 0x02;
const EV_ABS: u16 = 0x03;

const SYN_REPORT: u16 = 0;

const REL_WHEEL: u16 = 0x08;

const ABS_X: u16 = 0x00;
const ABS_Y: u16 = 0x01;

const BTN_LEFT: u16 = 0x110;
const BTN_RIGHT: u16 = 0x111;
const BTN_MIDDLE: u16 = 0x112;

const KEY_MAX: u32 = 0x2FF;

const BUS_VIRTUAL: u16 = 0x06;

const INPUT_PROP_DIRECT: u32 = 0x01;

// ── ioctl numbers ────────────────────────────────────────────────────────

fn _ioc(dir: u32, typ: u8, nr: u32, size: u32) u32 {
    return (dir << 30) | (@as(u32, typ) << 8) | nr | (size << 16);
}

const IOC_NONE: u32 = 0;
const IOC_WRITE: u32 = 1;

const UI_SET_EVBIT = _ioc(IOC_WRITE, 'U', 100, @sizeOf(c_int));
const UI_SET_KEYBIT = _ioc(IOC_WRITE, 'U', 101, @sizeOf(c_int));
const UI_SET_RELBIT = _ioc(IOC_WRITE, 'U', 103, @sizeOf(c_int));
const UI_SET_ABSBIT = _ioc(IOC_WRITE, 'U', 104, @sizeOf(c_int));
const UI_SET_PROPBIT = _ioc(IOC_WRITE, 'U', 110, @sizeOf(c_int));
const UI_DEV_SETUP = _ioc(IOC_WRITE, 'U', 3, @sizeOf(UinputSetup));
const UI_DEV_CREATE = _ioc(IOC_NONE, 'U', 1, 0);
const UI_DEV_DESTROY = _ioc(IOC_NONE, 'U', 2, 0);
const UI_ABS_SETUP = _ioc(IOC_WRITE, 'U', 4, @sizeOf(UinputAbsSetup));

// ── Structs (manual to avoid @cImport .type keyword) ─────────────────────

const InputEvent = extern struct {
    tv_sec: isize,
    tv_usec: isize,
    type: u16,
    code: u16,
    value: i32,

    comptime {
        std.debug.assert(@sizeOf(InputEvent) == 24);
    }
};

const InputId = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

const UINPUT_MAX_NAME_SIZE = 80;

const UinputSetup = extern struct {
    id: InputId,
    name: [UINPUT_MAX_NAME_SIZE]u8,
    ff_effects_max: u32,
};

const UinputAbsSetup = extern struct {
    code: u16,
    _pad: [2]u8 = .{ 0, 0 },
    // struct input_absinfo
    value: i32 = 0,
    minimum: i32,
    maximum: i32,
    fuzz: i32 = 0,
    flat: i32 = 0,
    resolution: i32 = 0,
};

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

fn doIoctl(fd: posix.fd_t, request: u32, arg: usize) !void {
    if (ioctl(@intCast(fd), @as(c_ulong, request), arg) < 0) {
        return error.IoctlFailed;
    }
}

// ── VirtualInput ─────────────────────────────────────────────────────────

/// Virtual keyboard + absolute mouse via Linux uinput.
/// EV_ABS with ABS_MAX = screen_res - 1 and INPUT_PROP_DIRECT
/// to get correct coordinate mapping (avoids Sunshine calibration bug).
pub const VirtualInput = struct {
    fd: posix.fd_t,

    pub fn init(screen_width: u32, screen_height: u32) !VirtualInput {
        const fd = posix.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch |err| {
            log.warn("cannot open /dev/uinput: {} (is user in 'input' group?)", .{err});
            return error.UinputUnavailable;
        };
        errdefer posix.close(fd);

        // Register event types
        try doIoctl(fd, UI_SET_EVBIT, EV_SYN);
        try doIoctl(fd, UI_SET_EVBIT, EV_KEY);
        try doIoctl(fd, UI_SET_EVBIT, EV_ABS);
        try doIoctl(fd, UI_SET_EVBIT, EV_REL);

        // Register all keyboard keys
        var key_code: u32 = 0;
        while (key_code <= KEY_MAX) : (key_code += 1) {
            try doIoctl(fd, UI_SET_KEYBIT, key_code);
        }

        // Mouse buttons
        try doIoctl(fd, UI_SET_KEYBIT, BTN_LEFT);
        try doIoctl(fd, UI_SET_KEYBIT, BTN_RIGHT);
        try doIoctl(fd, UI_SET_KEYBIT, BTN_MIDDLE);

        // Absolute axes (touchscreen-style direct mapping)
        try doIoctl(fd, UI_SET_ABSBIT, ABS_X);
        try doIoctl(fd, UI_SET_ABSBIT, ABS_Y);

        // Scroll (relative)
        try doIoctl(fd, UI_SET_RELBIT, REL_WHEEL);

        // INPUT_PROP_DIRECT — tells the kernel this is a direct input device
        // (like a touchscreen), so coordinates map 1:1 to screen pixels
        try doIoctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

        // Configure absolute axes with screen resolution
        var abs_x = UinputAbsSetup{
            .code = ABS_X,
            .minimum = 0,
            .maximum = @intCast(screen_width - 1),
        };
        try doIoctl(fd, UI_ABS_SETUP, @intFromPtr(&abs_x));

        var abs_y = UinputAbsSetup{
            .code = ABS_Y,
            .minimum = 0,
            .maximum = @intCast(screen_height - 1),
        };
        try doIoctl(fd, UI_ABS_SETUP, @intFromPtr(&abs_y));

        // Device metadata
        var setup = std.mem.zeroes(UinputSetup);
        setup.id = .{
            .bustype = BUS_VIRTUAL,
            .vendor = 0x0CA5,
            .product = 0x0001,
            .version = 1,
        };
        const name = "zerocast-input";
        @memcpy(setup.name[0..name.len], name);

        try doIoctl(fd, UI_DEV_SETUP, @intFromPtr(&setup));
        try doIoctl(fd, UI_DEV_CREATE, 0);

        log.info("virtual input device created ({d}x{d})", .{ screen_width, screen_height });
        return .{ .fd = fd };
    }

    pub fn deinit(self: *VirtualInput) void {
        doIoctl(self.fd, UI_DEV_DESTROY, 0) catch {};
        posix.close(self.fd);
    }

    /// Inject a key press or release. `value`: 1=down, 0=up.
    pub fn injectKey(self: *VirtualInput, linux_keycode: u16, value: i32) void {
        self.writeEvent(EV_KEY, linux_keycode, value);
        self.writeEvent(EV_SYN, SYN_REPORT, 0);
    }

    /// Inject a key event from a KeyboardEvent.code string.
    pub fn injectKeyCode(self: *VirtualInput, code: []const u8, value: i32) void {
        if (keymap.lookup(code)) |linux_key| {
            self.injectKey(linux_key, value);
        }
    }

    /// Move mouse to absolute coordinates.
    pub fn moveMouse(self: *VirtualInput, x: u16, y: u16) void {
        self.writeEvent(EV_ABS, ABS_X, @intCast(x));
        self.writeEvent(EV_ABS, ABS_Y, @intCast(y));
        self.writeEvent(EV_SYN, SYN_REPORT, 0);
    }

    /// Inject a mouse button press or release.
    pub fn injectMouseButton(self: *VirtualInput, button: u8, value: i32) void {
        const btn: u16 = switch (button) {
            0 => BTN_LEFT,
            1 => BTN_RIGHT,
            2 => BTN_MIDDLE,
            else => return,
        };
        self.writeEvent(EV_KEY, btn, value);
        self.writeEvent(EV_SYN, SYN_REPORT, 0);
    }

    /// Inject scroll event.
    pub fn injectScroll(self: *VirtualInput, delta: i16) void {
        // Normalize to discrete steps — browser sends delta in pixels (120 = 1 notch)
        const steps: i32 = @divTrunc(@as(i32, delta), 120);
        if (steps != 0) {
            self.writeEvent(EV_REL, REL_WHEEL, steps);
            self.writeEvent(EV_SYN, SYN_REPORT, 0);
        }
    }

    fn writeEvent(self: *VirtualInput, ev_type: u16, code: u16, value: i32) void {
        const event = InputEvent{
            .tv_sec = 0,
            .tv_usec = 0,
            .type = ev_type,
            .code = code,
            .value = value,
        };
        _ = posix.write(self.fd, std.mem.asBytes(&event)) catch {};
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "ioctl constants computed correctly" {
    // UI_SET_EVBIT: _IOW('U', 100, int) = direction=1, type='U', nr=100, size=4
    try std.testing.expectEqual(UI_SET_EVBIT, (1 << 30) | (@as(u32, 'U') << 8) | 100 | (4 << 16));
    try std.testing.expectEqual(UI_DEV_CREATE, (@as(u32, 'U') << 8) | 1);
    try std.testing.expectEqual(UI_DEV_DESTROY, (@as(u32, 'U') << 8) | 2);
}

test "InputEvent is 24 bytes" {
    try std.testing.expectEqual(@sizeOf(InputEvent), 24);
}

test "UinputSetup size" {
    // Kernel expects: InputId(8) + name(80) + ff_effects_max(4) = 92
    try std.testing.expectEqual(@sizeOf(UinputSetup), 92);
}
