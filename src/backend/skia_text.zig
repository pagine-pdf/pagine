const std = @import("std");
const skia = @import("skia");
const geom = @import("../geometry.zig");
const style = @import("../style.zig");
const fonts_mod = @import("../fonts.zig");
const te = @import("../layout/text_engine.zig");
const skia_canvas = @import("skia_canvas.zig");

const CachedParagraph = struct {
    paragraph: skia.paragraph.Paragraph,
    last_width: f32 = -1.0,
    built_page: u32 = 0,
    built_initial_phase: bool = true,
    has_dynamic: bool = false,
    lines: []te.LineMetric = &.{},
    placeholder_rects: []geom.Rect = &.{},
    span_ranges: []te.TextRange = &.{},
    max_line_width: f32 = 0,
    unresolved_glyphs: i32 = 0,
    placeholder_map: []u32 = &.{}, // maps inline_element index -> SkParagraph placeholder index

    fn deinit(self: *CachedParagraph, allocator: std.mem.Allocator) void {
        self.paragraph.deinit();
        if (self.lines.len > 0) allocator.free(self.lines);
        if (self.placeholder_rects.len > 0) allocator.free(self.placeholder_rects);
        if (self.span_ranges.len > 0) allocator.free(self.span_ranges);
        if (self.placeholder_map.len > 0) allocator.free(self.placeholder_map);
    }
};

