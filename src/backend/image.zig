const std = @import("std");
const skia = @import("skia");
const geom = @import("../geometry.zig");
const builder = @import("../builder.zig");
const fonts_mod = @import("../fonts.zig");
const sink_mod = @import("sink.zig");
const skia_canvas = @import("skia_canvas.zig");
const skia_text = @import("skia_text.zig");

pub const ImageFormat = enum {
    png,
    jpeg,
    webp,
};

pub const ImageRenderOptions = struct {
    fonts: ?*const fonts_mod.FontRegistry = null,
    format: ImageFormat = .png,
    dpi: f32 = 144.0,
    quality: i32 = 90,
    webp_lossless: bool = false,
    max_pages: u32 = 10_000,
    check_missing_glyphs: bool = false,
    enable_snapshot_cache: bool = true,
};

/// Collection of per-page encoded outputs (PNG/JPEG/WebP or SVG) with deterministic cleanup.
pub const RenderedPages = struct {
    allocator: std.mem.Allocator,
    items: []skia.Data,

    pub fn deinit(self: *RenderedPages) void {
        for (self.items) |*d| d.deinit();
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

const ImageBackend = struct {
    allocator: std.mem.Allocator,
    opts: ImageRenderOptions,
    drawer: skia_canvas.SkiaCanvasDrawer = .{},
    current_surface: ?skia.Surface = null,
    pages: std.ArrayList(skia.Data) = .empty,
    encode_err: ?anyerror = null,

    fn deinit(self: *ImageBackend) void {
        self.drawer.deinit();
        if (self.current_surface) |*s| s.deinit();
        for (self.pages.items) |*d| d.deinit();
        self.pages.deinit(self.allocator);
    }

    pub fn sink(self: *ImageBackend) sink_mod.RenderSink {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = skia_canvas.SkiaCanvasDrawer.makeVTable(ImageBackend, beginPage, endPage);

    fn beginPage(ptr: *anyopaque, size: geom.Size) anyerror!void {
        const self: *ImageBackend = @ptrCast(@alignCast(ptr));
        const scale_factor = self.opts.dpi / 72.0;
        const px_w: i32 = @max(1, @as(i32, @intFromFloat(@ceil(size.width * scale_factor))));
        const px_h: i32 = @max(1, @as(i32, @intFromFloat(@ceil(size.height * scale_factor))));

        var surf = try skia.Surface.makeRasterN32Premul(px_w, px_h);
        const canvas = surf.canvas();
        canvas.clear(.transparent);
        canvas.scale(scale_factor, scale_factor);

        self.current_surface = surf;
        self.drawer.canvas = canvas;
    }

    fn endPage(ptr: *anyopaque) void {
        const self: *ImageBackend = @ptrCast(@alignCast(ptr));
        self.drawer.canvas = null;
        if (self.current_surface) |*surf| {
            defer {
                surf.deinit();
                self.current_surface = null;
            }
            var snap = surf.makeImageSnapshot() catch |e| {
                self.encode_err = e;
                return;
            };
            defer snap.deinit();

            const encoded = switch (self.opts.format) {
                .png => snap.encodePng(null, 6),
                .jpeg => snap.encodeJpeg(null, self.opts.quality),
                .webp => snap.encodeWebp(null, @floatFromInt(self.opts.quality), self.opts.webp_lossless),
            } catch |e| {
                self.encode_err = e;
                return;
            };
            self.pages.append(self.allocator, encoded) catch |e| {
                var d = encoded;
                d.deinit();
                self.encode_err = e;
            };
        }
    }
};

/// Renders each page of `doc` into an encoded raster image (`PNG`, `JPEG`, or `WebP`).
pub fn renderImages(doc: *const builder.Document, opts: ImageRenderOptions) !RenderedPages {
    var owned_fonts: ?fonts_mod.FontRegistry = null;
    defer if (owned_fonts) |*f| f.deinit();

    const font_reg: *const fonts_mod.FontRegistry = if (opts.fonts) |f| f else blk: {
        owned_fonts = try fonts_mod.FontRegistry.init(.{});
        break :blk &owned_fonts.?;
    };

    var text_eng = skia_text.SkiaTextEngine.init(doc.backing_allocator, font_reg);
    defer text_eng.deinit();

    var backend: ImageBackend = .{
        .allocator = doc.backing_allocator,
        .opts = opts,
        .drawer = .{
            .allocator = doc.backing_allocator,
            .use_original_images = true,
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
    if (backend.encode_err) |e| return e;

    const slice = try backend.pages.toOwnedSlice(doc.backing_allocator);
    backend.drawer.deinit();
    return .{
        .allocator = doc.backing_allocator,
        .items = slice,
    };
}
