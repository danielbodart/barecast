const std = @import("std");

/// Map from KeyboardEvent.code (Web API string) to macOS virtual keycode.
/// Uses a compile-time StaticStringMap for O(1) lookup.
///
/// Virtual keycodes from Carbon HIToolbox Events.h (kVK_* constants).
/// These represent physical key positions on an ANSI keyboard layout.

// Letters (ANSI layout — physical positions, not characters)
const kVK_ANSI_A = 0x00;
const kVK_ANSI_S = 0x01;
const kVK_ANSI_D = 0x02;
const kVK_ANSI_F = 0x03;
const kVK_ANSI_H = 0x04;
const kVK_ANSI_G = 0x05;
const kVK_ANSI_Z = 0x06;
const kVK_ANSI_X = 0x07;
const kVK_ANSI_C = 0x08;
const kVK_ANSI_V = 0x09;
const kVK_ANSI_B = 0x0B;
const kVK_ANSI_Q = 0x0C;
const kVK_ANSI_W = 0x0D;
const kVK_ANSI_E = 0x0E;
const kVK_ANSI_R = 0x0F;
const kVK_ANSI_Y = 0x10;
const kVK_ANSI_T = 0x11;
const kVK_ANSI_1 = 0x12;
const kVK_ANSI_2 = 0x13;
const kVK_ANSI_3 = 0x14;
const kVK_ANSI_4 = 0x15;
const kVK_ANSI_6 = 0x16;
const kVK_ANSI_5 = 0x17;
const kVK_ANSI_Equal = 0x18;
const kVK_ANSI_9 = 0x19;
const kVK_ANSI_7 = 0x1A;
const kVK_ANSI_Minus = 0x1B;
const kVK_ANSI_8 = 0x1C;
const kVK_ANSI_0 = 0x1D;
const kVK_ANSI_RightBracket = 0x1E;
const kVK_ANSI_O = 0x1F;
const kVK_ANSI_U = 0x20;
const kVK_ANSI_LeftBracket = 0x21;
const kVK_ANSI_I = 0x22;
const kVK_ANSI_P = 0x23;
const kVK_ANSI_L = 0x25;
const kVK_ANSI_J = 0x26;
const kVK_ANSI_Quote = 0x27;
const kVK_ANSI_K = 0x28;
const kVK_ANSI_Semicolon = 0x29;
const kVK_ANSI_Backslash = 0x2A;
const kVK_ANSI_Comma = 0x2B;
const kVK_ANSI_Slash = 0x2C;
const kVK_ANSI_N = 0x2D;
const kVK_ANSI_M = 0x2E;
const kVK_ANSI_Period = 0x2F;
const kVK_ANSI_Grave = 0x32;

// Numpad
const kVK_ANSI_KeypadDecimal = 0x41;
const kVK_ANSI_KeypadMultiply = 0x43;
const kVK_ANSI_KeypadPlus = 0x45;
const kVK_ANSI_KeypadClear = 0x47;
const kVK_ANSI_KeypadDivide = 0x4B;
const kVK_ANSI_KeypadEnter = 0x4C;
const kVK_ANSI_KeypadMinus = 0x4E;
const kVK_ANSI_KeypadEquals = 0x51;
const kVK_ANSI_Keypad0 = 0x52;
const kVK_ANSI_Keypad1 = 0x53;
const kVK_ANSI_Keypad2 = 0x54;
const kVK_ANSI_Keypad3 = 0x55;
const kVK_ANSI_Keypad4 = 0x56;
const kVK_ANSI_Keypad5 = 0x57;
const kVK_ANSI_Keypad6 = 0x58;
const kVK_ANSI_Keypad7 = 0x59;
const kVK_ANSI_Keypad8 = 0x5B;
const kVK_ANSI_Keypad9 = 0x5C;

