const std = @import("std");
const skia = @import("skia");
const geom = @import("../geometry.zig");
const tree_mod = @import("../tree.zig");
const builder = @import("../builder.zig");
const engine = @import("../layout/engine.zig");
const diag = @import("../layout/diagnostics.zig");
const fonts_mod = @import("../fonts.zig");
const sink_mod = @import("sink.zig");
const skia_canvas = @import("skia_canvas.zig");
const skia_text = @import("skia_text.zig");

pub const PdfOptions = struct {
    fonts: ?*const fonts_mod.FontRegistry = null,
    title: ?[:0]const u8 = null,
    author: ?[:0]const u8 = null,
    subject: ?[:0]const u8 = null,
    keywords: ?[:0]const u8 = null,
    creator: ?[:0]const u8 = "pagine",
    producer: ?[:0]const u8 = "pagine (skia-zig)",
    lang: ?[:0]const u8 = null,
    pdfa: bool = false,
    outline: skia.pdf.Outline = .structure_element_headers,
    raster_dpi: f32 = 288.0,
    encoding_quality: i32 = 90,
    /// When true, embeds original raster images untouched instead of DPI-aware downsampling/re-encoding.
    use_original_images: bool = false,
    compression: skia.pdf.CompressionLevel = .default,
    max_pages: u32 = 10_000,
    /// When true, fails with `error.MissingGlyphs` if any text run has unresolved codepoints.
    check_missing_glyphs: bool = false,
    /// Enables Pass 1 -> Pass 2 `SkPicture` caching for static page content.
    enable_snapshot_cache: bool = true,
    diagnostic: ?*diag.LayoutDiagnostic = null,
};

