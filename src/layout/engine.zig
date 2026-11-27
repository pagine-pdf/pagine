const std = @import("std");
const geom = @import("../geometry.zig");
const style = @import("../style.zig");
const tree_mod = @import("../tree.zig");
const state_mod = @import("../state.zig");
const sink_mod = @import("../backend/sink.zig");
const sp = @import("space_plan.zig");
const te = @import("text_engine.zig");
const tbl = @import("table.zig");
const diag = @import("diagnostics.zig");

const NodeId = tree_mod.NodeId;
const null_node = tree_mod.null_node;
const Size = geom.Size;
const Point = geom.Point;
const Rect = geom.Rect;
const SpacePlan = sp.SpacePlan;

pub const RenderError = tree_mod.ComposeError || error{
    LayoutOverflow,
    MaxPagesExceeded,
    MissingGlyphs,
};

pub const MergePageNumberStrategy = enum {
    continuous,
    independent,
};

pub const RenderOptions = struct {
    max_pages: u32 = 10_000,
    default_direction: style.ContentDirection = .ltr,
    text_engine: ?te.TextEngine = null,
    pdf_tag_ids: []const i32 = &.{},
    /// When true, fails with `error.MissingGlyphs` if any text block shapes unresolved codepoints.
    check_missing_glyphs: bool = false,
    /// Enables Pass 1 -> Pass 2 display-list snapshot caching for static page content when supported by the sink.
    enable_snapshot_cache: bool = true,
    /// Optional out-parameter populated with a formatted constraint trace on `error.LayoutOverflow`.
    diagnostic: ?*diag.LayoutDiagnostic = null,
};

pub const RenderStats = struct {
    page_count: u32 = 0,
};

pub const PlannedTableEntry = struct {
    resolved: []tbl.TableCell,
    plan: tbl.PlannedTable,
};

const CachedSlotPlan = struct {
    avail: Size,
    draw_size: Size,
    plan: SpacePlan,
};

const LastTablePlan = struct {
    id: NodeId,
    current_row: u32,
    avail: Size,
    res: RenderContext.TablePlanResult,
};

