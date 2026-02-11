const std = @import("std");
const shared = @import("../shared.zig");
const lib = @import("../../capy.zig");
const objc = @import("objc");
const AppKit = @import("AppKit.zig");
const CapyAppDelegate = @import("CapyAppDelegate.zig");
const trait = @import("../../trait.zig");

const nil = objc.Object.fromId(@as(?*anyopaque, null));

const EventFunctions = shared.EventFunctions(@This());
const EventType = shared.BackendEventType;
const BackendError = shared.BackendError;
const MouseButton = shared.MouseButton;

pub const Monitor = @import("Monitor.zig");

pub const PeerType = GuiWidget;

pub const Button = @import("components/Button.zig");

const atomicValue = std.atomic.Value;
var activeWindows = atomicValue(usize).init(0);
var hasInit: bool = false;
var finishedLaunching = false;
var initPool: *objc.AutoreleasePool = undefined;

pub fn init() BackendError!void {
    if (!hasInit) {
        hasInit = true;
        initPool = objc.AutoreleasePool.init();
        const NSApplication = objc.getClass("NSApplication").?;
        const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
        app.msgSend(void, "setActivationPolicy:", .{AppKit.NSApplicationActivationPolicy.Regular});
        app.msgSend(void, "activateIgnoringOtherApps:", .{@as(u8, @intFromBool(true))});
        app.msgSend(void, "setDelegate:", .{CapyAppDelegate.get()});

        // Set up default menu bar with Quit item (Cmd+Q)
        setupDefaultMenuBar(app);
    }
}

fn setupDefaultMenuBar(app: objc.Object) void {
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;

    // Main menu bar
    const menubar = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    app.msgSend(void, "setMainMenu:", .{menubar.value});

    // Application menu item (container in the menu bar)
    const app_menu_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    menubar.msgSend(void, "addItem:", .{app_menu_item.value});

    // Application submenu
    const app_menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    // "Quit" with Cmd+Q - use separateWithTag to create, then set properties
    const quit_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    quit_item.msgSend(void, "setTitle:", .{AppKit.nsString("Quit")});
    quit_item.setProperty("action", objc.sel("terminate:"));
    quit_item.msgSend(void, "setKeyEquivalent:", .{AppKit.nsString("q")});
    app_menu.msgSend(void, "addItem:", .{quit_item.value});

    app_menu_item.msgSend(void, "setSubmenu:", .{app_menu.value});
}

pub fn showNativeMessageDialog(msgType: shared.MessageType, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrintSentinel(lib.internal.allocator, fmt, args, 0) catch {
        std.log.err("Could not launch message dialog, original text: " ++ fmt, args);
        return;
    };
    defer lib.internal.allocator.free(msg);

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSAlert = objc.getClass("NSAlert").?;
    const alert = NSAlert.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    alert.msgSend(void, "setMessageText:", .{AppKit.nsString("Message")});
    alert.msgSend(void, "setInformativeText:", .{AppKit.nsString(msg)});
    alert.msgSend(void, "setAlertStyle:", .{@as(AppKit.NSUInteger, switch (msgType) {
        .Information => AppKit.NSAlertStyle.Informational,
        .Warning => AppKit.NSAlertStyle.Warning,
        .Error => AppKit.NSAlertStyle.Critical,
    })});
    alert.msgSend(void, "addButtonWithTitle:", .{AppKit.nsString("OK")});
    _ = alert.msgSend(i64, "runModal", .{});
}

/// user data used for handling events
pub const EventUserData = struct {
    user: EventFunctions = .{},
    class: EventFunctions = .{},
    userdata: usize = 0,
    classUserdata: usize = 0,
    peer: objc.Object,
    focusOnClick: bool = false,
    actual_x: ?u31 = null,
    actual_y: ?u31 = null,
    actual_width: ?u31 = null,
    actual_height: ?u31 = null,
};

pub const GuiWidget = struct {
    object: objc.Object,
    data: *EventUserData,
};

pub inline fn getEventUserData(peer: GuiWidget) *EventUserData {
    return peer.data;
}

// ---------------------------------------------------------------------------
// ObjC runtime helpers
// ---------------------------------------------------------------------------

/// Retrieve the EventUserData pointer stored in an ObjC view's "capy_event_data" ivar.
fn getEventDataFromIvar(view: objc.Object) ?*EventUserData {
    const data_obj = view.getInstanceVariable("capy_event_data");
    if (@intFromPtr(data_obj.value) == 0) return null;
    return @as(*EventUserData, @ptrFromInt(@intFromPtr(data_obj.value)));
}

/// Store an EventUserData pointer in a view's "capy_event_data" ivar.
fn setEventDataIvar(view: objc.Object, data: *EventUserData) void {
    view.setInstanceVariable("capy_event_data", objc.Object{ .value = @ptrFromInt(@intFromPtr(data)) });
}

// ---------------------------------------------------------------------------
// CapyEventView - custom NSView subclass for event handling
// ---------------------------------------------------------------------------

var cachedCapyEventView: ?objc.Class = null;

fn getCapyEventViewClass() !objc.Class {
    if (cachedCapyEventView) |cls| return cls;

    const NSViewClass = objc.getClass("NSView").?;
    const CapyEventView = objc.allocateClassPair(NSViewClass, "CapyEventView") orelse return error.InitializationError;

    // Add ivar to store EventUserData pointer
    if (!CapyEventView.addIvar("capy_event_data")) return error.InitializationError;

    // isFlipped -> YES (top-left origin)
    _ = CapyEventView.addMethod("isFlipped", struct {
        fn imp(_: objc.c.id, _: objc.c.SEL) callconv(.c) u8 {
            return @intFromBool(true);
        }
    }.imp);

    // acceptsFirstResponder -> YES
    _ = CapyEventView.addMethod("acceptsFirstResponder", struct {
        fn imp(_: objc.c.id, _: objc.c.SEL) callconv(.c) u8 {
            return @intFromBool(true);
        }
    }.imp);

    // mouseDown:
    _ = CapyEventView.addMethod("mouseDown:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseButton(self_id, event_id, .Left, true);
        }
    }.imp);

    // mouseUp:
    _ = CapyEventView.addMethod("mouseUp:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseButton(self_id, event_id, .Left, false);
        }
    }.imp);

    // rightMouseDown:
    _ = CapyEventView.addMethod("rightMouseDown:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseButton(self_id, event_id, .Right, true);
        }
    }.imp);

    // rightMouseUp:
    _ = CapyEventView.addMethod("rightMouseUp:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseButton(self_id, event_id, .Right, false);
        }
    }.imp);

    // mouseMoved:
    _ = CapyEventView.addMethod("mouseMoved:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseMotion(self_id, event_id);
        }
    }.imp);

    // mouseDragged:
    _ = CapyEventView.addMethod("mouseDragged:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseMotion(self_id, event_id);
        }
    }.imp);

    // rightMouseDragged:
    _ = CapyEventView.addMethod("rightMouseDragged:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseMotion(self_id, event_id);
        }
    }.imp);

    // scrollWheel:
    _ = CapyEventView.addMethod("scrollWheel:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleScrollWheel(self_id, event_id);
        }
    }.imp);

    // keyDown:
    _ = CapyEventView.addMethod("keyDown:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleKeyEvent(self_id, event_id);
        }
    }.imp);

    // flagsChanged:
    _ = CapyEventView.addMethod("flagsChanged:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleFlagsChanged(self_id, event_id);
        }
    }.imp);

    // setFrameSize: override - call super then fire resize handler
    _ = CapyEventView.addMethod("setFrameSize:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, size: AppKit.CGSize) callconv(.c) void {
            // Call super
            const self_obj = objc.Object{ .value = self_id };
            const SuperClass = objc.getClass("NSView").?;
            self_obj.msgSendSuper(SuperClass, void, "setFrameSize:", .{size});

            const data = getEventDataFromIvar(self_obj) orelse return;
            const w: u32 = @intFromFloat(@max(size.width, 0));
            const h: u32 = @intFromFloat(@max(size.height, 0));
            data.actual_width = @intCast(@min(w, std.math.maxInt(u31)));
            data.actual_height = @intCast(@min(h, std.math.maxInt(u31)));
            if (data.class.resizeHandler) |handler|
                handler(w, h, @intFromPtr(data));
            if (data.user.resizeHandler) |handler|
                handler(w, h, data.userdata);
        }
    }.imp);

    objc.registerClassPair(CapyEventView);
    cachedCapyEventView = CapyEventView;
    return CapyEventView;
}

// ---------------------------------------------------------------------------
// CapyCanvasView - custom NSView subclass for Canvas (events + drawRect:)
// ---------------------------------------------------------------------------

var cachedCapyCanvasView: ?objc.Class = null;

