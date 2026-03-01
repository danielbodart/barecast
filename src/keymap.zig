const std = @import("std");

/// Map from KeyboardEvent.code (Web API string) to Linux input event keycode.
/// Uses a compile-time StaticStringMap for O(1) lookup.
///
/// The host owns the mapping — browser sends the platform-independent `code`
/// string (e.g. "KeyA", "ShiftLeft"), and we resolve to Linux keycodes here.
/// This makes the protocol portable across Mac/Windows/Linux browsers.

// Linux keycodes from linux/input-event-codes.h
// Only the subset reachable from standard keyboards.
const KEY_ESC = 1;
const KEY_1 = 2;
const KEY_2 = 3;
const KEY_3 = 4;
const KEY_4 = 5;
const KEY_5 = 6;
const KEY_6 = 7;
const KEY_7 = 8;
const KEY_8 = 9;
const KEY_9 = 10;
const KEY_0 = 11;
const KEY_MINUS = 12;
const KEY_EQUAL = 13;
const KEY_BACKSPACE = 14;
const KEY_TAB = 15;
const KEY_Q = 16;
const KEY_W = 17;
const KEY_E = 18;
const KEY_R = 19;
const KEY_T = 20;
const KEY_Y = 21;
const KEY_U = 22;
const KEY_I = 23;
const KEY_O = 24;
const KEY_P = 25;
const KEY_LEFTBRACE = 26;
const KEY_RIGHTBRACE = 27;
const KEY_ENTER = 28;
const KEY_LEFTCTRL = 29;
const KEY_A = 30;
const KEY_S = 31;
const KEY_D = 32;
const KEY_F = 33;
const KEY_G = 34;
const KEY_H = 35;
const KEY_J = 36;
const KEY_K = 37;
const KEY_L = 38;
const KEY_SEMICOLON = 39;
const KEY_APOSTROPHE = 40;
const KEY_GRAVE = 41;
const KEY_LEFTSHIFT = 42;
const KEY_BACKSLASH = 43;
const KEY_Z = 44;
const KEY_X = 45;
const KEY_C = 46;
const KEY_V = 47;
const KEY_B = 48;
const KEY_N = 49;
const KEY_M = 50;
const KEY_COMMA = 51;
const KEY_DOT = 52;
const KEY_SLASH = 53;
const KEY_RIGHTSHIFT = 54;
const KEY_KPASTERISK = 55;
const KEY_LEFTALT = 56;
const KEY_SPACE = 57;
const KEY_CAPSLOCK = 58;
const KEY_F1 = 59;
const KEY_F2 = 60;
const KEY_F3 = 61;
const KEY_F4 = 62;
const KEY_F5 = 63;
const KEY_F6 = 64;
const KEY_F7 = 65;
const KEY_F8 = 66;
const KEY_F9 = 67;
const KEY_F10 = 68;
const KEY_NUMLOCK = 69;
const KEY_SCROLLLOCK = 70;
const KEY_KP7 = 71;
const KEY_KP8 = 72;
const KEY_KP9 = 73;
const KEY_KPMINUS = 74;
const KEY_KP4 = 75;
const KEY_KP5 = 76;
const KEY_KP6 = 77;
const KEY_KPPLUS = 78;
const KEY_KP1 = 79;
const KEY_KP2 = 80;
const KEY_KP3 = 81;
const KEY_KP0 = 82;
const KEY_KPDOT = 83;
const KEY_F11 = 87;
const KEY_F12 = 88;
const KEY_KPENTER = 96;
const KEY_RIGHTCTRL = 97;
const KEY_KPSLASH = 98;
const KEY_SYSRQ = 99;
const KEY_RIGHTALT = 100;
const KEY_HOME = 102;
const KEY_UP = 103;
const KEY_PAGEUP = 104;
const KEY_LEFT = 105;
const KEY_RIGHT = 106;
const KEY_END = 107;
const KEY_DOWN = 108;
const KEY_PAGEDOWN = 109;
const KEY_INSERT = 110;
const KEY_DELETE = 111;
const KEY_MUTE = 113;
const KEY_VOLUMEDOWN = 114;
const KEY_VOLUMEUP = 115;
const KEY_PAUSE = 119;
const KEY_KPCOMMA = 121;
const KEY_LEFTMETA = 125;
const KEY_RIGHTMETA = 126;
const KEY_KPEQUAL = 117;
const KEY_CONTEXT_MENU = 127;

