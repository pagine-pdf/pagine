const std = @import("std");

/// Wraps Zig 0.17 `std.heap.SafeAllocator` so leak detection works in all optimize modes
/// and fails individual tests cleanly instead of aborting the entire test runner via `std.debug.assert`.
pub const TestAllocator = struct {
    gpa: std.heap.SafeAllocator,
    checked: bool = false,

    pub fn init() TestAllocator {
        return .{ .gpa = .init(std.heap.page_allocator, .{}) };
    }

    pub fn allocator(self: *TestAllocator) std.mem.Allocator {
        return self.gpa.allocator();
    }

    /// Call after all test resources have been freed (e.g. after the inner scope exits).
    pub fn expectNoLeaks(self: *TestAllocator) !void {
        self.checked = true;
        const leaks = self.gpa.deinit();
        try std.testing.expectEqual(@as(usize, 0), leaks);
    }

    /// Safety cleanup on early error return before `expectNoLeaks()`.
    pub fn deinit(self: *TestAllocator) void {
        if (!self.checked) {
            self.checked = true;
            _ = self.gpa.deinit();
        }
    }
};

/// Counts emitted `/Type /Page` objects in an uncompressed Skia PDF byte stream
/// (excluding `/Type /Pages` catalog nodes).
pub fn countPdfPages(pdf_bytes: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    const needle = "/Type /Page";
    while (std.mem.indexOfPos(u8, pdf_bytes, pos, needle)) |idx| {
        const after = idx + needle.len;
        if (after >= pdf_bytes.len or pdf_bytes[after] != 's') {
            count += 1;
        }
        pos = after;
    }
    return count;
}