fn getCapyCanvasViewClass() !objc.Class {
    if (cachedCapyCanvasView) |cls| return cls;

    const NSViewClass = objc.getClass("NSView").?;
    const CapyCanvasView = objc.allocateClassPair(NSViewClass, "CapyCanvasView") orelse return error.InitializationError;

    if (!CapyCanvasView.addIvar("capy_event_data")) return error.InitializationError;

    // isFlipped -> YES
    _ = CapyCanvasView.addMethod("isFlipped", struct {
        fn imp(_: objc.c.id, _: objc.c.SEL) callconv(.c) u8 {
            return @intFromBool(true);
        }
    }.imp);

    // acceptsFirstResponder -> YES
    _ = CapyCanvasView.addMethod("acceptsFirstResponder", struct {
        fn imp(_: objc.c.id, _: objc.c.SEL) callconv(.c) u8 {
            return @intFromBool(true);
        }
    }.imp);

    // mouseDown:
    _ = CapyCanvasView.addMethod("mouseDown:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseButton(self_id, event_id, .Left, true);
        }
    }.imp);

    // mouseUp:
    _ = CapyCanvasView.addMethod("mouseUp:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseButton(self_id, event_id, .Left, false);
        }
    }.imp);

    // rightMouseDown:
    _ = CapyCanvasView.addMethod("rightMouseDown:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseButton(self_id, event_id, .Right, true);
        }
    }.imp);

    // rightMouseUp:
    _ = CapyCanvasView.addMethod("rightMouseUp:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseButton(self_id, event_id, .Right, false);
        }
    }.imp);

    // mouseMoved:
    _ = CapyCanvasView.addMethod("mouseMoved:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseMotion(self_id, event_id);
        }
    }.imp);

    // mouseDragged:
    _ = CapyCanvasView.addMethod("mouseDragged:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleMouseMotion(self_id, event_id);
        }
    }.imp);

    // scrollWheel:
    _ = CapyCanvasView.addMethod("scrollWheel:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleScrollWheel(self_id, event_id);
        }
    }.imp);

    // keyDown:
    _ = CapyCanvasView.addMethod("keyDown:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleKeyEvent(self_id, event_id);
        }
    }.imp);

    // flagsChanged:
    _ = CapyCanvasView.addMethod("flagsChanged:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
            handleFlagsChanged(self_id, event_id);
        }
    }.imp);

    // setFrameSize: override
    _ = CapyCanvasView.addMethod("setFrameSize:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, size: AppKit.CGSize) callconv(.c) void {
            const self_obj = objc.Object{ .value = self_id };
            const SuperClass = objc.getClass("NSView").?;
            self_obj.msgSendSuper(SuperClass, void, "setFrameSize:", .{size});
            const data = getEventDataFromIvar(self_obj) orelse return;
            const w: u32 = @intFromFloat(@max(size.width, 0));
            const h: u32 = @intFromFloat(@max(size.height, 0));
            data.actual_width = @intCast(@min(w, std.math.maxInt(u31)));
            data.actual_height = @intCast(@min(h, std.math.maxInt(u31)));
            if (data.class.resizeHandler) |handler|
                handler(w, h, @intFromPtr(data));
            if (data.user.resizeHandler) |handler|
                handler(w, h, data.userdata);
        }
    }.imp);

    // drawRect: override - the core of Canvas rendering
    _ = CapyCanvasView.addMethod("drawRect:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, _: AppKit.CGRect) callconv(.c) void {
            const self_obj = objc.Object{ .value = self_id };
            const data = getEventDataFromIvar(self_obj) orelse return;

            // Get the current CGContext
            const NSGraphicsContext = objc.getClass("NSGraphicsContext").?;
            const gfx_ctx = NSGraphicsContext.msgSend(objc.Object, "currentContext", .{});
            if (gfx_ctx.value == null) return;
            const cg_context = gfx_ctx.msgSend(AppKit.CGContextRef, "CGContext", .{});
            if (cg_context == null) return;

            // CoreGraphics has bottom-left origin; flip for top-left
            const frame = self_obj.getProperty(AppKit.CGRect, "bounds");
            AppKit.CGContextSaveGState(cg_context);
            AppKit.CGContextTranslateCTM(cg_context, 0, frame.size.height);
            AppKit.CGContextScaleCTM(cg_context, 1.0, -1.0);

            const draw_ctx_impl = Canvas.DrawContextImpl{ .cg_context = cg_context };
            var draw_ctx = @import("../../backend.zig").DrawContext{ .impl = draw_ctx_impl };

            if (data.class.drawHandler) |handler|
                handler(&draw_ctx, @intFromPtr(data));
            if (data.user.drawHandler) |handler|
                handler(&draw_ctx, data.userdata);

            AppKit.CGContextRestoreGState(cg_context);
        }
    }.imp);

    objc.registerClassPair(CapyCanvasView);
    cachedCapyCanvasView = CapyCanvasView;
    return CapyCanvasView;
}

// ---------------------------------------------------------------------------
// CapyActionTarget - ObjC class for target/action pattern (buttons, etc.)
// ---------------------------------------------------------------------------

var cachedCapyActionTarget: ?objc.Class = null;

fn getCapyActionTargetClass() !objc.Class {
    if (cachedCapyActionTarget) |cls| return cls;

    const NSObjectClass = objc.getClass("NSObject").?;
    const CapyActionTarget = objc.allocateClassPair(NSObjectClass, "CapyActionTarget") orelse return error.InitializationError;

    if (!CapyActionTarget.addIvar("capy_event_data")) return error.InitializationError;

    _ = CapyActionTarget.addMethod("action:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
            const self_obj = objc.Object{ .value = self_id };
            const data = getEventDataFromIvar(self_obj) orelse return;
            if (data.class.clickHandler) |handler|
                handler(@intFromPtr(data));
            if (data.user.clickHandler) |handler|
                handler(data.userdata);
        }
    }.imp);

    objc.registerClassPair(CapyActionTarget);
    cachedCapyActionTarget = CapyActionTarget;
    return CapyActionTarget;
}

/// Create a CapyActionTarget instance wired to the given EventUserData.
pub fn createActionTarget(data: *EventUserData) !objc.Object {
    const cls = try getCapyActionTargetClass();
    const target = cls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    setEventDataIvar(target, data);
    return target;
}

// --- Menu support ---

var cachedCapyMenuTarget: ?objc.Class = null;

fn getCapyMenuTargetClass() !objc.Class {
    if (cachedCapyMenuTarget) |cls| return cls;

    const NSObjectClass = objc.getClass("NSObject").?;
    const CapyMenuTarget = objc.allocateClassPair(NSObjectClass, "CapyMenuTarget") orelse return error.InitializationError;

    // Add an ivar to store the callback function pointer
    if (!CapyMenuTarget.addIvar("capy_menu_callback")) return error.InitializationError;

    _ = CapyMenuTarget.addMethod("menuAction:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
            const self_obj = objc.Object{ .value = self_id };
            const raw = self_obj.getInstanceVariable("capy_menu_callback");
            const cb_ptr = @intFromPtr(raw.value);
            if (cb_ptr == 0) return;
            const callback: *const fn () void = @ptrFromInt(cb_ptr);
            callback();
        }
    }.imp);

    objc.registerClassPair(CapyMenuTarget);
    cachedCapyMenuTarget = CapyMenuTarget;
    return CapyMenuTarget;
}

fn createMenuItemFromConfig(item: lib.MenuItem, menu_target_cls: objc.Class) objc.Object {
    const NSMenuItem = objc.getClass("NSMenuItem").?;
    const NSMenu = objc.getClass("NSMenu").?;

    const ns_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    ns_item.msgSend(void, "setTitle:", .{AppKit.nsString(item.config.label)});

    if (item.items.len > 0) {
        // This is a submenu
        const submenu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        submenu.msgSend(void, "setTitle:", .{AppKit.nsString(item.config.label)});
        for (item.items) |sub_item| {
            const child = createMenuItemFromConfig(sub_item, menu_target_cls);
            submenu.msgSend(void, "addItem:", .{child.value});
        }
        ns_item.msgSend(void, "setSubmenu:", .{submenu.value});
    } else if (item.config.onClick) |callback| {
        // Leaf menu item with a click handler
        const target = menu_target_cls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        // Store callback function pointer in the ivar
        target.setInstanceVariable("capy_menu_callback", objc.Object{ .value = @ptrFromInt(@intFromPtr(callback)) });
        ns_item.msgSend(void, "setTarget:", .{target.value});
        ns_item.setProperty("action", objc.sel("menuAction:"));
    }

    return ns_item;
}

// ---------------------------------------------------------------------------
// CapyTextFieldDelegate - for text change notifications on NSTextField
// ---------------------------------------------------------------------------

var cachedCapyTextFieldDelegate: ?objc.Class = null;

fn getCapyTextFieldDelegateClass() !objc.Class {
    if (cachedCapyTextFieldDelegate) |cls| return cls;

    const NSObjectClass = objc.getClass("NSObject").?;
    const cls = objc.allocateClassPair(NSObjectClass, "CapyTextFieldDelegate") orelse return error.InitializationError;

    if (!cls.addIvar("capy_event_data")) return error.InitializationError;

    // controlTextDidChange:
    _ = cls.addMethod("controlTextDidChange:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
            const self_obj = objc.Object{ .value = self_id };
            const data = getEventDataFromIvar(self_obj) orelse return;
            if (data.class.changedTextHandler) |handler|
                handler(@intFromPtr(data));
            if (data.user.changedTextHandler) |handler|
                handler(data.userdata);
        }
    }.imp);

    objc.registerClassPair(cls);
    cachedCapyTextFieldDelegate = cls;
    return cls;
}

