const std = @import("std");
const skia = @import("skia");
const geom = @import("../geometry.zig");
const style = @import("../style.zig");
const tree_mod = @import("../tree.zig");
const sink_mod = @import("sink.zig");

pub inline fn toSkiaColor(col: style.Color) skia.Color {
    return skia.Color.fromU32(col.toU32());
}

pub inline fn toSkiaRect(r: geom.Rect) skia.Rect {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

pub const ImageCacheKey = struct {
    unique_id: u32,
    width: i32,
    height: i32,
    quality: u8,
};

/// Shared Skia drawing primitives driving any `skia.Canvas` (PDF, Raster Surface, SVG, PictureRecorder).
pub const SkiaCanvasDrawer = struct {
    canvas: ?skia.Canvas = null,
    allocator: ?std.mem.Allocator = null,
    default_image_dpi: f32 = 288.0,
    default_image_quality: u8 = 90,
    use_original_images: bool = false,
    image_cache: std.AutoHashMapUnmanaged(ImageCacheKey, skia.Image) = .empty,
    snapshot_recorder: ?skia.PictureRecorder = null,
    snapshot_saved_canvas: ?skia.Canvas = null,
    snapshots: std.AutoHashMapUnmanaged(u64, skia.Picture) = .empty,

    pub fn deinit(self: *SkiaCanvasDrawer) void {
        self.clearSnapshots();
        if (self.allocator) |alloc| {
            self.snapshots.deinit(alloc);
            var img_it = self.image_cache.valueIterator();
            while (img_it.next()) |img| img.deinit();
            self.image_cache.deinit(alloc);
        }
        self.canvas = null;
    }

    pub fn clearSnapshots(self: *SkiaCanvasDrawer) void {
        if (self.snapshot_recorder) |*rec| {
            rec.deinit();
            self.snapshot_recorder = null;
            self.canvas = self.snapshot_saved_canvas;
            self.snapshot_saved_canvas = null;
        }
        var it = self.snapshots.valueIterator();
        while (it.next()) |pic| pic.deinit();
        self.snapshots.clearRetainingCapacity();
    }

    pub fn save(self: *SkiaCanvasDrawer) void {
        if (self.canvas) |c| _ = c.save();
    }

    pub fn restore(self: *SkiaCanvasDrawer) void {
        if (self.canvas) |c| c.restore();
    }

    pub fn translate(self: *SkiaCanvasDrawer, dx: f32, dy: f32) void {
        if (self.canvas) |c| c.translate(dx, dy);
    }

    pub fn scale(self: *SkiaCanvasDrawer, sx: f32, sy: f32) void {
        if (self.canvas) |c| c.scale(sx, sy);
    }

    pub fn rotate(self: *SkiaCanvasDrawer, degrees: f32) void {
        if (self.canvas) |c| c.rotate(degrees);
    }

    pub fn clipRect(self: *SkiaCanvasDrawer, rect: geom.Rect, radius: f32) void {
        const c = self.canvas orelse return;
        const r = toSkiaRect(rect);
        if (radius > geom.epsilon) {
            c.clipRRect(skia.RRect.fromRectXY(r, radius, radius), .intersect, true);
        } else {
            c.clipRect(r, .intersect, true);
        }
    }

    pub fn drawRect(self: *SkiaCanvasDrawer, rect: geom.Rect, color: style.Color, radius: f32) void {
        const c = self.canvas orelse return;
        if (color.isTransparent() or rect.width() < geom.epsilon or rect.height() < geom.epsilon) return;
        var paint = skia.Paint.init(.{
            .color = toSkiaColor(color),
            .anti_alias = true,
        });
        defer paint.deinit();
        const r = toSkiaRect(rect);
        if (radius > geom.epsilon) {
            c.drawRoundRect(r, radius, radius, paint);
        } else {
            c.drawRect(r, paint);
        }
    }

    pub fn drawGradientRect(self: *SkiaCanvasDrawer, rect: geom.Rect, grad: style.LinearGradient, radius: f32) void {
        const c = self.canvas orelse return;
        if (grad.stops.len == 0 or rect.width() < geom.epsilon or rect.height() < geom.epsilon) return;

        var colors_buf: [16]skia.Color4f = undefined;
        var pos_buf: [16]f32 = undefined;
        const n = @min(grad.stops.len, colors_buf.len);
        for (0..n) |i| {
            colors_buf[i] = toSkiaColor(grad.stops[i].color).toColor4f();
            pos_buf[i] = grad.stops[i].pos;
        }

        const rad = std.math.degreesToRadians(grad.angle_deg);
        const cx = (rect.left + rect.right) * 0.5;
        const cy = (rect.top + rect.bottom) * 0.5;
        const half_w = rect.width() * 0.5;
        const half_h = rect.height() * 0.5;
        const dx = @cos(rad) * half_w;
        const dy = @sin(rad) * half_h;

        var shader = skia.Shader.makeLinearGradient(
            .{ .x = cx - dx, .y = cy - dy },
            .{ .x = cx + dx, .y = cy + dy },
            colors_buf[0..n],
            pos_buf[0..n],
            .clamp,
            null,
        ) orelse return;
        defer shader.deinit();

        var paint = skia.Paint.init(.{ .anti_alias = true });
        defer paint.deinit();
        paint.setShader(shader);

        const r = toSkiaRect(rect);
        if (radius > geom.epsilon) {
            c.drawRoundRect(r, radius, radius, paint);
        } else {
            c.drawRect(r, paint);
        }
    }

    pub fn drawBorder(self: *SkiaCanvasDrawer, rect: geom.Rect, border: style.BorderStyle) void {
        const c = self.canvas orelse return;
        if (border.color.isTransparent()) return;
        const sides = border.resolvedSides();
        if (sides.isZero()) return;

        // Uniform rounded border or uniform dashed border -> single stroke draw
        const is_uniform = geom.approxEq(sides.top, sides.right) and
            geom.approxEq(sides.top, sides.bottom) and
            geom.approxEq(sides.top, sides.left);

        if (is_uniform and (border.radius > geom.epsilon or border.dash != null)) {
            var paint = skia.Paint.init(.{
                .color = toSkiaColor(border.color),
                .style = .stroke,
                .stroke_width = sides.top,
                .anti_alias = true,
            });
            defer paint.deinit();

            var pe: ?skia.PathEffect = null;
            defer if (pe) |*p| p.deinit();
            if (border.dash) |d| {
                const intervals = [_]f32{ d.on, d.off };
                pe = skia.PathEffect.makeDash(&intervals, d.phase);
                if (pe) |p| paint.setPathEffect(p);
            }

            const r = toSkiaRect(rect);
            if (border.radius > geom.epsilon) {
                c.drawRoundRect(r, border.radius, border.radius, paint);
            } else {
                c.drawRect(r, paint);
            }
            return;
        }

        // Per-side borders (matches QuestPDF centered-edge semantics so adjacent table cells align seamlessly)
        const w = rect.width();
        const h = rect.height();
        if (border.dash) |d| {
            if (sides.top > geom.epsilon) {
                self.drawLine(rect.left, rect.top, rect.right, rect.top, sides.top, border.color, d);
            }
            if (sides.bottom > geom.epsilon) {
                self.drawLine(rect.left, rect.bottom, rect.right, rect.bottom, sides.bottom, border.color, d);
            }
            if (sides.left > geom.epsilon) {
                self.drawLine(rect.left, rect.top, rect.left, rect.bottom, sides.left, border.color, d);
            }
            if (sides.right > geom.epsilon) {
                self.drawLine(rect.right, rect.top, rect.right, rect.bottom, sides.right, border.color, d);
            }
            return;
        }

        var paint = skia.Paint.init(.{
            .color = toSkiaColor(border.color),
            .anti_alias = true,
        });
        defer paint.deinit();

        if (sides.top > geom.epsilon) {
            c.drawRect(.fromXYWH(rect.left - sides.left * 0.5, rect.top - sides.top * 0.5, w + sides.left * 0.5 + sides.right * 0.5, sides.top), paint);
        }
        if (sides.bottom > geom.epsilon) {
            c.drawRect(.fromXYWH(rect.left - sides.left * 0.5, rect.bottom - sides.bottom * 0.5, w + sides.left * 0.5 + sides.right * 0.5, sides.bottom), paint);
        }
        if (sides.left > geom.epsilon) {
            c.drawRect(.fromXYWH(rect.left - sides.left * 0.5, rect.top - sides.top * 0.5, sides.left, h + sides.top * 0.5 + sides.bottom * 0.5), paint);
        }
        if (sides.right > geom.epsilon) {
            c.drawRect(.fromXYWH(rect.right - sides.right * 0.5, rect.top - sides.top * 0.5, sides.right, h + sides.top * 0.5 + sides.bottom * 0.5), paint);
        }
    }

    pub fn drawLine(self: *SkiaCanvasDrawer, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: style.Color, dash: ?style.DashPattern) void {
        const c = self.canvas orelse return;
        if (color.isTransparent() or thickness < geom.epsilon) return;
        var paint = skia.Paint.init(.{
            .color = toSkiaColor(color),
            .style = .stroke,
            .stroke_width = thickness,
            .anti_alias = true,
        });
        defer paint.deinit();

        var pe: ?skia.PathEffect = null;
        defer if (pe) |*p| p.deinit();
        if (dash) |d| {
            const intervals = [_]f32{ d.on, d.off };
            pe = skia.PathEffect.makeDash(&intervals, d.phase);
            if (pe) |p| paint.setPathEffect(p);
        }

        c.drawLine(x0, y0, x1, y1, paint);
    }

    pub fn drawShadow(self: *SkiaCanvasDrawer, rect: geom.Rect, radius: f32, shadow: style.ShadowStyle) void {
        const c = self.canvas orelse return;
        if (shadow.color.isTransparent()) return;
        var paint = skia.Paint.init(.{
            .color = toSkiaColor(shadow.color),
            .anti_alias = true,
        });
        defer paint.deinit();

        var mf: ?skia.MaskFilter = null;
        defer if (mf) |*m| m.deinit();
        if (shadow.blur_sigma > geom.epsilon) {
            mf = skia.MaskFilter.makeBlur(.normal, shadow.blur_sigma, true);
            if (mf) |m| paint.setMaskFilter(m);
        }

        const r = skia.Rect{
            .left = rect.left + shadow.offset_x,
            .top = rect.top + shadow.offset_y,
            .right = rect.right + shadow.offset_x,
            .bottom = rect.bottom + shadow.offset_y,
        };
        if (radius > geom.epsilon) {
            c.drawRoundRect(r, radius, radius, paint);
        } else {
            c.drawRect(r, paint);
        }
    }

    pub fn annotateUrl(self: *SkiaCanvasDrawer, rect: geom.Rect, url: []const u8) void {
        if (self.canvas) |c| c.annotateUrl(toSkiaRect(rect), url);
    }

    pub fn annotateNamedDest(self: *SkiaCanvasDrawer, pt: geom.Point, name: []const u8) void {
        if (self.canvas) |c| c.annotateNamedDestination(.{ .x = pt.x, .y = pt.y }, name);
    }

    pub fn annotateLinkToDest(self: *SkiaCanvasDrawer, rect: geom.Rect, name: []const u8) void {
        if (self.canvas) |c| c.annotateLinkToDestination(toSkiaRect(rect), name);
    }

    pub fn drawParagraph(self: *SkiaCanvasDrawer, handle: *anyopaque) void {
        const c = self.canvas orelse return;
        const p: *skia.paragraph.Paragraph = @ptrCast(@alignCast(handle));
        p.paint(c, 0, 0);
    }

    fn isImageOpaque(self: *SkiaCanvasDrawer, img: skia.Image) bool {
        const alloc = self.allocator orelse return false;
        const w = img.width();
        const h = img.height();
        if (w <= 0 or h <= 0) return true;
        const info = skia.ImageInfo.makeRgba8888(w, h, .unpremul);
        const row_bytes = info.minRowBytes();
        const total = info.computeByteSize(row_bytes);
        const buf = alloc.alloc(u8, total) catch return false;
        defer alloc.free(buf);
        if (!img.readPixels(null, info, buf, row_bytes, 0, 0)) return false;
        var i: usize = 3;
        while (i < buf.len) : (i += 4) {
            if (buf[i] != 255) return false;
        }
        return true;
    }

    fn getOrOptimizeImage(self: *SkiaCanvasDrawer, img: skia.Image, dst: geom.Rect, opts: sink_mod.ImageDrawOptions) skia.Image {
        if (self.use_original_images) return img;
        const alloc = self.allocator orelse return img;
        const dpi = opts.target_dpi orelse self.default_image_dpi;
        if (dpi <= geom.epsilon) return img;

        const orig_w = img.width();
        const orig_h = img.height();
        if (orig_w <= 0 or orig_h <= 0) return img;

        const want_w: i32 = @max(1, @as(i32, @intFromFloat(@ceil(dst.width() * dpi / 72.0))));
        const want_h: i32 = @max(1, @as(i32, @intFromFloat(@ceil(dst.height() * dpi / 72.0))));
        const target_w = @min(orig_w, want_w);
        const target_h = @min(orig_h, want_h);
        const quality: u8 = if (opts.quality) |q| @backingInt(q) else self.default_image_quality;

        const needs_downsample = target_w < orig_w or target_h < orig_h;
        const explicit_reencode = opts.quality != null and quality < 100;
        if (!needs_downsample and !explicit_reencode) return img;

        const key: ImageCacheKey = .{
            .unique_id = img.uniqueId(),
            .width = target_w,
            .height = target_h,
            .quality = quality,
        };
        if (self.image_cache.get(key)) |cached| return cached;

        var surf = skia.Surface.makeRasterN32Premul(target_w, target_h) catch return img;
        defer surf.deinit();
        const sc = surf.canvas();
        sc.clear(.transparent);
        sc.drawImageRect(
            img,
            null,
            .fromXYWH(0, 0, @floatFromInt(target_w), @floatFromInt(target_h)),
            skia.SamplingOptions.mitchell,
            null,
            .strict,
        );
        var snap = surf.makeImageSnapshot() catch return img;
        defer snap.deinit();

        const encoded = if (quality < 100 and self.isImageOpaque(snap))
            snap.encodeJpeg(null, @intCast(quality)) catch return img
        else
            snap.encodePng(null, 6) catch return img;
        defer {
            var d = encoded;
            d.deinit();
        }

        var compressed = skia.Image.fromEncoded(encoded) catch return img;
        self.image_cache.put(alloc, key, compressed) catch {
            compressed.deinit();
            return img;
        };
        return compressed;
    }

    pub fn drawImage(self: *SkiaCanvasDrawer, img_ref: tree_mod.ImageRef, dst: geom.Rect, opts: sink_mod.ImageDrawOptions) void {
        const c = self.canvas orelse return;
        if (dst.width() < geom.epsilon or dst.height() < geom.epsilon) return;
        const raw_img: skia.Image = .{ .ptr = @ptrCast(@alignCast(img_ref.ptr)) };
        const effective = self.getOrOptimizeImage(raw_img, dst, opts);
        c.drawImageRect(effective, null, toSkiaRect(dst), skia.SamplingOptions.mitchell, null, .strict);
    }

    pub fn drawSvg(self: *SkiaCanvasDrawer, svg_ref: tree_mod.SvgRef, dst: geom.Rect) void {
        const c = self.canvas orelse return;
        if (dst.width() < geom.epsilon or dst.height() < geom.epsilon) return;
        const dom: skia.svg.SvgDom = .{ .ptr = @ptrCast(@alignCast(svg_ref.ptr)) };
        _ = c.save();
        defer c.restore();
        c.translate(dst.left, dst.top);
        const sx = if (svg_ref.width > geom.epsilon) dst.width() / svg_ref.width else 1.0;
        const sy = if (svg_ref.height > geom.epsilon) dst.height() / svg_ref.height else 1.0;
        c.scale(sx, sy);
        dom.render(c);
    }

    pub fn drawSvgPath(self: *SkiaCanvasDrawer, path_data: [:0]const u8, dst: geom.Rect, color: style.Color, stroke_width: ?f32, fit: bool) void {
        const c = self.canvas orelse return;
        if (color.isTransparent() or path_data.len == 0) return;
        var path = skia.Path.fromSvgString(path_data) catch return;
        defer path.deinit();

        var paint = skia.Paint.init(.{
            .color = toSkiaColor(color),
            .style = if (stroke_width != null) .stroke else .fill,
            .stroke_width = stroke_width orelse 0,
            .anti_alias = true,
        });
        defer paint.deinit();

        _ = c.save();
        defer c.restore();
        if (fit and dst.width() > geom.epsilon and dst.height() > geom.epsilon) {
            const bounds = path.getBounds();
            const bw = bounds.width();
            const bh = bounds.height();
            if (bw > geom.epsilon and bh > geom.epsilon) {
                const s = @min(dst.width() / bw, dst.height() / bh);
                const off_x = dst.left + (dst.width() - bw * s) * 0.5;
                const off_y = dst.top + (dst.height() - bh * s) * 0.5;
                c.translate(off_x, off_y);
                c.scale(s, s);
                c.translate(-bounds.left, -bounds.top);
            }
        }
        c.drawPath(path, paint);
    }

    pub fn drawCustomCanvas(self: *SkiaCanvasDrawer, size: geom.Size, ctx: ?*const anyopaque, draw_fn: tree_mod.CanvasDrawFn) void {
        const c = self.canvas orelse return;
        _ = c.save();
        defer c.restore();
        draw_fn(ctx, @ptrCast(c.ptr), size);
    }

    pub fn setPdfNodeId(self: *SkiaCanvasDrawer, node_id: i32) void {
        if (self.canvas) |c| skia.pdf.setNodeId(c, node_id);
    }

    pub fn beginSnapshot(self: *SkiaCanvasDrawer, bounds: geom.Size) bool {
        if (self.allocator == null or self.snapshot_recorder != null) return false;
        const rec = skia.PictureRecorder.init();
        self.snapshot_saved_canvas = self.canvas;
        self.snapshot_recorder = rec;
        self.canvas = rec.beginRecording(.fromXYWH(0, 0, @max(1.0, bounds.width), @max(1.0, bounds.height)));
        return true;
    }

    pub fn endSnapshot(self: *SkiaCanvasDrawer, key: u64) void {
        self.canvas = self.snapshot_saved_canvas;
        self.snapshot_saved_canvas = null;
        var rec = self.snapshot_recorder orelse return;
        self.snapshot_recorder = null;
        defer rec.deinit();

        const alloc = self.allocator orelse return;
        var pic = rec.finishRecording() catch return;
        if (self.snapshots.fetchRemove(key)) |kv| {
            var old = kv.value;
            old.deinit();
        }
        self.snapshots.put(alloc, key, pic) catch {
            pic.deinit();
        };
    }

    pub fn replaySnapshot(self: *SkiaCanvasDrawer, key: u64) bool {
        const c = self.canvas orelse return false;
        if (self.snapshots.fetchRemove(key)) |kv| {
            var pic = kv.value;
            defer pic.deinit();
            c.drawPicture(pic, null, null);
            return true;
        }
        return false;
    }

    /// Generates `RenderSink.VTable` delegates for any wrapper struct `Host` that has a `drawer: SkiaCanvasDrawer` field.
    pub fn makeVTable(
        comptime Host: type,
        comptime beginPageFn: fn (*anyopaque, geom.Size) anyerror!void,
        comptime endPageFn: fn (*anyopaque) void,
    ) sink_mod.RenderSink.VTable {
        const S = struct {
            inline fn d(ptr: *anyopaque) *SkiaCanvasDrawer {
                const h: *Host = @ptrCast(@alignCast(ptr));
                return &h.drawer;
            }
            fn save(p: *anyopaque) void {
                d(p).save();
            }
            fn restore(p: *anyopaque) void {
                d(p).restore();
            }
            fn translate(p: *anyopaque, dx: f32, dy: f32) void {
                d(p).translate(dx, dy);
            }
            fn scale(p: *anyopaque, sx: f32, sy: f32) void {
                d(p).scale(sx, sy);
            }
            fn rotate(p: *anyopaque, deg: f32) void {
                d(p).rotate(deg);
            }
            fn clipRect(p: *anyopaque, r: geom.Rect, rad: f32) void {
                d(p).clipRect(r, rad);
            }
            fn drawRect(p: *anyopaque, r: geom.Rect, col: style.Color, rad: f32) void {
                d(p).drawRect(r, col, rad);
            }
            fn drawGradientRect(p: *anyopaque, r: geom.Rect, g: style.LinearGradient, rad: f32) void {
                d(p).drawGradientRect(r, g, rad);
            }
            fn drawBorder(p: *anyopaque, r: geom.Rect, b: style.BorderStyle) void {
                d(p).drawBorder(r, b);
            }
            fn drawLine(p: *anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, t: f32, col: style.Color, dash: ?style.DashPattern) void {
                d(p).drawLine(x0, y0, x1, y1, t, col, dash);
            }
            fn drawShadow(p: *anyopaque, r: geom.Rect, rad: f32, sh: style.ShadowStyle) void {
                d(p).drawShadow(r, rad, sh);
            }
            fn annotateUrl(p: *anyopaque, r: geom.Rect, url: []const u8) void {
                d(p).annotateUrl(r, url);
            }
            fn annotateNamedDest(p: *anyopaque, pt: geom.Point, name: []const u8) void {
                d(p).annotateNamedDest(pt, name);
            }
            fn annotateLinkToDest(p: *anyopaque, r: geom.Rect, name: []const u8) void {
                d(p).annotateLinkToDest(r, name);
            }
            fn drawParagraph(p: *anyopaque, handle: *anyopaque) void {
                d(p).drawParagraph(handle);
            }
            fn drawImage(p: *anyopaque, img: tree_mod.ImageRef, dst: geom.Rect, opts: sink_mod.ImageDrawOptions) void {
                d(p).drawImage(img, dst, opts);
            }
            fn drawSvg(p: *anyopaque, svg: tree_mod.SvgRef, dst: geom.Rect) void {
                d(p).drawSvg(svg, dst);
            }
            fn drawSvgPath(p: *anyopaque, path_data: [:0]const u8, dst: geom.Rect, col: style.Color, sw: ?f32, fit: bool) void {
                d(p).drawSvgPath(path_data, dst, col, sw, fit);
            }
            fn drawCustomCanvas(p: *anyopaque, size: geom.Size, ctx: ?*const anyopaque, draw_fn: tree_mod.CanvasDrawFn) void {
                d(p).drawCustomCanvas(size, ctx, draw_fn);
            }
            fn setPdfNodeId(p: *anyopaque, node_id: i32) void {
                d(p).setPdfNodeId(node_id);
            }
            fn beginSnap(p: *anyopaque, _: u64, bounds: geom.Size) ?sink_mod.RenderSink {
                if (!d(p).beginSnapshot(bounds)) return null;
                const h: *Host = @ptrCast(@alignCast(p));
                return h.sink();
            }
            fn endSnap(p: *anyopaque, key: u64) void {
                d(p).endSnapshot(key);
            }
            fn replaySnap(p: *anyopaque, key: u64) bool {
                return d(p).replaySnapshot(key);
            }
            fn clearSnaps(p: *anyopaque) void {
                d(p).clearSnapshots();
            }
        };
        return .{
            .beginPage = beginPageFn,
            .endPage = endPageFn,
            .save = S.save,
            .restore = S.restore,
            .translate = S.translate,
            .scale = S.scale,
            .rotate = S.rotate,
            .clipRect = S.clipRect,
            .drawRect = S.drawRect,
            .drawGradientRect = S.drawGradientRect,
            .drawBorder = S.drawBorder,
            .drawLine = S.drawLine,
            .drawShadow = S.drawShadow,
            .annotateUrl = S.annotateUrl,
            .annotateNamedDest = S.annotateNamedDest,
            .annotateLinkToDest = S.annotateLinkToDest,
            .drawParagraph = S.drawParagraph,
            .drawImage = S.drawImage,
            .drawSvg = S.drawSvg,
            .drawSvgPath = S.drawSvgPath,
            .drawCustomCanvas = S.drawCustomCanvas,
            .setPdfNodeId = S.setPdfNodeId,
            .beginSnapshot = S.beginSnap,
            .endSnapshot = S.endSnap,
            .replaySnapshot = S.replaySnap,
            .clearSnapshots = S.clearSnaps,
        };
    }
};