/// Pure-Zig recording sink parameterized by namespace (`core` or `pagine`) so both
/// core unit tests and Skia integration tests share one implementation without module type conflicts.
pub fn RecordingSink(comptime NS: type) type {
    const geom = NS.geometry;
    const style = NS.style;
    const tree_mod = NS.tree;
    const sink_mod = NS.sink;

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        pages: std.ArrayList(PageRecord) = .empty,
        tx: f32 = 0,
        ty: f32 = 0,
        save_stack: std.ArrayList(geom.Point) = .empty,
        oom: bool = false,

        // Optional Pass 1 -> Pass 2 snapshot recording/replay support for testing Snapshot Cache.
        enable_snapshots: bool = false,
        recording_snapshot: ?SnapshotBuffer = null,
        snapshot_saved_origin: geom.Point = .zero,
        snapshots: std.AutoHashMapUnmanaged(u64, SnapshotBuffer) = .empty,
        snapshots_recorded: u32 = 0,
        snapshots_replayed: u32 = 0,

        pub const DrawRectCmd = struct {
            rect: geom.Rect,
            color: style.Color,
            radius: f32,
        };

        pub const LineCmd = struct {
            x0: f32,
            y0: f32,
            x1: f32,
            y1: f32,
        };

        const SnapshotBuffer = struct {
            rects: std.ArrayList(DrawRectCmd) = .empty,
            borders: std.ArrayList(geom.Rect) = .empty,
            lines: std.ArrayList(LineCmd) = .empty,
            paragraph_draws: u32 = 0,

            fn deinit(self: *SnapshotBuffer, allocator: std.mem.Allocator) void {
                self.rects.deinit(allocator);
                self.borders.deinit(allocator);
                self.lines.deinit(allocator);
            }
        };

        pub const PageRecord = struct {
            size: geom.Size,
            rects: std.ArrayList(DrawRectCmd) = .empty,
            borders: std.ArrayList(geom.Rect) = .empty,
            lines: std.ArrayList(LineCmd) = .empty,
            clips: std.ArrayList(geom.Rect) = .empty,
            scales: std.ArrayList(geom.Point) = .empty,
            rotations: std.ArrayList(f32) = .empty,
            urls: std.ArrayList([]const u8) = .empty,
            dests: std.ArrayList([]const u8) = .empty,
            links: std.ArrayList([]const u8) = .empty,
            pdf_node_ids: std.ArrayList(i32) = .empty,
            paragraph_draws: u32 = 0,
            image_draws: u32 = 0,
            svg_draws: u32 = 0,
            svg_path_draws: u32 = 0,
            canvas_draws: u32 = 0,
            snapshot_replays: u32 = 0,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn initWithSnapshots(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .enable_snapshots = true };
        }

        pub fn deinit(self: *Self) void {
            self.clearSnapshotsInternal();
            self.snapshots.deinit(self.allocator);
            for (self.pages.items) |*p| {
                p.rects.deinit(self.allocator);
                p.borders.deinit(self.allocator);
                p.lines.deinit(self.allocator);
                p.clips.deinit(self.allocator);
                p.scales.deinit(self.allocator);
                p.rotations.deinit(self.allocator);
                p.urls.deinit(self.allocator);
                p.dests.deinit(self.allocator);
                p.links.deinit(self.allocator);
                p.pdf_node_ids.deinit(self.allocator);
            }
            self.pages.deinit(self.allocator);
            self.save_stack.deinit(self.allocator);
        }

        fn clearSnapshotsInternal(self: *Self) void {
            if (self.recording_snapshot) |*buf| {
                buf.deinit(self.allocator);
                self.recording_snapshot = null;
            }
            var it = self.snapshots.valueIterator();
            while (it.next()) |buf| buf.deinit(self.allocator);
            self.snapshots.clearRetainingCapacity();
        }

        pub fn sink(self: *Self) sink_mod.RenderSink {
            return .{
                .ptr = @ptrCast(self),
                .vtable = if (self.enable_snapshots) &snapshot_vtable else &plain_vtable,
            };
        }

        fn currentPage(self: *Self) *PageRecord {
            return self.pages.lastPtr().?;
        }

        fn makeVTable(comptime with_snapshots: bool) sink_mod.RenderSink.VTable {
            return .{
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
                .beginSnapshot = if (with_snapshots) beginSnapshot else null,
                .endSnapshot = if (with_snapshots) endSnapshot else null,
                .replaySnapshot = if (with_snapshots) replaySnapshot else null,
                .clearSnapshots = if (with_snapshots) clearSnapshots else null,
            };
        }

        const plain_vtable = makeVTable(false);
        const snapshot_vtable = makeVTable(true);

        fn beginPage(ptr: *anyopaque, size: geom.Size) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tx = 0;
            self.ty = 0;
            self.save_stack.clearRetainingCapacity();
            try self.pages.append(self.allocator, .{ .size = size });
        }

        fn endPage(_: *anyopaque) void {}

        fn save(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.save_stack.append(self.allocator, .{ .x = self.tx, .y = self.ty }) catch {
                self.oom = true;
            };
        }

        fn restore(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.save_stack.pop()) |pt| {
                self.tx = pt.x;
                self.ty = pt.y;
            }
        }

        fn translate(ptr: *anyopaque, dx: f32, dy: f32) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tx += dx;
            self.ty += dy;
        }

        fn scale(ptr: *anyopaque, sx: f32, sy: f32) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null or self.pages.items.len == 0) return;
            self.currentPage().scales.append(self.allocator, .{ .x = sx, .y = sy }) catch {
                self.oom = true;
            };
        }

        fn rotate(ptr: *anyopaque, deg: f32) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null or self.pages.items.len == 0) return;
            self.currentPage().rotations.append(self.allocator, deg) catch {
                self.oom = true;
            };
        }

        fn clipRect(ptr: *anyopaque, rect: geom.Rect, _: f32) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null or self.pages.items.len == 0) return;
            const shifted = geom.Rect{
                .left = rect.left + self.tx,
                .top = rect.top + self.ty,
                .right = rect.right + self.tx,
                .bottom = rect.bottom + self.ty,
            };
            self.currentPage().clips.append(self.allocator, shifted) catch {
                self.oom = true;
            };
        }

        fn drawRect(ptr: *anyopaque, rect: geom.Rect, color: style.Color, radius: f32) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const shifted = geom.Rect{
                .left = rect.left + self.tx,
                .top = rect.top + self.ty,
                .right = rect.right + self.tx,
                .bottom = rect.bottom + self.ty,
            };
            const cmd: DrawRectCmd = .{ .rect = shifted, .color = color, .radius = radius };
            if (self.recording_snapshot) |*buf| {
                buf.rects.append(self.allocator, cmd) catch {
                    self.oom = true;
                };
                return;
            }
            self.currentPage().rects.append(self.allocator, cmd) catch {
                self.oom = true;
            };
        }

        fn drawGradientRect(ptr: *anyopaque, rect: geom.Rect, _: style.LinearGradient, radius: f32) void {
            drawRect(ptr, rect, style.Color.black, radius);
        }

        fn drawBorder(ptr: *anyopaque, rect: geom.Rect, _: style.BorderStyle) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const shifted = geom.Rect{
                .left = rect.left + self.tx,
                .top = rect.top + self.ty,
                .right = rect.right + self.tx,
                .bottom = rect.bottom + self.ty,
            };
            if (self.recording_snapshot) |*buf| {
                buf.borders.append(self.allocator, shifted) catch {
                    self.oom = true;
                };
                return;
            }
            self.currentPage().borders.append(self.allocator, shifted) catch {
                self.oom = true;
            };
        }

        fn drawLine(ptr: *anyopaque, x0: f32, y0: f32, x1: f32, y1: f32, _: f32, _: style.Color, _: ?style.DashPattern) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const cmd: LineCmd = .{
                .x0 = x0 + self.tx,
                .y0 = y0 + self.ty,
                .x1 = x1 + self.tx,
                .y1 = y1 + self.ty,
            };
            if (self.recording_snapshot) |*buf| {
                buf.lines.append(self.allocator, cmd) catch {
                    self.oom = true;
                };
                return;
            }
            self.currentPage().lines.append(self.allocator, cmd) catch {
                self.oom = true;
            };
        }

        fn drawShadow(_: *anyopaque, _: geom.Rect, _: f32, _: style.ShadowStyle) void {}

        fn annotateUrl(ptr: *anyopaque, _: geom.Rect, url: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null) return;
            self.currentPage().urls.append(self.allocator, url) catch {
                self.oom = true;
            };
        }

        fn annotateNamedDest(ptr: *anyopaque, _: geom.Point, name: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null) return;
            self.currentPage().dests.append(self.allocator, name) catch {
                self.oom = true;
            };
        }

        fn annotateLinkToDest(ptr: *anyopaque, _: geom.Rect, name: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null) return;
            self.currentPage().links.append(self.allocator, name) catch {
                self.oom = true;
            };
        }

        fn drawParagraph(ptr: *anyopaque, _: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot) |*buf| {
                buf.paragraph_draws += 1;
                return;
            }
            self.currentPage().paragraph_draws += 1;
        }

        fn recImage(ptr: *anyopaque, _: tree_mod.ImageRef, _: geom.Rect, _: sink_mod.ImageDrawOptions) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null or self.pages.items.len == 0) return;
            self.currentPage().image_draws += 1;
        }

        fn recSvg(ptr: *anyopaque, _: tree_mod.SvgRef, _: geom.Rect) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null or self.pages.items.len == 0) return;
            self.currentPage().svg_draws += 1;
        }

        fn recSvgPath(ptr: *anyopaque, _: [:0]const u8, _: geom.Rect, _: style.Color, _: ?f32, _: bool) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null or self.pages.items.len == 0) return;
            self.currentPage().svg_path_draws += 1;
        }

        fn recCanvas(ptr: *anyopaque, _: geom.Size, _: ?*const anyopaque, _: tree_mod.CanvasDrawFn) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null or self.pages.items.len == 0) return;
            self.currentPage().canvas_draws += 1;
        }

        fn recNodeId(ptr: *anyopaque, node_id: i32) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null or self.pages.items.len == 0) return;
            self.currentPage().pdf_node_ids.append(self.allocator, node_id) catch {
                self.oom = true;
            };
        }

        fn beginSnapshot(ptr: *anyopaque, _: u64, _: geom.Size) ?sink_mod.RenderSink {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.recording_snapshot != null) return null;
            self.snapshot_saved_origin = .{ .x = self.tx, .y = self.ty };
            self.tx = 0;
            self.ty = 0;
            self.recording_snapshot = .{};
            return self.sink();
        }

        fn endSnapshot(ptr: *anyopaque, key: u64) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.tx = self.snapshot_saved_origin.x;
            self.ty = self.snapshot_saved_origin.y;
            var buf = self.recording_snapshot orelse return;
            self.recording_snapshot = null;

            if (self.snapshots.fetchRemove(key)) |kv| {
                var old = kv.value;
                old.deinit(self.allocator);
            }
            self.snapshots.put(self.allocator, key, buf) catch {
                buf.deinit(self.allocator);
                self.oom = true;
                return;
            };
            self.snapshots_recorded += 1;
        }

        fn replaySnapshot(ptr: *anyopaque, key: u64) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.snapshots.fetchRemove(key)) |kv| {
                var buf = kv.value;
                defer buf.deinit(self.allocator);
                const page = self.currentPage();
                for (buf.rects.items) |cmd| {
                    page.rects.append(self.allocator, .{
                        .rect = .{
                            .left = cmd.rect.left + self.tx,
                            .top = cmd.rect.top + self.ty,
                            .right = cmd.rect.right + self.tx,
                            .bottom = cmd.rect.bottom + self.ty,
                        },
                        .color = cmd.color,
                        .radius = cmd.radius,
                    }) catch {
                        self.oom = true;
                    };
                }
                for (buf.borders.items) |r| {
                    page.borders.append(self.allocator, .{
                        .left = r.left + self.tx,
                        .top = r.top + self.ty,
                        .right = r.right + self.tx,
                        .bottom = r.bottom + self.ty,
                    }) catch {
                        self.oom = true;
                    };
                }
                for (buf.lines.items) |ln| {
                    page.lines.append(self.allocator, .{
                        .x0 = ln.x0 + self.tx,
                        .y0 = ln.y0 + self.ty,
                        .x1 = ln.x1 + self.tx,
                        .y1 = ln.y1 + self.ty,
                    }) catch {
                        self.oom = true;
                    };
                }
                page.paragraph_draws += buf.paragraph_draws;
                page.snapshot_replays += 1;
                self.snapshots_replayed += 1;
                return true;
            }
            return false;
        }

        fn clearSnapshots(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.clearSnapshotsInternal();
        }
    };
}

