//! URI based system for retrieving assets
const std = @import("std");
const http = @import("http.zig");
const internal = @import("internal.zig");
const runtime = @import("runtime.zig");
const log = std.log.scoped(.assets);
const Uri = std.Uri;

const GetError = Uri.ParseError || http.SendRequestError || error{ UnsupportedScheme, InvalidPath } || std.mem.Allocator.Error;

pub const AssetHandle = struct {
    data: union(enum) {
        http: http.HttpResponse,
        file: std.Io.File,
    },

    pub const ReadError = http.HttpResponse.ReadError || std.Io.File.ReadStreamingError;

    pub fn read(self: *AssetHandle, dest: []u8) ReadError!usize {
        switch (self.data) {
            .http => |*resp| {
                return try resp.read(dest);
            },
            .file => |file| {
                return file.readStreaming(runtime.io(), &.{dest}) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => |read_err| return read_err,
                };
            },
        }
    }

    /// Read all contents into an allocated buffer
    pub fn readAllAlloc(self: *AssetHandle, alloc: std.mem.Allocator, max_size: usize) ![]u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(alloc);
        var buf: [4096]u8 = undefined;
        while (true) {
            if (result.items.len == max_size) {
                const overflow = try self.read(buf[0..1]);
                if (overflow != 0) return error.StreamTooLong;
                break;
            }
            const remaining = max_size - result.items.len;
            const n = try self.read(buf[0..@min(buf.len, remaining)]);
            if (n == 0) break;
            try result.appendSlice(alloc, buf[0..n]);
        }
        return result.toOwnedSlice(alloc);
    }

    pub fn deinit(self: *AssetHandle) void {
        switch (self.data) {
            .http => |*resp| {
                resp.deinit();
            },
            .file => |file| {
                file.close(runtime.io());
            },
        }
    }
};

pub fn get(url: []const u8) GetError!AssetHandle {
    // Normalize the URI for the file:// and asset:// scheme
    var out_url: [4096]u8 = undefined;
    const new_size = std.mem.replacementSize(u8, url, "///", "/");
    _ = std.mem.replace(u8, url, "///", "/", &out_url);

    const uri = try Uri.parse(out_url[0..new_size]);
    log.debug("Loading {s}", .{url});

    if (std.mem.eql(u8, uri.scheme, "asset")) {
        var raw_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const raw_uri_path = uri.path.toRaw(&raw_path_buf) catch return error.InvalidPath;
        const relative_asset_path = std.mem.trimStart(u8, raw_uri_path, "/\\");

        const asset_path = try std.fs.path.join(internal.allocator, &.{ "assets", relative_asset_path });
        defer internal.allocator.free(asset_path);
        log.debug("-> {s}", .{asset_path});

        const file = try std.Io.Dir.cwd().openFile(runtime.io(), asset_path, .{});
        return AssetHandle{ .data = .{ .file = file } };
    } else if (std.mem.eql(u8, uri.scheme, "file")) {
        var raw_path_buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const raw_uri_path = uri.path.toRaw(&raw_path_buf2) catch return error.InvalidPath;

        log.debug("-> {s}", .{raw_uri_path});
        const file = try std.Io.Dir.openFileAbsolute(runtime.io(), raw_uri_path, .{});
        return AssetHandle{ .data = .{ .file = file } };
    } else if (std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https")) {
        const request = http.HttpRequest.get(url);
        var response = try request.send();

        while (!response.isReady()) {
            // TODO: suspend; when async is back
        }
        try response.checkError();

        return AssetHandle{ .data = .{ .http = response } };
    } else {
        return error.UnsupportedScheme;
    }
}

test "asset:// URI loads file from assets directory" {
    // internal.allocator defaults to std.testing.allocator in test mode
    var handle = try get("asset:///ziglogo.png");
    defer handle.deinit();
    const contents = try handle.readAllAlloc(std.testing.allocator, std.math.maxInt(usize));
    defer std.testing.allocator.free(contents);
    // PNG files start with the magic bytes 0x89 P N G
    try std.testing.expect(contents.len > 8);
    try std.testing.expectEqual(@as(u8, 0x89), contents[0]);
    try std.testing.expectEqual(@as(u8, 'P'), contents[1]);
    try std.testing.expectEqual(@as(u8, 'N'), contents[2]);
    try std.testing.expectEqual(@as(u8, 'G'), contents[3]);
}

test "triple-slash URI normalization" {
    // Verify that asset:///path normalizes correctly (the bug that caused SIGABRT)
    var out_url: [4096]u8 = undefined;
    const url = "asset:///ziglogo.png";
    const new_size = std.mem.replacementSize(u8, url, "///", "/");
    _ = std.mem.replace(u8, url, "///", "/", &out_url);
    const normalized = out_url[0..new_size];
    // After normalization, "asset:///ziglogo.png" -> "asset:/ziglogo.png"
    try std.testing.expectEqualStrings("asset:/ziglogo.png", normalized);
    // Verify it parses as a valid URI
    const uri = try Uri.parse(normalized);
    try std.testing.expectEqualStrings("asset", uri.scheme);
}

test "unsupported scheme returns error" {
    // internal.allocator defaults to std.testing.allocator in test mode
    const result = get("ftp://example.com/file.png");
    try std.testing.expectError(error.UnsupportedScheme, result);
}

test "AssetHandle.readAllAlloc accepts exact limit and rejects oversized file" {
    const tmp_root = runtime.getEnv("TMPDIR") orelse return error.MissingTmpDir;
    var tmp_dir = try std.Io.Dir.openDirAbsolute(runtime.io(), tmp_root, .{});
    defer tmp_dir.close(runtime.io());

    var name_buffer: [96]u8 = undefined;
    const fixture = fixture: for (0..1024) |suffix| {
        const name = try std.fmt.bufPrint(&name_buffer, "capy-assets-read-limit-{d}", .{suffix});
        const file = tmp_dir.createFile(runtime.io(), name, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break :fixture .{ .name = name, .file = file };
    } else return error.NoTemporaryFileNameAvailable;
    defer tmp_dir.deleteFile(runtime.io(), fixture.name) catch |err| {
        std.debug.panic("failed to remove TMPDIR asset fixture: {s}", .{@errorName(err)});
    };

    {
        var fixture_file = fixture.file;
        defer fixture_file.close(runtime.io());
        try fixture_file.writeStreamingAll(runtime.io(), "abcde");
    }

    {
        const file = try tmp_dir.openFile(runtime.io(), fixture.name, .{});
        var handle = AssetHandle{ .data = .{ .file = file } };
        defer handle.deinit();
        const exact = try handle.readAllAlloc(std.testing.allocator, 5);
        defer std.testing.allocator.free(exact);
        try std.testing.expectEqualStrings("abcde", exact);
    }

    {
        const file = try tmp_dir.openFile(runtime.io(), fixture.name, .{});
        var handle = AssetHandle{ .data = .{ .file = file } };
        defer handle.deinit();
        if (handle.readAllAlloc(std.testing.allocator, 4)) |unexpected| {
            std.testing.allocator.free(unexpected);
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqual(error.StreamTooLong, err);
        }
    }
}
