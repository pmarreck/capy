const std = @import("std");
const builtin = @import("builtin");

/// Supplies synchronous runtime facilities to the library without changing its
/// public API to carry Zig 0.16's dependency-injected I/O handle everywhere.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn monotonicNow() std.Io.Timestamp {
    return std.Io.Timestamp.now(io(), .awake);
}

pub fn elapsedNanosecondsSince(start: std.Io.Timestamp) u64 {
    const elapsed = start.durationTo(monotonicNow()).nanoseconds;
    return if (elapsed <= 0) 0 else @intCast(elapsed);
}

pub fn getEnv(name: [:0]const u8) ?[]const u8 {
    if (comptime !builtin.link_libc) return null;
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

/// Preserves the old synchronous mutex interface for short critical sections.
pub const Lock = struct {
    state: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *Lock) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Lock) void {
        self.state.unlock();
    }

    pub fn lockShared(self: *Lock) void {
        self.lock();
    }

    pub fn unlockShared(self: *Lock) void {
        self.unlock();
    }
};