// Control keys
const kVK_Return = 0x24;
const kVK_Tab = 0x30;
const kVK_Space = 0x31;
const kVK_Delete = 0x33; // Backspace
const kVK_Escape = 0x35;
const kVK_Command = 0x37;
const kVK_Shift = 0x38;
const kVK_CapsLock = 0x39;
const kVK_Option = 0x3A;
const kVK_Control = 0x3B;
const kVK_RightCommand = 0x36;
const kVK_RightShift = 0x3C;
const kVK_RightOption = 0x3D;
const kVK_RightControl = 0x3E;

// Function keys
const kVK_F1 = 0x7A;
const kVK_F2 = 0x78;
const kVK_F3 = 0x63;
const kVK_F4 = 0x76;
const kVK_F5 = 0x60;
const kVK_F6 = 0x61;
const kVK_F7 = 0x62;
const kVK_F8 = 0x64;
const kVK_F9 = 0x65;
const kVK_F10 = 0x6D;
const kVK_F11 = 0x67;
const kVK_F12 = 0x6F;

// Navigation
const kVK_Home = 0x73;
const kVK_PageUp = 0x74;
const kVK_ForwardDelete = 0x75;
const kVK_End = 0x77;
const kVK_PageDown = 0x79;

// Arrows
const kVK_LeftArrow = 0x7B;
const kVK_RightArrow = 0x7C;
const kVK_DownArrow = 0x7D;
const kVK_UpArrow = 0x7E;

// Media
const kVK_VolumeUp = 0x48;
const kVK_VolumeDown = 0x49;
const kVK_Mute = 0x4A;

// Misc
const kVK_Help = 0x72; // Insert on PC keyboards
const kVK_ContextualMenu = 0x6E;
const kVK_F13 = 0x69; // PrintScreen on PC keyboards
const kVK_JIS_KeypadComma = 0x5F;

