const std = @import("std");
const skia = @import("skia");

/// Explicit font collection and custom typeface registry backed by Skia.
/// Create once (or per worker thread to avoid lock contention) and pass to `Document`.
pub const FontRegistry = struct {
    font_mgr: skia.FontMgr,
    provider: skia.paragraph.TypefaceFontProvider,
    collection: skia.paragraph.FontCollection,
    registered_count: usize = 0,

    pub const InitOptions = struct {
        /// Enable system font fallback via the platform FontMgr (CoreText / FontConfig / DirectWrite).
        enable_system_fonts: bool = true,
        /// Enable Skia glyph-level fallback when a primary family lacks a codepoint.
        enable_font_fallback: bool = true,
        /// Enable SkParagraph's internal paragraph cache. Set `false` for maximum multi-threaded scalability.
        enable_paragraph_cache: bool = true,
    };

    pub const Error = error{
        NoFontManager,
        InvalidFontData,
        FontFileNotFound,
        OutOfMemory,
    };

    pub fn init(opts: InitOptions) Error!FontRegistry {
        var font_mgr = skia.FontMgr.default() catch return error.NoFontManager;
        errdefer font_mgr.deinit();

        const provider = skia.paragraph.TypefaceFontProvider.init();
        const collection = skia.paragraph.FontCollection.init();

        if (opts.enable_system_fonts) {
            collection.setDefaultFontMgr(font_mgr);
        }
        collection.setAssetFontMgr(provider);
        collection.setFontFallbackEnabled(opts.enable_font_fallback);
        collection.setParagraphCacheEnabled(opts.enable_paragraph_cache);

        return .{
            .font_mgr = font_mgr,
            .provider = provider,
            .collection = collection,
            .registered_count = 0,
        };
    }

    pub fn deinit(self: *FontRegistry) void {
        self.collection.deinit();
        self.provider.deinit();
        self.font_mgr.deinit();
        self.* = undefined;
    }

    /// Registers a font from an in-memory buffer (e.g. `@embedFile("fonts/Inter.ttf")`).
    /// Pass `alias = null` to register under the font's internal family name.
    pub fn registerBytes(self: *FontRegistry, bytes: []const u8, alias: ?[:0]const u8) Error!void {
        var data = try skia.Data.fromBytes(bytes);
        defer data.deinit();
        var tf = self.font_mgr.makeFromData(data, 0) orelse return error.InvalidFontData;
        defer tf.deinit();
        self.provider.registerTypeface(tf, alias);
        self.registered_count += 1;
    }

    /// Registers a font from a filesystem path.
    pub fn registerFile(self: *FontRegistry, path: [:0]const u8, alias: ?[:0]const u8) Error!void {
        var tf = self.font_mgr.makeFromFile(path, 0) orelse return error.FontFileNotFound;
        defer tf.deinit();
        self.provider.registerTypeface(tf, alias);
        self.registered_count += 1;
    }

    pub fn setFallbackEnabled(self: *FontRegistry, enabled: bool) void {
        self.collection.setFontFallbackEnabled(enabled);
    }

    /// Toggles SkParagraph's internal ParagraphCache (disable when rendering concurrently on multiple threads).
    pub fn setParagraphCacheEnabled(self: *FontRegistry, enabled: bool) void {
        self.collection.setParagraphCacheEnabled(enabled);
    }
};