// ---------------------------------------------------------------------------
// Slider action target (fires propertyChangeHandler)
// ---------------------------------------------------------------------------

var cachedCapySliderTarget: ?objc.Class = null;

fn getCapySliderTargetClass() !objc.Class {
    if (cachedCapySliderTarget) |cls| return cls;

    const NSObjectClass = objc.getClass("NSObject").?;
    const cls = objc.allocateClassPair(NSObjectClass, "CapySliderTarget") orelse return error.InitializationError;
    if (!cls.addIvar("capy_event_data")) return error.InitializationError;

    _ = cls.addMethod("sliderAction:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, sender_id: objc.c.id) callconv(.c) void {
            const self_obj = objc.Object{ .value = self_id };
            const data = getEventDataFromIvar(self_obj) orelse return;
            const sender = objc.Object{ .value = sender_id };
            const value: f32 = @floatCast(sender.getProperty(AppKit.CGFloat, "doubleValue"));
            if (data.class.propertyChangeHandler) |handler|
                handler("value", @ptrCast(&value), @intFromPtr(data));
            if (data.user.propertyChangeHandler) |handler|
                handler("value", @ptrCast(&value), data.userdata);
        }
    }.imp);

    objc.registerClassPair(cls);
    cachedCapySliderTarget = cls;
    return cls;
}

// ---------------------------------------------------------------------------
// Dropdown action target (fires propertyChangeHandler)
// ---------------------------------------------------------------------------

var cachedCapyDropdownTarget: ?objc.Class = null;

fn getCapyDropdownTargetClass() !objc.Class {
    if (cachedCapyDropdownTarget) |cls| return cls;

    const NSObjectClass = objc.getClass("NSObject").?;
    const cls = objc.allocateClassPair(NSObjectClass, "CapyDropdownTarget") orelse return error.InitializationError;
    if (!cls.addIvar("capy_event_data")) return error.InitializationError;

    _ = cls.addMethod("dropdownAction:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, sender_id: objc.c.id) callconv(.c) void {
            const self_obj = objc.Object{ .value = self_id };
            const data = getEventDataFromIvar(self_obj) orelse return;
            const sender = objc.Object{ .value = sender_id };
            const index: i64 = sender.getProperty(i64, "indexOfSelectedItem");
            if (index < 0) return;
            const idx: usize = @intCast(index);
            if (data.class.propertyChangeHandler) |handler|
                handler("selected", @ptrCast(&idx), @intFromPtr(data));
            if (data.user.propertyChangeHandler) |handler|
                handler("selected", @ptrCast(&idx), data.userdata);
        }
    }.imp);

    objc.registerClassPair(cls);
    cachedCapyDropdownTarget = cls;
    return cls;
}

// ---------------------------------------------------------------------------
// Shared event handler implementations
// ---------------------------------------------------------------------------

fn handleMouseButton(self_id: objc.c.id, event_id: objc.c.id, button: MouseButton, pressed: bool) void {
    const self_obj = objc.Object{ .value = self_id };
    const data = getEventDataFromIvar(self_obj) orelse return;
    const event_obj = objc.Object{ .value = event_id };

    // Get location in the view's coordinate system
    const location_in_window = event_obj.getProperty(AppKit.CGPoint, "locationInWindow");
    const location = self_obj.msgSend(AppKit.CGPoint, "convertPoint:fromView:", .{ location_in_window, @as(objc.c.id, null) });

    const mx: i32 = @intFromFloat(@floor(location.x));
    const my: i32 = @intFromFloat(@floor(location.y));

    if (data.class.mouseButtonHandler) |handler|
        handler(button, pressed, mx, my, @intFromPtr(data));
    if (data.user.mouseButtonHandler) |handler| {
        if (data.focusOnClick) {
            (objc.Object{ .value = self_id }).msgSend(void, "becomeFirstResponder", .{});
        }
        handler(button, pressed, mx, my, data.userdata);
    }
}

fn handleMouseMotion(self_id: objc.c.id, event_id: objc.c.id) void {
    const self_obj = objc.Object{ .value = self_id };
    const data = getEventDataFromIvar(self_obj) orelse return;
    const event_obj = objc.Object{ .value = event_id };

    const location_in_window = event_obj.getProperty(AppKit.CGPoint, "locationInWindow");
    const location = self_obj.msgSend(AppKit.CGPoint, "convertPoint:fromView:", .{ location_in_window, @as(objc.c.id, null) });

    const mx: i32 = @intFromFloat(@floor(location.x));
    const my: i32 = @intFromFloat(@floor(location.y));

    if (data.class.mouseMotionHandler) |handler|
        handler(mx, my, @intFromPtr(data));
    if (data.user.mouseMotionHandler) |handler|
        handler(mx, my, data.userdata);
}

fn handleScrollWheel(self_id: objc.c.id, event_id: objc.c.id) void {
    const self_obj = objc.Object{ .value = self_id };
    const data = getEventDataFromIvar(self_obj) orelse return;
    const event_obj = objc.Object{ .value = event_id };
    const dx: f32 = @floatCast(event_obj.getProperty(AppKit.CGFloat, "scrollingDeltaX"));
    const dy: f32 = @floatCast(event_obj.getProperty(AppKit.CGFloat, "scrollingDeltaY"));
    if (data.class.scrollHandler) |handler|
        handler(dx, dy, @intFromPtr(data));
    if (data.user.scrollHandler) |handler|
        handler(dx, dy, data.userdata);
}

fn handleKeyEvent(self_id: objc.c.id, event_id: objc.c.id) void {
    const self_obj = objc.Object{ .value = self_id };
    const data = getEventDataFromIvar(self_obj) orelse return;
    const event_obj = objc.Object{ .value = event_id };

    // Get characters as UTF-8
    const chars_nsstring = event_obj.getProperty(objc.Object, "characters");
    if (chars_nsstring.value != null) {
        const utf8 = chars_nsstring.msgSend([*:0]const u8, "UTF8String", .{});
        const str = std.mem.sliceTo(utf8, 0);
        if (str.len > 0) {
            if (data.class.keyTypeHandler) |handler|
                handler(str, @intFromPtr(data));
            if (data.user.keyTypeHandler) |handler|
                handler(str, data.userdata);
        }
    }

    const keycode: u16 = event_obj.getProperty(u16, "keyCode");
    if (data.class.keyPressHandler) |handler|
        handler(keycode, @intFromPtr(data));
    if (data.user.keyPressHandler) |handler|
        handler(keycode, data.userdata);
}

fn handleFlagsChanged(self_id: objc.c.id, event_id: objc.c.id) void {
    const self_obj = objc.Object{ .value = self_id };
    const data = getEventDataFromIvar(self_obj) orelse return;
    const event_obj = objc.Object{ .value = event_id };
    const keycode: u16 = event_obj.getProperty(u16, "keyCode");
    if (data.class.keyPressHandler) |handler|
        handler(keycode, @intFromPtr(data));
    if (data.user.keyPressHandler) |handler|
        handler(keycode, data.userdata);
}

/// Add an NSTrackingArea to a view for mouse motion events.
fn addTrackingArea(view: objc.Object) void {
    const NSTrackingArea = objc.getClass("NSTrackingArea") orelse return;
    const opts = AppKit.NSTrackingAreaOptions.MouseMoved |
        AppKit.NSTrackingAreaOptions.MouseEnteredAndExited |
        AppKit.NSTrackingAreaOptions.ActiveAlways |
        AppKit.NSTrackingAreaOptions.InVisibleRect;
    const tracking_area = NSTrackingArea.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
        AppKit.CGRect.make(0, 0, 0, 0), // InVisibleRect makes this auto-update
        opts,
        view,
        @as(objc.c.id, null),
    });
    view.msgSend(void, "addTrackingArea:", .{tracking_area});
}

// ---------------------------------------------------------------------------
// Events mixin
// ---------------------------------------------------------------------------

