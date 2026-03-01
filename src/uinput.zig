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
const UI_SET_RELBIT = _ioc(IOC_WRITE, 'U', 102, @sizeOf(c_int));
const UI_SET_ABSBIT = _ioc(IOC_WRITE, 'U', 103, @sizeOf(c_int));
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

/// Virtual keyboard + absolute pointer via Linux uinput.
/// Two separate devices to avoid libinput classification conflicts:
/// - Pointer: EV_ABS + INPUT_PROP_DIRECT + BTN_LEFT/RIGHT/MIDDLE + REL_WHEEL
///   (no keyboard keys → avoids tablet classification)
/// - Keyboard: EV_KEY only (standard keyboard keycodes)
/// When capturing a sub-region (--geometry), x_offset/y_offset translate
/// capture-region coordinates to full-screen coordinates.
pub const VirtualInput = struct {
    pointer_fd: posix.fd_t,
    keyboard_fd: posix.fd_t,
    x_offset: u16,
    y_offset: u16,

    pub fn init(screen_width: u32, screen_height: u32, x_offset: u16, y_offset: u16) !VirtualInput {
        // ── Pointer device: absolute mouse + scroll ──────────────────
        const ptr_fd = posix.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch |err| {
            log.warn("cannot open /dev/uinput: {} (is user in 'input' group?)", .{err});
            return error.UinputUnavailable;
        };
        errdefer posix.close(ptr_fd);

        try doIoctl(ptr_fd, UI_SET_EVBIT, EV_SYN);
        try doIoctl(ptr_fd, UI_SET_EVBIT, EV_KEY);
        try doIoctl(ptr_fd, UI_SET_EVBIT, EV_ABS);
        try doIoctl(ptr_fd, UI_SET_EVBIT, EV_REL);

        // Only mouse buttons — no keyboard keys, so libinput won't
        // classify this as a tablet or keyboard
        try doIoctl(ptr_fd, UI_SET_KEYBIT, BTN_LEFT);
        try doIoctl(ptr_fd, UI_SET_KEYBIT, BTN_RIGHT);
        try doIoctl(ptr_fd, UI_SET_KEYBIT, BTN_MIDDLE);

        try doIoctl(ptr_fd, UI_SET_ABSBIT, ABS_X);
        try doIoctl(ptr_fd, UI_SET_ABSBIT, ABS_Y);
        try doIoctl(ptr_fd, UI_SET_RELBIT, REL_WHEEL);

        // INPUT_PROP_DIRECT: coordinates map 1:1 to screen pixels.
        // Safe here because without keyboard keys, udev classifies this
        // as a touchscreen/pointer, not a tablet.
        try doIoctl(ptr_fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

        // ABS ranges match full screen resolution
        var abs_x = UinputAbsSetup{
            .code = ABS_X,
            .minimum = 0,
            .maximum = @intCast(screen_width - 1),
            .resolution = 4,
        };
        try doIoctl(ptr_fd, UI_ABS_SETUP, @intFromPtr(&abs_x));

        var abs_y = UinputAbsSetup{
            .code = ABS_Y,
            .minimum = 0,
            .maximum = @intCast(screen_height - 1),
            .resolution = 4,
        };
        try doIoctl(ptr_fd, UI_ABS_SETUP, @intFromPtr(&abs_y));

        var ptr_setup = std.mem.zeroes(UinputSetup);
        ptr_setup.id = .{ .bustype = BUS_VIRTUAL, .vendor = 0x0CA5, .product = 0x0001, .version = 1 };
        const ptr_name = "zerocast-pointer";
        @memcpy(ptr_setup.name[0..ptr_name.len], ptr_name);
        try doIoctl(ptr_fd, UI_DEV_SETUP, @intFromPtr(&ptr_setup));
        try doIoctl(ptr_fd, UI_DEV_CREATE, 0);

        // ── Keyboard device: keys only ───────────────────────────────
        const kbd_fd = posix.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch |err| {
            log.warn("cannot open /dev/uinput for keyboard: {}", .{err});
            return error.UinputUnavailable;
        };
        errdefer posix.close(kbd_fd);

        try doIoctl(kbd_fd, UI_SET_EVBIT, EV_SYN);
        try doIoctl(kbd_fd, UI_SET_EVBIT, EV_KEY);

        var key_code: u32 = 0;
        while (key_code <= 255) : (key_code += 1) {
            try doIoctl(kbd_fd, UI_SET_KEYBIT, key_code);
        }

        var kbd_setup = std.mem.zeroes(UinputSetup);
        kbd_setup.id = .{ .bustype = BUS_VIRTUAL, .vendor = 0x0CA5, .product = 0x0002, .version = 1 };
        const kbd_name = "zerocast-keyboard";
        @memcpy(kbd_setup.name[0..kbd_name.len], kbd_name);
        try doIoctl(kbd_fd, UI_DEV_SETUP, @intFromPtr(&kbd_setup));
        try doIoctl(kbd_fd, UI_DEV_CREATE, 0);

        log.info("virtual input: pointer ({d}x{d}, offset +{d}+{d}) + keyboard", .{ screen_width, screen_height, x_offset, y_offset });
        return .{ .pointer_fd = ptr_fd, .keyboard_fd = kbd_fd, .x_offset = x_offset, .y_offset = y_offset };
    }

    pub fn deinit(self: *VirtualInput) void {
        doIoctl(self.pointer_fd, UI_DEV_DESTROY, 0) catch {};
        posix.close(self.pointer_fd);
        doIoctl(self.keyboard_fd, UI_DEV_DESTROY, 0) catch {};
        posix.close(self.keyboard_fd);
    }

    /// Inject a key press or release. `value`: 1=down, 0=up.
    pub fn injectKey(self: *VirtualInput, linux_keycode: u16, value: i32) void {
        self.writeKbd(EV_KEY, linux_keycode, value);
        self.writeKbd(EV_SYN, SYN_REPORT, 0);
    }

    /// Inject a key event from a KeyboardEvent.code string.
    pub fn injectKeyCode(self: *VirtualInput, code: []const u8, value: i32) void {
        if (keymap.lookup(code)) |linux_key| {
            self.injectKey(linux_key, value);
        }
    }

    /// Move mouse to absolute screen coordinates (applies geometry offset).
    pub fn moveMouse(self: *VirtualInput, x: u16, y: u16) void {
        self.writePtr(EV_ABS, ABS_X, @as(i32, x) + self.x_offset);
        self.writePtr(EV_ABS, ABS_Y, @as(i32, y) + self.y_offset);
        self.writePtr(EV_SYN, SYN_REPORT, 0);
    }

    /// Inject a mouse button press or release.
    pub fn injectMouseButton(self: *VirtualInput, button: u8, value: i32) void {
        const btn: u16 = switch (button) {
            0 => BTN_LEFT,
            1 => BTN_RIGHT,
            2 => BTN_MIDDLE,
            else => return,
        };
        self.writePtr(EV_KEY, btn, value);
        self.writePtr(EV_SYN, SYN_REPORT, 0);
    }

    /// Inject scroll event.
    pub fn injectScroll(self: *VirtualInput, delta: i16) void {
        const steps: i32 = @divTrunc(@as(i32, delta), 120);
        if (steps != 0) {
            self.writePtr(EV_REL, REL_WHEEL, steps);
            self.writePtr(EV_SYN, SYN_REPORT, 0);
        }
    }

    fn writePtr(self: *VirtualInput, ev_type: u16, code: u16, value: i32) void {
        writeEvent(self.pointer_fd, ev_type, code, value);
    }

    fn writeKbd(self: *VirtualInput, ev_type: u16, code: u16, value: i32) void {
        writeEvent(self.keyboard_fd, ev_type, code, value);
    }

    fn writeEvent(fd: posix.fd_t, ev_type: u16, code: u16, value: i32) void {
        const event = InputEvent{
            .tv_sec = 0,
            .tv_usec = 0,
            .type = ev_type,
            .code = code,
            .value = value,
        };
        _ = posix.write(fd, std.mem.asBytes(&event)) catch {};
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "ioctl constants match linux/uinput.h" {
    // UI_SET_EVBIT: _IOW('U', 100, int) = direction=1, type='U', nr=100, size=4
    try std.testing.expectEqual(UI_SET_EVBIT, (1 << 30) | (@as(u32, 'U') << 8) | 100 | (4 << 16));
    // UI_SET_KEYBIT: _IOW('U', 101, int)
    try std.testing.expectEqual(UI_SET_KEYBIT, (1 << 30) | (@as(u32, 'U') << 8) | 101 | (4 << 16));
    // UI_SET_RELBIT: _IOW('U', 102, int)
    try std.testing.expectEqual(UI_SET_RELBIT, (1 << 30) | (@as(u32, 'U') << 8) | 102 | (4 << 16));
    // UI_SET_ABSBIT: _IOW('U', 103, int)
    try std.testing.expectEqual(UI_SET_ABSBIT, (1 << 30) | (@as(u32, 'U') << 8) | 103 | (4 << 16));
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