pub const code_to_keycode = std.StaticStringMap(u16).initComptime(.{
    // Letters
    .{ "KeyA", KEY_A },
    .{ "KeyB", KEY_B },
    .{ "KeyC", KEY_C },
    .{ "KeyD", KEY_D },
    .{ "KeyE", KEY_E },
    .{ "KeyF", KEY_F },
    .{ "KeyG", KEY_G },
    .{ "KeyH", KEY_H },
    .{ "KeyI", KEY_I },
    .{ "KeyJ", KEY_J },
    .{ "KeyK", KEY_K },
    .{ "KeyL", KEY_L },
    .{ "KeyM", KEY_M },
    .{ "KeyN", KEY_N },
    .{ "KeyO", KEY_O },
    .{ "KeyP", KEY_P },
    .{ "KeyQ", KEY_Q },
    .{ "KeyR", KEY_R },
    .{ "KeyS", KEY_S },
    .{ "KeyT", KEY_T },
    .{ "KeyU", KEY_U },
    .{ "KeyV", KEY_V },
    .{ "KeyW", KEY_W },
    .{ "KeyX", KEY_X },
    .{ "KeyY", KEY_Y },
    .{ "KeyZ", KEY_Z },

    // Digits
    .{ "Digit0", KEY_0 },
    .{ "Digit1", KEY_1 },
    .{ "Digit2", KEY_2 },
    .{ "Digit3", KEY_3 },
    .{ "Digit4", KEY_4 },
    .{ "Digit5", KEY_5 },
    .{ "Digit6", KEY_6 },
    .{ "Digit7", KEY_7 },
    .{ "Digit8", KEY_8 },
    .{ "Digit9", KEY_9 },

    // Function keys
    .{ "F1", KEY_F1 },
    .{ "F2", KEY_F2 },
    .{ "F3", KEY_F3 },
    .{ "F4", KEY_F4 },
    .{ "F5", KEY_F5 },
    .{ "F6", KEY_F6 },
    .{ "F7", KEY_F7 },
    .{ "F8", KEY_F8 },
    .{ "F9", KEY_F9 },
    .{ "F10", KEY_F10 },
    .{ "F11", KEY_F11 },
    .{ "F12", KEY_F12 },

    // Modifiers
    .{ "ShiftLeft", KEY_LEFTSHIFT },
    .{ "ShiftRight", KEY_RIGHTSHIFT },
    .{ "ControlLeft", KEY_LEFTCTRL },
    .{ "ControlRight", KEY_RIGHTCTRL },
    .{ "AltLeft", KEY_LEFTALT },
    .{ "AltRight", KEY_RIGHTALT },
    .{ "MetaLeft", KEY_LEFTMETA },
    .{ "MetaRight", KEY_RIGHTMETA },

    // Punctuation & symbols
    .{ "Backquote", KEY_GRAVE },
    .{ "Minus", KEY_MINUS },
    .{ "Equal", KEY_EQUAL },
    .{ "BracketLeft", KEY_LEFTBRACE },
    .{ "BracketRight", KEY_RIGHTBRACE },
    .{ "Backslash", KEY_BACKSLASH },
    .{ "Semicolon", KEY_SEMICOLON },
    .{ "Quote", KEY_APOSTROPHE },
    .{ "Comma", KEY_COMMA },
    .{ "Period", KEY_DOT },
    .{ "Slash", KEY_SLASH },

    // Control keys
    .{ "Escape", KEY_ESC },
    .{ "Tab", KEY_TAB },
    .{ "CapsLock", KEY_CAPSLOCK },
    .{ "Space", KEY_SPACE },
    .{ "Enter", KEY_ENTER },
    .{ "Backspace", KEY_BACKSPACE },
    .{ "Delete", KEY_DELETE },
    .{ "Insert", KEY_INSERT },
    .{ "Home", KEY_HOME },
    .{ "End", KEY_END },
    .{ "PageUp", KEY_PAGEUP },
    .{ "PageDown", KEY_PAGEDOWN },
    .{ "PrintScreen", KEY_SYSRQ },
    .{ "ScrollLock", KEY_SCROLLLOCK },
    .{ "Pause", KEY_PAUSE },
    .{ "ContextMenu", KEY_CONTEXT_MENU },
    .{ "NumLock", KEY_NUMLOCK },

    // Arrow keys
    .{ "ArrowUp", KEY_UP },
    .{ "ArrowDown", KEY_DOWN },
    .{ "ArrowLeft", KEY_LEFT },
    .{ "ArrowRight", KEY_RIGHT },

    // Numpad
    .{ "Numpad0", KEY_KP0 },
    .{ "Numpad1", KEY_KP1 },
    .{ "Numpad2", KEY_KP2 },
    .{ "Numpad3", KEY_KP3 },
    .{ "Numpad4", KEY_KP4 },
    .{ "Numpad5", KEY_KP5 },
    .{ "Numpad6", KEY_KP6 },
    .{ "Numpad7", KEY_KP7 },
    .{ "Numpad8", KEY_KP8 },
    .{ "Numpad9", KEY_KP9 },
    .{ "NumpadAdd", KEY_KPPLUS },
    .{ "NumpadSubtract", KEY_KPMINUS },
    .{ "NumpadMultiply", KEY_KPASTERISK },
    .{ "NumpadDivide", KEY_KPSLASH },
    .{ "NumpadDecimal", KEY_KPDOT },
    .{ "NumpadEnter", KEY_KPENTER },
    .{ "NumpadEqual", KEY_KPEQUAL },
    .{ "NumpadComma", KEY_KPCOMMA },

    // Audio keys (common on modern keyboards)
    .{ "AudioVolumeMute", KEY_MUTE },
    .{ "AudioVolumeDown", KEY_VOLUMEDOWN },
    .{ "AudioVolumeUp", KEY_VOLUMEUP },
});