pub fn Events(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn setupEvents(peer: GuiWidget) BackendError!void {
            peer.data.* = EventUserData{ .peer = peer.object };

            // If this is one of our custom views, store EventUserData in its ivar
            // and add a tracking area for mouse motion
            const class_name_ptr = objc.c.object_getClassName(peer.object.value);
            const class_name = std.mem.sliceTo(class_name_ptr, 0);
            if (std.mem.eql(u8, class_name, "CapyEventView") or
                std.mem.eql(u8, class_name, "CapyCanvasView"))
            {
                setEventDataIvar(peer.object, peer.data);
                addTrackingArea(peer.object);
            }
        }

        pub fn setUserData(self: *T, data: anytype) void {
            comptime {
                if (!trait.isSingleItemPtr(@TypeOf(data))) {
                    @compileError(std.fmt.comptimePrint("Expected single item pointer, got {s}", .{@typeName(@TypeOf(data))}));
                }
            }

            getEventUserData(self.peer).userdata = @intFromPtr(data);
        }

        pub inline fn setCallback(self: *T, comptime eType: EventType, cb: anytype) !void {
            const data = &getEventUserData(self.peer).user;
            switch (eType) {
                .Click => data.clickHandler = cb,
                .Draw => data.drawHandler = cb,
                .MouseButton => data.mouseButtonHandler = cb,
                .MouseMotion => data.mouseMotionHandler = cb,
                .Scroll => data.scrollHandler = cb,
                .TextChanged => data.changedTextHandler = cb,
                .Resize => data.resizeHandler = cb,
                .KeyType => data.keyTypeHandler = cb,
                .KeyPress => data.keyPressHandler = cb,
                .PropertyChange => data.propertyChangeHandler = cb,
            }
        }

        pub fn setOpacity(self: *const T, opacity: f32) void {
            self.peer.object.msgSend(void, "setAlphaValue:", .{@as(AppKit.CGFloat, @floatCast(opacity))});
        }

        pub fn getX(self: *const T) c_int {
            const data = getEventUserData(self.peer);
            return data.actual_x orelse 0;
        }

        pub fn getY(self: *const T) c_int {
            const data = getEventUserData(self.peer);
            return data.actual_y orelse 0;
        }

        pub fn getWidth(self: *const T) u32 {
            const data = getEventUserData(self.peer);
            if (data.actual_width) |w| return w;
            const frame = self.peer.object.getProperty(AppKit.CGRect, "frame");
            return @intFromFloat(@max(frame.size.width, 0));
        }

        pub fn getHeight(self: *const T) u32 {
            const data = getEventUserData(self.peer);
            if (data.actual_height) |h| return h;
            const frame = self.peer.object.getProperty(AppKit.CGRect, "frame");
            return @intFromFloat(@max(frame.size.height, 0));
        }

        pub fn getPreferredSize(self: *const T) lib.Size {
            if (@hasDecl(T, "getPreferredSize_impl")) {
                return self.getPreferredSize_impl();
            }
            return lib.Size.init(
                100,
                100,
            );
        }

        pub fn requestDraw(self: *T) !void {
            self.peer.object.msgSend(void, "setNeedsDisplay:", .{@as(u8, @intFromBool(true))});
        }

        pub fn deinit(self: *const T) void {
            const peer = self.peer;
            lib.internal.allocator.destroy(peer.data);
        }
    };
}

// ---------------------------------------------------------------------------
// Helpers for Container size tracking (mirrors GTK's widgetSizeChanged)
// ---------------------------------------------------------------------------

pub fn widgetSizeChanged(peer: GuiWidget, width: u32, height: u32) void {
    const data = getEventUserData(peer);
    data.actual_width = @intCast(@min(width, std.math.maxInt(u31)));
    data.actual_height = @intCast(@min(height, std.math.maxInt(u31)));
    if (data.class.resizeHandler) |handler|
        handler(width, height, @intFromPtr(data));
    if (data.user.resizeHandler) |handler|
        handler(width, height, data.userdata);
}

// ---------------------------------------------------------------------------
// Window helpers
// ---------------------------------------------------------------------------

/// Recursively find the maximum extent (x+width, y+height) of all subviews.
fn maxSubviewExtent(view: objc.Object) struct { width: AppKit.CGFloat, height: AppKit.CGFloat } {
    const subviews = view.msgSend(objc.Object, "subviews", .{});
    const count: usize = @intCast(subviews.msgSend(u64, "count", .{}));

    var max_w: AppKit.CGFloat = 0;
    var max_h: AppKit.CGFloat = 0;

    for (0..count) |i| {
        const subview = subviews.msgSend(objc.Object, "objectAtIndex:", .{@as(u64, @intCast(i))});
        const frame = subview.getProperty(AppKit.CGRect, "frame");

        // This subview's own extent
        const extent_w = frame.origin.x + frame.size.width;
        const extent_h = frame.origin.y + frame.size.height;
        max_w = @max(max_w, extent_w);
        max_h = @max(max_h, extent_h);

        // Check children recursively
        const child_extent = maxSubviewExtent(subview);
        max_w = @max(max_w, frame.origin.x + child_extent.width);
        max_h = @max(max_h, frame.origin.y + child_extent.height);
    }

    return .{ .width = max_w, .height = max_h };
}

/// Expand the window if its content's natural size exceeds the current
/// content area. Mimics GTK's auto-expansion from gtk_window_set_default_size.
fn expandWindowToFitContent(window: objc.Object) void {
    const content_view = window.msgSend(objc.Object, "contentView", .{});
    if (@intFromPtr(content_view.value) == 0) return;

    const content_frame = content_view.getProperty(AppKit.CGRect, "frame");
    const extent = maxSubviewExtent(content_view);

    var needs_resize = false;
    var new_w = content_frame.size.width;
    var new_h = content_frame.size.height;

    if (extent.width > content_frame.size.width) {
        new_w = extent.width;
        needs_resize = true;
    }
    if (extent.height > content_frame.size.height) {
        new_h = extent.height;
        needs_resize = true;
    }

    if (needs_resize) {
        window.msgSend(void, "setContentSize:", .{AppKit.CGSize{
            .width = new_w,
            .height = new_h,
        }});
        // Re-sync the child with the new content size
        syncChildToContentView(window);
    }
}

/// Synchronize the child contentView's frame and EventUserData with the
/// window's actual content area.  This is the macOS equivalent of GTK's
/// gtkLayout callback – it ensures the layout engine always works with the
/// real available size.
fn syncChildToContentView(window: objc.Object) void {
    const content_view = window.msgSend(objc.Object, "contentView", .{});
    if (@intFromPtr(content_view.value) == 0) return;

    const content_frame = content_view.getProperty(AppKit.CGRect, "frame");
    const w: u32 = @intFromFloat(@max(content_frame.size.width, 0));
    const h: u32 = @intFromFloat(@max(content_frame.size.height, 0));

    // Look up the class to see if this is one of our tracked views
    const class_name_ptr = objc.c.object_getClassName(content_view.value);
    const class_name = std.mem.sliceTo(class_name_ptr, 0);
    if (std.mem.eql(u8, class_name, "CapyEventView") or
        std.mem.eql(u8, class_name, "CapyCanvasView"))
    {
        if (getEventDataFromIvar(content_view)) |data| {
            const w_changed = if (data.actual_width) |old| w != old else true;
            const h_changed = if (data.actual_height) |old| h != old else true;
            data.actual_width = @intCast(@min(w, std.math.maxInt(u31)));
            data.actual_height = @intCast(@min(h, std.math.maxInt(u31)));
            if (w_changed or h_changed) {
                if (data.class.resizeHandler) |handler|
                    handler(w, h, @intFromPtr(data));
                if (data.user.resizeHandler) |handler|
                    handler(w, h, data.userdata);
            }
        }
    }
}

// CapyWindowDelegate - receives windowDidResize: notifications
var cachedCapyWindowDelegate: ?objc.Class = null;

