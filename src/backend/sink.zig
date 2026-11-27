const std = @import("std");
const geom = @import("../geometry.zig");
const style = @import("../style.zig");
const tree_mod = @import("../tree.zig");

pub const ImageDrawOptions = struct {
    target_dpi: ?f32 = null,
    quality: ?style.ImageCompressionQuality = null,
};

/// Thin drawing backend contract decoupling the pure-Zig layout engine from Skia.
/// Implemented by `NullSink` (Pass 1), `RecordingSink` (core tests), and `SkiaSink` (PDF/Image/SVG).
pub const RenderSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginPage: *const fn (ptr: *anyopaque, size: geom.Size) anyerror!void,
        endPage: *const fn (ptr: *anyopaque) void,
        save: *const fn (ptr: *anyopaque) void,
        restore: *const fn (ptr: *anyopaque) void,
        translate: *const fn (ptr: *anyopaque, dx: f32, dy: f32) void,
        scale: *const fn (ptr: *anyopaque, sx: f32, sy: f32) void,
        rotate: *const fn (ptr: *anyopaque, degrees: f32) void,
        clipRect: *const fn (ptr: *anyopaque, rect: geom.Rect, radius: f32) void,
        drawRect: *const fn (ptr: *anyopaque, rect: geom.Rect, color: style.Color, radius: f32) void,
        drawGradientRect: *const fn (ptr: *anyopaque, rect: geom.Rect, gradient: style.LinearGradient, radius: f32) void,
        drawBorder: *const fn (ptr: *anyopaque, rect: geom.Rect, border: style.BorderStyle) void,
        drawLine: *const fn (ptr: *anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: style.Color, dash: ?style.DashPattern) void,
        drawShadow: *const fn (ptr: *anyopaque, rect: geom.Rect, radius: f32, shadow: style.ShadowStyle) void,
        annotateUrl: *const fn (ptr: *anyopaque, rect: geom.Rect, url: []const u8) void,
        annotateNamedDest: *const fn (ptr: *anyopaque, pt: geom.Point, name: []const u8) void,
        annotateLinkToDest: *const fn (ptr: *anyopaque, rect: geom.Rect, name: []const u8) void,
        drawParagraph: *const fn (ptr: *anyopaque, handle: *anyopaque) void,
        drawImage: *const fn (ptr: *anyopaque, img: tree_mod.ImageRef, dst: geom.Rect, opts: ImageDrawOptions) void,
        drawSvg: *const fn (ptr: *anyopaque, svg: tree_mod.SvgRef, dst: geom.Rect) void,
        drawSvgPath: *const fn (ptr: *anyopaque, path_data: [:0]const u8, dst: geom.Rect, color: style.Color, stroke_width: ?f32, fit: bool) void,
        drawCustomCanvas: *const fn (ptr: *anyopaque, size: geom.Size, ctx: ?*const anyopaque, draw_fn: tree_mod.CanvasDrawFn) void,
        setPdfNodeId: *const fn (ptr: *anyopaque, node_id: i32) void,
        /// Optional Pass 1 -> Pass 2 display-list snapshot hooks (e.g. `SkPictureRecorder` / `SkPicture`).
        beginSnapshot: ?*const fn (ptr: *anyopaque, key: u64, bounds: geom.Size) ?RenderSink = null,
        endSnapshot: ?*const fn (ptr: *anyopaque, key: u64) void = null,
        replaySnapshot: ?*const fn (ptr: *anyopaque, key: u64) bool = null,
        clearSnapshots: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub inline fn beginPage(self: RenderSink, size: geom.Size) !void {
        return self.vtable.beginPage(self.ptr, size);
    }
    pub inline fn endPage(self: RenderSink) void {
        self.vtable.endPage(self.ptr);
    }
    pub inline fn save(self: RenderSink) void {
        self.vtable.save(self.ptr);
    }
    pub inline fn restore(self: RenderSink) void {
        self.vtable.restore(self.ptr);
    }
    pub inline fn translate(self: RenderSink, dx: f32, dy: f32) void {
        self.vtable.translate(self.ptr, dx, dy);
    }
    pub inline fn scale(self: RenderSink, sx: f32, sy: f32) void {
        self.vtable.scale(self.ptr, sx, sy);
    }
    pub inline fn rotate(self: RenderSink, degrees: f32) void {
        self.vtable.rotate(self.ptr, degrees);
    }
    pub inline fn clipRect(self: RenderSink, rect: geom.Rect, radius: f32) void {
        self.vtable.clipRect(self.ptr, rect, radius);
    }
    pub inline fn drawRect(self: RenderSink, rect: geom.Rect, color: style.Color, radius: f32) void {
        self.vtable.drawRect(self.ptr, rect, color, radius);
    }
    pub inline fn drawGradientRect(self: RenderSink, rect: geom.Rect, gradient: style.LinearGradient, radius: f32) void {
        self.vtable.drawGradientRect(self.ptr, rect, gradient, radius);
    }
    pub inline fn drawBorder(self: RenderSink, rect: geom.Rect, border: style.BorderStyle) void {
        self.vtable.drawBorder(self.ptr, rect, border);
    }
    pub inline fn drawLine(self: RenderSink, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: style.Color, dash: ?style.DashPattern) void {
        self.vtable.drawLine(self.ptr, x0, y0, x1, y1, thickness, color, dash);
    }
    pub inline fn drawShadow(self: RenderSink, rect: geom.Rect, radius: f32, shadow: style.ShadowStyle) void {
        self.vtable.drawShadow(self.ptr, rect, radius, shadow);
    }
    pub inline fn annotateUrl(self: RenderSink, rect: geom.Rect, url: []const u8) void {
        self.vtable.annotateUrl(self.ptr, rect, url);
    }
    pub inline fn annotateNamedDest(self: RenderSink, pt: geom.Point, name: []const u8) void {
        self.vtable.annotateNamedDest(self.ptr, pt, name);
    }
    pub inline fn annotateLinkToDest(self: RenderSink, rect: geom.Rect, name: []const u8) void {
        self.vtable.annotateLinkToDest(self.ptr, rect, name);
    }
    pub inline fn drawParagraph(self: RenderSink, handle: *anyopaque) void {
        self.vtable.drawParagraph(self.ptr, handle);
    }
    pub inline fn drawImage(self: RenderSink, img: tree_mod.ImageRef, dst: geom.Rect, opts: ImageDrawOptions) void {
        self.vtable.drawImage(self.ptr, img, dst, opts);
    }
    pub inline fn drawSvg(self: RenderSink, svg: tree_mod.SvgRef, dst: geom.Rect) void {
        self.vtable.drawSvg(self.ptr, svg, dst);
    }
    pub inline fn drawSvgPath(self: RenderSink, path_data: [:0]const u8, dst: geom.Rect, color: style.Color, stroke_width: ?f32, fit: bool) void {
        self.vtable.drawSvgPath(self.ptr, path_data, dst, color, stroke_width, fit);
    }
    pub inline fn drawCustomCanvas(self: RenderSink, size: geom.Size, ctx: ?*const anyopaque, draw_fn: tree_mod.CanvasDrawFn) void {
        self.vtable.drawCustomCanvas(self.ptr, size, ctx, draw_fn);
    }
    pub inline fn setPdfNodeId(self: RenderSink, node_id: i32) void {
        self.vtable.setPdfNodeId(self.ptr, node_id);
    }
    pub inline fn beginSnapshot(self: RenderSink, key: u64, bounds: geom.Size) ?RenderSink {
        if (self.vtable.beginSnapshot) |f| return f(self.ptr, key, bounds);
        return null;
    }
    pub inline fn endSnapshot(self: RenderSink, key: u64) void {
        if (self.vtable.endSnapshot) |f| f(self.ptr, key);
    }
    pub inline fn replaySnapshot(self: RenderSink, key: u64) bool {
        if (self.vtable.replaySnapshot) |f| return f(self.ptr, key);
        return false;
    }
    pub inline fn clearSnapshots(self: RenderSink) void {
        if (self.vtable.clearSnapshots) |f| f(self.ptr);
    }
};

