const std = @import("std");
const skia = @import("skia");
const geom = @import("../geometry.zig");
const builder = @import("../builder.zig");
const fonts_mod = @import("../fonts.zig");
const sink_mod = @import("sink.zig");
const skia_canvas = @import("skia_canvas.zig");
const skia_text = @import("skia_text.zig");
const img_backend = @import("image.zig");

pub const SvgRenderOptions = struct {
    fonts: ?*const fonts_mod.FontRegistry = null,
    flags: u32 = skia.svg.CanvasFlags.none,
    max_pages: u32 = 10_000,
    check_missing_glyphs: bool = false,
    enable_snapshot_cache: bool = true,
};

const SvgBackend = struct {
    allocator: std.mem.Allocator,
    opts: SvgRenderOptions,
    drawer: skia_canvas.SkiaCanvasDrawer = .{},
    current_svg: ?skia.svg.SvgCanvas = null,
    pages: std.ArrayList(skia.Data) = .empty,
    err: ?anyerror = null,

    fn deinit(self: *SvgBackend) void {
        self.drawer.deinit();
        if (self.current_svg) |*s| s.deinit();
        for (self.pages.items) |*d| d.deinit();
        self.pages.deinit(self.allocator);
    }

    pub fn sink(self: *SvgBackend) sink_mod.RenderSink {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = skia_canvas.SkiaCanvasDrawer.makeVTable(SvgBackend, beginPage, endPage);

    fn beginPage(ptr: *anyopaque, size: geom.Size) anyerror!void {
        const self: *SvgBackend = @ptrCast(@alignCast(ptr));
        const svg_c = try skia.svg.SvgCanvas.init(.fromXYWH(0, 0, size.width, size.height), self.opts.flags);
        self.current_svg = svg_c;
        self.drawer.canvas = self.current_svg.?.canvas();
    }

    fn endPage(ptr: *anyopaque) void {
        const self: *SvgBackend = @ptrCast(@alignCast(ptr));
        self.drawer.canvas = null;
        if (self.current_svg) |*s| {
            defer {
                s.deinit();
                self.current_svg = null;
            }
            const data = s.finish();
            self.pages.append(self.allocator, data) catch |e| {
                var d = data;
                d.deinit();
                self.err = e;
            };
        }
    }
};

/// Renders each page of `doc` into standalone SVG XML bytes (`RenderedPages`).
pub fn renderSvg(doc: *const builder.Document, opts: SvgRenderOptions) !img_backend.RenderedPages {
    var owned_fonts: ?fonts_mod.FontRegistry = null;
    defer if (owned_fonts) |*f| f.deinit();

    const font_reg: *const fonts_mod.FontRegistry = if (opts.fonts) |f| f else blk: {
        owned_fonts = try fonts_mod.FontRegistry.init(.{});
        break :blk &owned_fonts.?;
    };

    var text_eng = skia_text.SkiaTextEngine.init(doc.backing_allocator, font_reg);
    defer text_eng.deinit();

    var backend: SvgBackend = .{
        .allocator = doc.backing_allocator,
        .opts = opts,
        .drawer = .{
            .allocator = doc.backing_allocator,
            .default_image_dpi = 288.0,
        },
    };
    errdefer backend.deinit();

    _ = try doc.renderToSink(backend.sink(), .{
        .max_pages = opts.max_pages,
        .default_direction = doc.default_direction,
        .text_engine = text_eng.engine(),
        .check_missing_glyphs = opts.check_missing_glyphs,
        .enable_snapshot_cache = opts.enable_snapshot_cache,
    });
    if (backend.err) |e| return e;

    const slice = try backend.pages.toOwnedSlice(doc.backing_allocator);
    backend.drawer.deinit();
    return .{
        .allocator = doc.backing_allocator,
        .items = slice,
    };
}