fn getCapyWindowDelegateClass() !objc.Class {
    if (cachedCapyWindowDelegate) |cls| return cls;

    const NSObjectClass = objc.getClass("NSObject").?;
    const cls = objc.allocateClassPair(NSObjectClass, "CapyWindowDelegate") orelse return error.InitializationError;

    if (!cls.addIvar("capy_window")) return error.InitializationError;

    _ = cls.addMethod("windowDidResize:", struct {
        fn imp(self_id: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
            const self_obj = objc.Object{ .value = self_id };
            const window_obj = self_obj.getInstanceVariable("capy_window");
            if (@intFromPtr(window_obj.value) == 0) return;
            const window = objc.Object{ .value = window_obj.value };
            syncChildToContentView(window);
        }
    }.imp);

    objc.registerClassPair(cls);
    cachedCapyWindowDelegate = cls;
    return cls;
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

pub const Window = struct {
    source_dpi: u32 = 96,
    scale: f32 = 1.0,
    peer: GuiWidget,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn registerTickCallback(self: *Window) void {
        _ = self;
        // TODO: NSTimer or CVDisplayLink for tick callbacks
    }

    pub fn create() BackendError!Window {
        const NSWindow = objc.getClass("NSWindow").?;
        const rect = AppKit.NSRect.make(0, 0, 800, 600);
        const style = AppKit.NSWindowStyleMask.Titled | AppKit.NSWindowStyleMask.Closable | AppKit.NSWindowStyleMask.Miniaturizable | AppKit.NSWindowStyleMask.Resizable;
        const flag: u8 = @intFromBool(false);

        const window = NSWindow.msgSend(objc.Object, "alloc", .{});
        _ = window.msgSend(
            objc.Object,
            "initWithContentRect:styleMask:backing:defer:",
            .{ rect, style, AppKit.NSBackingStore.Buffered, flag },
        );

        // Set up window delegate for resize notifications
        const delegate_cls = getCapyWindowDelegateClass() catch null;
        if (delegate_cls) |cls| {
            const delegate = cls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
            delegate.setInstanceVariable("capy_window", window);
            window.msgSend(void, "setDelegate:", .{delegate.value});
        }

        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = window };

        return Window{
            .peer = GuiWidget{
                .object = window,
                .data = data,
            },
        };
    }

    pub fn resize(self: *Window, width: c_int, height: c_int) void {
        // Use setContentSize: so the content area (not the window frame including
        // title bar) gets the requested dimensions.
        self.peer.object.msgSend(void, "setContentSize:", .{AppKit.CGSize{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        }});
        // Propagate to child contentView
        syncChildToContentView(self.peer.object);
    }

    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        self.peer.object.setProperty("title", AppKit.nsString(title));
    }

    pub fn setChild(self: *Window, optional_peer: ?GuiWidget) void {
        if (optional_peer) |peer| {
            self.peer.object.setProperty("contentView", peer);
            // Immediately size the child to match the content area
            syncChildToContentView(self.peer.object);
        } else {
            self.peer.object.setProperty("contentView", nil);
        }
    }

    pub fn setSourceDpi(self: *Window, dpi: u32) void {
        self.source_dpi = 96;
        const resolution = @as(f32, 96.0);
        self.scale = resolution / @as(f32, @floatFromInt(dpi));
    }

    pub fn show(self: *Window) void {
        // Auto-expand window to fit content if content overflows.
        // This mimics GTK's gtk_window_set_default_size behavior where the
        // window expands to accommodate its content's natural size.
        expandWindowToFitContent(self.peer.object);

        self.peer.object.msgSend(void, "makeKeyAndOrderFront:", .{self.peer.object.value});
        _ = activeWindows.fetchAdd(1, .release);
    }

    pub fn close(self: *Window) void {
        self.peer.object.msgSend(void, "close", .{});
        _ = activeWindows.fetchSub(1, .release);
    }

    pub fn setMenuBar(self: *Window, bar: anytype) void {
        _ = self;
        const NSMenu = objc.getClass("NSMenu") orelse return;
        const menu_target_cls = getCapyMenuTargetClass() catch return;

        const menubar = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

        // Always add the application menu with Quit as the first item
        const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
        const app_menu_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        menubar.msgSend(void, "addItem:", .{app_menu_item.value});

        const app_menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        const quit_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        quit_item.msgSend(void, "setTitle:", .{AppKit.nsString("Quit")});
        quit_item.setProperty("action", objc.sel("terminate:"));
        quit_item.msgSend(void, "setKeyEquivalent:", .{AppKit.nsString("q")});
        app_menu.msgSend(void, "addItem:", .{quit_item.value});
        app_menu_item.msgSend(void, "setSubmenu:", .{app_menu.value});

        // Add user-defined menus
        for (bar.menus) |menu_item| {
            const item = createMenuItemFromConfig(menu_item, menu_target_cls);
            menubar.msgSend(void, "addItem:", .{item.value});
        }

        // Set as application's main menu
        const app = objc.getClass("NSApplication").?.msgSend(objc.Object, "sharedApplication", .{});
        app.msgSend(void, "setMainMenu:", .{menubar.value});
    }

    pub fn setFullscreen(self: *Window, monitor: anytype, video_mode: anytype) void {
        _ = monitor;
        _ = video_mode;
        self.peer.object.msgSend(void, "toggleFullScreen:", .{self.peer.object.value});
    }

    pub fn unfullscreen(self: *Window) void {
        self.peer.object.msgSend(void, "toggleFullScreen:", .{self.peer.object.value});
    }
};

// ---------------------------------------------------------------------------
// Container
// ---------------------------------------------------------------------------

pub const Container = struct {
    peer: GuiWidget,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() BackendError!Container {
        const cls = try getCapyEventViewClass();
        const view = cls.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 1, 1)});
        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = view };
        setEventDataIvar(view, data);
        addTrackingArea(view);
        return Container{ .peer = GuiWidget{
            .object = view,
            .data = data,
        } };
    }

    pub fn add(self: *const Container, peer: GuiWidget) void {
        self.peer.object.msgSend(void, "addSubview:", .{peer.object});
    }

    pub fn remove(self: *const Container, peer: GuiWidget) void {
        _ = self;
        peer.object.msgSend(void, "removeFromSuperview", .{});
    }

    pub fn move(self: *const Container, peer: GuiWidget, x: u32, y: u32) void {
        _ = self;
        const peerFrame = peer.object.getProperty(AppKit.NSRect, "frame");
        peer.object.setProperty("frame", AppKit.NSRect.make(
            @floatFromInt(x),
            @floatFromInt(y),
            peerFrame.size.width,
            peerFrame.size.height,
        ));
        const data = getEventUserData(peer);
        data.actual_x = @intCast(x);
        data.actual_y = @intCast(y);
    }

    pub fn resize(self: *const Container, peer: GuiWidget, width: u32, height: u32) void {
        _ = self;
        const peerFrame = peer.object.getProperty(AppKit.NSRect, "frame");
        peer.object.setProperty("frame", AppKit.NSRect.make(
            peerFrame.origin.x,
            peerFrame.origin.y,
            @floatFromInt(width),
            @floatFromInt(height),
        ));
        widgetSizeChanged(peer, width, height);
    }

    pub fn setTabOrder(self: *const Container, peers: []const GuiWidget) void {
        _ = peers;
        _ = self;
    }
};

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