pub const code_to_keycode = std.StaticStringMap(u16).initComptime(.{
    // Letters
    .{ "KeyA", kVK_ANSI_A },
    .{ "KeyB", kVK_ANSI_B },
    .{ "KeyC", kVK_ANSI_C },
    .{ "KeyD", kVK_ANSI_D },
    .{ "KeyE", kVK_ANSI_E },
    .{ "KeyF", kVK_ANSI_F },
    .{ "KeyG", kVK_ANSI_G },
    .{ "KeyH", kVK_ANSI_H },
    .{ "KeyI", kVK_ANSI_I },
    .{ "KeyJ", kVK_ANSI_J },
    .{ "KeyK", kVK_ANSI_K },
    .{ "KeyL", kVK_ANSI_L },
    .{ "KeyM", kVK_ANSI_M },
    .{ "KeyN", kVK_ANSI_N },
    .{ "KeyO", kVK_ANSI_O },
    .{ "KeyP", kVK_ANSI_P },
    .{ "KeyQ", kVK_ANSI_Q },
    .{ "KeyR", kVK_ANSI_R },
    .{ "KeyS", kVK_ANSI_S },
    .{ "KeyT", kVK_ANSI_T },
    .{ "KeyU", kVK_ANSI_U },
    .{ "KeyV", kVK_ANSI_V },
    .{ "KeyW", kVK_ANSI_W },
    .{ "KeyX", kVK_ANSI_X },
    .{ "KeyY", kVK_ANSI_Y },
    .{ "KeyZ", kVK_ANSI_Z },

    // Digits
    .{ "Digit0", kVK_ANSI_0 },
    .{ "Digit1", kVK_ANSI_1 },
    .{ "Digit2", kVK_ANSI_2 },
    .{ "Digit3", kVK_ANSI_3 },
    .{ "Digit4", kVK_ANSI_4 },
    .{ "Digit5", kVK_ANSI_5 },
    .{ "Digit6", kVK_ANSI_6 },
    .{ "Digit7", kVK_ANSI_7 },
    .{ "Digit8", kVK_ANSI_8 },
    .{ "Digit9", kVK_ANSI_9 },

    // Function keys
    .{ "F1", kVK_F1 },
    .{ "F2", kVK_F2 },
    .{ "F3", kVK_F3 },
    .{ "F4", kVK_F4 },
    .{ "F5", kVK_F5 },
    .{ "F6", kVK_F6 },
    .{ "F7", kVK_F7 },
    .{ "F8", kVK_F8 },
    .{ "F9", kVK_F9 },
    .{ "F10", kVK_F10 },
    .{ "F11", kVK_F11 },
    .{ "F12", kVK_F12 },

    // Modifiers
    .{ "ShiftLeft", kVK_Shift },
    .{ "ShiftRight", kVK_RightShift },
    .{ "ControlLeft", kVK_Control },
    .{ "ControlRight", kVK_RightControl },
    .{ "AltLeft", kVK_Option },
    .{ "AltRight", kVK_RightOption },
    .{ "MetaLeft", kVK_Command },
    .{ "MetaRight", kVK_RightCommand },

    // Punctuation & symbols
    .{ "Backquote", kVK_ANSI_Grave },
    .{ "Minus", kVK_ANSI_Minus },
    .{ "Equal", kVK_ANSI_Equal },
    .{ "BracketLeft", kVK_ANSI_LeftBracket },
    .{ "BracketRight", kVK_ANSI_RightBracket },
    .{ "Backslash", kVK_ANSI_Backslash },
    .{ "Semicolon", kVK_ANSI_Semicolon },
    .{ "Quote", kVK_ANSI_Quote },
    .{ "Comma", kVK_ANSI_Comma },
    .{ "Period", kVK_ANSI_Period },
    .{ "Slash", kVK_ANSI_Slash },

    // Control keys
    .{ "Escape", kVK_Escape },
    .{ "Tab", kVK_Tab },
    .{ "CapsLock", kVK_CapsLock },
    .{ "Space", kVK_Space },
    .{ "Enter", kVK_Return },
    .{ "Backspace", kVK_Delete },
    .{ "Delete", kVK_ForwardDelete },
    .{ "Insert", kVK_Help }, // PC Insert maps to Mac Help key
    .{ "Home", kVK_Home },
    .{ "End", kVK_End },
    .{ "PageUp", kVK_PageUp },
    .{ "PageDown", kVK_PageDown },
    .{ "PrintScreen", kVK_F13 }, // PC PrintScreen → Mac F13
    .{ "ContextMenu", kVK_ContextualMenu },
    .{ "NumLock", kVK_ANSI_KeypadClear }, // Mac uses Clear instead of NumLock
    // ScrollLock and Pause have no macOS equivalent — silently dropped

    // Arrow keys
    .{ "ArrowUp", kVK_UpArrow },
    .{ "ArrowDown", kVK_DownArrow },
    .{ "ArrowLeft", kVK_LeftArrow },
    .{ "ArrowRight", kVK_RightArrow },

    // Numpad
    .{ "Numpad0", kVK_ANSI_Keypad0 },
    .{ "Numpad1", kVK_ANSI_Keypad1 },
    .{ "Numpad2", kVK_ANSI_Keypad2 },
    .{ "Numpad3", kVK_ANSI_Keypad3 },
    .{ "Numpad4", kVK_ANSI_Keypad4 },
    .{ "Numpad5", kVK_ANSI_Keypad5 },
    .{ "Numpad6", kVK_ANSI_Keypad6 },
    .{ "Numpad7", kVK_ANSI_Keypad7 },
    .{ "Numpad8", kVK_ANSI_Keypad8 },
    .{ "Numpad9", kVK_ANSI_Keypad9 },
    .{ "NumpadAdd", kVK_ANSI_KeypadPlus },
    .{ "NumpadSubtract", kVK_ANSI_KeypadMinus },
    .{ "NumpadMultiply", kVK_ANSI_KeypadMultiply },
    .{ "NumpadDivide", kVK_ANSI_KeypadDivide },
    .{ "NumpadDecimal", kVK_ANSI_KeypadDecimal },
    .{ "NumpadEnter", kVK_ANSI_KeypadEnter },
    .{ "NumpadEqual", kVK_ANSI_KeypadEquals },
    .{ "NumpadComma", kVK_JIS_KeypadComma },

    // Audio keys
    .{ "AudioVolumeMute", kVK_Mute },
    .{ "AudioVolumeDown", kVK_VolumeDown },
    .{ "AudioVolumeUp", kVK_VolumeUp },
});