pub const PdfBackend = struct {
    doc: skia.pdf.Document,
    drawer: skia_canvas.SkiaCanvasDrawer = .{},
    structure_root: ?skia.pdf.StructureElementNode = null,

    pub fn init(allocator: std.mem.Allocator, opts: PdfOptions, structure_root: ?skia.pdf.StructureElementNode) !PdfBackend {
        const pdf_doc = try skia.pdf.Document.init(.{
            .title = opts.title,
            .author = opts.author,
            .subject = opts.subject,
            .keywords = opts.keywords,
            .creator = opts.creator,
            .producer = opts.producer,
            .lang = opts.lang,
            .pdfa = opts.pdfa,
            .raster_dpi = opts.raster_dpi,
            .encoding_quality = opts.encoding_quality,
            .compression_level = opts.compression,
            .structure_tree_root = structure_root,
            .outline = if (structure_root != null) opts.outline else .none,
        });
        return .{
            .doc = pdf_doc,
            .drawer = .{
                .allocator = allocator,
                .default_image_dpi = opts.raster_dpi,
                .default_image_quality = @intCast(std.math.clamp(opts.encoding_quality, 1, 100)),
                .use_original_images = opts.use_original_images,
            },
            .structure_root = structure_root,
        };
    }

    pub fn deinit(self: *PdfBackend) void {
        self.drawer.deinit();
        self.doc.deinit();
        if (self.structure_root) |*root| root.deinit();
        self.* = undefined;
    }

    pub fn finish(self: *PdfBackend) skia.Data {
        return self.doc.finish();
    }

    pub fn sink(self: *PdfBackend) sink_mod.RenderSink {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = skia_canvas.SkiaCanvasDrawer.makeVTable(PdfBackend, beginPage, endPage);

    fn beginPage(ptr: *anyopaque, size: geom.Size) anyerror!void {
        const self: *PdfBackend = @ptrCast(@alignCast(ptr));
        const canvas = try self.doc.beginPage(size.width, size.height, null);
        self.drawer.canvas = canvas;
    }

    fn endPage(ptr: *anyopaque) void {
        const self: *PdfBackend = @ptrCast(@alignCast(ptr));
        self.drawer.canvas = null;
        self.doc.endPage();
    }
};

fn buildStructureTree(
    allocator: std.mem.Allocator,
    tree: *const tree_mod.Tree,
) !struct { root: ?skia.pdf.StructureElementNode, tag_ids: []i32 } {
    const tag_ids = try allocator.alloc(i32, tree.nodes.items.len);
    errdefer allocator.free(tag_ids);
    @memset(tag_ids, 0);

    var tag_count: usize = 0;
    for (tree.nodes.items) |n| {
        if (n.payload == .semantic_tag) tag_count += 1;
    }
    if (tag_count == 0) {
        return .{ .root = null, .tag_ids = tag_ids };
    }

    var root = try skia.pdf.StructureElementNode.init("Document", 1);
    errdefer root.deinit();

    var next_id: i32 = 2;
    for (tree.nodes.items, 0..) |n, idx| {
        if (n.payload == .semantic_tag) {
            const cfg = n.payload.semantic_tag;
            var elem = try skia.pdf.StructureElementNode.init(cfg.tag, next_id);
            if (cfg.alt) |a| elem.setAlt(a);
            if (cfg.lang) |l| elem.setLang(l);
            root.appendChild(&elem);
            tag_ids[idx] = next_id;
            next_id += 1;
        }
    }

    return .{ .root = root, .tag_ids = tag_ids };
}

/// Renders a `Document` directly into PDF bytes owned by `skia.Data` (`defer data.deinit()`).
pub fn renderPdf(doc: *const builder.Document, opts: PdfOptions) !skia.Data {
    var owned_fonts: ?fonts_mod.FontRegistry = null;
    defer if (owned_fonts) |*f| f.deinit();

    const font_reg: *const fonts_mod.FontRegistry = if (opts.fonts) |f| f else blk: {
        owned_fonts = try fonts_mod.FontRegistry.init(.{});
        break :blk &owned_fonts.?;
    };

    var text_eng = skia_text.SkiaTextEngine.init(doc.backing_allocator, font_reg);
    defer text_eng.deinit();

    const struct_info = try buildStructureTree(doc.backing_allocator, &doc.tree);
    defer doc.backing_allocator.free(struct_info.tag_ids);

    var backend = try PdfBackend.init(doc.backing_allocator, opts, struct_info.root);
    defer backend.deinit();

    _ = try doc.renderToSink(backend.sink(), .{
        .max_pages = opts.max_pages,
        .default_direction = doc.default_direction,
        .text_engine = text_eng.engine(),
        .pdf_tag_ids = struct_info.tag_ids,
        .check_missing_glyphs = opts.check_missing_glyphs,
        .enable_snapshot_cache = opts.enable_snapshot_cache,
        .diagnostic = opts.diagnostic,
    });

    return backend.finish();
}

/// Merges multiple `Document` instances into a single PDF using either continuous or independent page numbering.
pub fn mergePdf(
    allocator: std.mem.Allocator,
    docs: []const *const builder.Document,
    strategy: engine.MergePageNumberStrategy,
    opts: PdfOptions,
) !skia.Data {
    var owned_fonts: ?fonts_mod.FontRegistry = null;
    defer if (owned_fonts) |*f| f.deinit();

    const font_reg: *const fonts_mod.FontRegistry = if (opts.fonts) |f| f else blk: {
        owned_fonts = try fonts_mod.FontRegistry.init(.{});
        break :blk &owned_fonts.?;
    };

    const trees = try allocator.alloc(*const tree_mod.Tree, docs.len);
    defer allocator.free(trees);
    for (docs, 0..) |d, i| trees[i] = &d.tree;

    var text_eng = skia_text.SkiaTextEngine.init(allocator, font_reg);
    defer text_eng.deinit();

    var backend = try PdfBackend.init(allocator, opts, null);
    defer backend.deinit();

    _ = try engine.renderMergedTrees(allocator, trees, backend.sink(), strategy, .{
        .max_pages = opts.max_pages,
        .text_engine = text_eng.engine(),
        .check_missing_glyphs = opts.check_missing_glyphs,
        .enable_snapshot_cache = opts.enable_snapshot_cache,
        .diagnostic = opts.diagnostic,
    });

    return backend.finish();
}