pub const Canvas = struct {
    peer: GuiWidget,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() BackendError!Canvas {
        const cls = try getCapyCanvasViewClass();
        const view = cls.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 1, 1)});
        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = view };
        setEventDataIvar(view, data);
        addTrackingArea(view);
        return Canvas{
            .peer = GuiWidget{
                .object = view,
                .data = data,
            },
        };
    }

    pub const DrawContextImpl = struct {
        cg_context: AppKit.CGContextRef,
        pending_gradient: ?shared.LinearGradient = null,

        pub const TextLayout = struct {
            wrap: ?f64 = null,
            font: ?AppKit.CTFontRef = null,

            pub const Font = struct {
                face: [:0]const u8,
                size: f64,
            };

            pub const TextSize = struct { width: u32, height: u32 };

            pub fn init() TextLayout {
                return TextLayout{};
            }

            pub fn setFont(self: *TextLayout, font: Font) void {
                if (self.font) |old| AppKit.CFRelease(old);
                const cf_name = AppKit.CFStringCreateWithBytes(
                    AppKit.kCFAllocatorDefault,
                    font.face.ptr,
                    @intCast(font.face.len),
                    AppKit.CFStringEncoding_UTF8,
                    0,
                );
                defer if (cf_name != null) AppKit.CFRelease(cf_name);
                self.font = AppKit.CTFontCreateWithName(cf_name, font.size, null);
            }

            pub fn getTextSize(self: *TextLayout, str: []const u8) TextSize {
                if (str.len == 0) return TextSize{ .width = 0, .height = 0 };

                const cf_str = AppKit.CFStringCreateWithBytes(
                    AppKit.kCFAllocatorDefault,
                    str.ptr,
                    @intCast(str.len),
                    AppKit.CFStringEncoding_UTF8,
                    0,
                );
                defer if (cf_str != null) AppKit.CFRelease(cf_str);
                if (cf_str == null) return TextSize{ .width = 0, .height = 0 };

                var attr_string: AppKit.CFAttributedStringRef = null;
                if (self.font) |f| {
                    const keys = [_]?*const anyopaque{@as(?*const anyopaque, @ptrCast(AppKit.kCTFontAttributeName))};
                    const values = [_]?*const anyopaque{@as(?*const anyopaque, @ptrCast(f))};
                    const attrs = AppKit.CFDictionaryCreate(
                        AppKit.kCFAllocatorDefault,
                        &keys,
                        &values,
                        1,
                        &AppKit.kCFTypeDictionaryKeyCallBacks,
                        &AppKit.kCFTypeDictionaryValueCallBacks,
                    );
                    defer if (attrs != null) AppKit.CFRelease(attrs);
                    attr_string = AppKit.CFAttributedStringCreate(AppKit.kCFAllocatorDefault, cf_str, attrs);
                } else {
                    attr_string = AppKit.CFAttributedStringCreate(AppKit.kCFAllocatorDefault, cf_str, null);
                }
                defer if (attr_string != null) AppKit.CFRelease(attr_string);
                if (attr_string == null) return TextSize{ .width = 0, .height = 0 };

                const ct_line = AppKit.CTLineCreateWithAttributedString(attr_string);
                defer if (ct_line != null) AppKit.CFRelease(ct_line);
                if (ct_line == null) return TextSize{ .width = 0, .height = 0 };

                var ascent: AppKit.CGFloat = 0;
                var descent: AppKit.CGFloat = 0;
                var leading: AppKit.CGFloat = 0;
                const width = AppKit.CTLineGetTypographicBounds(ct_line, &ascent, &descent, &leading);
                const height = ascent + descent + leading;

                return TextSize{
                    .width = @intFromFloat(@ceil(width)),
                    .height = @intFromFloat(@ceil(height)),
                };
            }

            pub fn deinit(self: *TextLayout) void {
                if (self.font) |f| AppKit.CFRelease(f);
                self.font = null;
            }
        };

        pub fn setColorRGBA(self: *DrawContextImpl, r: f32, g: f32, b: f32, a: f32) void {
            self.pending_gradient = null;
            AppKit.CGContextSetRGBFillColor(self.cg_context, r, g, b, a);
            AppKit.CGContextSetRGBStrokeColor(self.cg_context, r, g, b, a);
        }

        pub fn setLinearGradient(self: *DrawContextImpl, gradient: shared.LinearGradient) void {
            self.pending_gradient = gradient;
        }

        pub fn rectangle(self: *DrawContextImpl, x: i32, y: i32, w: u32, h: u32) void {
            AppKit.CGContextAddRect(self.cg_context, AppKit.CGRect.make(
                @floatFromInt(x),
                @floatFromInt(y),
                @floatFromInt(w),
                @floatFromInt(h),
            ));
        }

        pub fn roundedRectangleEx(self: *DrawContextImpl, x: i32, y: i32, w: u32, h: u32, corner_radiuses: [4]f32) void {
            const fx: AppKit.CGFloat = @floatFromInt(x);
            const fy: AppKit.CGFloat = @floatFromInt(y);
            const fw: AppKit.CGFloat = @floatFromInt(w);
            const fh: AppKit.CGFloat = @floatFromInt(h);

            const max_radius = @min(fw, fh) / 2.0;
            const tl: AppKit.CGFloat = @min(@as(AppKit.CGFloat, @floatCast(corner_radiuses[0])), max_radius);
            const tr: AppKit.CGFloat = @min(@as(AppKit.CGFloat, @floatCast(corner_radiuses[1])), max_radius);
            const br: AppKit.CGFloat = @min(@as(AppKit.CGFloat, @floatCast(corner_radiuses[2])), max_radius);
            const bl: AppKit.CGFloat = @min(@as(AppKit.CGFloat, @floatCast(corner_radiuses[3])), max_radius);

            AppKit.CGContextBeginPath(self.cg_context);
            AppKit.CGContextMoveToPoint(self.cg_context, fx + tl, fy);
            AppKit.CGContextAddArcToPoint(self.cg_context, fx + fw, fy, fx + fw, fy + tr, tr);
            AppKit.CGContextAddArcToPoint(self.cg_context, fx + fw, fy + fh, fx + fw - br, fy + fh, br);
            AppKit.CGContextAddArcToPoint(self.cg_context, fx, fy + fh, fx, fy + fh - bl, bl);
            AppKit.CGContextAddArcToPoint(self.cg_context, fx, fy, fx + tl, fy, tl);
            AppKit.CGContextClosePath(self.cg_context);
        }

        pub fn ellipse(self: *DrawContextImpl, x: i32, y: i32, w: u32, h: u32) void {
            AppKit.CGContextAddEllipseInRect(self.cg_context, AppKit.CGRect.make(
                @floatFromInt(x),
                @floatFromInt(y),
                @floatFromInt(w),
                @floatFromInt(h),
            ));
        }

        pub fn text(self: *DrawContextImpl, x: i32, y: i32, layout: TextLayout, str: []const u8) void {
            if (str.len == 0) return;

            const cf_str = AppKit.CFStringCreateWithBytes(
                AppKit.kCFAllocatorDefault,
                str.ptr,
                @intCast(str.len),
                AppKit.CFStringEncoding_UTF8,
                0,
            );
            defer if (cf_str != null) AppKit.CFRelease(cf_str);
            if (cf_str == null) return;

            var attr_string: AppKit.CFAttributedStringRef = null;
            if (layout.font) |f| {
                const keys = [_]?*const anyopaque{@as(?*const anyopaque, @ptrCast(AppKit.kCTFontAttributeName))};
                const values = [_]?*const anyopaque{@as(?*const anyopaque, @ptrCast(f))};
                const attrs = AppKit.CFDictionaryCreate(
                    AppKit.kCFAllocatorDefault,
                    &keys,
                    &values,
                    1,
                    &AppKit.kCFTypeDictionaryKeyCallBacks,
                    &AppKit.kCFTypeDictionaryValueCallBacks,
                );
                defer if (attrs != null) AppKit.CFRelease(attrs);
                attr_string = AppKit.CFAttributedStringCreate(AppKit.kCFAllocatorDefault, cf_str, attrs);
            } else {
                attr_string = AppKit.CFAttributedStringCreate(AppKit.kCFAllocatorDefault, cf_str, null);
            }
            defer if (attr_string != null) AppKit.CFRelease(attr_string);
            if (attr_string == null) return;

            const ct_line = AppKit.CTLineCreateWithAttributedString(attr_string);
            defer if (ct_line != null) AppKit.CFRelease(ct_line);
            if (ct_line == null) return;

            AppKit.CGContextSetTextPosition(self.cg_context, @floatFromInt(x), @floatFromInt(y));
            AppKit.CTLineDraw(ct_line, self.cg_context);
        }

        pub fn line(self: *DrawContextImpl, x1: i32, y1: i32, x2: i32, y2: i32) void {
            AppKit.CGContextMoveToPoint(self.cg_context, @floatFromInt(x1), @floatFromInt(y1));
            AppKit.CGContextAddLineToPoint(self.cg_context, @floatFromInt(x2), @floatFromInt(y2));
            AppKit.CGContextStrokePath(self.cg_context);
        }

        pub fn image(self: *DrawContextImpl, x: i32, y: i32, w: u32, h: u32, data: lib.ImageData) void {
            const cg_image = data.peer.cg_image orelse return;
            const rect = AppKit.CGRect.make(
                @floatFromInt(x),
                @floatFromInt(y),
                @floatFromInt(w),
                @floatFromInt(h),
            );
            AppKit.CGContextDrawImage(self.cg_context, rect, cg_image);
        }

        pub fn clear(self: *DrawContextImpl, x: u32, y: u32, w: u32, h: u32) void {
            AppKit.CGContextClearRect(self.cg_context, AppKit.CGRect.make(
                @floatFromInt(x),
                @floatFromInt(y),
                @floatFromInt(w),
                @floatFromInt(h),
            ));
        }

        pub fn setStrokeWidth(self: *DrawContextImpl, width: f32) void {
            AppKit.CGContextSetLineWidth(self.cg_context, @floatCast(width));
        }

        pub fn stroke(self: *DrawContextImpl) void {
            AppKit.CGContextStrokePath(self.cg_context);
        }

        pub fn fill(self: *DrawContextImpl) void {
            if (self.pending_gradient) |gradient| {
                AppKit.CGContextSaveGState(self.cg_context);
                AppKit.CGContextClip(self.cg_context);

                const color_space = AppKit.CGColorSpaceCreateDeviceRGB();
                defer AppKit.CGColorSpaceRelease(color_space);

                const max_stops = 16;
                var components: [max_stops * 4]AppKit.CGFloat = undefined;
                var locations: [max_stops]AppKit.CGFloat = undefined;
                const count = @min(gradient.stops.len, max_stops);
                for (0..count) |i| {
                    const stop = gradient.stops[i];
                    components[i * 4 + 0] = @as(AppKit.CGFloat, @floatFromInt(stop.color.red)) / 255.0;
                    components[i * 4 + 1] = @as(AppKit.CGFloat, @floatFromInt(stop.color.green)) / 255.0;
                    components[i * 4 + 2] = @as(AppKit.CGFloat, @floatFromInt(stop.color.blue)) / 255.0;
                    components[i * 4 + 3] = @as(AppKit.CGFloat, @floatFromInt(stop.color.alpha)) / 255.0;
                    locations[i] = @floatCast(stop.offset);
                }

                const cg_gradient = AppKit.CGGradientCreateWithColorComponents(
                    color_space,
                    &components,
                    &locations,
                    count,
                );
                defer if (cg_gradient != null) AppKit.CGGradientRelease(cg_gradient);

                if (cg_gradient != null) {
                    AppKit.CGContextDrawLinearGradient(
                        self.cg_context,
                        cg_gradient,
                        AppKit.CGPoint{ .x = @floatCast(gradient.x0), .y = @floatCast(gradient.y0) },
                        AppKit.CGPoint{ .x = @floatCast(gradient.x1), .y = @floatCast(gradient.y1) },
                        AppKit.CGGradientDrawingOptions.DrawsBeforeStartLocation | AppKit.CGGradientDrawingOptions.DrawsAfterEndLocation,
                    );
                }

                AppKit.CGContextRestoreGState(self.cg_context);
                self.pending_gradient = null;
            } else {
                AppKit.CGContextFillPath(self.cg_context);
            }
        }
    };
};

// ---------------------------------------------------------------------------
// postEmptyEvent / runStep
// ---------------------------------------------------------------------------

pub fn postEmptyEvent() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSEvent = objc.getClass("NSEvent") orelse return;
    const event = NSEvent.msgSend(objc.Object, "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
        AppKit.NSEventType.ApplicationDefined,
        AppKit.CGPoint{ .x = 0, .y = 0 },
        @as(AppKit.NSUInteger, 0),
        @as(AppKit.CGFloat, 0),
        @as(i64, 0),
        @as(objc.c.id, null),
        @as(i16, 0),
        @as(i64, 0),
        @as(i64, 0),
    });
    if (event.value == null) return;

    const NSApplication = objc.getClass("NSApplication").?;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    app.msgSend(void, "postEvent:atStart:", .{ event, @as(u8, @intFromBool(true)) });
}