/// Look up a macOS virtual keycode from a KeyboardEvent.code string.
pub fn lookup(code: []const u8) ?u16 {
    return code_to_keycode.get(code);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "lookup letters" {
    try std.testing.expectEqual(lookup("KeyA").?, kVK_ANSI_A);
    try std.testing.expectEqual(lookup("KeyZ").?, kVK_ANSI_Z);
}

test "lookup digits" {
    try std.testing.expectEqual(lookup("Digit0").?, kVK_ANSI_0);
    try std.testing.expectEqual(lookup("Digit9").?, kVK_ANSI_9);
}

test "lookup function keys" {
    try std.testing.expectEqual(lookup("F1").?, kVK_F1);
    try std.testing.expectEqual(lookup("F12").?, kVK_F12);
}

test "lookup modifiers" {
    try std.testing.expectEqual(lookup("ShiftLeft").?, kVK_Shift);
    try std.testing.expectEqual(lookup("ControlRight").?, kVK_RightControl);
    try std.testing.expectEqual(lookup("AltLeft").?, kVK_Option);
    try std.testing.expectEqual(lookup("MetaLeft").?, kVK_Command);
}

test "lookup arrows" {
    try std.testing.expectEqual(lookup("ArrowUp").?, kVK_UpArrow);
    try std.testing.expectEqual(lookup("ArrowDown").?, kVK_DownArrow);
    try std.testing.expectEqual(lookup("ArrowLeft").?, kVK_LeftArrow);
    try std.testing.expectEqual(lookup("ArrowRight").?, kVK_RightArrow);
}

test "lookup control keys" {
    try std.testing.expectEqual(lookup("Escape").?, kVK_Escape);
    try std.testing.expectEqual(lookup("Space").?, kVK_Space);
    try std.testing.expectEqual(lookup("Enter").?, kVK_Return);
    try std.testing.expectEqual(lookup("Backspace").?, kVK_Delete);
    try std.testing.expectEqual(lookup("Tab").?, kVK_Tab);
    try std.testing.expectEqual(lookup("Delete").?, kVK_ForwardDelete);
}

test "lookup numpad" {
    try std.testing.expectEqual(lookup("Numpad0").?, kVK_ANSI_Keypad0);
    try std.testing.expectEqual(lookup("NumpadAdd").?, kVK_ANSI_KeypadPlus);
    try std.testing.expectEqual(lookup("NumpadEnter").?, kVK_ANSI_KeypadEnter);
}

test "lookup punctuation" {
    try std.testing.expectEqual(lookup("Backquote").?, kVK_ANSI_Grave);
    try std.testing.expectEqual(lookup("Semicolon").?, kVK_ANSI_Semicolon);
    try std.testing.expectEqual(lookup("Comma").?, kVK_ANSI_Comma);
    try std.testing.expectEqual(lookup("Period").?, kVK_ANSI_Period);
    try std.testing.expectEqual(lookup("Slash").?, kVK_ANSI_Slash);
}

test "lookup unknown returns null" {
    try std.testing.expect(lookup("NonExistentKey") == null);
    try std.testing.expect(lookup("") == null);
    try std.testing.expect(lookup("keya") == null); // case-sensitive
}

test "lookup covers all standard keys" {
    const required = [_][]const u8{
        "KeyA",     "KeyZ",      "Digit0",       "Digit9",
        "F1",       "F12",       "ShiftLeft",     "ControlRight",
        "ArrowUp",  "ArrowDown", "ArrowLeft",     "ArrowRight",
        "Space",    "Enter",     "Backspace",     "Tab",
        "Escape",   "Numpad0",   "NumpadEnter",
        "Comma",    "Period",    "Slash",         "Semicolon",
    };
    for (required) |code| {
        try std.testing.expect(lookup(code) != null);
    }
}