/// Look up a Linux keycode from a KeyboardEvent.code string.
pub fn lookup(code: []const u8) ?u16 {
    return code_to_keycode.get(code);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "lookup letters" {
    try std.testing.expectEqual(lookup("KeyA").?, KEY_A);
    try std.testing.expectEqual(lookup("KeyZ").?, KEY_Z);
}

test "lookup digits" {
    try std.testing.expectEqual(lookup("Digit0").?, KEY_0);
    try std.testing.expectEqual(lookup("Digit9").?, KEY_9);
}

test "lookup function keys" {
    try std.testing.expectEqual(lookup("F1").?, KEY_F1);
    try std.testing.expectEqual(lookup("F12").?, KEY_F12);
}

test "lookup modifiers" {
    try std.testing.expectEqual(lookup("ShiftLeft").?, KEY_LEFTSHIFT);
    try std.testing.expectEqual(lookup("ControlRight").?, KEY_RIGHTCTRL);
    try std.testing.expectEqual(lookup("AltLeft").?, KEY_LEFTALT);
    try std.testing.expectEqual(lookup("MetaLeft").?, KEY_LEFTMETA);
}

test "lookup arrows" {
    try std.testing.expectEqual(lookup("ArrowUp").?, KEY_UP);
    try std.testing.expectEqual(lookup("ArrowDown").?, KEY_DOWN);
    try std.testing.expectEqual(lookup("ArrowLeft").?, KEY_LEFT);
    try std.testing.expectEqual(lookup("ArrowRight").?, KEY_RIGHT);
}

test "lookup control keys" {
    try std.testing.expectEqual(lookup("Escape").?, KEY_ESC);
    try std.testing.expectEqual(lookup("Space").?, KEY_SPACE);
    try std.testing.expectEqual(lookup("Enter").?, KEY_ENTER);
    try std.testing.expectEqual(lookup("Backspace").?, KEY_BACKSPACE);
    try std.testing.expectEqual(lookup("Tab").?, KEY_TAB);
    try std.testing.expectEqual(lookup("Delete").?, KEY_DELETE);
}

test "lookup numpad" {
    try std.testing.expectEqual(lookup("Numpad0").?, KEY_KP0);
    try std.testing.expectEqual(lookup("NumpadAdd").?, KEY_KPPLUS);
    try std.testing.expectEqual(lookup("NumpadEnter").?, KEY_KPENTER);
}

test "lookup punctuation" {
    try std.testing.expectEqual(lookup("Backquote").?, KEY_GRAVE);
    try std.testing.expectEqual(lookup("Semicolon").?, KEY_SEMICOLON);
    try std.testing.expectEqual(lookup("Comma").?, KEY_COMMA);
    try std.testing.expectEqual(lookup("Period").?, KEY_DOT);
    try std.testing.expectEqual(lookup("Slash").?, KEY_SLASH);
}

test "lookup unknown returns null" {
    try std.testing.expect(lookup("NonExistentKey") == null);
    try std.testing.expect(lookup("") == null);
    try std.testing.expect(lookup("keya") == null); // case-sensitive
}

test "lookup covers all standard keys" {
    // Verify a representative sample from each category resolves
    const required = [_][]const u8{
        "KeyA", "KeyZ", "Digit0", "Digit9",
        "F1",   "F12",  "ShiftLeft", "ControlRight",
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
        "Space", "Enter", "Backspace", "Tab", "Escape",
        "Numpad0", "NumpadEnter",
        "Comma", "Period", "Slash", "Semicolon",
    };
    for (required) |code| {
        try std.testing.expect(lookup(code) != null);
    }
}