pub fn runStep(step: shared.EventLoopStep) bool {
    const NSApplication = objc.getClass("NSApplication").?;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    if (!finishedLaunching) {
        finishedLaunching = true;
        if (step == .Blocking) {
            app.msgSend(void, "run", .{});
        }
    }

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSDate = objc.getClass("NSDate").?;
    const distant_past = NSDate.msgSend(objc.Object, "distantPast", .{});
    const distant_future = NSDate.msgSend(objc.Object, "distantFuture", .{});

    const event = app.msgSend(objc.Object, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
        AppKit.NSEventMaskAny,
        switch (step) {
            .Asynchronous => distant_past,
            .Blocking => distant_future,
        },
        AppKit.NSDefaultRunLoopMode,
        true,
    });
    if (event.value != null) {
        app.msgSend(void, "sendEvent:", .{event});
    }
    return activeWindows.load(.acquire) != 0;
}

// ---------------------------------------------------------------------------
// Label
// ---------------------------------------------------------------------------

pub const Label = struct {
    peer: GuiWidget,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() !Label {
        const NSTextField = objc.getClass("NSTextField").?;
        const label = NSTextField.msgSend(objc.Object, "labelWithString:", .{AppKit.nsString("")});
        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = label };
        return Label{
            .peer = GuiWidget{
                .object = label,
                .data = data,
            },
        };
    }

    pub fn setAlignment(self: *Label, alignment: f32) void {
        // NSTextAlignment: 0=Left, 1=Right, 2=Center
        const ns_alignment: AppKit.NSUInteger = if (alignment < 0.33)
            0
        else if (alignment > 0.66)
            1
        else
            2;
        self.peer.object.setProperty("alignment", ns_alignment);
    }

    pub fn setText(self: *Label, text_arg: []const u8) void {
        const nullTerminatedText = lib.internal.allocator.dupeZ(u8, text_arg) catch return;
        defer lib.internal.allocator.free(nullTerminatedText);
        self.peer.object.msgSend(void, "setStringValue:", .{AppKit.nsString(nullTerminatedText)});
    }

    pub fn setFont(self: *Label, font: lib.Font) void {
        _ = self;
        _ = font;
    }

    pub fn destroy(self: *Label) void {
        _ = self;
    }
};

// ---------------------------------------------------------------------------
// ScrollView
// ---------------------------------------------------------------------------

pub const ScrollView = struct {
    peer: GuiWidget,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() BackendError!ScrollView {
        const NSScrollView = objc.getClass("NSScrollView").?;
        const scroll_view = NSScrollView.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 1, 1)});
        scroll_view.setProperty("hasVerticalScroller", @as(u8, @intFromBool(true)));
        scroll_view.setProperty("hasHorizontalScroller", @as(u8, @intFromBool(true)));
        scroll_view.setProperty("autohidesScrollers", @as(u8, @intFromBool(true)));

        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = scroll_view };
        return ScrollView{ .peer = GuiWidget{
            .object = scroll_view,
            .data = data,
        } };
    }

    pub fn setChild(self: *ScrollView, child_peer: GuiWidget, child_widget: anytype) void {
        _ = child_widget;
        self.peer.object.msgSend(void, "setDocumentView:", .{child_peer.object});
    }
};

// ---------------------------------------------------------------------------
// TextField
// ---------------------------------------------------------------------------

pub const TextField = struct {
    peer: GuiWidget,
    delegate: ?objc.Object = null,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;

    pub fn create() BackendError!TextField {
        const NSTextField = objc.getClass("NSTextField").?;
        const field = NSTextField.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 100, 22)});
        field.setProperty("editable", @as(u8, @intFromBool(true)));
        field.setProperty("bezeled", @as(u8, @intFromBool(true)));
        field.setProperty("drawsBackground", @as(u8, @intFromBool(true)));
        field.setProperty("selectable", @as(u8, @intFromBool(true)));

        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = field };

        // Create delegate for text change notifications
        const delegate_cls = try getCapyTextFieldDelegateClass();
        const delegate = delegate_cls.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        setEventDataIvar(delegate, data);
        field.setProperty("delegate", delegate);

        return TextField{
            .peer = GuiWidget{
                .object = field,
                .data = data,
            },
            .delegate = delegate,
        };
    }

    pub fn setText(self: *TextField, text_arg: []const u8) void {
        const nullTerminatedText = lib.internal.allocator.dupeZ(u8, text_arg) catch return;
        defer lib.internal.allocator.free(nullTerminatedText);
        self.peer.object.msgSend(void, "setStringValue:", .{AppKit.nsString(nullTerminatedText)});
    }

    pub fn getText(self: *TextField) []const u8 {
        const nsstr = self.peer.object.getProperty(objc.Object, "stringValue");
        if (nsstr.value == null) return "";
        const utf8 = nsstr.msgSend([*:0]const u8, "UTF8String", .{});
        return std.mem.sliceTo(utf8, 0);
    }

    pub fn setReadOnly(self: *TextField, read_only: bool) void {
        self.peer.object.setProperty("editable", @as(u8, @intFromBool(!read_only)));
    }

    pub fn deinit(self: *const TextField) void {
        _events.deinit(self);
    }
};

// ---------------------------------------------------------------------------
// TextArea
// ---------------------------------------------------------------------------

pub const TextArea = struct {
    peer: GuiWidget,
    text_view: objc.Object,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() BackendError!TextArea {
        const NSScrollView = objc.getClass("NSScrollView").?;
        const scroll_view = NSScrollView.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 200, 100)});
        scroll_view.setProperty("hasVerticalScroller", @as(u8, @intFromBool(true)));
        scroll_view.setProperty("hasHorizontalScroller", @as(u8, @intFromBool(false)));
        scroll_view.setProperty("autohidesScrollers", @as(u8, @intFromBool(true)));

        const NSTextView = objc.getClass("NSTextView").?;
        const text_view = NSTextView.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 200, 100)});
        text_view.setProperty("autoresizingMask", @as(AppKit.NSUInteger, 2)); // NSViewWidthSizable
        text_view.msgSend(void, "setRichText:", .{@as(u8, @intFromBool(false))});

        scroll_view.msgSend(void, "setDocumentView:", .{text_view});

        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = scroll_view };
        return TextArea{
            .peer = GuiWidget{
                .object = scroll_view,
                .data = data,
            },
            .text_view = text_view,
        };
    }

    pub fn setText(self: *TextArea, text_arg: []const u8) void {
        const nullTerminatedText = lib.internal.allocator.dupeZ(u8, text_arg) catch return;
        defer lib.internal.allocator.free(nullTerminatedText);
        self.text_view.msgSend(void, "setString:", .{AppKit.nsString(nullTerminatedText)});
    }

    pub fn getText(self: *TextArea) []const u8 {
        const nsstr = self.text_view.getProperty(objc.Object, "string");
        if (nsstr.value == null) return "";
        const utf8 = nsstr.msgSend([*:0]const u8, "UTF8String", .{});
        return std.mem.sliceTo(utf8, 0);
    }

    pub fn setMonospaced(self: *TextArea, monospaced: bool) void {
        const NSFont = objc.getClass("NSFont") orelse return;
        const font = if (monospaced)
            NSFont.msgSend(objc.Object, "monospacedSystemFontOfSize:weight:", .{
                @as(AppKit.CGFloat, 13.0),
                @as(AppKit.CGFloat, 0.0),
            })
        else
            NSFont.msgSend(objc.Object, "systemFontOfSize:", .{
                @as(AppKit.CGFloat, 13.0),
            });
        if (font.value != null) {
            self.text_view.msgSend(void, "setFont:", .{font});
        }
    }
};

// ---------------------------------------------------------------------------
// CheckBox
// ---------------------------------------------------------------------------

pub const CheckBox = struct {
    peer: GuiWidget,
    action_target: ?objc.Object = null,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() BackendError!CheckBox {
        const NSButton = objc.getClass("NSButton").?;
        const button = NSButton.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 100, 22)});
        button.msgSend(void, "setButtonType:", .{@as(AppKit.NSUInteger, AppKit.NSButtonType.Switch)});
        button.setProperty("title", AppKit.nsString(""));

        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = button };

        const target = try createActionTarget(data);
        button.setProperty("target", target);
        button.setProperty("action", objc.sel("action:"));

        return CheckBox{
            .peer = GuiWidget{
                .object = button,
                .data = data,
            },
            .action_target = target,
        };
    }

    pub fn setChecked(self: *CheckBox, checked: bool) void {
        self.peer.object.setProperty("state", @as(i64, if (checked) AppKit.NSControlStateValue.On else AppKit.NSControlStateValue.Off));
    }

    pub fn isChecked(self: *CheckBox) bool {
        const state: i64 = self.peer.object.getProperty(i64, "state");
        return state == AppKit.NSControlStateValue.On;
    }

    pub fn setEnabled(self: *CheckBox, enabled: bool) void {
        self.peer.object.setProperty("enabled", @as(u8, @intFromBool(enabled)));
    }

    pub fn setLabel(self: *CheckBox, label_text: [:0]const u8) void {
        self.peer.object.setProperty("title", AppKit.nsString(label_text.ptr));
    }

    pub fn getLabel(self: *CheckBox) [:0]const u8 {
        const title = self.peer.object.getProperty(objc.Object, "title");
        if (title.value == null) return "";
        const label = title.msgSend([*:0]const u8, "UTF8String", .{});
        return std.mem.sliceTo(label, 0);
    }
};