/// No-op sink used during Pass 1 dry-run pagination and speculative layout.
pub const NullSink = struct {
    var dummy: u8 = 0;

    pub fn sink() RenderSink {
        return .{ .ptr = @ptrCast(&dummy), .vtable = &vtable };
    }

    const vtable: RenderSink.VTable = .{
        .beginPage = beginPage,
        .endPage = endPage,
        .save = noop0,
        .restore = noop0,
        .translate = noop2f,
        .scale = noop2f,
        .rotate = noop1f,
        .clipRect = noopClip,
        .drawRect = noopRect,
        .drawGradientRect = noopGrad,
        .drawBorder = noopBorder,
        .drawLine = noopLine,
        .drawShadow = noopShadow,
        .annotateUrl = noopAnnotRect,
        .annotateNamedDest = noopAnnotPt,
        .annotateLinkToDest = noopAnnotRect,
        .drawParagraph = noopParagraph,
        .drawImage = noopImage,
        .drawSvg = noopSvg,
        .drawSvgPath = noopSvgPath,
        .drawCustomCanvas = noopCanvas,
        .setPdfNodeId = noopNodeId,
    };

    fn beginPage(_: *anyopaque, _: geom.Size) anyerror!void {}
    fn endPage(_: *anyopaque) void {}
    fn noop0(_: *anyopaque) void {}
    fn noop1f(_: *anyopaque, _: f32) void {}
    fn noop2f(_: *anyopaque, _: f32, _: f32) void {}
    fn noopClip(_: *anyopaque, _: geom.Rect, _: f32) void {}
    fn noopRect(_: *anyopaque, _: geom.Rect, _: style.Color, _: f32) void {}
    fn noopGrad(_: *anyopaque, _: geom.Rect, _: style.LinearGradient, _: f32) void {}
    fn noopBorder(_: *anyopaque, _: geom.Rect, _: style.BorderStyle) void {}
    fn noopLine(_: *anyopaque, _: f32, _: f32, _: f32, _: f32, _: f32, _: style.Color, _: ?style.DashPattern) void {}
    fn noopShadow(_: *anyopaque, _: geom.Rect, _: f32, _: style.ShadowStyle) void {}
    fn noopAnnotRect(_: *anyopaque, _: geom.Rect, _: []const u8) void {}
    fn noopAnnotPt(_: *anyopaque, _: geom.Point, _: []const u8) void {}
    fn noopParagraph(_: *anyopaque, _: *anyopaque) void {}
    fn noopImage(_: *anyopaque, _: tree_mod.ImageRef, _: geom.Rect, _: ImageDrawOptions) void {}
    fn noopSvg(_: *anyopaque, _: tree_mod.SvgRef, _: geom.Rect) void {}
    fn noopSvgPath(_: *anyopaque, _: [:0]const u8, _: geom.Rect, _: style.Color, _: ?f32, _: bool) void {}
    fn noopCanvas(_: *anyopaque, _: geom.Size, _: ?*const anyopaque, _: tree_mod.CanvasDrawFn) void {}
    fn noopNodeId(_: *anyopaque, _: i32) void {}
};

