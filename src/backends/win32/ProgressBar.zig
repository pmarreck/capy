const std = @import("std");
const lib = @import("../../capy.zig");
const win32Backend = @import("win32.zig");
const zigwin32 = @import("zigwin32");
const win32 = zigwin32.everything;
const Events = @import("backend.zig").Events;
const L = zigwin32.zig.L;

const ProgressBar = @This();

peer: win32.HWND,

const PBM_SETRANGE32: u32 = 0x0406;
const PBM_SETPOS: u32 = 0x0402;

const _events = Events(@This());
pub const process = _events.process;
pub const setupEvents = _events.setupEvents;
pub const setUserData = _events.setUserData;
pub const setCallback = _events.setCallback;
pub const requestDraw = _events.requestDraw;
pub const getWidth = _events.getWidth;
pub const getHeight = _events.getHeight;
pub const getPreferredSize = _events.getPreferredSize;
pub const setOpacity = _events.setOpacity;
pub const deinit = _events.deinit;

pub fn create() !ProgressBar {
    const hwnd = win32.CreateWindowExW(
        @as(win32.WINDOW_EX_STYLE, @enumFromInt(0)), // dwExtStyle
        L("msctls_progress32"), // lpClassName
        L(""), // lpWindowName
        @as(win32.WINDOW_STYLE, @enumFromInt(
            @intFromEnum(win32.WS_CHILD) |
                @intFromEnum(win32.WS_VISIBLE),
        )), // dwStyle
        0, // X
        0, // Y
        200, // nWidth
        20, // nHeight
        @import("backend.zig").defaultWHWND, // hWndParent
        null, // hMenu
        @import("backend.zig").hInst, // hInstance
        null, // lpParam
    ) orelse return @import("backend.zig").Win32Error.InitializationError;

    try ProgressBar.setupEvents(hwnd);
    // Set range 0-1000 for finer granularity (value is f32 0.0-1.0)
    _ = win32.SendMessageW(hwnd, PBM_SETRANGE32, 0, 1000);

    return ProgressBar{ .peer = hwnd };
}

pub fn setValue(self: *ProgressBar, value: f32) void {
    const pos: i32 = @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 1000.0);
    _ = win32.SendMessageW(self.peer, PBM_SETPOS, @intCast(pos), 0);
}
