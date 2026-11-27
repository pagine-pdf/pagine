const std = @import("std");
const skia = @import("skia");
const geom = @import("geometry.zig");
const tree_mod = @import("tree.zig");
const fonts_mod = @import("fonts.zig");

/// Decoded, reference-counted raster image ready for placement into one or more documents.
pub const Image = struct {
    sk_image: skia.Image,

    pub fn fromBytes(encoded: []const u8) error{ DecodeFailed, OutOfMemory }!Image {
        var data = try skia.Data.fromBytes(encoded);
        defer data.deinit();
        const img = try skia.Image.fromEncoded(data);
        return .{ .sk_image = img };
    }

    pub fn fromSkia(img: skia.Image) Image {
        return .{ .sk_image = img.clone() };
    }

    pub fn width(self: Image) f32 {
        return @floatFromInt(self.sk_image.width());
    }

    pub fn height(self: Image) f32 {
        return @floatFromInt(self.sk_image.height());
    }

    pub fn size(self: Image) geom.Size {
        return .{ .width = self.width(), .height = self.height() };
    }

    pub fn clone(self: Image) Image {
        return .{ .sk_image = self.sk_image.clone() };
    }

    pub fn deinit(self: *Image) void {
        self.sk_image.deinit();
        self.* = undefined;
    }

    /// Produces a retained opaque `ImageRef` that `Document` automatically releases on `deinit()`.
    pub fn retainRef(self: Image) tree_mod.ImageRef {
        const cloned = self.sk_image.clone();
        return .{
            .ptr = @ptrCast(cloned.ptr),
            .width = self.width(),
            .height = self.height(),
            .release_fn = releaseSkiaImage,
        };
    }

    fn releaseSkiaImage(raw: *anyopaque) void {
        var img: skia.Image = .{ .ptr = @ptrCast(@alignCast(raw)) };
        img.deinit();
    }
};

/// Parsed, reference-counted vector SVG DOM (`SkSVGDOM`).
pub const Svg = struct {
    dom: skia.svg.SvgDom,
    intrinsic_size: geom.Size,

    pub fn fromBytes(xml: []const u8, fonts: ?*const fonts_mod.FontRegistry) error{SvgParseFailed}!Svg {
        const fm: ?skia.FontMgr = if (fonts) |f| f.font_mgr else null;
        var dom = try skia.svg.SvgDom.fromBytes(xml, fm);
        const cs = dom.containerSize();
        const intrinsic = if (cs.width > 0 and cs.height > 0)
            geom.Size.init(cs.width, cs.height)
        else blk: {
            const iv = dom.intrinsicSize(.{ .width = 300, .height = 150 }, 96.0);
            break :blk geom.Size.init(
                if (iv.width > 0) iv.width else 100,
                if (iv.height > 0) iv.height else 100,
            );
        };
        return .{
            .dom = dom,
            .intrinsic_size = intrinsic,
        };
    }

    pub fn size(self: Svg) geom.Size {
        return self.intrinsic_size;
    }

    pub fn clone(self: Svg) Svg {
        return .{
            .dom = self.dom.clone(),
            .intrinsic_size = self.intrinsic_size,
        };
    }

    pub fn deinit(self: *Svg) void {
        self.dom.deinit();
        self.* = undefined;
    }

    /// Produces a retained opaque `SvgRef` that `Document` automatically releases on `deinit()`.
    pub fn retainRef(self: Svg) tree_mod.SvgRef {
        const cloned = self.dom.clone();
        return .{
            .ptr = @ptrCast(cloned.ptr),
            .width = self.intrinsic_size.width,
            .height = self.intrinsic_size.height,
            .release_fn = releaseSkiaSvg,
        };
    }

    fn releaseSkiaSvg(raw: *anyopaque) void {
        var dom: skia.svg.SvgDom = .{ .ptr = @ptrCast(@alignCast(raw)) };
        dom.deinit();
    }
};