/// Pure-Zig recording sink for deterministic unit testing of layout & pagination coordinates.
pub const RecordingSink = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList(PageRecord) = .empty,
    tx: f32 = 0,
    ty: f32 = 0,
    save_stack: std.ArrayList(geom.Point) = .empty,

    pub const DrawRectCmd = struct {
        rect: geom.Rect,
        color: style.Color,
        radius: f32,
    };

    pub const PageRecord = struct {
        size: geom.Size,
        rects: std.ArrayList(DrawRectCmd) = .empty,
        borders: std.ArrayList(geom.Rect) = .empty,
        lines: std.ArrayList(struct { x0: f32, y0: f32, x1: f32, y1: f32 }) = .empty,
        urls: std.ArrayList([]const u8) = .empty,
        dests: std.ArrayList([]const u8) = .empty,
        links: std.ArrayList([]const u8) = .empty,
        paragraph_draws: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) RecordingSink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RecordingSink) void {
        for (self.pages.items) |*p| {
            p.rects.deinit(self.allocator);
            p.borders.deinit(self.allocator);
            p.lines.deinit(self.allocator);
            p.urls.deinit(self.allocator);
            p.dests.deinit(self.allocator);
            p.links.deinit(self.allocator);
        }
        self.pages.deinit(self.allocator);
        self.save_stack.deinit(self.allocator);
    }

    pub fn sink(self: *RecordingSink) RenderSink {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn currentPage(self: *RecordingSink) *PageRecord {
        return self.pages.lastPtr().?;
    }

    const vtable: RenderSink.VTable = .{
        .beginPage = beginPage,
        .endPage = endPage,
        .save = save,
        .restore = restore,
        .translate = translate,
        .scale = scale,
        .rotate = rotate,
        .clipRect = clipRect,
        .drawRect = drawRect,
        .drawGradientRect = drawGradientRect,
        .drawBorder = drawBorder,
        .drawLine = drawLine,
        .drawShadow = drawShadow,
        .annotateUrl = annotateUrl,
        .annotateNamedDest = annotateNamedDest,
        .annotateLinkToDest = annotateLinkToDest,
        .drawParagraph = drawParagraph,
        .drawImage = recImage,
        .drawSvg = recSvg,
        .drawSvgPath = recSvgPath,
        .drawCustomCanvas = recCanvas,
        .setPdfNodeId = recNodeId,
    };

    fn beginPage(ptr: *anyopaque, size: geom.Size) anyerror!void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        self.tx = 0;
        self.ty = 0;
        self.save_stack.clearRetainingCapacity();
        try self.pages.append(self.allocator, .{ .size = size });
    }

    fn endPage(_: *anyopaque) void {}

    fn save(ptr: *anyopaque) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        self.save_stack.append(self.allocator, .{ .x = self.tx, .y = self.ty }) catch {};
    }

    fn restore(ptr: *anyopaque) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        if (self.save_stack.pop()) |pt| {
            self.tx = pt.x;
            self.ty = pt.y;
        }
    }

    fn translate(ptr: *anyopaque, dx: f32, dy: f32) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        self.tx += dx;
        self.ty += dy;
    }

    fn scale(_: *anyopaque, _: f32, _: f32) void {}
    fn rotate(_: *anyopaque, _: f32) void {}
    fn clipRect(_: *anyopaque, _: geom.Rect, _: f32) void {}

    fn drawRect(ptr: *anyopaque, rect: geom.Rect, color: style.Color, radius: f32) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        const shifted = geom.Rect{
            .left = rect.left + self.tx,
            .top = rect.top + self.ty,
            .right = rect.right + self.tx,
            .bottom = rect.bottom + self.ty,
        };
        self.currentPage().rects.append(self.allocator, .{
            .rect = shifted,
            .color = color,
            .radius = radius,
        }) catch {};
    }

    fn drawGradientRect(ptr: *anyopaque, rect: geom.Rect, _: style.LinearGradient, radius: f32) void {
        drawRect(ptr, rect, style.Color.black, radius);
    }

    fn drawBorder(ptr: *anyopaque, rect: geom.Rect, _: style.BorderStyle) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        const shifted = geom.Rect{
            .left = rect.left + self.tx,
            .top = rect.top + self.ty,
            .right = rect.right + self.tx,
            .bottom = rect.bottom + self.ty,
        };
        self.currentPage().borders.append(self.allocator, shifted) catch {};
    }

    fn drawLine(ptr: *anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, _: f32, _: style.Color, _: ?style.DashPattern) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        self.currentPage().lines.append(self.allocator, .{
            .x0 = x0 + self.tx,
            .y0 = y0 + self.ty,
            .x1 = x1 + self.tx,
            .y1 = y1 + self.ty,
        }) catch {};
    }

    fn drawShadow(_: *anyopaque, _: geom.Rect, _: f32, _: style.ShadowStyle) void {}

    fn annotateUrl(ptr: *anyopaque, _: geom.Rect, url: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        self.currentPage().urls.append(self.allocator, url) catch {};
    }

    fn annotateNamedDest(ptr: *anyopaque, _: geom.Point, name: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        self.currentPage().dests.append(self.allocator, name) catch {};
    }

    fn annotateLinkToDest(ptr: *anyopaque, _: geom.Rect, name: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        self.currentPage().links.append(self.allocator, name) catch {};
    }

    fn drawParagraph(ptr: *anyopaque, _: *anyopaque) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr));
        self.currentPage().paragraph_draws += 1;
    }

    fn recImage(_: *anyopaque, _: tree_mod.ImageRef, _: geom.Rect, _: ImageDrawOptions) void {}
    fn recSvg(_: *anyopaque, _: tree_mod.SvgRef, _: geom.Rect) void {}
    fn recSvgPath(_: *anyopaque, _: [:0]const u8, _: geom.Rect, _: style.Color, _: ?f32, _: bool) void {}
    fn recCanvas(_: *anyopaque, _: geom.Size, _: ?*const anyopaque, _: tree_mod.CanvasDrawFn) void {}
    fn recNodeId(_: *anyopaque, _: i32) void {}
};