/// Deterministic monospace text engine fake for pure-Zig core unit tests.
/// Records Pass 2 rendered text, page number, and effective alignment for exact assertions.
pub fn MockTextEngine(comptime NS: type) type {
    const geom = NS.geometry;
    const style = NS.style;
    const te = NS.text_engine;

    return struct {
        const Self = @This();

        pub const Record = struct {
            text: []u8,
            alignment: style.TextAlign,
            page: u32,
            line_count: usize,
        };

        char_width: f32 = 6.0,
        line_height_factor: f32 = 1.2,
        /// Optional substring that triggers `unresolved_glyphs = 1` for testing `check_missing_glyphs`.
        missing_glyph_marker: ?[]const u8 = null,
        records: std.ArrayList(Record) = .empty,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.records.items) |r| self.allocator.free(r.text);
            self.records.deinit(self.allocator);
        }

        pub fn engine(self: *Self) te.TextEngine {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }

        pub fn hasRendered(self: *const Self, expected: []const u8) bool {
            for (self.records.items) |r| {
                if (std.mem.eql(u8, r.text, expected)) return true;
            }
            return false;
        }

        pub fn findAlignment(self: *const Self, expected_text: []const u8) ?style.TextAlign {
            for (self.records.items) |r| {
                if (std.mem.eql(u8, r.text, expected_text)) return r.alignment;
            }
            return null;
        }

        const vtable: te.TextEngine.VTable = .{
            .layoutParagraph = layoutParagraph,
            .getRangeRects = getRangeRects,
        };

        fn layoutParagraph(ptr: *anyopaque, req: te.LayoutRequest) anyerror!te.ShapedLayout {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const base_style = req.config.default_style.inheritFrom(req.inherited_style).resolve();
            const lh = base_style.size * (base_style.line_height orelse self.line_height_factor);

            var full_text: std.ArrayList(u8) = .empty;
            const ranges = try req.scratch.alloc(te.TextRange, req.spans.len);
            var ph_rects: std.ArrayList(geom.Rect) = .empty;
            var inline_idx: usize = 0;

            for (req.spans, 0..) |span, idx| {
                const start: u32 = @intCast(full_text.items.len);
                switch (span) {
                    .literal => |l| try full_text.appendSlice(req.scratch, l.text),
                    .hyperlink => |h| try full_text.appendSlice(req.scratch, h.text),
                    .section_link => |s| try full_text.appendSlice(req.scratch, s.text),
                    .page_number => |pn| {
                        var tmp: [64]u8 = undefined;
                        const txt = te.formatPageNumber(pn, req.page_ctx, &tmp);
                        try full_text.appendSlice(req.scratch, txt);
                    },
                    .inline_element => {
                        const sz = if (inline_idx < req.inline_sizes.len) req.inline_sizes[inline_idx] else geom.Size.zero;
                        inline_idx += 1;
                        try ph_rects.append(req.scratch, geom.Rect.fromXYWH(0, 0, sz.width, sz.height));
                        try full_text.append(req.scratch, ' ');
                    },
                }
                ranges[idx] = .{ .start = start, .end = @intCast(full_text.items.len) };
            }

            const text = full_text.items;
            const only_ws = blk: {
                for (text) |ch| {
                    if (!std.ascii.isWhitespace(ch)) break :blk false;
                }
                break :blk true;
            };

            if (text.len == 0 or only_ws) {
                const ws_lines = try req.scratch.alloc(te.LineMetric, 1);
                ws_lines[0] = .{ .width = 0, .height = lh, .baseline = lh * 0.8 };
                return .{
                    .lines = if (text.len == 0) &.{} else ws_lines,
                    .contains_only_whitespace = true,
                    .span_ranges = ranges,
                };
            }

            const max_chars_per_line: usize = @max(1, @as(usize, @intFromFloat(@floor(req.max_width / self.char_width))));
            var lines: std.ArrayList(te.LineMetric) = .empty;
            var max_line_w: f32 = 0;

            var it = std.mem.splitScalar(u8, text, '\n');
            var para_idx: usize = 0;
            while (it.next()) |para| : (para_idx += 1) {
                if (para_idx > 0 and req.config.paragraph_spacing > geom.epsilon) {
                    try lines.append(req.scratch, .{ .width = 0, .height = req.config.paragraph_spacing });
                }
                if (para.len == 0) {
                    try lines.append(req.scratch, .{ .width = 0, .height = lh, .baseline = lh * 0.8 });
                    continue;
                }
                var pos: usize = 0;
                while (pos < para.len) {
                    const take = @min(max_chars_per_line, para.len - pos);
                    const w = @as(f32, @floatFromInt(take)) * self.char_width;
                    max_line_w = @max(max_line_w, w);
                    try lines.append(req.scratch, .{ .width = w, .height = lh, .baseline = lh * 0.8 });
                    pos += take;
                }
            }

            if (req.config.clamp_lines) |limit| {
                if (lines.items.len > limit) {
                    lines.items.len = limit;
                }
            }

            if (!req.page_ctx.is_initial_phase) {
                try self.records.append(self.allocator, .{
                    .text = try self.allocator.dupe(u8, text),
                    .alignment = req.effective_alignment,
                    .page = req.page_ctx.current_page,
                    .line_count = lines.items.len,
                });
            }

            const unresolved: i32 = if (self.missing_glyph_marker) |marker|
                (if (std.mem.indexOf(u8, text, marker) != null) @as(i32, 1) else 0)
            else
                0;

            return .{
                .handle = @ptrCast(self),
                .lines = lines.items,
                .placeholder_rects = ph_rects.items,
                .span_ranges = ranges,
                .max_line_width = max_line_w,
                .contains_only_whitespace = false,
                .unresolved_glyphs = unresolved,
            };
        }

        fn getRangeRects(_: *anyopaque, _: *anyopaque, start: u32, end: u32, scratch: std.mem.Allocator) anyerror![]const geom.Rect {
            if (end <= start) return &.{};
            const out = try scratch.alloc(geom.Rect, 1);
            out[0] = geom.Rect.fromXYWH(0, 0, @as(f32, @floatFromInt(end - start)) * 6.0, 12.0);
            return out;
        }
    };
}
