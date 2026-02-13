const std = @import("std");
const capy = @import("capy");

// Sample data for the table
const sample_data = [_][3][]const u8{
    .{ "Alice", "Engineer", "San Francisco" },
    .{ "Bob", "Designer", "New York" },
    .{ "Carol", "Manager", "Chicago" },
    .{ "Dave", "Developer", "Austin" },
    .{ "Eve", "Analyst", "Seattle" },
    .{ "Frank", "Architect", "Denver" },
    .{ "Grace", "Researcher", "Boston" },
    .{ "Heidi", "Consultant", "Portland" },
};

fn cellProvider(row: usize, col: usize, buf: []u8) []const u8 {
    if (row >= sample_data.len or col >= 3) return "";
    const text = sample_data[row][col];
    const len = @min(text.len, buf.len);
    @memcpy(buf[0..len], text[0..len]);
    return buf[0..len];
}

pub fn onOpenFile(_: *anyopaque) !void {
    const path = capy.openFileDialog(.{
        .title = "Select a File",
        .filters = &.{
            .{ .name = "Zig Files", .pattern = "*.zig" },
            .{ .name = "All Files", .pattern = "*.*" },
        },
    });
    if (path) |p| {
        defer capy.allocator.free(p);
        std.debug.print("Selected file: {s}\n", .{p});
    } else {
        std.debug.print("File dialog cancelled\n", .{});
    }
}

pub fn onOpenDir(_: *anyopaque) !void {
    const path = capy.openFileDialog(.{
        .title = "Select a Directory",
        .select_directories = true,
    });
    if (path) |p| {
        defer capy.allocator.free(p);
        std.debug.print("Selected directory: {s}\n", .{p});
    } else {
        std.debug.print("Directory dialog cancelled\n", .{});
    }
}

pub fn main() !void {
    try capy.init();
    defer capy.deinit();

    var window = try capy.Window.init();
    defer window.deinit();

    // Create widgets
    var progress_value = capy.Atom(f32).of(0.65);

    // Context menu for right-click demo
    var ctx_menu = capy.contextMenu(.{});
    _ = ctx_menu.setItems(&.{
        .{ .label = "Cut", .on_click = null },
        .{ .label = "Copy", .on_click = null },
        .{ .label = "Paste", .on_click = null },
        .{ .label = "", .separator = true },
        .{ .label = "Select All", .on_click = null },
    });

    // Table
    var tbl = capy.table(.{ .row_count = sample_data.len });
    _ = tbl.setColumns(&.{
        .{ .header = "Name", .width = 120 },
        .{ .header = "Role", .width = 120 },
        .{ .header = "City", .width = 140 },
    });
    _ = tbl.setCellProvider(&cellProvider);

    try window.set(
        try capy.column(.{}, .{
            // Title
            capy.label(.{ .text = "Capy Widget Showcase" }),

            // Dividers
            capy.divider(.{ .orientation = .Horizontal }),

            // Row 1: ProgressBar + Spinner
            try capy.row(.{}, .{
                capy.label(.{ .text = "Progress:" }),
                capy.progressBar(.{ .value = progress_value.get() }),
                capy.spinner(.{}),
            }),

            capy.divider(.{ .orientation = .Horizontal }),

            // Row 2: SegmentedControl
            try capy.row(.{}, .{
                capy.label(.{ .text = "View:" }),
                capy.segmentedControl(.{ .labels = &.{ "Day", "Week", "Month" } }),
            }),

            capy.divider(.{ .orientation = .Horizontal }),

            // Row 3: MenuButton
            try capy.row(.{}, .{
                capy.label(.{ .text = "Format:" }),
                capy.menuButton(.{ .items = &.{ "PDF", "CSV", "JSON", "XML" } }),
            }),

            capy.divider(.{ .orientation = .Horizontal }),

            // Row 4: File Dialogs
            try capy.row(.{}, .{
                capy.label(.{ .text = "Dialogs:" }),
                capy.button(.{ .label = "Open File...", .onclick = onOpenFile }),
                capy.button(.{ .label = "Select Directory...", .onclick = onOpenDir }),
            }),

            capy.divider(.{ .orientation = .Horizontal }),

            // Row 5: Table
            capy.label(.{ .text = "Team Directory:" }),
            tbl,

            // Flyout panel (initially closed) and context menu
            capy.flyoutPanel(.{ .open = false }),
            ctx_menu,
        }),
    );

    window.setTitle("Widget Showcase");
    window.setPreferredSize(600, 700);
    window.show();

    capy.runEventLoop();
}