/// Production text shaping engine powered by `skia.paragraph` (HarfBuzz + ICU BiDi/CJK).
/// Caches built `skia.paragraph.Paragraph` handles per `NodeId` and frees them deterministically in `deinit()`.
pub const SkiaTextEngine = struct {
    allocator: std.mem.Allocator,
    fonts: *const fonts_mod.FontRegistry,
    cache: std.AutoHashMapUnmanaged(u32, CachedParagraph) = .empty,

    pub fn init(allocator: std.mem.Allocator, fonts: *const fonts_mod.FontRegistry) SkiaTextEngine {
        return .{
            .allocator = allocator,
            .fonts = fonts,
            .cache = .empty,
        };
    }

    pub fn deinit(self: *SkiaTextEngine) void {
        var it = self.cache.valueIterator();
        while (it.next()) |entry| {
            entry.deinit(self.allocator);
        }
        self.cache.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn engine(self: *SkiaTextEngine) te.TextEngine {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable: te.TextEngine.VTable = .{
        .layoutParagraph = layoutParagraph,
        .getRangeRects = getRangeRects,
        .evict = evictNode,
    };

    fn evictNode(ptr: *anyopaque, node_id: u32) void {
        const self: *SkiaTextEngine = @ptrCast(@alignCast(ptr));
        if (self.cache.fetchRemove(node_id)) |kv| {
            var old = kv.value;
            old.deinit(self.allocator);
        }
    }

    fn mapAlign(a: style.TextAlign) skia.paragraph.TextAlign {
        return switch (a) {
            .left => .left,
            .right => .right,
            .center => .center,
            .justify => .justify,
            .start => .start,
            .end => .end,
        };
    }

    fn mapDir(d: style.ContentDirection) skia.paragraph.TextDirection {
        return switch (d) {
            .ltr => .ltr,
            .rtl => .rtl,
        };
    }

    fn mapPlaceholderAlign(a: te.InlineElementAlignment) skia.paragraph.PlaceholderAlignment {
        return switch (a) {
            .above_baseline => .above_baseline,
            .below_baseline => .below_baseline,
            .top => .top,
            .bottom => .bottom,
            .middle => .middle,
        };
    }

    fn mapDecStyle(ds: style.TextDecorationStyle) skia.paragraph.TextDecorationStyle {
        return switch (ds) {
            .solid => .solid,
            .double => .double,
            .dotted => .dotted,
            .dashed => .dashed,
            .wavy => .wavy,
        };
    }

    fn buildSkTextStyle(resolved: style.ResolvedTextStyle, scratch: std.mem.Allocator) !skia.paragraph.TextStyle {
        var ts = skia.paragraph.TextStyle.init(.{
            .color = skia_canvas.toSkiaColor(resolved.color),
            .font_size = resolved.effectiveFontSize(),
            .font_style = .{
                .weight = @backingInt(resolved.weight),
                .slant = switch (resolved.slant) {
                    .upright => .upright,
                    .italic => .italic,
                    .oblique => .oblique,
                },
            },
        });
        errdefer ts.deinit();

        if (resolved.font_families.len > 0) {
            const ptrs = try scratch.alloc([*:0]const u8, resolved.font_families.len);
            for (resolved.font_families, 0..) |f, i| ptrs[i] = f.ptr;
            ts.setFontFamilies(ptrs);
        }

        if (resolved.line_height) |lh| {
            if (lh > 0) ts.setHeight(lh, true);
        }
        if (!geom.approxEq(resolved.letter_spacing, 0)) {
            ts.setLetterSpacing(resolved.letter_spacing * resolved.size);
        }
        if (!geom.approxEq(resolved.word_spacing, 0)) {
            ts.setWordSpacing(resolved.word_spacing * resolved.size);
        }
        const baseline_shift = resolved.effectiveBaselineShift();
        if (!geom.approxEq(baseline_shift, 0)) {
            ts.setBaselineShift(baseline_shift);
        }

        if (!resolved.background.isTransparent()) {
            var bg_paint = skia.Paint.init(.{ .color = skia_canvas.toSkiaColor(resolved.background) });
            defer bg_paint.deinit();
            ts.setBackgroundPaint(bg_paint);
        }

        var dec_mask: u32 = skia.paragraph.TextDecoration.none;
        if (resolved.underline) dec_mask |= skia.paragraph.TextDecoration.underline;
        if (resolved.strikethrough) dec_mask |= skia.paragraph.TextDecoration.line_through;
        if (resolved.overline) dec_mask |= skia.paragraph.TextDecoration.overline;
        if (dec_mask != 0) {
            ts.setDecoration(
                dec_mask,
                skia_canvas.toSkiaColor(resolved.decoration_color),
                mapDecStyle(resolved.decoration_style),
                resolved.decoration_thickness,
            );
        }

        if (resolved.locale) |loc| {
            ts.setLocale(loc);
        }
        for (resolved.font_features) |feat| {
            ts.addFontFeature(feat.name, feat.value);
        }

        return ts;
    }

    fn isOnlyWhitespace(spans: []const te.TextSpanItem) bool {
        for (spans) |sp| {
            switch (sp) {
                .page_number, .inline_element => return false,
                .literal => |l| {
                    for (l.text) |ch| {
                        if (!std.ascii.isWhitespace(ch)) return false;
                    }
                },
                .hyperlink => |h| {
                    for (h.text) |ch| {
                        if (!std.ascii.isWhitespace(ch)) return false;
                    }
                },
                .section_link => |s| {
                    for (s.text) |ch| {
                        if (!std.ascii.isWhitespace(ch)) return false;
                    }
                },
            }
        }
        return true;
    }

    fn layoutParagraph(ptr: *anyopaque, req: te.LayoutRequest) anyerror!te.ShapedLayout {
        const self: *SkiaTextEngine = @ptrCast(@alignCast(ptr));
        if (req.spans.len == 0) {
            return .{ .contains_only_whitespace = true };
        }

        const cache_key: u32 = if (req.is_ephemeral) (req.node_id | 0x8000_0000) else req.node_id;
        const whitespace_only = isOnlyWhitespace(req.spans);
        const need_rebuild = blk: {
            if (req.is_ephemeral) break :blk true;
            if (self.cache.getPtr(cache_key)) |entry| {
                if (entry.has_dynamic and (entry.built_page != req.page_ctx.current_page or entry.built_initial_phase != req.page_ctx.is_initial_phase)) {
                    break :blk true;
                }
                break :blk false;
            }
            break :blk true;
        };

        if (need_rebuild) {
            if (self.cache.fetchRemove(cache_key)) |kv| {
                var old = kv.value;
                old.deinit(self.allocator);
            }

            const built = try self.buildParagraphEntry(req, whitespace_only);
            try self.cache.put(self.allocator, cache_key, built);
        }

        const entry = self.cache.getPtr(cache_key).?;
        if (entry.last_width < 0 or !geom.approxEq(entry.last_width, req.max_width)) {
            // Add `geom.epsilon` before SkParagraph's internal SkScalarFloorToScalar
            // so tiny IEEE-754 subtraction drift (e.g. padding/margin round-trips
            // yielding 43.999996 instead of 44.0) does not drop a full point.
            const layout_w = if (req.max_width < geom.max_dimension) req.max_width + geom.epsilon else req.max_width;
            entry.paragraph.layout(layout_w);
            entry.last_width = req.max_width;
            entry.unresolved_glyphs = entry.paragraph.unresolvedGlyphs();

            // Refresh line metrics
            if (entry.lines.len > 0) {
                self.allocator.free(entry.lines);
                entry.lines = &.{};
            }
            const sk_lines = try entry.paragraph.getLineMetrics(req.scratch);
            const out_lines = try self.allocator.alloc(te.LineMetric, sk_lines.len);
            var max_w: f32 = 0;
            for (sk_lines, 0..) |lm, i| {
                const w: f32 = @floatCast(lm.width);
                const h: f32 = @floatCast(lm.height);
                const bl: f32 = @floatCast(lm.baseline);
                out_lines[i] = .{ .width = w, .height = h, .baseline = bl };
                max_w = @max(max_w, w);
            }
            if (sk_lines.len > 0) {
                const longest = entry.paragraph.longestLine();
                if (longest > max_w) max_w = longest;
            }
            entry.lines = out_lines;
            // SkParagraph::layout(rawWidth) applies SkScalarFloorToScalar(rawWidth)
            // when its default rounding hack is enabled. Ceiling the reported line
            // width ensures re-layout at the measured width (Row.auto, Alignment,
            // Shrink) never truncates below `longestLine()` and spuriously wraps.
            entry.max_line_width = if (max_w > 0) @ceil(max_w) else 0;

            // Refresh placeholder rects (filtered to user inline elements via placeholder_map)
            if (entry.placeholder_rects.len > 0) {
                self.allocator.free(entry.placeholder_rects);
                entry.placeholder_rects = &.{};
            }
            if (entry.placeholder_map.len > 0) {
                const all_boxes = try entry.paragraph.getRectsForPlaceholders(req.scratch);
                const out_rects = try self.allocator.alloc(geom.Rect, entry.placeholder_map.len);
                for (entry.placeholder_map, 0..) |sk_idx, i| {
                    if (sk_idx < all_boxes.len) {
                        const r = all_boxes[sk_idx].rect;
                        out_rects[i] = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
                    } else {
                        out_rects[i] = .{};
                    }
                }
                entry.placeholder_rects = out_rects;
            }
        }

        return .{
            .handle = @ptrCast(&entry.paragraph),
            .lines = entry.lines,
            .placeholder_rects = entry.placeholder_rects,
            .span_ranges = entry.span_ranges,
            .max_line_width = entry.max_line_width,
            .contains_only_whitespace = whitespace_only,
            .unresolved_glyphs = entry.unresolved_glyphs,
        };
    }

    fn utf16Len(utf8: []const u8) u32 {
        var count: u32 = 0;
        var i: usize = 0;
        while (i < utf8.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch {
                i += 1;
                count += 1;
                continue;
            };
            if (i + seq_len > utf8.len) {
                count += 1;
                break;
            }
            const cp = std.unicode.utf8Decode(utf8[i .. i + seq_len]) catch 0xFFFD;
            count += if (cp > 0xFFFF) 2 else 1;
            i += seq_len;
        }
        return count;
    }

    fn buildParagraphEntry(self: *SkiaTextEngine, req: te.LayoutRequest, whitespace_only: bool) !CachedParagraph {
        const base_style = req.config.default_style.inheritFrom(req.inherited_style);
        const resolved_base = base_style.resolve();

        var default_ts = try buildSkTextStyle(resolved_base, req.scratch);
        defer default_ts.deinit();

        var ps = skia.paragraph.ParagraphStyle.init(.{
            .text_align = mapAlign(req.effective_alignment),
            .text_direction = mapDir(req.direction),
            .text_style = default_ts,
        });
        defer ps.deinit();

        if (req.config.clamp_lines) |ml| {
            ps.setMaxLines(ml);
            ps.setEllipsis(req.config.clamp_ellipsis);
        }

        var pb = try skia.paragraph.ParagraphBuilder.init(ps, self.fonts.collection);
        defer pb.deinit();

        const span_ranges = try self.allocator.alloc(te.TextRange, req.spans.len);
        errdefer self.allocator.free(span_ranges);
        @memset(span_ranges, .{ .start = 0, .end = 0 });

        var ph_map: std.ArrayList(u32) = .empty;
        defer ph_map.deinit(self.allocator);

        if (whitespace_only) {
            pb.pushStyle(default_ts);
            pb.addText("\u{00A0}"); // non-breaking space for accurate single-line height
            pb.pop();
        } else {
            // SkParagraph::getRectsForRange indexes in UTF-16 code units (placeholders count as 1 unit).
            var utf16_pos: u32 = 0;
            var sk_ph_index: u32 = 0;
            var inline_idx: usize = 0;

            const has_para_fmt = req.config.paragraph_spacing > geom.epsilon or req.config.first_line_indent > geom.epsilon;
            var spacer_ts: ?skia.paragraph.TextStyle = null;
            defer if (spacer_ts) |*s| s.deinit();
            if (has_para_fmt) {
                spacer_ts = skia.paragraph.TextStyle.init(.{
                    .font_size = 0.01,
                    .height = 1.0,
                    .height_override = true,
                });
            }

            if (req.config.first_line_indent > geom.epsilon) {
                pb.addPlaceholder(.{
                    .width = req.config.first_line_indent,
                    .height = 0,
                    .alignment = .middle,
                });
                utf16_pos += 1;
                sk_ph_index += 1;
            }

            for (req.spans, 0..) |span, idx| {
                switch (span) {
                    .literal => |l| {
                        const res = l.style.inheritFrom(base_style).resolve();
                        var ts = try buildSkTextStyle(res, req.scratch);
                        defer ts.deinit();
                        span_ranges[idx] = addTextWithParagraphFmt(pb, ts, spacer_ts, l.text, req.config, &utf16_pos, &sk_ph_index);
                    },
                    .hyperlink => |h| {
                        const res = h.style.inheritFrom(base_style).resolve();
                        var ts = try buildSkTextStyle(res, req.scratch);
                        defer ts.deinit();
                        span_ranges[idx] = addTextWithParagraphFmt(pb, ts, spacer_ts, h.text, req.config, &utf16_pos, &sk_ph_index);
                    },
                    .section_link => |s| {
                        const res = s.style.inheritFrom(base_style).resolve();
                        var ts = try buildSkTextStyle(res, req.scratch);
                        defer ts.deinit();
                        span_ranges[idx] = addTextWithParagraphFmt(pb, ts, spacer_ts, s.text, req.config, &utf16_pos, &sk_ph_index);
                    },
                    .page_number => |pn| {
                        var tmp: [64]u8 = undefined;
                        const txt = te.formatPageNumber(pn, req.page_ctx, &tmp);
                        const res = pn.style.inheritFrom(base_style).resolve();
                        var ts = try buildSkTextStyle(res, req.scratch);
                        defer ts.deinit();
                        const start = utf16_pos;
                        pb.pushStyle(ts);
                        pb.addText(txt);
                        pb.pop();
                        utf16_pos += utf16Len(txt);
                        span_ranges[idx] = .{ .start = start, .end = utf16_pos };
                    },
                    .inline_element => |ie| {
                        const sz = if (inline_idx < req.inline_sizes.len) req.inline_sizes[inline_idx] else geom.Size.zero;
                        inline_idx += 1;
                        pb.addPlaceholder(.{
                            .width = sz.width,
                            .height = sz.height,
                            .alignment = mapPlaceholderAlign(ie.alignment),
                        });
                        try ph_map.append(self.allocator, sk_ph_index);
                        span_ranges[idx] = .{ .start = utf16_pos, .end = utf16_pos + 1 };
                        utf16_pos += 1;
                        sk_ph_index += 1;
                    },
                }
            }
        }

        const paragraph = try pb.build();
        return .{
            .paragraph = paragraph,
            .last_width = -1.0,
            .built_page = req.page_ctx.current_page,
            .built_initial_phase = req.page_ctx.is_initial_phase,
            .has_dynamic = req.config.has_dynamic_page_number,
            .span_ranges = span_ranges,
            .placeholder_map = try ph_map.toOwnedSlice(self.allocator),
        };
    }

    fn addTextWithParagraphFmt(
        pb: skia.paragraph.ParagraphBuilder,
        ts: skia.paragraph.TextStyle,
        spacer_ts: ?skia.paragraph.TextStyle,
        raw_text: []const u8,
        cfg: te.TextBlockConfig,
        utf16_pos: *u32,
        sk_ph_index: *u32,
    ) te.TextRange {
        const start = utf16_pos.*;
        const has_fmt = cfg.paragraph_spacing > geom.epsilon or cfg.first_line_indent > geom.epsilon;
        if (!has_fmt or std.mem.indexOfScalar(u8, raw_text, '\n') == null) {
            pb.pushStyle(ts);
            pb.addText(raw_text);
            pb.pop();
            utf16_pos.* += utf16Len(raw_text);
            return .{ .start = start, .end = utf16_pos.* };
        }

        var it = std.mem.splitScalar(u8, raw_text, '\n');
        var first = true;
        while (it.next()) |frag| {
            if (!first) {
                if (cfg.paragraph_spacing > geom.epsilon) {
                    if (spacer_ts) |sts| {
                        pb.pushStyle(sts);
                        pb.addText("\n ");
                        pb.pop();
                        utf16_pos.* += 2;
                    }
                    pb.addPlaceholder(.{
                        .width = 0,
                        .height = cfg.paragraph_spacing,
                        .alignment = .middle,
                    });
                    utf16_pos.* += 1;
                    sk_ph_index.* += 1;
                    if (spacer_ts) |sts| {
                        pb.pushStyle(sts);
                        pb.addText(" \n");
                        pb.pop();
                        utf16_pos.* += 2;
                    }
                } else {
                    pb.pushStyle(ts);
                    pb.addText("\n");
                    pb.pop();
                    utf16_pos.* += 1;
                }

                if (cfg.first_line_indent > geom.epsilon) {
                    pb.addPlaceholder(.{
                        .width = cfg.first_line_indent,
                        .height = 0,
                        .alignment = .middle,
                    });
                    utf16_pos.* += 1;
                    sk_ph_index.* += 1;
                }
            }
            first = false;
            if (frag.len > 0) {
                pb.pushStyle(ts);
                pb.addText(frag);
                pb.pop();
                utf16_pos.* += utf16Len(frag);
            }
        }
        return .{ .start = start, .end = utf16_pos.* };
    }

    fn getRangeRects(_: *anyopaque, handle: *anyopaque, start: u32, end: u32, scratch: std.mem.Allocator) anyerror![]const geom.Rect {
        if (end <= start) return &.{};
        const p: *skia.paragraph.Paragraph = @ptrCast(@alignCast(handle));
        const boxes = try p.getRectsForRange(scratch, start, end, .tight, .tight);
        const out = try scratch.alloc(geom.Rect, boxes.len);
        for (boxes, 0..) |b, i| {
            out[i] = .{ .left = b.rect.left, .top = b.rect.top, .right = b.rect.right, .bottom = b.rect.bottom };
        }
        return out;
    }
};