// ---------------------------------------------------------------------------
// Slider
// ---------------------------------------------------------------------------

pub const Slider = struct {
    peer: GuiWidget,
    action_target: ?objc.Object = null,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() BackendError!Slider {
        const NSSlider = objc.getClass("NSSlider").?;
        const slider = NSSlider.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 100, 22)});
        slider.setProperty("minValue", @as(AppKit.CGFloat, 0.0));
        slider.setProperty("maxValue", @as(AppKit.CGFloat, 1.0));
        slider.setProperty("continuous", @as(u8, @intFromBool(true)));

        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = slider };

        const target_cls = try getCapySliderTargetClass();
        const target = target_cls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        setEventDataIvar(target, data);
        slider.setProperty("target", target);
        slider.setProperty("action", objc.sel("sliderAction:"));

        return Slider{
            .peer = GuiWidget{
                .object = slider,
                .data = data,
            },
            .action_target = target,
        };
    }

    pub fn getValue(self: *Slider) f32 {
        return @floatCast(self.peer.object.getProperty(AppKit.CGFloat, "doubleValue"));
    }

    pub fn setValue(self: *Slider, value: f32) void {
        self.peer.object.setProperty("doubleValue", @as(AppKit.CGFloat, @floatCast(value)));
    }

    pub fn setMinimum(self: *Slider, min: f32) void {
        self.peer.object.setProperty("minValue", @as(AppKit.CGFloat, @floatCast(min)));
    }

    pub fn setMaximum(self: *Slider, max: f32) void {
        self.peer.object.setProperty("maxValue", @as(AppKit.CGFloat, @floatCast(max)));
    }

    pub fn setStepSize(self: *Slider, step: f32) void {
        _ = self;
        _ = step;
    }

    pub fn setEnabled(self: *Slider, enabled: bool) void {
        self.peer.object.setProperty("enabled", @as(u8, @intFromBool(enabled)));
    }

    pub fn setOrientation(self: *Slider, orientation: anytype) void {
        _ = orientation;
        self.peer.object.setProperty("vertical", @as(u8, @intFromBool(false)));
    }
};

// ---------------------------------------------------------------------------
// Dropdown
// ---------------------------------------------------------------------------

pub const Dropdown = struct {
    peer: GuiWidget,
    action_target: ?objc.Object = null,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() BackendError!Dropdown {
        const NSPopUpButton = objc.getClass("NSPopUpButton").?;
        const popup = NSPopUpButton.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:pullsDown:", .{ AppKit.NSRect.make(0, 0, 100, 22), @as(u8, @intFromBool(false)) });

        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = popup };

        const target_cls = try getCapyDropdownTargetClass();
        const target = target_cls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        setEventDataIvar(target, data);
        popup.setProperty("target", target);
        popup.setProperty("action", objc.sel("dropdownAction:"));

        return Dropdown{
            .peer = GuiWidget{
                .object = popup,
                .data = data,
            },
            .action_target = target,
        };
    }

    pub fn getSelectedIndex(self: *Dropdown) ?usize {
        const index: i64 = self.peer.object.getProperty(i64, "indexOfSelectedItem");
        if (index < 0) return null;
        return @intCast(index);
    }

    pub fn setSelectedIndex(self: *Dropdown, index: ?usize) void {
        if (index) |i| {
            self.peer.object.msgSend(void, "selectItemAtIndex:", .{@as(i64, @intCast(i))});
        }
    }

    pub fn setValues(self: *Dropdown, values: anytype) void {
        self.peer.object.msgSend(void, "removeAllItems", .{});
        for (values) |value| {
            const str = lib.internal.allocator.dupeZ(u8, value) catch continue;
            defer lib.internal.allocator.free(str);
            self.peer.object.msgSend(void, "addItemWithTitle:", .{AppKit.nsString(str)});
        }
    }

    pub fn setEnabled(self: *Dropdown, enabled: bool) void {
        self.peer.object.setProperty("enabled", @as(u8, @intFromBool(enabled)));
    }
};

// ---------------------------------------------------------------------------
// TabContainer
// ---------------------------------------------------------------------------

pub const TabContainer = struct {
    peer: GuiWidget,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() BackendError!TabContainer {
        const NSTabView = objc.getClass("NSTabView").?;
        const tab_view = NSTabView.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 200, 200)});

        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = tab_view };
        return TabContainer{
            .peer = GuiWidget{
                .object = tab_view,
                .data = data,
            },
        };
    }

    pub fn insert(self: *TabContainer, position: usize, child_peer: GuiWidget) usize {
        const NSTabViewItem = objc.getClass("NSTabViewItem").?;
        const item = NSTabViewItem.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithIdentifier:", .{@as(objc.c.id, null)});
        item.setProperty("view", child_peer.object);
        self.peer.object.msgSend(void, "insertTabViewItem:atIndex:", .{ item, @as(i64, @intCast(position)) });
        return position;
    }

    pub fn setLabel(self: *TabContainer, position: usize, label_text: [:0]const u8) void {
        const item = self.peer.object.msgSend(objc.Object, "tabViewItemAtIndex:", .{@as(i64, @intCast(position))});
        if (item.value != null) {
            item.setProperty("label", AppKit.nsString(label_text.ptr));
        }
    }

    pub fn getTabsNumber(self: *TabContainer) usize {
        const count: i64 = self.peer.object.getProperty(i64, "numberOfTabViewItems");
        if (count < 0) return 0;
        return @intCast(count);
    }
};

// ---------------------------------------------------------------------------
// NavigationSidebar
// ---------------------------------------------------------------------------

pub const NavigationSidebar = struct {
    peer: GuiWidget,

    const _events = Events(@This());
    pub const setupEvents = _events.setupEvents;
    pub const setUserData = _events.setUserData;
    pub const setCallback = _events.setCallback;
    pub const setOpacity = _events.setOpacity;
    pub const getX = _events.getX;
    pub const getY = _events.getY;
    pub const getWidth = _events.getWidth;
    pub const getHeight = _events.getHeight;
    pub const getPreferredSize = _events.getPreferredSize;
    pub const requestDraw = _events.requestDraw;
    pub const deinit = _events.deinit;

    pub fn create() BackendError!NavigationSidebar {
        const NSScrollView = objc.getClass("NSScrollView").?;
        const scroll_view = NSScrollView.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{AppKit.NSRect.make(0, 0, 200, 400)});
        scroll_view.setProperty("hasVerticalScroller", @as(u8, @intFromBool(true)));

        const data = try lib.internal.allocator.create(EventUserData);
        data.* = EventUserData{ .peer = scroll_view };
        return NavigationSidebar{
            .peer = GuiWidget{
                .object = scroll_view,
                .data = data,
            },
        };
    }

    pub fn append(self: *NavigationSidebar, item: anytype) void {
        _ = self;
        _ = item;
    }
};

// ---------------------------------------------------------------------------
// ImageData
// ---------------------------------------------------------------------------

pub const ImageData = struct {
    cg_image: AppKit.CGImageRef = null,
    width: usize = 0,
    height: usize = 0,

    pub fn from(width: usize, height: usize, stride: usize, cs: lib.Colorspace, bytes: []const u8) !ImageData {
        const color_space = AppKit.CGColorSpaceCreateDeviceRGB();
        defer AppKit.CGColorSpaceRelease(color_space);

        const bits_per_component: usize = 8;
        const bitmap_info: u32 = switch (cs) {
            .RGBA => AppKit.CGBitmapInfo.PremultipliedLast,
            .RGB => AppKit.CGBitmapInfo.NoneSkipLast,
        };

        const ctx = AppKit.CGBitmapContextCreate(
            @constCast(@ptrCast(bytes.ptr)),
            width,
            height,
            bits_per_component,
            stride,
            color_space,
            bitmap_info,
        );
        if (ctx == null) return error.UnknownError;

        const cg_image = AppKit.CGBitmapContextCreateImage(ctx);
        return ImageData{
            .cg_image = cg_image,
            .width = width,
            .height = height,
        };
    }

    pub fn draw(self: *ImageData) DrawLock {
        _ = self;
        return DrawLock{};
    }

    pub fn deinit(self: *ImageData) void {
        if (self.cg_image != null) {
            AppKit.CGImageRelease(self.cg_image);
            self.cg_image = null;
        }
    }

    pub const DrawLock = struct {
        pub fn end(self: *DrawLock) void {
            _ = self;
        }
    };
};

// ---------------------------------------------------------------------------
// AudioGenerator (stub - GTK also stubs this)
// ---------------------------------------------------------------------------

pub const AudioGenerator = struct {
    pub fn create(sample_rate: f32) !AudioGenerator {
        _ = sample_rate;
        return AudioGenerator{};
    }

    pub fn getBuffer(self: *const AudioGenerator, channel: u16) []f32 {
        _ = self;
        _ = channel;
        return &[_]f32{};
    }

    pub fn copyBuffer(self: *AudioGenerator, channel: u16) void {
        _ = self;
        _ = channel;
    }

    pub fn doneWrite(self: *AudioGenerator) void {
        _ = self;
    }

    pub fn deinit(self: *AudioGenerator) void {
        _ = self;
    }
};