pub const RenderContext = struct {
    gpa: std.mem.Allocator,
    scratch: *std.heap.ArenaAllocator,
    tree: *const tree_mod.Tree,
    state: *state_mod.StateStore,
    page_ctx: *state_mod.PageContext,
    sink: sink_mod.RenderSink,
    text_engine: ?te.TextEngine = null,
    direction: style.ContentDirection = .ltr,
    text_style: style.TextStyle = .empty,
    inherited_text_align: ?style.TextAlign = null,
    current_pdf_node_id: i32 = 0,
    is_ephemeral_subtree: bool = false,
    in_repeating_context: bool = false,
    is_simulating: bool = false,
    in_snapshot_record: bool = false,
    check_missing_glyphs: bool = false,
    missing_glyphs: bool = false,
    /// Pre-planned & validated tables indexed by `NodeId` (eliminates O(Pages * Cells) re-sorting).
    planned_tables: []const ?PlannedTableEntry = &.{},
    /// Bottom-up static subtree flags indexed by `NodeId`.
    static_nodes: []const bool = &.{},
    /// Optional target sink supporting `beginSnapshot`/`endSnapshot` during Pass 1.
    snapshot_sink: ?sink_mod.RenderSink = null,
    /// Pass 1 -> Pass 2 cached slot plans keyed by `(doc_id, page_number, node_id)`.
    snapshot_plans: ?*std.AutoHashMapUnmanaged(u64, CachedSlotPlan) = null,
    /// Single-entry same-page table plan cache (valid within current `scratch` arena epoch).
    last_table_plan: ?LastTablePlan = null,
    /// Optional lookup table mapping Tree `NodeId` -> PDF/UA StructureElement node_id (>0).
    pdf_tag_ids: []const i32 = &.{},
    /// Set to true if an internal allocation fails during measure/draw.
    oom: bool = false,
    /// Last wrap reason captured at root for diagnostics.
    last_wrap_reason: ?[]const u8 = null,

    inline fn scratchAlloc(self: *RenderContext) std.mem.Allocator {
        return self.scratch.allocator();
    }

    inline fn isNodeStatic(self: *const RenderContext, id: NodeId) bool {
        if (id == null_node or id >= self.static_nodes.len) return false;
        return self.static_nodes[id];
    }

    inline fn snapshotKey(doc_id: u32, page_num: u32, node_id: NodeId) u64 {
        return (@as(u64, doc_id & 0xFFFF) << 48) | (@as(u64, page_num & 0xFF_FFFF) << 24) | @as(u64, node_id & 0xFF_FFFF);
    }

    pub fn measure(self: *RenderContext, id: NodeId, available: Size) SpacePlan {
        if (id == null_node) return .empty();
        if (available.isNegative()) return .wrap("Available space is negative.");

        const node = self.tree.get(id);
        return switch (node.payload) {
            .empty => .empty(),
            .container => if (node.first_child == null_node) .empty() else self.measure(node.first_child, available),
            .page => |cfg| self.measurePage(cfg, available),
            .column => |cfg| self.measureColumn(id, cfg.spacing, available),
            .row => |cfg| self.measureRow(id, cfg.spacing, available),
            .row_item => self.measureRowItem(id, available),
            .decoration => |cfg| self.measureDecoration(cfg, available),
            .layers => self.measureLayers(id, available),
            .layer => self.measure(node.first_child, available),
            .inlined => |cfg| self.measureInlined(id, cfg, available),
            .multi_column => |cfg| self.measureMultiColumn(cfg, available),
            .table_section => |cfg| self.measureTableSection(id, cfg, available),
            .padding => |insets| self.measurePadding(node.first_child, insets, available),
            .background => self.measureVisualWrapper(node.first_child, available),
            .border => self.measureVisualWrapper(node.first_child, available),
            .box => |cfg| self.measureBox(node.first_child, cfg, available),
            .constrained => |cfg| self.measureConstrained(node.first_child, cfg, available),
            .alignment => |cfg| blk: {
                const prev_ta = self.inherited_text_align;
                if (cfg.horizontal) |ha| self.inherited_text_align = mapHorizToTextAlign(ha);
                defer self.inherited_text_align = prev_ta;
                break :blk self.measure(node.first_child, available);
            },
            .extend => |cfg| self.measureExtend(node.first_child, cfg.horizontal, cfg.vertical, available),
            .shrink => self.measure(node.first_child, available),
            .unconstrained => self.measure(node.first_child, Size.max),
            .aspect_ratio => |cfg| self.measureAspectRatio(node.first_child, cfg.ratio, cfg.option, available),
            .clip => self.measure(node.first_child, available),
            .transform => |t| self.measureTransform(node.first_child, t, available),
            .line => |cfg| self.measureLine(cfg.horizontal, cfg.thickness, available),
            .default_text_style => |ts| blk: {
                const prev = self.text_style;
                self.text_style = ts.inheritFrom(prev);
                defer self.text_style = prev;
                break :blk self.measure(node.first_child, available);
            },
            .direction_setter => |dir| blk: {
                const prev = self.direction;
                self.direction = dir;
                defer self.direction = prev;
                break :blk self.measure(node.first_child, available);
            },
            .page_break => blk: {
                if (self.state.getBool(id)) break :blk .empty();
                break :blk .partial(.zero);
            },
            .show_entire => blk: {
                const m = self.measure(node.first_child, available);
                if (m.kind == .wrap) break :blk .wrap("ShowEntire child does not fit on page.");
                if (m.kind == .partial_render) break :blk .wrap("ShowEntire child only fits partially on page.");
                break :blk m;
            },
            .ensure_space => |cfg| blk: {
                const m = self.measure(node.first_child, available);
                if (self.state.getHardBool(id)) break :blk m;
                if (m.kind != .partial_render) break :blk m;
                if (cfg.min_height <= available.height + geom.epsilon) break :blk m;
                break :blk .wrap("Available height is less than EnsureSpace minimum height.");
            },
            .show_once => blk: {
                if (self.state.getHardBool(id)) break :blk .empty();
                break :blk self.measure(node.first_child, available);
            },
            .skip_once => blk: {
                if (!self.state.getHardBool(id)) break :blk .empty();
                break :blk self.measure(node.first_child, available);
            },
            .stop_paging => blk: {
                const m = self.measure(node.first_child, available);
                break :blk switch (m.kind) {
                    .wrap => .full(.zero),
                    .partial_render => .full(m.size),
                    .full_render, .empty => m,
                };
            },
            .repeat => self.measure(node.first_child, available),
            .show_if => |cfg| blk: {
                const visible = cfg.predicate(cfg.ctx, .{
                    .page_number = self.page_ctx.current_page,
                    .total_pages = self.page_ctx.totalPages(),
                });
                if (!visible) break :blk .empty();
                break :blk self.measure(node.first_child, available);
            },
            .section, .section_link, .hyperlink => self.measure(node.first_child, available),
            .debug_area => self.measureVisualWrapper(node.first_child, available),
            .text_block => |cfg| self.measureTextBlock(id, cfg, available),
            .image => |cfg| self.measureMedia(id, cfg.ref.width, cfg.ref.height, cfg.scaling, available),
            .svg => |cfg| self.measureMedia(id, cfg.ref.width, cfg.ref.height, cfg.scaling, available),
            .svg_path => if (self.state.getBool(id)) .empty() else .full(.zero),
            .canvas => if (self.state.getBool(id)) .empty() else .full(.zero),
            .dynamic => |cfg| self.measureDynamic(id, cfg, available),
            .semantic_tag => self.measure(node.first_child, available),
            .placeholder => .full(.zero),
        };
    }

    pub fn draw(self: *RenderContext, id: NodeId, available: Size) void {
        if (id == null_node) return;
        const node = self.tree.get(id);

        switch (node.payload) {
            .empty => {},
            .container => self.draw(node.first_child, available),
            .page => |cfg| self.drawPage(cfg, available),
            .column => |cfg| self.drawColumn(id, cfg.spacing, available),
            .row => |cfg| self.drawRow(id, cfg.spacing, available),
            .row_item => self.drawRowItem(id, available),
            .decoration => |cfg| self.drawDecoration(cfg, available),
            .layers => self.drawLayers(id, available),
            .layer => self.draw(node.first_child, available),
            .inlined => |cfg| self.drawInlined(id, cfg, available),
            .multi_column => |cfg| self.drawMultiColumn(cfg, available),
            .table_section => |cfg| self.drawTableSection(id, cfg, available),
            .padding => |insets| self.drawPadding(node.first_child, insets, available),
            .background => |cfg| {
                const rect = Rect.fromXYWH(0, 0, available.width, available.height);
                if (cfg.gradient) |g| {
                    self.sink.drawGradientRect(rect, g, cfg.radius);
                } else if (cfg.color) |col| {
                    if (!col.isTransparent()) self.sink.drawRect(rect, col, cfg.radius);
                }
                self.draw(node.first_child, available);
            },
            .border => |b| {
                self.draw(node.first_child, available);
                self.sink.drawBorder(Rect.fromXYWH(0, 0, available.width, available.height), b);
            },
            .box => |cfg| self.drawBox(node.first_child, cfg, available),
            .constrained => |cfg| self.drawConstrained(node.first_child, cfg, available),
            .alignment => |cfg| self.drawAlignment(node.first_child, cfg.horizontal, cfg.vertical, available),
            .extend => self.draw(node.first_child, available),
            .shrink => |cfg| self.drawShrink(node.first_child, cfg.horizontal, cfg.vertical, available),
            .unconstrained => self.draw(node.first_child, Size.max),
            .aspect_ratio => |cfg| self.drawAspectRatio(node.first_child, cfg.ratio, cfg.option, available),
            .clip => |cfg| {
                self.sink.save();
                self.sink.clipRect(Rect.fromXYWH(0, 0, available.width, available.height), cfg.radius);
                self.draw(node.first_child, available);
                self.sink.restore();
            },
            .transform => |t| self.drawTransform(node.first_child, t, available),
            .line => |cfg| self.drawLine(cfg.horizontal, cfg.thickness, cfg.color, cfg.dash, available),
            .default_text_style => |ts| {
                const prev = self.text_style;
                self.text_style = ts.inheritFrom(prev);
                defer self.text_style = prev;
                self.draw(node.first_child, available);
            },
            .direction_setter => |dir| {
                const prev = self.direction;
                self.direction = dir;
                defer self.direction = prev;
                self.draw(node.first_child, available);
            },
            .page_break => {
                self.state.setBool(id, true);
            },
            .show_entire => self.draw(node.first_child, available),
            .ensure_space => {
                self.draw(node.first_child, available);
                self.state.setHardBool(id, true);
            },
            .show_once => {
                if (self.state.getHardBool(id)) return;
                const m = self.measure(node.first_child, available);
                if (m.isDone()) self.state.setHardBool(id, true);
                self.draw(node.first_child, available);
            },
            .skip_once => {
                if (self.state.getHardBool(id)) {
                    self.draw(node.first_child, available);
                }
                self.state.setHardBool(id, true);
            },
            .stop_paging => self.draw(node.first_child, available),
            .repeat => {
                const prev_rep = self.in_repeating_context;
                self.in_repeating_context = true;
                defer self.in_repeating_context = prev_rep;
                const m = self.measure(node.first_child, available);
                self.draw(node.first_child, available);
                if (m.kind == .full_render) {
                    self.state.resetSubtree(self.tree, node.first_child, false);
                }
            },
            .show_if => |cfg| {
                const visible = cfg.predicate(cfg.ctx, .{
                    .page_number = self.page_ctx.current_page,
                    .total_pages = self.page_ctx.totalPages(),
                });
                if (!visible) return;
                self.draw(node.first_child, available);
            },
            .section => |cfg| {
                if (!self.state.getBool(id)) {
                    self.sink.annotateNamedDest(.zero, cfg.name);
                    self.state.setBool(id, true);
                }
                self.page_ctx.recordSectionPage(self.gpa, cfg.name) catch {
                    self.oom = true;
                };
                self.draw(node.first_child, available);
            },
            .section_link => |cfg| {
                self.sink.annotateLinkToDest(Rect.fromXYWH(0, 0, available.width, available.height), cfg.name);
                self.draw(node.first_child, available);
            },
            .hyperlink => |cfg| {
                self.sink.annotateUrl(Rect.fromXYWH(0, 0, available.width, available.height), cfg.url);
                self.draw(node.first_child, available);
            },
            .debug_area => |cfg| {
                self.draw(node.first_child, available);
                self.sink.drawRect(Rect.fromXYWH(0, 0, available.width, available.height), cfg.color.withAlpha(0x22), 0);
                self.sink.drawBorder(Rect.fromXYWH(0, 0, available.width, available.height), .{ .all = 1, .color = cfg.color });
            },
            .text_block => |cfg| self.drawTextBlock(id, cfg, available),
            .image => |cfg| {
                if (self.state.getBool(id)) return;
                const sz = computeMediaSize(cfg.ref.width, cfg.ref.height, cfg.scaling, available);
                self.sink.drawImage(cfg.ref, Rect.fromXYWH(0, 0, sz.width, sz.height), .{
                    .target_dpi = cfg.target_dpi,
                    .quality = cfg.quality,
                });
                self.state.setBool(id, true);
            },
            .svg => |cfg| {
                if (self.state.getBool(id)) return;
                const sz = computeMediaSize(cfg.ref.width, cfg.ref.height, cfg.scaling, available);
                self.sink.drawSvg(cfg.ref, Rect.fromXYWH(0, 0, sz.width, sz.height));
                self.state.setBool(id, true);
            },
            .svg_path => |cfg| {
                if (self.state.getBool(id)) return;
                self.sink.drawSvgPath(cfg.path_data, Rect.fromXYWH(0, 0, available.width, available.height), cfg.color, cfg.stroke_width, cfg.fit);
                self.state.setBool(id, true);
            },
            .canvas => |cfg| {
                if (self.state.getBool(id)) return;
                self.sink.drawCustomCanvas(available, cfg.ctx, cfg.draw_fn);
                self.state.setBool(id, true);
            },
            .dynamic => |cfg| self.drawDynamic(id, cfg, available),
            .semantic_tag => {
                const prev_id = self.current_pdf_node_id;
                const tag_id: i32 = if (id < self.pdf_tag_ids.len and self.pdf_tag_ids[id] != 0)
                    self.pdf_tag_ids[id]
                else
                    prev_id;
                if (tag_id != prev_id) {
                    self.current_pdf_node_id = tag_id;
                    self.sink.setPdfNodeId(tag_id);
                }
                defer if (tag_id != prev_id) {
                    self.current_pdf_node_id = prev_id;
                    self.sink.setPdfNodeId(prev_id);
                };
                self.draw(node.first_child, available);
            },
            .placeholder => {
                const rect = Rect.fromXYWH(0, 0, available.width, available.height);
                self.sink.drawRect(rect, style.Color.slate_200, 0);
                self.sink.drawBorder(rect, .{ .all = 1, .color = style.Color.slate_400 });
            },
        }
    }

    // -------------------------------------------------------------------------
    // Page Layout
    // -------------------------------------------------------------------------

    const PagePlan = struct {
        page_size: Size,
        inner_width: f32,
        header_plan: SpacePlan,
        content_avail: Size = .zero,
        content_plan: SpacePlan,
        footer_plan: SpacePlan,
        content_draw_size: Size,
        used_snapshot_plan: bool = false,
        result: SpacePlan,
    };

    fn planPage(self: *RenderContext, cfg: tree_mod.PageConfig, available: Size) PagePlan {
        const min_sz = cfg.size_mode.minSize();
        const max_sz = cfg.size_mode.maxSize();

        const avail_w = @min(max_sz.width, available.width);
        const avail_h = @min(max_sz.height, available.height);

        const inner_w = avail_w - cfg.margin.totalHorizontal();
        const inner_h = avail_h - cfg.margin.totalVertical();
        if (inner_w < -geom.epsilon or inner_h < -geom.epsilon) {
            return .{
                .page_size = .zero,
                .inner_width = 0,
                .header_plan = .empty(),
                .content_plan = .empty(),
                .footer_plan = .empty(),
                .content_draw_size = .zero,
                .result = .wrap("Page margins exceed page size."),
            };
        }

        const inner_avail = Size.init(@max(0, inner_w), @max(0, inner_h));
        const header_plan = if (cfg.header != null_node) self.measure(cfg.header, inner_avail) else SpacePlan.empty();
        if (header_plan.kind == .wrap or header_plan.kind == .partial_render) {
            return .{
                .page_size = .zero,
                .inner_width = inner_avail.width,
                .header_plan = header_plan,
                .content_plan = .empty(),
                .footer_plan = .empty(),
                .content_draw_size = .zero,
                .result = .wrap("Page header does not fit completely on the page."),
            };
        }

        const footer_plan = if (cfg.footer != null_node) self.measure(cfg.footer, inner_avail) else SpacePlan.empty();
        if (footer_plan.kind == .wrap or footer_plan.kind == .partial_render) {
            return .{
                .page_size = .zero,
                .inner_width = inner_avail.width,
                .header_plan = header_plan,
                .content_plan = .empty(),
                .footer_plan = footer_plan,
                .content_draw_size = .zero,
                .result = .wrap("Page footer does not fit completely on the page."),
            };
        }

        const content_avail_h = inner_avail.height - header_plan.size.height - footer_plan.size.height;
        if (content_avail_h < -geom.epsilon) {
            return .{
                .page_size = .zero,
                .inner_width = inner_avail.width,
                .header_plan = header_plan,
                .content_plan = .empty(),
                .footer_plan = footer_plan,
                .content_draw_size = .zero,
                .result = .wrap("Page header and footer leave no vertical space for content."),
            };
        }

        const content_avail = Size.init(inner_avail.width, @max(0, content_avail_h));
        var used_snapshot_plan = false;
        const content_plan = blk: {
            if (cfg.content == null_node) break :blk SpacePlan.full(.zero);
            if (!self.page_ctx.is_initial_phase) {
                if (self.snapshot_plans) |plans| {
                    const key = snapshotKey(self.page_ctx.current_document_id, self.page_ctx.current_page, cfg.content);
                    if (plans.get(key)) |cached| {
                        if (geom.approxEq(cached.avail.width, content_avail.width) and
                            geom.approxEq(cached.avail.height, content_avail.height))
                        {
                            used_snapshot_plan = true;
                            break :blk cached.plan;
                        }
                    }
                }
            }
            break :blk self.measure(cfg.content, content_avail);
        };
        if (content_plan.kind == .wrap) {
            return .{
                .page_size = .zero,
                .inner_width = inner_avail.width,
                .header_plan = header_plan,
                .content_avail = content_avail,
                .content_plan = content_plan,
                .footer_plan = footer_plan,
                .content_draw_size = .zero,
                .result = content_plan,
            };
        }

        const fixed_w = geom.approxEq(min_sz.width, max_sz.width);
        const fixed_h = geom.approxEq(min_sz.height, max_sz.height);

        const content_draw_w = if (fixed_w) inner_avail.width else @max(content_plan.size.width, @max(header_plan.size.width, footer_plan.size.width));
        const content_draw_h = if (fixed_h) content_avail.height else content_plan.size.height;

        const used_inner_w = @max(content_draw_w, @max(header_plan.size.width, footer_plan.size.width));
        const used_inner_h = header_plan.size.height + content_draw_h + footer_plan.size.height;

        const page_size = Size.init(
            @max(min_sz.width, used_inner_w + cfg.margin.totalHorizontal()),
            @max(min_sz.height, used_inner_h + cfg.margin.totalVertical()),
        );

        const result: SpacePlan = if (content_plan.kind == .partial_render)
            .partial(page_size)
        else
            .full(page_size);

        return .{
            .page_size = page_size,
            .inner_width = @max(0, page_size.width - cfg.margin.totalHorizontal()),
            .header_plan = header_plan,
            .content_avail = content_avail,
            .content_plan = content_plan,
            .footer_plan = footer_plan,
            .content_draw_size = Size.init(content_draw_w, content_draw_h),
            .used_snapshot_plan = used_snapshot_plan,
            .result = result,
        };
    }

    fn measurePagePlan(self: *RenderContext, page_id: NodeId, available: Size) PagePlan {
        const cfg = self.tree.get(page_id).payload.page;
        const prev_dir = self.direction;
        const prev_ts = self.text_style;
        if (cfg.direction) |d| self.direction = d;
        self.text_style = cfg.default_text_style.inheritFrom(prev_ts);
        defer {
            self.direction = prev_dir;
            self.text_style = prev_ts;
        }
        return self.planPage(cfg, available);
    }

    fn measurePage(self: *RenderContext, cfg: tree_mod.PageConfig, available: Size) SpacePlan {
        const prev_dir = self.direction;
        const prev_ts = self.text_style;
        if (cfg.direction) |d| self.direction = d;
        self.text_style = cfg.default_text_style.inheritFrom(prev_ts);
        defer {
            self.direction = prev_dir;
            self.text_style = prev_ts;
        }
        return self.planPage(cfg, available).result;
    }

    fn drawPage(self: *RenderContext, cfg: tree_mod.PageConfig, available: Size) void {
        const prev_dir = self.direction;
        const prev_ts = self.text_style;
        if (cfg.direction) |d| self.direction = d;
        self.text_style = cfg.default_text_style.inheritFrom(prev_ts);
        defer {
            self.direction = prev_dir;
            self.text_style = prev_ts;
        }

        const plan = self.planPage(cfg, available);
        self.drawPageBody(cfg, plan);
    }

    fn drawPageWithPlan(self: *RenderContext, page_id: NodeId, plan: PagePlan) void {
        const cfg = self.tree.get(page_id).payload.page;
        const prev_dir = self.direction;
        const prev_ts = self.text_style;
        if (cfg.direction) |d| self.direction = d;
        self.text_style = cfg.default_text_style.inheritFrom(prev_ts);
        defer {
            self.direction = prev_dir;
            self.text_style = prev_ts;
        }
        self.drawPageBody(cfg, plan);
    }

    fn drawPageBody(self: *RenderContext, cfg: tree_mod.PageConfig, plan: PagePlan) void {
        if (plan.result.kind == .wrap) return;

        // 1. Page background color
        if (!cfg.background_color.isTransparent()) {
            self.sink.drawRect(Rect.fromXYWH(0, 0, plan.page_size.width, plan.page_size.height), cfg.background_color, 0);
        }

        // 2. Background layer (repeats every page, ignores margins)
        if (cfg.background != null_node) {
            const prev_rep = self.in_repeating_context;
            self.in_repeating_context = true;
            defer self.in_repeating_context = prev_rep;
            const bg_m = self.measure(cfg.background, plan.page_size);
            if (bg_m.kind != .wrap) {
                self.draw(cfg.background, plan.page_size);
                if (bg_m.kind == .full_render) {
                    self.state.resetSubtree(self.tree, cfg.background, false);
                }
            }
        }

        // 3. Primary layer (margins -> header / content / footer)
        self.sink.translate(cfg.margin.left, cfg.margin.top);

        if (cfg.header != null_node and plan.header_plan.kind != .empty) {
            const prev_rep = self.in_repeating_context;
            self.in_repeating_context = true;
            defer self.in_repeating_context = prev_rep;
            self.draw(cfg.header, Size.init(plan.inner_width, plan.header_plan.size.height));
            self.state.resetSubtree(self.tree, cfg.header, false);
        }

        self.sink.translate(0, plan.header_plan.size.height);
        if (cfg.content != null_node) {
            const content_key = snapshotKey(self.page_ctx.current_document_id, self.page_ctx.current_page, cfg.content);
            var handled = false;
            if (self.page_ctx.is_initial_phase) {
                if (self.snapshot_sink) |snap_sink| {
                    if (self.snapshot_plans) |plans| {
                        if (self.isNodeStatic(cfg.content) and
                            !hasDynamicSlotHeight(self.tree, cfg.header) and
                            !hasDynamicSlotHeight(self.tree, cfg.footer))
                        {
                            if (snap_sink.beginSnapshot(content_key, plan.content_draw_size)) |rec_sink| {
                                const prev_sink = self.sink;
                                const prev_rec = self.in_snapshot_record;
                                self.sink = rec_sink;
                                self.in_snapshot_record = true;
                                self.draw(cfg.content, plan.content_draw_size);
                                self.sink = prev_sink;
                                self.in_snapshot_record = prev_rec;
                                snap_sink.endSnapshot(content_key);
                                plans.put(self.gpa, content_key, .{
                                    .avail = plan.content_avail,
                                    .draw_size = plan.content_draw_size,
                                    .plan = plan.content_plan,
                                }) catch {
                                    self.oom = true;
                                };
                                handled = true;
                            }
                        }
                    }
                }
            } else if (plan.used_snapshot_plan) {
                if (self.snapshot_plans) |plans| {
                    if (plans.get(content_key)) |cached| {
                        if (geom.approxEq(cached.draw_size.width, plan.content_draw_size.width) and
                            geom.approxEq(cached.draw_size.height, plan.content_draw_size.height))
                        {
                            if (self.sink.replaySnapshot(content_key)) {
                                handled = true;
                            }
                        }
                    }
                }
            }
            if (!handled) {
                self.draw(cfg.content, plan.content_draw_size);
            }
        }

        self.sink.translate(0, plan.content_draw_size.height);
        if (cfg.footer != null_node and plan.footer_plan.kind != .empty) {
            const prev_rep = self.in_repeating_context;
            self.in_repeating_context = true;
            defer self.in_repeating_context = prev_rep;
            self.draw(cfg.footer, Size.init(plan.inner_width, plan.footer_plan.size.height));
            self.state.resetSubtree(self.tree, cfg.footer, false);
        }

        self.sink.translate(-cfg.margin.left, -(cfg.margin.top + plan.header_plan.size.height + plan.content_draw_size.height));

        // 4. Foreground layer / watermark (repeats every page, ignores margins)
        if (cfg.foreground != null_node) {
            const prev_rep = self.in_repeating_context;
            self.in_repeating_context = true;
            defer self.in_repeating_context = prev_rep;
            const fg_m = self.measure(cfg.foreground, plan.page_size);
            if (fg_m.kind != .wrap) {
                self.draw(cfg.foreground, plan.page_size);
                if (fg_m.kind == .full_render) {
                    self.state.resetSubtree(self.tree, cfg.foreground, false);
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Column
    // -------------------------------------------------------------------------

    const ColumnCmd = struct {
        child: NodeId,
        plan: SpacePlan,
        offset_y: f32,
    };

    fn planColumn(self: *RenderContext, id: NodeId, spacing: f32, available: Size) []ColumnCmd {
        const node = self.tree.get(id);
        const start_idx = self.state.getU32(id);
        if (start_idx >= node.child_count) return &.{};

        var cmds: std.ArrayList(ColumnCmd) = .empty;
        var child = node.first_child;
        var idx: u32 = 0;
        while (child != null_node and idx < start_idx) : (idx += 1) {
            child = self.tree.get(child).next_sibling;
        }

        var top_offset: f32 = 0;
        while (child != null_node) : (child = self.tree.get(child).next_sibling) {
            const avail_h = available.height - top_offset;
            const item_space = if (avail_h >= 0) Size.init(available.width, avail_h) else Size.zero;

            const m = self.measure(child, item_space);
            if (m.kind == .wrap) break;
            if (item_space.isZero() and !m.size.isZero()) break;

            // Avoid trailing spacing before a zero-size/empty item
            if (top_offset > 0 and m.size.width < geom.epsilon and m.size.height < geom.epsilon) {
                top_offset -= spacing;
            }

            cmds.append(self.scratchAlloc(), .{
                .child = child,
                .plan = m,
                .offset_y = top_offset,
            }) catch {
                self.oom = true;
                return &.{};
            };

            if (m.kind == .partial_render) break;
            top_offset += m.size.height + spacing;
        }

        return cmds.items;
    }

    fn measureColumn(self: *RenderContext, id: NodeId, spacing: f32, available: Size) SpacePlan {
        const node = self.tree.get(id);
        const start_idx = self.state.getU32(id);
        if (node.child_count == 0 or start_idx >= node.child_count) return .empty();

        const cmds = self.planColumn(id, spacing, available);
        if (cmds.len == 0) return .wrap("Available space is insufficient to render even a single column item.");

        var max_w: f32 = 0;
        var done_count: u32 = 0;
        for (cmds) |cmd| {
            max_w = @max(max_w, cmd.plan.size.width);
            if (cmd.plan.isDone()) done_count += 1;
        }
        const last = cmds[cmds.len - 1];
        const total_h = last.offset_y + last.plan.size.height;

        if (max_w > available.width + geom.epsilon) return .wrap("Column content exceeds available width.");
        if (total_h > available.height + geom.epsilon) return .wrap("Column content exceeds available height.");

        const sz = Size.init(max_w, total_h);
        return if (start_idx + done_count >= node.child_count) .full(sz) else .partial(sz);
    }

    fn drawColumn(self: *RenderContext, id: NodeId, spacing: f32, available: Size) void {
        const cmds = self.planColumn(id, spacing, available);
        var done_count: u32 = 0;
        for (cmds) |cmd| {
            self.sink.translate(0, cmd.offset_y);
            self.draw(cmd.child, Size.init(available.width, cmd.plan.size.height));
            self.sink.translate(0, -cmd.offset_y);
            if (cmd.plan.isDone()) done_count += 1;
        }
        self.state.setU32(id, self.state.getU32(id) + done_count);
    }

    // -------------------------------------------------------------------------
    // Row
    // -------------------------------------------------------------------------

    const RowCmd = struct {
        item_node: NodeId,
        width: f32,
        height: f32,
        offset_x: f32,
        plan: SpacePlan,
    };

    fn planRow(self: *RenderContext, id: NodeId, spacing: f32, available: Size) struct { cmds: []RowCmd, negative_width: bool } {
        const node = self.tree.get(id);
        if (node.child_count == 0) return .{ .cmds = &.{}, .negative_width = false };

        const count = node.child_count;
        const widths = self.scratchAlloc().alloc(f32, count) catch {
            self.oom = true;
            return .{ .cmds = &.{}, .negative_width = false };
        };
        const items = self.scratchAlloc().alloc(NodeId, count) catch {
            self.oom = true;
            return .{ .cmds = &.{}, .negative_width = false };
        };

        var constant_sum: f32 = 0;
        var relative_sum: f32 = 0;

        var child = node.first_child;
        var i: usize = 0;
        while (child != null_node) : ({
            child = self.tree.get(child).next_sibling;
            i += 1;
        }) {
            items[i] = child;
            const item_node = self.tree.get(child);
            switch (item_node.payload.row_item.mode) {
                .auto => {
                    const m = self.measureRowItem(child, Size.max);
                    widths[i] = m.size.width;
                    constant_sum += m.size.width;
                },
                .constant => |w| {
                    widths[i] = w;
                    constant_sum += w;
                },
                .relative => |rel| {
                    widths[i] = rel;
                    relative_sum += rel;
                },
            }
        }

        const spacing_total = if (count > 1) @as(f32, @floatFromInt(count - 1)) * spacing else 0;
        if (relative_sum > 0) {
            const per_unit = (available.width - constant_sum - spacing_total) / relative_sum;
            for (items, 0..) |item_id, idx| {
                if (self.tree.get(item_id).payload.row_item.mode == .relative) {
                    widths[idx] *= per_unit;
                }
            }
        }

        for (widths) |w| {
            if (w < -geom.epsilon) return .{ .cmds = &.{}, .negative_width = true };
        }

        const cmds = self.scratchAlloc().alloc(RowCmd, count) catch {
            self.oom = true;
            return .{ .cmds = &.{}, .negative_width = false };
        };

        var left_offset: f32 = 0;
        var any_wrap = false;
        var max_h: f32 = 0;

        for (items, 0..) |item_id, idx| {
            const w = @max(0, widths[idx]);
            const item_space = Size.init(w, available.height);
            const m = self.measureRowItem(item_id, item_space);
            cmds[idx] = .{
                .item_node = item_id,
                .width = w,
                .height = available.height,
                .offset_x = left_offset,
                .plan = m,
            };
            left_offset += w + spacing;

            if (!self.state.getBool(item_id)) {
                if (m.kind == .wrap) any_wrap = true;
                max_h = @max(max_h, m.size.height);
            }
        }

        if (any_wrap) return .{ .cmds = cmds, .negative_width = false };

        for (cmds) |*cmd| {
            cmd.height = max_h;
            if (!geom.approxEq(max_h, available.height)) {
                cmd.plan = self.measureRowItem(cmd.item_node, Size.init(cmd.width, max_h));
            }
        }

        return .{ .cmds = cmds, .negative_width = false };
    }

    fn measureRowItem(self: *RenderContext, id: NodeId, available: Size) SpacePlan {
        if (self.state.getBool(id)) return .empty();
        return self.measure(self.tree.get(id).first_child, available);
    }

    fn drawRowItem(self: *RenderContext, id: NodeId, available: Size) void {
        if (self.state.getBool(id)) return;
        self.draw(self.tree.get(id).first_child, available);
    }

    fn measureRow(self: *RenderContext, id: NodeId, spacing: f32, available: Size) SpacePlan {
        const node = self.tree.get(id);
        if (node.child_count == 0) return .empty();

        var all_rendered = true;
        var c = node.first_child;
        while (c != null_node) : (c = self.tree.get(c).next_sibling) {
            if (!self.state.getBool(c)) {
                all_rendered = false;
                break;
            }
        }
        if (all_rendered) return .empty();

        const planned = self.planRow(id, spacing, available);
        if (planned.negative_width) return .wrap("Row items require more horizontal space than available.");
        if (planned.cmds.len == 0) return .empty();

        var any_partial = false;
        var max_h: f32 = 0;
        for (planned.cmds) |cmd| {
            if (!self.state.getBool(cmd.item_node)) {
                if (cmd.plan.kind == .wrap) return .wrap("Row item does not fit in available space.");
                if (cmd.plan.kind == .partial_render) any_partial = true;
            }
            max_h = @max(max_h, cmd.height);
        }

        const last = planned.cmds[planned.cmds.len - 1];
        const total_w = last.offset_x + last.width;
        if (total_w > available.width + geom.epsilon) return .wrap("Row exceeds available width.");
        if (max_h > available.height + geom.epsilon) return .wrap("Row exceeds available height.");

        const sz = Size.init(total_w, max_h);
        return if (any_partial) .partial(sz) else .full(sz);
    }

    fn drawRow(self: *RenderContext, id: NodeId, spacing: f32, available: Size) void {
        const planned = self.planRow(id, spacing, available);
        if (planned.negative_width) return;

        for (planned.cmds) |cmd| {
            if (cmd.plan.kind == .wrap) continue;
            const was_done = self.state.getBool(cmd.item_node);
            if (!was_done and cmd.plan.isDone()) {
                // Draw first, then mark rendered so child still draws!
            }
            const x = switch (self.direction) {
                .ltr => cmd.offset_x,
                .rtl => available.width - cmd.offset_x - cmd.width,
            };
            self.sink.translate(x, 0);
            self.drawRowItem(cmd.item_node, Size.init(cmd.width, available.height));
            self.sink.translate(-x, 0);

            if (!was_done and cmd.plan.isDone()) {
                self.state.setBool(cmd.item_node, true);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Decoration & Layers
    // -------------------------------------------------------------------------

    fn measureDecoration(self: *RenderContext, cfg: anytype, available: Size) SpacePlan {
        const before_m = if (cfg.before != null_node) self.measure(cfg.before, available) else SpacePlan.empty();
        if (before_m.kind == .wrap or before_m.kind == .partial_render) {
            return .wrap("Decoration before slot does not fit completely on page.");
        }
        const after_m = if (cfg.after != null_node) self.measure(cfg.after, available) else SpacePlan.empty();
        if (after_m.kind == .wrap or after_m.kind == .partial_render) {
            return .wrap("Decoration after slot does not fit completely on page.");
        }

        const content_h = available.height - before_m.size.height - after_m.size.height;
        if (content_h < -geom.epsilon) return .wrap("Decoration before/after slots exceed available height.");

        const content_m = if (cfg.content != null_node)
            self.measure(cfg.content, Size.init(available.width, @max(0, content_h)))
        else
            SpacePlan.empty();

        if (content_m.kind == .empty) return .empty();
        if (content_m.kind == .wrap) return .wrap("Decoration content does not fit on page.");

        const w = @max(before_m.size.width, @max(content_m.size.width, after_m.size.width));
        const h = before_m.size.height + content_m.size.height + after_m.size.height;
        if (w > available.width + geom.epsilon) return .wrap("Decoration exceeds available width.");
        if (h > available.height + geom.epsilon) return .wrap("Decoration exceeds available height.");

        return if (content_m.kind == .partial_render) .partial(Size.init(w, h)) else .full(Size.init(w, h));
    }

    fn drawDecoration(self: *RenderContext, cfg: anytype, available: Size) void {
        const before_m = if (cfg.before != null_node) self.measure(cfg.before, available) else SpacePlan.empty();
        const after_m = if (cfg.after != null_node) self.measure(cfg.after, available) else SpacePlan.empty();
        const content_h = @max(0, available.height - before_m.size.height - after_m.size.height);
        const content_m = if (cfg.content != null_node) self.measure(cfg.content, Size.init(available.width, content_h)) else SpacePlan.empty();
        if (content_m.kind == .empty or content_m.kind == .wrap) return;

        const w = @max(before_m.size.width, @max(content_m.size.width, after_m.size.width));
        const x_off: f32 = if (self.direction == .rtl) available.width - w else 0;

        if (cfg.before != null_node and before_m.kind != .empty) {
            const prev_rep = self.in_repeating_context;
            self.in_repeating_context = true;
            defer self.in_repeating_context = prev_rep;
            self.sink.translate(x_off, 0);
            self.draw(cfg.before, Size.init(w, before_m.size.height));
            self.sink.translate(-x_off, 0);
            self.state.resetSubtree(self.tree, cfg.before, false);
        }
        if (cfg.content != null_node) {
            self.sink.translate(x_off, before_m.size.height);
            self.draw(cfg.content, Size.init(w, content_m.size.height));
            self.sink.translate(-x_off, -before_m.size.height);
        }
        if (cfg.after != null_node and after_m.kind != .empty) {
            const prev_rep = self.in_repeating_context;
            self.in_repeating_context = true;
            defer self.in_repeating_context = prev_rep;
            const y_after = before_m.size.height + content_m.size.height;
            self.sink.translate(x_off, y_after);
            self.draw(cfg.after, Size.init(w, after_m.size.height));
            self.sink.translate(-x_off, -y_after);
            self.state.resetSubtree(self.tree, cfg.after, false);
        }
    }

    fn measureLayers(self: *RenderContext, id: NodeId, available: Size) SpacePlan {
        var child = self.tree.get(id).first_child;
        while (child != null_node) : (child = self.tree.get(child).next_sibling) {
            const n = self.tree.get(child);
            if (n.payload.layer.is_primary) {
                return self.measure(n.first_child, available);
            }
        }
        return .empty();
    }

    fn drawLayers(self: *RenderContext, id: NodeId, available: Size) void {
        var child = self.tree.get(id).first_child;
        while (child != null_node) : (child = self.tree.get(child).next_sibling) {
            const n = self.tree.get(child);
            const m = self.measure(n.first_child, available);
            if (m.kind != .wrap) {
                self.draw(n.first_child, available);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Inlined (Flow Wrap Container)
    // -------------------------------------------------------------------------

    const InlinedItemMeas = struct {
        child: NodeId,
        size: Size,
    };

    const InlinedLine = struct {
        items: []InlinedItemMeas,
        content_width: f32,
        height: f32,
    };

    fn planInlinedLines(self: *RenderContext, id: NodeId, cfg: anytype, available: Size) []InlinedLine {
        const node = self.tree.get(id);
        const start_idx = self.state.getU32(id);
        if (start_idx >= node.child_count) return &.{};

        var child = node.first_child;
        var skip: u32 = 0;
        while (child != null_node and skip < start_idx) : (skip += 1) {
            child = self.tree.get(child).next_sibling;
        }

        const eff_align: tree_mod.InlinedAlignment = cfg.alignment orelse
            if (self.direction == .ltr) .left else .right;

        var lines: std.ArrayList(InlinedLine) = .empty;
        var top_offset: f32 = 0;

        while (child != null_node) {
            var line_items: std.ArrayList(InlinedItemMeas) = .empty;
            var left_offset: f32 = if (eff_align == .space_around) cfg.horizontal_spacing * 2 else 0;
            var content_w: f32 = 0;
            var line_h: f32 = 0;

            var cursor = child;
            while (cursor != null_node) {
                const m = self.measure(cursor, Size.init(available.width, geom.max_dimension));
                if (m.kind == .wrap) break;
                if (left_offset + m.size.width > available.width + geom.epsilon) break;

                line_items.append(self.scratchAlloc(), .{ .child = cursor, .size = m.size }) catch {
                    self.oom = true;
                    return &.{};
                };
                content_w += m.size.width;
                line_h = @max(line_h, m.size.height);
                left_offset += m.size.width + cfg.horizontal_spacing;
                cursor = self.tree.get(cursor).next_sibling;
            }

            if (line_items.items.len == 0) break;
            if (top_offset + line_h > available.height + geom.epsilon) break;

            lines.append(self.scratchAlloc(), .{
                .items = line_items.items,
                .content_width = content_w,
                .height = line_h,
            }) catch {
                self.oom = true;
                return &.{};
            };
            top_offset += line_h + cfg.vertical_spacing;
            child = cursor;
        }

        return lines.items;
    }

    fn measureInlined(self: *RenderContext, id: NodeId, cfg: anytype, available: Size) SpacePlan {
        const node = self.tree.get(id);
        const start_idx = self.state.getU32(id);
        if (node.child_count == 0 or start_idx >= node.child_count) return .empty();

        const lines = self.planInlinedLines(id, cfg, available);
        if (lines.len == 0) return .wrap("Available space is insufficient to render even a single inlined item.");

        var max_w: f32 = 0;
        var total_h: f32 = 0;
        var rendered_count: u32 = 0;
        for (lines, 0..) |line, i| {
            const line_w = line.content_width + if (line.items.len > 1) @as(f32, @floatFromInt(line.items.len - 1)) * cfg.horizontal_spacing else 0;
            max_w = @max(max_w, line_w);
            total_h += line.height;
            if (i > 0) total_h += cfg.vertical_spacing;
            rendered_count += @intCast(line.items.len);
        }

        const sz = Size.init(@min(max_w, available.width), total_h);
        return if (start_idx + rendered_count >= node.child_count) .full(sz) else .partial(sz);
    }

    fn drawInlined(self: *RenderContext, id: NodeId, cfg: anytype, available: Size) void {
        const lines = self.planInlinedLines(id, cfg, available);
        const eff_align: tree_mod.InlinedAlignment = cfg.alignment orelse
            if (self.direction == .ltr) .left else .right;

        var top_offset: f32 = 0;
        var rendered_count: u32 = 0;

        for (lines) |line| {
            const n = line.items.len;
            const elem_gap: f32 = if (n <= 1) 0 else switch (eff_align) {
                .justify => (available.width - line.content_width) / @as(f32, @floatFromInt(n - 1)),
                .space_around => (available.width - line.content_width) / @as(f32, @floatFromInt(n + 1)),
                else => cfg.horizontal_spacing,
            };
            const base_empty = available.width - line.content_width - if (n > 1) @as(f32, @floatFromInt(n - 1)) * cfg.horizontal_spacing else 0;
            var left_offset: f32 = switch (eff_align) {
                .left => if (self.direction == .ltr) 0 else base_empty,
                .justify => 0,
                .space_around => elem_gap,
                .center => base_empty * 0.5,
                .right => if (self.direction == .ltr) base_empty else 0,
            };

            for (line.items) |it| {
                const draw_h = if (it.size.height < geom.epsilon) line.height else it.size.height;
                const y_off: f32 = switch (cfg.baseline_alignment) {
                    .top => 0,
                    .middle => (line.height - draw_h) * 0.5,
                    .bottom => line.height - draw_h,
                };
                const x_pos = if (self.direction == .ltr) left_offset else available.width - it.size.width - left_offset;
                self.sink.translate(x_pos, top_offset + y_off);
                self.draw(it.child, Size.init(it.size.width, draw_h));
                self.sink.translate(-x_pos, -(top_offset + y_off));
                left_offset += it.size.width + elem_gap;
            }

            top_offset += line.height + cfg.vertical_spacing;
            rendered_count += @intCast(n);
        }

        self.state.setU32(id, self.state.getU32(id) + rendered_count);
    }

    // -------------------------------------------------------------------------
    // MultiColumn (Newspaper Columns + Binary-Search Height Balancing)
    // -------------------------------------------------------------------------

    fn columnAvailSpace(cfg: anytype, available: Size) Size {
        const count_f: f32 = @floatFromInt(@max(1, cfg.column_count));
        const total_spacing = cfg.spacing * (count_f - 1.0);
        const col_w = (available.width - total_spacing) / count_f;
        return Size.init(col_w, available.height);
    }

    fn simulateMultiColumn(self: *RenderContext, cfg: anytype, available: Size) struct { first: SpacePlan, last: SpacePlan, max_h: f32 } {
        const cp = self.state.checkpoint(self.scratchAlloc()) catch {
            self.oom = true;
            return .{ .first = .empty(), .last = .empty(), .max_h = 0 };
        };
        defer self.state.restore(cp);

        const prev_sink = self.sink;
        const prev_sim = self.is_simulating;
        self.sink = sink_mod.NullSink.sink();
        self.is_simulating = true;
        defer {
            self.sink = prev_sink;
            self.is_simulating = prev_sim;
        }

        const col_space = columnAvailSpace(cfg, available);
        if (col_space.width < -geom.epsilon) {
            return .{ .first = .wrap("MultiColumn column width is negative."), .last = .wrap(""), .max_h = 0 };
        }

        var first: SpacePlan = .empty();
        var last: SpacePlan = .empty();
        var max_h: f32 = 0;

        const count = @max(1, cfg.column_count);
        for (0..count) |i| {
            const m = self.measure(cfg.content, col_space);
            if (i == 0) first = m;
            last = m;
            if (m.kind == .wrap or m.kind == .empty) break;
            max_h = @max(max_h, m.size.height);
            self.draw(cfg.content, Size.init(col_space.width, m.size.height));
            if (m.kind == .full_render) break;
        }

        return .{ .first = first, .last = last, .max_h = max_h };
    }

    fn measureMultiColumn(self: *RenderContext, cfg: anytype, available: Size) SpacePlan {
        if (cfg.content == null_node) return .empty();
        const sim = self.simulateMultiColumn(cfg, available);
        if (sim.first.kind == .empty or sim.first.kind == .wrap) return sim.first;

        if (sim.last.kind == .partial_render or sim.last.kind == .wrap) {
            return .partial(Size.init(available.width, sim.max_h));
        }
        if (!cfg.balance_height) {
            return .full(Size.init(available.width, sim.max_h));
        }

        // Binary search minimal balanced height across columns (8 iterations)
        var min_h: f32 = 0;
        var max_h: f32 = available.height;
        for (0..8) |_| {
            const mid = (min_h + max_h) * 0.5;
            const probe = self.simulateMultiColumn(cfg, Size.init(available.width, mid));
            if (probe.first.kind != .wrap and (probe.last.kind == .empty or probe.last.kind == .full_render)) {
                max_h = mid;
            } else {
                min_h = mid;
            }
        }
        return .full(Size.init(available.width, max_h));
    }

    fn drawMultiColumn(self: *RenderContext, cfg: anytype, available: Size) void {
        if (cfg.content == null_node) return;
        const effective_avail = if (cfg.balance_height) blk: {
            const m = self.measureMultiColumn(cfg, available);
            if (m.kind == .wrap or m.kind == .empty) return;
            break :blk Size.init(available.width, @min(available.height, m.size.height));
        } else available;

        const col_space = columnAvailSpace(cfg, effective_avail);
        const spacer_space = Size.init(cfg.spacing, effective_avail.height);
        const count = @max(1, cfg.column_count);
        var x_off: f32 = 0;

        for (0..count) |i| {
            const m = self.measure(cfg.content, col_space);
            if (m.kind == .wrap or m.kind == .empty) break;

            const draw_x = if (self.direction == .ltr) x_off else available.width - x_off - col_space.width;
            self.sink.translate(draw_x, 0);
            self.draw(cfg.content, Size.init(col_space.width, m.size.height));
            self.sink.translate(-draw_x, 0);
            x_off += col_space.width;

            if (m.kind == .full_render) break;

            if (i + 1 < count) {
                if (cfg.spacer != null_node and cfg.spacing > geom.epsilon) {
                    const prev_rep = self.in_repeating_context;
                    self.in_repeating_context = true;
                    defer self.in_repeating_context = prev_rep;
                    const sm = self.measure(cfg.spacer, spacer_space);
                    if (sm.kind != .wrap) {
                        const sx = if (self.direction == .ltr) x_off else available.width - x_off - cfg.spacing;
                        self.sink.translate(sx, 0);
                        self.draw(cfg.spacer, spacer_space);
                        self.sink.translate(-sx, 0);
                        self.state.resetSubtree(self.tree, cfg.spacer, false);
                    }
                }
                x_off += cfg.spacing;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Table Section (ColSpan/RowSpan, Auto-Placement & Multi-Page Row Pagination)
    // -------------------------------------------------------------------------

    const TableCellCmd = struct {
        cell_index: u32,
        cell: tbl.TableCell,
        plan: SpacePlan,
        size: Size,
        offset: Point,
    };

    const TablePlanResult = struct {
        cmds: []TableCellCmd,
        total_width: f32,
        starting_rows_count: u32,
        current_row: u32,
        invalid: bool = false,
    };

    fn planTableSection(self: *RenderContext, id: NodeId, cfg: tbl.TableSectionConfig, available: Size) TablePlanResult {
        const cols = self.tree.getTableColumns(cfg);
        const raw_cells = self.tree.getTableCells(cfg);
        const current_row = self.state.getU32(id) + 1; // stored 0-based so zero-init => row 1

        if (cols.len == 0 or raw_cells.len == 0) {
            return .{ .cmds = &.{}, .total_width = 0, .starting_rows_count = 0, .current_row = current_row };
        }

        if (!self.is_simulating) {
            if (self.last_table_plan) |lp| {
                if (lp.id == id and lp.current_row == current_row and
                    geom.approxEq(lp.avail.width, available.width) and
                    geom.approxEq(lp.avail.height, available.height))
                {
                    return lp.res;
                }
            }
        }

        const planned: PlannedTableEntry = blk: {
            if (id < self.planned_tables.len) {
                if (self.planned_tables[id]) |cached| break :blk cached;
            }
            const p = tbl.planAndValidate(self.scratchAlloc(), @intCast(cols.len), raw_cells) catch {
                return .{ .cmds = &.{}, .total_width = 0, .starting_rows_count = 0, .current_row = current_row, .invalid = true };
            };
            break :blk .{ .resolved = p.resolved, .plan = p.plan };
        };
        if (current_row > planned.plan.starting_rows_count) {
            return .{ .cmds = &.{}, .total_width = 0, .starting_rows_count = planned.plan.starting_rows_count, .current_row = current_row };
        }

        const col_layout = tbl.computeColumnOffsets(self.scratchAlloc(), cols, available.width) catch {
            self.oom = true;
            return .{ .cmds = &.{}, .total_width = 0, .starting_rows_count = 0, .current_row = current_row };
        };

        const max_row = planned.plan.total_rows_count;
        const row_bottom = self.scratchAlloc().alloc(f32, max_row + 2) catch {
            self.oom = true;
            return .{ .cmds = &.{}, .total_width = col_layout.total_width, .starting_rows_count = planned.plan.starting_rows_count, .current_row = current_row };
        };
        @memset(row_bottom, 0);

        var cmds: std.ArrayList(TableCellCmd) = .empty;
        var scan_row: u32 = current_row;
        var max_rendering_row: u32 = max_row;
        var max_seen_end_row: u32 = current_row;

        const start_sorted_idx = tbl.lowerBoundByEndRow(planned.resolved, planned.plan.sorted_indices, current_row);
        for (planned.plan.sorted_indices[start_sorted_idx..]) |cell_idx| {
            const cell = planned.resolved[cell_idx];
            const cell_end_row = cell.row + cell.row_span - 1;
            if (cell_end_row < current_row) continue;

            if (cell.row > scan_row) {
                row_bottom[scan_row] = @max(row_bottom[scan_row], row_bottom[scan_row - 1]);
                if (row_bottom[scan_row - 1] > available.height + geom.epsilon) break;
                var r = scan_row + 1;
                while (r <= cell.row) : (r += 1) {
                    row_bottom[r] = @max(row_bottom[r - 1], row_bottom[r]);
                }
                scan_row = cell.row;
            }

            if (cell.row > max_rendering_row + planned.plan.max_row_span) break;

            const top_row_idx = if (cell.row >= current_row) cell.row - 1 else current_row - 1;
            const top_off = row_bottom[top_row_idx];
            const cell_w = col_layout.offsets[cell.col + cell.col_span - 1] - col_layout.offsets[cell.col - 1];
            const cell_avail_h = available.height - top_off;

            const m: SpacePlan = if (self.state.getAuxBool(id, cell_idx))
                .empty()
            else
                self.measure(cell.child, Size.init(@max(0, cell_w), cell_avail_h));

            if (m.kind == .partial_render) {
                max_rendering_row = @min(max_rendering_row, cell_end_row);
            }
            if (m.kind == .wrap) {
                max_rendering_row = @min(max_rendering_row, if (cell.row > 0) cell.row - 1 else 0);
                continue;
            }

            row_bottom[cell_end_row] = @max(row_bottom[cell_end_row], top_off + m.size.height);
            max_seen_end_row = @max(max_seen_end_row, cell_end_row);

            cmds.append(self.scratchAlloc(), .{
                .cell_index = cell_idx,
                .cell = cell,
                .plan = m,
                .size = Size.init(@max(0, cell_w), m.size.height),
                .offset = Point.init(col_layout.offsets[cell.col - 1], top_off),
            }) catch {
                self.oom = true;
                return .{ .cmds = &.{}, .total_width = col_layout.total_width, .starting_rows_count = planned.plan.starting_rows_count, .current_row = current_row };
            };
        }

        if (cmds.items.len == 0) {
            return .{ .cmds = &.{}, .total_width = col_layout.total_width, .starting_rows_count = planned.plan.starting_rows_count, .current_row = current_row };
        }

        // Propagate monotonic row bottom offsets only over rows touched on this page
        const prop_limit = @min(max_row, max_seen_end_row);
        var r: u32 = current_row;
        while (r <= prop_limit) : (r += 1) {
            row_bottom[r] = @max(row_bottom[r - 1], row_bottom[r]);
        }

        // Filter out cells belonging to rejected rows and equalize row-span heights
        var write: usize = 0;
        var table_h: f32 = 0;
        for (cmds.items) |cmd| {
            if (cmd.cell.row > max_rendering_row) continue;
            var adj = cmd;
            const top_row_idx = if (cmd.cell.row >= current_row) cmd.cell.row - 1 else current_row - 1;
            const last_row = @min(cmd.cell.row + cmd.cell.row_span - 1, max_rendering_row);
            adj.offset.y = row_bottom[top_row_idx];
            adj.size.height = @max(0, row_bottom[last_row] - adj.offset.y);
            table_h = @max(table_h, adj.offset.y + adj.size.height);
            cmds.items[write] = adj;
            write += 1;
        }
        cmds.items.len = write;

        if (cfg.extend_last_cells_to_bottom and cmds.items.len > 0) {
            const cols_count: u32 = @intCast(cols.len);
            var col_i: u32 = 1;
            while (col_i <= cols_count) : (col_i += 1) {
                var best_idx: ?usize = null;
                var best_end: u32 = 0;
                for (cmds.items, 0..) |cmd, idx| {
                    if (cmd.cell.col <= col_i and col_i < cmd.cell.col + cmd.cell.col_span) {
                        const end_r = cmd.cell.row + cmd.cell.row_span;
                        if (end_r >= best_end) {
                            best_end = end_r;
                            best_idx = idx;
                        }
                    }
                }
                if (best_idx) |bi| {
                    cmds.items[bi].size.height = @max(cmds.items[bi].size.height, table_h - cmds.items[bi].offset.y);
                }
            }
        }

        const out_res: TablePlanResult = .{
            .cmds = cmds.items,
            .total_width = col_layout.total_width,
            .starting_rows_count = planned.plan.starting_rows_count,
            .current_row = current_row,
        };
        if (!self.is_simulating) {
            self.last_table_plan = .{
                .id = id,
                .current_row = current_row,
                .avail = available,
                .res = out_res,
            };
        }
        return out_res;
    }

    fn computeNextTableRow(self: *RenderContext, id: NodeId, res: TablePlanResult) u32 {
        if (res.cmds.len == 0 or res.current_row > res.starting_rows_count) return res.current_row;

        var max_cmd_row: u32 = res.current_row;
        for (res.cmds) |cmd| {
            if (cmd.cell.row >= res.current_row and cmd.cell.row > max_cmd_row) {
                max_cmd_row = cmd.cell.row;
            }
        }
        const span_rows: usize = max_cmd_row - res.current_row + 1;
        // 0 = no cell seen, 1 = all cells seen so far done, 2 = at least one cell not done
        const status = self.scratchAlloc().alloc(u8, span_rows) catch {
            // Fallback without allocation
            var next_row = res.current_row;
            var candidate = res.current_row;
            while (candidate <= max_cmd_row) : (candidate += 1) {
                var found_any = false;
                var all_done = true;
                for (res.cmds) |cmd| {
                    if (cmd.cell.row == candidate) {
                        found_any = true;
                        if (!self.state.getAuxBool(id, cmd.cell_index) and !cmd.plan.isDone()) {
                            all_done = false;
                            break;
                        }
                    }
                }
                if (!found_any or !all_done) break;
                next_row = candidate + 1;
            }
            return next_row;
        };
        @memset(status, 0);

        for (res.cmds) |cmd| {
            if (cmd.cell.row < res.current_row) continue;
            const rel = cmd.cell.row - res.current_row;
            const cell_done = self.state.getAuxBool(id, cmd.cell_index) or cmd.plan.isDone();
            if (!cell_done) {
                status[rel] = 2;
            } else if (status[rel] == 0) {
                status[rel] = 1;
            }
        }

        var next_row = res.current_row;
        for (status) |st| {
            if (st != 1) break;
            next_row += 1;
        }
        return next_row;
    }

    fn measureTableSection(self: *RenderContext, id: NodeId, cfg: tbl.TableSectionConfig, available: Size) SpacePlan {
        const res = self.planTableSection(id, cfg, available);
        if (res.invalid) return .wrap("Invalid table configuration.");
        if (cfg.cells_len == 0 or res.current_row > res.starting_rows_count) return .empty();
        if (res.cmds.len == 0) return .wrap("Insufficient vertical space to render even a single table row.");

        var max_h: f32 = 0;
        for (res.cmds) |cmd| {
            max_h = @max(max_h, cmd.offset.y + cmd.size.height);
        }
        if (res.total_width > available.width + geom.epsilon) {
            return .wrap("Table width exceeds available horizontal space.");
        }

        const sz = Size.init(res.total_width, max_h);
        const next_row = self.computeNextTableRow(id, res);
        return if (next_row > res.starting_rows_count) .full(sz) else .partial(sz);
    }

    fn drawTableSection(self: *RenderContext, id: NodeId, cfg: tbl.TableSectionConfig, available: Size) void {
        const res = self.planTableSection(id, cfg, available);
        if (res.invalid or res.cmds.len == 0) return;

        // Sort commands by z_index (insertion order) for deterministic border/background layering
        const ZSort = struct {
            pub fn lessThan(_: void, a: TableCellCmd, b: TableCellCmd) bool {
                return a.cell.z_index < b.cell.z_index;
            }
        };
        std.mem.sort(TableCellCmd, res.cmds, {}, ZSort.lessThan);

        for (res.cmds) |cmd| {
            if (cmd.plan.kind == .wrap) continue;
            const already_done = self.state.getAuxBool(id, cmd.cell_index);
            if (!already_done) {
                const x = if (self.direction == .ltr) cmd.offset.x else available.width - cmd.offset.x - cmd.size.width;
                self.sink.translate(x, cmd.offset.y);
                self.draw(cmd.cell.child, cmd.size);
                self.sink.translate(-x, -cmd.offset.y);

                if (cmd.plan.isDone()) {
                    self.state.setAuxBool(id, cmd.cell_index, true);
                }
            }
        }

        const next_row = self.computeNextTableRow(id, res);
        self.state.setU32(id, next_row - 1);
        self.last_table_plan = null;
    }

    // -------------------------------------------------------------------------
    // Box Model, Constraints, Alignment & Transforms
    // -------------------------------------------------------------------------

    fn measureVisualWrapper(self: *RenderContext, child: NodeId, available: Size) SpacePlan {
        if (child == null_node) return .full(.zero);
        return self.measure(child, available);
    }

    fn measurePadding(self: *RenderContext, child: NodeId, insets: geom.EdgeInsets, available: Size) SpacePlan {
        const inner = Size.init(
            available.width - insets.totalHorizontal(),
            available.height - insets.totalVertical(),
        );
        if (inner.isNegative()) return .wrap("Padding exceeds available space.");

        const m = if (child == null_node) SpacePlan.full(.zero) else self.measure(child, inner.clampPositive());
        if (m.kind == .empty or m.kind == .wrap) return m;

        const out = Size.init(
            m.size.width + insets.totalHorizontal(),
            m.size.height + insets.totalVertical(),
        );
        return if (m.kind == .partial_render) .partial(out) else .full(out);
    }

    fn drawPadding(self: *RenderContext, child: NodeId, insets: geom.EdgeInsets, available: Size) void {
        const inner = Size.init(
            @max(0, available.width - insets.totalHorizontal()),
            @max(0, available.height - insets.totalVertical()),
        );
        self.sink.translate(insets.left, insets.top);
        self.draw(child, inner);
        self.sink.translate(-insets.left, -insets.top);
    }

    fn measureBox(self: *RenderContext, child: NodeId, cfg: tree_mod.BoxConfig, available: Size) SpacePlan {
        return self.measurePadding(child, cfg.padding, available);
    }

    fn drawBox(self: *RenderContext, child: NodeId, cfg: tree_mod.BoxConfig, available: Size) void {
        const rect = Rect.fromXYWH(0, 0, available.width, available.height);
        const radius = if (cfg.radius > 0) cfg.radius else if (cfg.border) |b| b.radius else 0;

        if (cfg.shadow) |sh| {
            self.sink.drawShadow(rect, radius, sh);
        }
        if (cfg.gradient) |g| {
            self.sink.drawGradientRect(rect, g, radius);
        } else if (cfg.background) |bg| {
            if (!bg.isTransparent()) self.sink.drawRect(rect, bg, radius);
        }

        if (cfg.clip) {
            self.sink.save();
            self.sink.clipRect(rect, radius);
        }

        self.drawPadding(child, cfg.padding, available);

        if (cfg.clip) {
            self.sink.restore();
        }

        if (cfg.border) |b| {
            var b_eff = b;
            if (b_eff.radius == 0 and radius > 0) b_eff.radius = radius;
            self.sink.drawBorder(rect, b_eff);
        }
    }

    fn measureConstrained(self: *RenderContext, child: NodeId, cfg: anytype, available: Size) SpacePlan {
        if (cfg.min_width) |min_w| {
            if (min_w > available.width + geom.epsilon) return .wrap("Available width is less than MinWidth.");
        }
        if (cfg.min_height) |min_h| {
            if (min_h > available.height + geom.epsilon) return .wrap("Available height is less than MinHeight.");
        }

        const child_avail = Size.init(
            if (cfg.max_width) |max_w| @min(max_w, available.width) else available.width,
            if (cfg.max_height) |max_h| @min(max_h, available.height) else available.height,
        );

        const m = if (child == null_node) blk: {
            if (cfg.enforce_when_empty or cfg.min_width != null or cfg.min_height != null) {
                break :blk SpacePlan.full(.zero);
            }
            break :blk SpacePlan.empty();
        } else self.measure(child, child_avail);

        if (m.kind == .wrap) return m;
        if (m.kind == .empty and !cfg.enforce_when_empty) return .empty();

        const actual = Size.init(
            if (cfg.min_width) |min_w| @max(min_w, m.size.width) else m.size.width,
            if (cfg.min_height) |min_h| @max(min_h, m.size.height) else m.size.height,
        );

        return switch (m.kind) {
            .partial_render => .partial(actual),
            .full_render, .empty => .full(actual),
            .wrap => unreachable,
        };
    }

    fn drawConstrained(self: *RenderContext, child: NodeId, cfg: anytype, available: Size) void {
        const target = Size.init(
            if (cfg.max_width) |max_w| @min(max_w, available.width) else available.width,
            if (cfg.max_height) |max_h| @min(max_h, available.height) else available.height,
        );
        const x_off: f32 = if (self.direction == .rtl) available.width - target.width else 0;
        self.sink.translate(x_off, 0);
        self.draw(child, target);
        self.sink.translate(-x_off, 0);
    }

    fn drawAlignment(
        self: *RenderContext,
        child: NodeId,
        h_align: ?style.HorizontalAlign,
        v_align: ?style.VerticalAlign,
        available: Size,
    ) void {
        const prev_ta = self.inherited_text_align;
        if (h_align) |ha| self.inherited_text_align = mapHorizToTextAlign(ha);
        defer self.inherited_text_align = prev_ta;

        const m = self.measure(child, available);
        if (m.kind == .empty or m.kind == .wrap) return;

        const child_sz = Size.init(
            if (h_align != null) m.size.width else available.width,
            if (v_align != null) m.size.height else available.height,
        );

        const dx: f32 = if (h_align) |ha| blk: {
            const diff = available.width - child_sz.width;
            break :blk switch (ha) {
                .left => 0,
                .center => diff * 0.5,
                .right => diff,
                .start => if (self.direction == .ltr) 0 else diff,
                .end => if (self.direction == .ltr) diff else 0,
            };
        } else 0;

        const dy: f32 = if (v_align) |va| blk: {
            const diff = available.height - child_sz.height;
            break :blk switch (va) {
                .top => 0,
                .middle => diff * 0.5,
                .bottom => diff,
            };
        } else 0;

        self.sink.translate(dx, dy);
        self.draw(child, child_sz);
        self.sink.translate(-dx, -dy);
    }

    fn measureExtend(self: *RenderContext, child: NodeId, ext_h: bool, ext_v: bool, available: Size) SpacePlan {
        const m = if (child == null_node) SpacePlan.full(.zero) else self.measure(child, available);
        if (m.kind == .empty or m.kind == .wrap) return m;
        const target = Size.init(
            if (ext_h) available.width else m.size.width,
            if (ext_v) available.height else m.size.height,
        );
        return if (m.kind == .partial_render) .partial(target) else .full(target);
    }

    fn drawShrink(self: *RenderContext, child: NodeId, sh_h: bool, sh_v: bool, available: Size) void {
        const m = self.measure(child, available);
        if (m.kind == .empty or m.kind == .wrap) return;
        const target = Size.init(
            if (sh_h) m.size.width else available.width,
            if (sh_v) m.size.height else available.height,
        );
        const dx: f32 = if (self.direction == .rtl) available.width - target.width else 0;
        self.sink.translate(dx, 0);
        self.draw(child, target);
        self.sink.translate(-dx, 0);
    }

    fn aspectRatioTarget(ratio: f32, option: style.AspectRatioOption, available: Size) Size {
        const fit_w = Size.init(available.width, available.width / ratio);
        const fit_h = Size.init(available.height * ratio, available.height);
        return switch (option) {
            .fit_width => fit_w,
            .fit_height => fit_h,
            .fit_area => if (fit_w.height <= available.height + geom.epsilon) fit_w else fit_h,
        };
    }

    fn measureAspectRatio(self: *RenderContext, child: NodeId, ratio: f32, option: style.AspectRatioOption, available: Size) SpacePlan {
        if (ratio <= 0) return .wrap("AspectRatio must be positive.");
        const target = aspectRatioTarget(ratio, option, available);
        if (target.width > available.width + geom.epsilon or target.height > available.height + geom.epsilon) {
            return .wrap("AspectRatio target exceeds available space.");
        }
        const m = if (child == null_node) SpacePlan.full(target) else self.measure(child, target);
        if (m.kind == .wrap or m.kind == .empty) return m;
        return if (m.kind == .partial_render) .partial(target) else .full(target);
    }

    fn drawAspectRatio(self: *RenderContext, child: NodeId, ratio: f32, option: style.AspectRatioOption, available: Size) void {
        if (ratio <= 0) return;
        const target = aspectRatioTarget(ratio, option, available);
        self.draw(child, target);
    }

    fn measureTransform(self: *RenderContext, child: NodeId, t: anytype, available: Size) SpacePlan {
        return switch (t) {
            .translate, .rotate => self.measure(child, available),
            .scale => |s| blk: {
                if (s.x <= 0 or s.y <= 0) break :blk .wrap("Scale factor must be positive.");
                const scaled_avail = Size.init(available.width / s.x, available.height / s.y);
                const m = self.measure(child, scaled_avail);
                if (m.kind == .wrap or m.kind == .empty) break :blk m;
                const sz = Size.init(m.size.width * s.x, m.size.height * s.y);
                break :blk if (m.kind == .partial_render) .partial(sz) else .full(sz);
            },
            .scale_to_fit => blk: {
                const scale_val = self.findScaleToFit(child, available);
                const scaled_avail = Size.init(available.width / scale_val, available.height / scale_val);
                const m = self.measure(child, scaled_avail);
                if (m.kind == .wrap or m.kind == .empty) break :blk m;
                break :blk .full(Size.init(m.size.width * scale_val, m.size.height * scale_val));
            },
            .rotate_right_90, .rotate_left_90 => blk: {
                const swapped = Size.init(available.height, available.width);
                const m = self.measure(child, swapped);
                if (m.kind == .wrap or m.kind == .empty) break :blk m;
                const out = Size.init(m.size.height, m.size.width);
                break :blk if (m.kind == .partial_render) .partial(out) else .full(out);
            },
        };
    }

    fn drawTransform(self: *RenderContext, child: NodeId, t: anytype, available: Size) void {
        switch (t) {
            .translate => |p| {
                self.sink.translate(p.x, p.y);
                self.draw(child, available);
                self.sink.translate(-p.x, -p.y);
            },
            .rotate => |deg| {
                self.sink.save();
                self.sink.rotate(deg);
                self.draw(child, available);
                self.sink.restore();
            },
            .scale => |s| {
                if (s.x <= 0 or s.y <= 0) return;
                self.sink.save();
                self.sink.scale(s.x, s.y);
                self.draw(child, Size.init(available.width / s.x, available.height / s.y));
                self.sink.restore();
            },
            .scale_to_fit => {
                const s = self.findScaleToFit(child, available);
                self.sink.save();
                self.sink.scale(s, s);
                self.draw(child, Size.init(available.width / s, available.height / s));
                self.sink.restore();
            },
            .rotate_right_90 => {
                self.sink.save();
                self.sink.translate(available.width, 0);
                self.sink.rotate(90);
                self.draw(child, Size.init(available.height, available.width));
                self.sink.restore();
            },
            .rotate_left_90 => {
                self.sink.save();
                self.sink.translate(0, available.height);
                self.sink.rotate(-90);
                self.draw(child, Size.init(available.height, available.width));
                self.sink.restore();
            },
        }
    }

    fn findScaleToFit(self: *RenderContext, child: NodeId, available: Size) f32 {
        const full_m = self.measure(child, available);
        if (full_m.kind == .full_render or full_m.kind == .empty) return 1.0;

        var low: f32 = 0.01;
        var high: f32 = 1.0;
        for (0..10) |_| {
            const mid = (low + high) * 0.5;
            const m = self.measure(child, Size.init(available.width / mid, available.height / mid));
            if (m.kind == .full_render or m.kind == .empty) {
                low = mid;
            } else {
                high = mid;
            }
        }
        return low;
    }

    fn measureLine(_: *RenderContext, horizontal: bool, thickness: f32, available: Size) SpacePlan {
        if (horizontal) {
            if (thickness > available.height + geom.epsilon) return .wrap("Horizontal line exceeds available height.");
            return .full(Size.init(0, thickness));
        } else {
            if (thickness > available.width + geom.epsilon) return .wrap("Vertical line exceeds available width.");
            return .full(Size.init(thickness, 0));
        }
    }

    fn drawLine(self: *RenderContext, horizontal: bool, thickness: f32, color: style.Color, dash: ?style.DashPattern, available: Size) void {
        if (horizontal) {
            const y = thickness * 0.5;
            self.sink.drawLine(0, y, available.width, y, thickness, color, dash);
        } else {
            const x = thickness * 0.5;
            self.sink.drawLine(x, 0, x, available.height, thickness, color, dash);
        }
    }

    // -------------------------------------------------------------------------
    // TextBlock (Rich Text & Multi-Page Line Splitting)
    // -------------------------------------------------------------------------

    fn mapHorizToTextAlign(ha: style.HorizontalAlign) style.TextAlign {
        return switch (ha) {
            .left => .left,
            .center => .center,
            .right => .right,
            .start => .start,
            .end => .end,
        };
    }

    fn shapeTextBlock(self: *RenderContext, id: NodeId, cfg: te.TextBlockConfig, max_width: f32) ?te.ShapedLayout {
        const text_eng = self.text_engine orelse return null;
        const spans = self.tree.getTextSpans(cfg);
        if (spans.len == 0) return .{ .contains_only_whitespace = true };

        // Measure inline embedded elements (assumed single-line, unconstrained)
        var inline_sizes: std.ArrayList(Size) = .empty;
        for (spans) |span| {
            if (span == .inline_element) {
                const m = self.measure(span.inline_element.child_node, Size.max);
                inline_sizes.append(self.scratchAlloc(), m.size) catch {
                    self.oom = true;
                    return null;
                };
            }
        }

        const effective_align = cfg.alignment orelse self.inherited_text_align orelse .start;
        const shaped = text_eng.layoutParagraph(.{
            .node_id = id,
            .is_ephemeral = self.is_ephemeral_subtree,
            .config = cfg,
            .spans = spans,
            .inherited_style = self.text_style,
            .effective_alignment = effective_align,
            .direction = self.direction,
            .page_ctx = self.page_ctx,
            .inline_sizes = inline_sizes.items,
            .max_width = max_width,
            .scratch = self.scratchAlloc(),
        }) catch {
            self.oom = true;
            return null;
        };
        if (self.check_missing_glyphs and shaped.unresolved_glyphs > 0) {
            self.missing_glyphs = true;
        }
        return shaped;
    }

    fn measureTextBlock(self: *RenderContext, id: NodeId, cfg: te.TextBlockConfig, available: Size) SpacePlan {
        if (cfg.spans_len == 0) return .empty();
        if (self.state.getU32At(id, 2) != 0) return .empty(); // is_rendered

        const shaped = self.shapeTextBlock(id, cfg, available.width) orelse return .empty();
        if (shaped.lines.len == 0) return .full(.zero);

        if (shaped.contains_only_whitespace) {
            const h = shaped.lines[0].height;
            return if (h <= available.height + geom.epsilon)
                .full(Size.init(0, h))
            else
                .wrap("Available vertical space is insufficient for whitespace text line.");
        }

        const cur_line = self.state.getU32At(id, 0);
        if (cur_line >= shaped.lines.len) return .empty();

        var total_h: f32 = 0;
        var lines_fit: u32 = 0;
        var i: usize = cur_line;
        while (i < shaped.lines.len) : (i += 1) {
            const next_h = total_h + shaped.lines[i].height;
            if (next_h > available.height + geom.epsilon) break;
            total_h = next_h;
            lines_fit += 1;
        }

        if (lines_fit == 0) {
            return .wrap("Available vertical space is insufficient to render even a single line of text.");
        }

        const req_sz = Size.init(
            @min(shaped.max_line_width, available.width),
            @min(total_h, available.height),
        );

        return if (cur_line + lines_fit < shaped.lines.len) .partial(req_sz) else .full(req_sz);
    }

    fn drawTextBlock(self: *RenderContext, id: NodeId, cfg: te.TextBlockConfig, available: Size) void {
        if (cfg.spans_len == 0) return;
        if (self.state.getU32At(id, 2) != 0) return;

        const shaped = self.shapeTextBlock(id, cfg, available.width) orelse return;
        if (shaped.contains_only_whitespace or shaped.lines.len == 0) {
            self.state.setU32At(id, 2, 1);
            return;
        }

        const cur_line = self.state.getU32At(id, 0);
        const cur_top: f32 = @bitCast(self.state.getU32At(id, 1));
        if (cur_line >= shaped.lines.len) {
            self.state.setU32At(id, 2, 1);
            return;
        }

        var taken_h: f32 = 0;
        var lines_to_draw: u32 = 0;
        var i: usize = cur_line;
        while (i < shaped.lines.len) : (i += 1) {
            const next_h = taken_h + shaped.lines[i].height;
            if (next_h > available.height + geom.epsilon) break;
            taken_h = next_h;
            lines_to_draw += 1;
        }
        if (lines_to_draw == 0) return;

        const spans_multi_page = lines_to_draw < shaped.lines.len;
        if (spans_multi_page) {
            self.sink.save();
            self.sink.clipRect(Rect.fromXYWH(0, 0, available.width, taken_h), 0);
            self.sink.translate(0, -cur_top);
        }

        if (shaped.handle) |h| {
            self.sink.drawParagraph(h);
        }

        // Draw visible inline elements and annotate inline hyperlinks / section links
        const spans = self.tree.getTextSpans(cfg);
        var inline_idx: usize = 0;
        for (spans, 0..) |span, s_idx| {
            switch (span) {
                .inline_element => |ie| {
                    if (inline_idx < shaped.placeholder_rects.len) {
                        const pr = shaped.placeholder_rects[inline_idx];
                        if (pr.bottom >= cur_top - geom.epsilon and pr.top <= cur_top + taken_h + geom.epsilon) {
                            self.sink.translate(pr.left, pr.top);
                            self.draw(ie.child_node, Size.init(pr.width(), pr.height()));
                            self.sink.translate(-pr.left, -pr.top);
                        }
                    }
                    inline_idx += 1;
                },
                .hyperlink => |hl| {
                    if (shaped.handle) |h| {
                        if (s_idx < shaped.span_ranges.len) {
                            const rng = shaped.span_ranges[s_idx];
                            if (self.text_engine) |eng| {
                                const rects = eng.getRangeRects(h, rng.start, rng.end, self.scratchAlloc()) catch &.{};
                                for (rects) |r| {
                                    if (r.bottom >= cur_top - geom.epsilon and r.top <= cur_top + taken_h + geom.epsilon) {
                                        self.sink.annotateUrl(r, hl.url);
                                    }
                                }
                            }
                        }
                    }
                },
                .section_link => |sl| {
                    if (shaped.handle) |h| {
                        if (s_idx < shaped.span_ranges.len) {
                            const rng = shaped.span_ranges[s_idx];
                            if (self.text_engine) |eng| {
                                const rects = eng.getRangeRects(h, rng.start, rng.end, self.scratchAlloc()) catch &.{};
                                for (rects) |r| {
                                    if (r.bottom >= cur_top - geom.epsilon and r.top <= cur_top + taken_h + geom.epsilon) {
                                        self.sink.annotateLinkToDest(r, sl.section_name);
                                    }
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }

        if (spans_multi_page) {
            self.sink.restore();
        }

        const next_line = cur_line + lines_to_draw;
        const next_top = cur_top + taken_h;
        self.state.setU32At(id, 0, next_line);
        self.state.setU32At(id, 1, @bitCast(next_top));
        if (next_line >= shaped.lines.len) {
            self.state.setU32At(id, 2, 1);
            // Evict finished non-repeating paragraph to keep peak memory O(1 page)
            if (!self.in_repeating_context and !self.is_ephemeral_subtree and !self.is_simulating and
                (!self.page_ctx.is_initial_phase or self.in_snapshot_record))
            {
                if (self.text_engine) |eng| eng.evict(id);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Media (Image / SVG) & Dynamic Components
    // -------------------------------------------------------------------------

    fn computeMediaSize(intrinsic_w: f32, intrinsic_h: f32, scaling: style.ImageScaling, available: Size) Size {
        if (intrinsic_w <= geom.epsilon or intrinsic_h <= geom.epsilon) return available;
        const ratio = intrinsic_w / intrinsic_h;
        return switch (scaling) {
            .fit_unproportionally => available,
            .fit_width => Size.init(available.width, available.width / ratio),
            .fit_height => Size.init(available.height * ratio, available.height),
            .fit_area => blk: {
                const by_w_h = available.width / ratio;
                if (by_w_h <= available.height + geom.epsilon) {
                    break :blk Size.init(available.width, by_w_h);
                }
                break :blk Size.init(available.height * ratio, available.height);
            },
        };
    }

    fn measureMedia(self: *RenderContext, id: NodeId, intrinsic_w: f32, intrinsic_h: f32, scaling: style.ImageScaling, available: Size) SpacePlan {
        if (self.state.getBool(id)) return .empty();
        const sz = computeMediaSize(intrinsic_w, intrinsic_h, scaling, available);
        if (sz.width > available.width + geom.epsilon or sz.height > available.height + geom.epsilon) {
            return .wrap("Media element exceeds available space.");
        }
        return .full(sz);
    }

    fn dynamicMeasureCallback(
        raw_ctx: *anyopaque,
        sub_tree: *const tree_mod.Tree,
        root_node: NodeId,
        available: Size,
    ) tree_mod.MeasureResult {
        const parent: *RenderContext = @ptrCast(@alignCast(raw_ctx));
        var sub_state = state_mod.StateStore.initForTree(parent.gpa, sub_tree) catch {
            parent.oom = true;
            return .{ .size = .zero, .fits_completely = false, .wraps = true };
        };
        defer sub_state.deinit(parent.gpa);

        var sub_ctx: RenderContext = .{
            .gpa = parent.gpa,
            .scratch = parent.scratch,
            .tree = sub_tree,
            .state = &sub_state,
            .page_ctx = parent.page_ctx,
            .sink = sink_mod.NullSink.sink(),
            .text_engine = parent.text_engine,
            .direction = parent.direction,
            .text_style = parent.text_style,
            .inherited_text_align = parent.inherited_text_align,
            .is_ephemeral_subtree = true,
            .is_simulating = true,
            .check_missing_glyphs = parent.check_missing_glyphs,
        };
        const m = sub_ctx.measure(root_node, available);
        if (sub_ctx.oom) parent.oom = true;
        if (sub_ctx.missing_glyphs) parent.missing_glyphs = true;
        return .{
            .size = m.size,
            .fits_completely = (m.kind == .full_render or m.kind == .empty),
            .wraps = (m.kind == .wrap),
        };
    }

    fn measureDynamic(self: *RenderContext, id: NodeId, cfg: tree_mod.DynamicConfig, available: Size) SpacePlan {
        if (self.state.getAuxBool(id, 0)) return .empty();

        // Speculative state copy in scratch so measure() stays pure/idempotent
        const live_state = self.state.getDynSlice(id, cfg.initial_state.len);
        const temp_state = self.scratchAlloc().dupe(u8, live_state) catch {
            self.oom = true;
            return .empty();
        };

        var sub_tree = tree_mod.Tree.init(self.gpa);
        defer sub_tree.deinit();
        const sub_root = sub_tree.addNode(.container);

        const res = cfg.compose_fn(temp_state, .{
            .page_number = self.page_ctx.current_page,
            .total_pages = self.page_ctx.totalPages(),
            .available_size = available,
            .direction = self.direction,
            .text_style = self.text_style,
            ._allocator = self.gpa,
            ._measure_ctx = @ptrCast(self),
            ._measure_fn = dynamicMeasureCallback,
        }, &sub_tree, sub_root);

        if (sub_tree.compose_error != null) {
            self.oom = true;
            return .wrap("Dynamic component compose error.");
        }

        var sub_state = state_mod.StateStore.initForTree(self.gpa, &sub_tree) catch {
            self.oom = true;
            return .empty();
        };
        defer sub_state.deinit(self.gpa);

        var sub_ctx: RenderContext = .{
            .gpa = self.gpa,
            .scratch = self.scratch,
            .tree = &sub_tree,
            .state = &sub_state,
            .page_ctx = self.page_ctx,
            .sink = sink_mod.NullSink.sink(),
            .text_engine = self.text_engine,
            .direction = self.direction,
            .text_style = self.text_style,
            .inherited_text_align = self.inherited_text_align,
            .is_ephemeral_subtree = true,
            .check_missing_glyphs = self.check_missing_glyphs,
        };
        const m = sub_ctx.measure(sub_root, available);
        if (sub_ctx.oom) self.oom = true;
        if (sub_ctx.missing_glyphs) self.missing_glyphs = true;
        if (m.kind == .wrap or m.kind == .partial_render) {
            return .wrap("Dynamic component emitted content that does not fit on a single page.");
        }
        return if (res.has_more_content) .partial(m.size) else .full(m.size);
    }

    fn drawDynamic(self: *RenderContext, id: NodeId, cfg: tree_mod.DynamicConfig, available: Size) void {
        if (self.state.getAuxBool(id, 0)) return;

        const live_state = self.state.getDynSlice(id, cfg.initial_state.len);
        var sub_tree = tree_mod.Tree.init(self.gpa);
        defer sub_tree.deinit();
        const sub_root = sub_tree.addNode(.container);

        const res = cfg.compose_fn(live_state, .{
            .page_number = self.page_ctx.current_page,
            .total_pages = self.page_ctx.totalPages(),
            .available_size = available,
            .direction = self.direction,
            .text_style = self.text_style,
            ._allocator = self.gpa,
            ._measure_ctx = @ptrCast(self),
            ._measure_fn = dynamicMeasureCallback,
        }, &sub_tree, sub_root);

        if (sub_tree.compose_error != null) {
            self.oom = true;
            return;
        }

        var sub_state = state_mod.StateStore.initForTree(self.gpa, &sub_tree) catch {
            self.oom = true;
            return;
        };
        defer sub_state.deinit(self.gpa);

        var sub_ctx: RenderContext = .{
            .gpa = self.gpa,
            .scratch = self.scratch,
            .tree = &sub_tree,
            .state = &sub_state,
            .page_ctx = self.page_ctx,
            .sink = self.sink,
            .text_engine = self.text_engine,
            .direction = self.direction,
            .text_style = self.text_style,
            .inherited_text_align = self.inherited_text_align,
            .current_pdf_node_id = self.current_pdf_node_id,
            .is_ephemeral_subtree = true,
            .check_missing_glyphs = self.check_missing_glyphs,
        };
        sub_ctx.draw(sub_root, available);
        if (sub_ctx.oom) self.oom = true;
        if (sub_ctx.missing_glyphs) self.missing_glyphs = true;

        if (!res.has_more_content) {
            self.state.setAuxBool(id, 0, true);
        }
    }
};

fn preplanTables(arena: std.mem.Allocator, tree: *const tree_mod.Tree) ![]?PlannedTableEntry {
    const out = try arena.alloc(?PlannedTableEntry, tree.nodes.items.len);
    @memset(out, null);
    for (tree.nodes.items, 0..) |node, idx| {
        if (node.payload == .table_section) {
            const ts = node.payload.table_section;
            const p = try tbl.planAndValidate(arena, ts.cols_len, tree.getTableCells(ts));
            out[idx] = .{ .resolved = p.resolved, .plan = p.plan };
        }
    }
    return out;
}

fn hasDynamicSlotHeight(tree: *const tree_mod.Tree, root: NodeId) bool {
    if (root == null_node) return false;
    const node = tree.get(root);
    switch (node.payload) {
        .show_if, .dynamic => return true,
        .decoration => |d| return hasDynamicSlotHeight(tree, d.before) or hasDynamicSlotHeight(tree, d.content) or hasDynamicSlotHeight(tree, d.after),
        .multi_column => |mc| return hasDynamicSlotHeight(tree, mc.content) or hasDynamicSlotHeight(tree, mc.spacer),
        .table_section => |ts| {
            for (tree.getTableCells(ts)) |cell| {
                if (hasDynamicSlotHeight(tree, cell.child)) return true;
            }
            return false;
        },
        .text_block => |tb| {
            for (tree.getTextSpans(tb)) |span| {
                if (span == .inline_element and hasDynamicSlotHeight(tree, span.inline_element.child_node)) return true;
            }
            return false;
        },
        else => {
            var ch = node.first_child;
            while (ch != null_node) : (ch = tree.get(ch).next_sibling) {
                if (hasDynamicSlotHeight(tree, ch)) return true;
            }
            return false;
        },
    }
}

fn computeStaticNode(tree: *const tree_mod.Tree, id: NodeId, visited: []u8, result: []bool) bool {
    if (id == null_node) return true;
    if (visited[id] != 0) return result[id];
    visited[id] = 1;

    const node = tree.get(id);
    var is_static = true;
    switch (node.payload) {
        .dynamic, .show_if, .section, .section_link, .hyperlink, .semantic_tag, .canvas => {
            is_static = false;
        },
        .text_block => |tb| {
            if (tb.has_dynamic_page_number) {
                is_static = false;
            } else {
                for (tree.getTextSpans(tb)) |span| {
                    switch (span) {
                        .hyperlink, .section_link, .page_number => is_static = false,
                        .inline_element => |ie| {
                            if (!computeStaticNode(tree, ie.child_node, visited, result)) is_static = false;
                        },
                        .literal => {},
                    }
                }
            }
        },
        .page => |p| {
            const s1 = computeStaticNode(tree, p.background, visited, result);
            const s2 = computeStaticNode(tree, p.header, visited, result);
            const s3 = computeStaticNode(tree, p.content, visited, result);
            const s4 = computeStaticNode(tree, p.footer, visited, result);
            const s5 = computeStaticNode(tree, p.foreground, visited, result);
            is_static = s1 and s2 and s3 and s4 and s5;
        },
        .decoration => |d| {
            const s1 = computeStaticNode(tree, d.before, visited, result);
            const s2 = computeStaticNode(tree, d.content, visited, result);
            const s3 = computeStaticNode(tree, d.after, visited, result);
            is_static = s1 and s2 and s3;
        },
        .multi_column => |mc| {
            const s1 = computeStaticNode(tree, mc.content, visited, result);
            const s2 = computeStaticNode(tree, mc.spacer, visited, result);
            is_static = s1 and s2;
        },
        .table_section => |ts| {
            for (tree.getTableCells(ts)) |cell| {
                if (!computeStaticNode(tree, cell.child, visited, result)) is_static = false;
            }
        },
        else => {
            var ch = node.first_child;
            while (ch != null_node) : (ch = tree.get(ch).next_sibling) {
                if (!computeStaticNode(tree, ch, visited, result)) is_static = false;
            }
        },
    }
    result[id] = is_static;
    return is_static;
}

fn computeStaticFlags(arena: std.mem.Allocator, tree: *const tree_mod.Tree) ![]bool {
    const n = tree.nodes.items.len;
    const result = try arena.alloc(bool, n);
    const visited = try arena.alloc(u8, n);
    @memset(result, false);
    @memset(visited, 0);
    for (tree.pages.items) |pid| {
        _ = computeStaticNode(tree, pid, visited, result);
    }
    return result;
}

/// Executes QuestPDF-style two-pass pagination:
/// - Pass 1 (`NullSink` + optional `SkPicture` static snapshot recording): resolves `DocumentLength` and `Section` page spans.
/// - Pass 2 (`target_sink`): renders final output with resolved cross-page metadata and replays static snapshots.
pub fn renderTree(
    gpa: std.mem.Allocator,
    tree: *const tree_mod.Tree,
    target_sink: sink_mod.RenderSink,
    options: RenderOptions,
) (RenderError || anyerror)!RenderStats {
    try tree.checkError();

    var plan_arena = std.heap.ArenaAllocator.init(gpa);
    defer plan_arena.deinit();

    const planned_tables = try preplanTables(plan_arena.allocator(), tree);
    const static_nodes = try computeStaticFlags(plan_arena.allocator(), tree);

    var state = try state_mod.StateStore.initForTree(gpa, tree);
    defer state.deinit(gpa);

    var page_ctx: state_mod.PageContext = .{};
    defer page_ctx.deinit(gpa);

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var snapshot_plans: std.AutoHashMapUnmanaged(u64, CachedSlotPlan) = .empty;
    defer snapshot_plans.deinit(gpa);
    defer target_sink.clearSnapshots();

    const use_snap = options.enable_snapshot_cache and target_sink.vtable.beginSnapshot != null;

    // Pass 1: dry-run measurement pass (+ optional static snapshot capture)
    try runPass(
        gpa,
        &scratch,
        tree,
        &state,
        &page_ctx,
        sink_mod.NullSink.sink(),
        options,
        planned_tables,
        static_nodes,
        if (use_snap) target_sink else null,
        if (use_snap) &snapshot_plans else null,
    );

    // Pass 2: actual rendering pass (+ optional static snapshot playback)
    page_ctx.proceedToRenderPhase();
    try runPass(
        gpa,
        &scratch,
        tree,
        &state,
        &page_ctx,
        target_sink,
        options,
        planned_tables,
        static_nodes,
        null,
        if (use_snap) &snapshot_plans else null,
    );

    return .{ .page_count = page_ctx.document_length };
}

/// Merges multiple `Tree` documents into a single output stream with either continuous
/// or independent page numbering across sub-documents.
pub fn renderMergedTrees(
    gpa: std.mem.Allocator,
    trees: []const *const tree_mod.Tree,
    target_sink: sink_mod.RenderSink,
    strategy: MergePageNumberStrategy,
    options: RenderOptions,
) (RenderError || anyerror)!RenderStats {
    if (strategy == .independent) {
        var total: u32 = 0;
        for (trees) |t| {
            const st = try renderTree(gpa, t, target_sink, options);
            total += st.page_count;
        }
        return .{ .page_count = total };
    }

    var plan_arena = std.heap.ArenaAllocator.init(gpa);
    defer plan_arena.deinit();

    const all_tables = try plan_arena.allocator().alloc([]?PlannedTableEntry, trees.len);
    const all_static = try plan_arena.allocator().alloc([]bool, trees.len);
    for (trees, 0..) |t, i| {
        try t.checkError();
        all_tables[i] = try preplanTables(plan_arena.allocator(), t);
        all_static[i] = try computeStaticFlags(plan_arena.allocator(), t);
    }

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    // Continuous page numbering across all merged documents
    const states = try gpa.alloc(state_mod.StateStore, trees.len);
    var initialized: usize = 0;
    defer {
        for (0..initialized) |i| states[i].deinit(gpa);
        gpa.free(states);
    }
    for (trees, 0..) |t, i| {
        states[i] = try state_mod.StateStore.initForTree(gpa, t);
        initialized = i + 1;
    }

    var page_ctx: state_mod.PageContext = .{};
    defer page_ctx.deinit(gpa);

    var snapshot_plans: std.AutoHashMapUnmanaged(u64, CachedSlotPlan) = .empty;
    defer snapshot_plans.deinit(gpa);
    defer target_sink.clearSnapshots();

    const use_snap = options.enable_snapshot_cache and target_sink.vtable.beginSnapshot != null;

    // Pass 1 across all documents
    for (trees, 0..) |t, i| {
        page_ctx.current_document_id = @intCast(i);
        try runPass(
            gpa,
            &scratch,
            t,
            &states[i],
            &page_ctx,
            sink_mod.NullSink.sink(),
            options,
            all_tables[i],
            all_static[i],
            if (use_snap) target_sink else null,
            if (use_snap) &snapshot_plans else null,
        );
    }

    // Pass 2 across all documents with resolved global total pages
    page_ctx.proceedToRenderPhase();
    for (trees, 0..) |t, i| {
        page_ctx.current_document_id = @intCast(i);
        try runPass(
            gpa,
            &scratch,
            t,
            &states[i],
            &page_ctx,
            target_sink,
            options,
            all_tables[i],
            all_static[i],
            null,
            if (use_snap) &snapshot_plans else null,
        );
    }

    return .{ .page_count = page_ctx.document_length };
}

fn runPass(
    gpa: std.mem.Allocator,
    scratch: *std.heap.ArenaAllocator,
    tree: *const tree_mod.Tree,
    state: *state_mod.StateStore,
    page_ctx: *state_mod.PageContext,
    sink: sink_mod.RenderSink,
    options: RenderOptions,
    planned_tables: []const ?PlannedTableEntry,
    static_nodes: []const bool,
    snapshot_sink: ?sink_mod.RenderSink,
    snapshot_plans: ?*std.AutoHashMapUnmanaged(u64, CachedSlotPlan),
) (RenderError || anyerror)!void {
    state.resetAll(true);

    var ctx: RenderContext = .{
        .gpa = gpa,
        .scratch = scratch,
        .tree = tree,
        .state = state,
        .page_ctx = page_ctx,
        .sink = sink,
        .text_engine = options.text_engine,
        .direction = options.default_direction,
        .pdf_tag_ids = options.pdf_tag_ids,
        .check_missing_glyphs = options.check_missing_glyphs,
        .planned_tables = planned_tables,
        .static_nodes = static_nodes,
        .snapshot_sink = snapshot_sink,
        .snapshot_plans = snapshot_plans,
    };

    for (tree.pages.items) |page_id| {
        var pages_in_set: u32 = 0;
        while (true) {
            _ = scratch.reset(.retain_capacity);
            ctx.last_table_plan = null;

            if (page_ctx.current_page >= options.max_pages) {
                return error.MaxPagesExceeded;
            }

            page_ctx.incrementPage();
            const page_plan = ctx.measurePagePlan(page_id, Size.max);
            const plan = page_plan.result;
            if (ctx.oom) return error.OutOfMemory;
            if (ctx.missing_glyphs) return error.MissingGlyphs;

            if (plan.kind == .wrap) {
                if (options.diagnostic) |d| {
                    d.page_number = page_ctx.current_page;
                    d.reason = plan.wrap_reason orelse "Layout overflow";
                    if (d.report.len > 0) d.allocator.free(d.report);
                    d.report = diag.formatOverflowReport(d.allocator, tree, &ctx, page_id, page_ctx.current_page, plan.wrap_reason) catch &.{};
                }
                page_ctx.decrementPage();
                ctx.last_wrap_reason = plan.wrap_reason;
                return error.LayoutOverflow;
            }

            if (plan.kind == .empty and pages_in_set > 0) {
                page_ctx.decrementPage();
                break;
            }

            try sink.beginPage(plan.size);
            ctx.drawPageWithPlan(page_id, page_plan);
            sink.endPage();
            if (ctx.oom) return error.OutOfMemory;
            if (ctx.missing_glyphs) return error.MissingGlyphs;

            pages_in_set += 1;
            if (plan.kind == .full_render or plan.kind == .empty) {
                break;
            }
        }
    }
}
