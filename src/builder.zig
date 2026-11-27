const std = @import("std");
const geom = @import("geometry.zig");
const style = @import("style.zig");
const tree_mod = @import("tree.zig");
const engine = @import("layout/engine.zig");
const te = @import("layout/text_engine.zig");
const tbl = @import("layout/table.zig");
const sink_mod = @import("backend/sink.zig");

const NodeId = tree_mod.NodeId;
const null_node = tree_mod.null_node;

pub const PageOptions = struct {
    size: geom.PageSizeMode = .a4,
    margin: geom.EdgeInput = .{},
    background_color: style.Color = style.Color.white,
    default_text_style: style.TextStyle = .empty,
    direction: ?style.ContentDirection = null,
};

pub const ColumnOptions = struct {
    spacing: f32 = 0,
};

pub const RowOptions = struct {
    spacing: f32 = 0,
};

pub const BoxOptions = struct {
    padding: geom.EdgeInput = .{},
    background: ?style.Color = null,
    gradient: ?style.LinearGradient = null,
    border: ?style.BorderStyle = null,
    radius: f32 = 0,
    clip: bool = false,
    shadow: ?style.ShadowStyle = null,
};

pub const ConstrainedOptions = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: ?f32 = null,
    max_width: ?f32 = null,
    min_height: ?f32 = null,
    max_height: ?f32 = null,
    enforce_when_empty: bool = false,
};

pub const LineOptions = struct {
    thickness: f32 = 1.0,
    color: style.Color = style.Color.black,
    dash: ?style.DashPattern = null,
};

pub const BackgroundOptions = struct {
    color: ?style.Color = null,
    gradient: ?style.LinearGradient = null,
    radius: f32 = 0,
};

pub const RichTextOptions = struct {
    alignment: ?style.TextAlign = null,
    style: style.TextStyle = .empty,
    clamp_lines: ?u32 = null,
    clamp_ellipsis: [:0]const u8 = "…",
    paragraph_spacing: f32 = 0,
    first_line_indent: f32 = 0,
};

pub const TableOptions = struct {
    columns: []const tbl.ColumnDef,
    extend_last_cells_to_bottom: bool = false,
};

pub const InlinedOptions = struct {
    horizontal_spacing: f32 = 0,
    vertical_spacing: f32 = 0,
    alignment: ?tree_mod.InlinedAlignment = null,
    baseline: style.VerticalAlign = .top,
};

pub const MultiColumnOptions = struct {
    columns: u32 = 2,
    spacing: f32 = 12,
    balance_height: bool = false,
};

pub const ImageOptions = struct {
    scaling: style.ImageScaling = .fit_area,
    target_dpi: ?f32 = null,
    quality: ?style.ImageCompressionQuality = null,
};

pub const SvgOptions = struct {
    scaling: style.ImageScaling = .fit_area,
};

pub const SvgPathOptions = struct {
    color: style.Color = style.Color.black,
    /// When null, fills the path; when non-null, strokes the path with this width.
    stroke_width: ?f32 = null,
    /// Uniformly scales and centers the path's bounds to fit inside the available box.
    fit: bool = true,
};

/// Top-level document builder owning the Arena-allocated immutable layout tree.
/// Builder methods never return errors mid-chain; any OOM or structural compose error
/// is latched and returned cleanly when `validate()` or `render*()` is invoked.
pub const Document = struct {
    backing_allocator: std.mem.Allocator,
    tree: tree_mod.Tree,
    default_direction: style.ContentDirection = .ltr,

    pub const InitOptions = struct {
        default_direction: style.ContentDirection = .ltr,
    };

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) Document {
        return .{
            .backing_allocator = allocator,
            .tree = tree_mod.Tree.init(allocator),
            .default_direction = opts.default_direction,
        };
    }

    pub fn deinit(self: *Document) void {
        self.tree.deinit();
        self.* = undefined;
    }

    pub fn addPage(self: *Document, opts: PageOptions) PageBuilder {
        const page_id = self.tree.addPageNode(.{
            .size_mode = opts.size,
            .margin = opts.margin.resolve(),
            .background_color = opts.background_color,
            .default_text_style = opts.default_text_style,
            .direction = opts.direction,
        });
        return .{ .tree = &self.tree, .page_id = page_id };
    }

    pub fn validate(self: *const Document) tree_mod.ComposeError!void {
        return self.tree.checkError();
    }

    /// Renders this document into any `RenderSink` (useful for pure-Zig tests and custom backends).
    pub fn renderToSink(self: *const Document, sink: sink_mod.RenderSink, opts: engine.RenderOptions) !engine.RenderStats {
        var effective = opts;
        if (effective.default_direction == .ltr and self.default_direction == .rtl) {
            effective.default_direction = .rtl;
        }
        return engine.renderTree(self.backing_allocator, &self.tree, sink, effective);
    }
};

/// Scoped builder handle for a PageSet (header / content / footer / background / foreground).
pub const PageBuilder = struct {
    tree: *tree_mod.Tree,
    page_id: NodeId,

    fn slotFor(self: PageBuilder, comptime field_name: []const u8) Slot {
        if (self.page_id == null_node) return .{ .tree = self.tree, .node = null_node };
        const page_cfg = &self.tree.getMut(self.page_id).payload.page;
        if (@field(page_cfg, field_name) != null_node) {
            self.tree.fail(error.DuplicatePageSlot);
            return .{ .tree = self.tree, .node = null_node };
        }
        const c = self.tree.addNode(.container);
        @field(&self.tree.getMut(self.page_id).payload.page, field_name) = c;
        return .{ .tree = self.tree, .node = c };
    }

    pub fn background(self: PageBuilder) Slot {
        return self.slotFor("background");
    }

    pub fn foreground(self: PageBuilder) Slot {
        return self.slotFor("foreground");
    }

    pub fn header(self: PageBuilder) Slot {
        return self.slotFor("header");
    }

    pub fn content(self: PageBuilder) Slot {
        return self.slotFor("content");
    }

    pub fn footer(self: PageBuilder) Slot {
        return self.slotFor("footer");
    }
};

/// Lightweight 16-byte single-child container handle enabling QuestPDF-style fluent chaining in Zig.
pub const Slot = struct {
    tree: *tree_mod.Tree,
    node: NodeId,

    fn wrap(self: Slot, payload: tree_mod.NodePayload) Slot {
        if (self.node == null_node) return self;
        const child = self.tree.addNode(payload);
        self.tree.attachSingleChild(self.node, child);
        return .{ .tree = self.tree, .node = child };
    }

    fn leaf(self: Slot, payload: tree_mod.NodePayload) void {
        _ = self.wrap(payload);
    }

    // --- Compositional / Reusable Components ---

    /// Invokes any Zig struct defining `pub fn compose(self: ..., slot: pagine.Slot) void` with zero boxing.
    pub fn component(self: Slot, comp: anytype) void {
        comp.compose(self);
    }

    /// Tags this slot with a Zig `@src()` location for overflow diagnostics.
    pub fn source(self: Slot, loc: std.builtin.SourceLocation) Slot {
        if (self.node != null_node) {
            self.tree.getMut(self.node).source_loc = loc;
        }
        return self;
    }

    // --- Multi-child Containers ---

    pub fn column(self: Slot, opts: ColumnOptions) ColumnBuilder {
        const next = self.wrap(.{ .column = .{ .spacing = opts.spacing } });
        return .{ .tree = self.tree, .node = next.node };
    }

    pub fn row(self: Slot, opts: RowOptions) RowBuilder {
        const next = self.wrap(.{ .row = .{ .spacing = opts.spacing } });
        return .{ .tree = self.tree, .node = next.node };
    }

    pub fn decoration(self: Slot) DecorationBuilder {
        const next = self.wrap(.{ .decoration = .{} });
        return .{ .tree = self.tree, .node = next.node };
    }

    pub fn layers(self: Slot) LayersBuilder {
        const next = self.wrap(.layers);
        return .{ .tree = self.tree, .node = next.node };
    }

    pub fn inlined(self: Slot, opts: InlinedOptions) InlinedBuilder {
        const next = self.wrap(.{ .inlined = .{
            .horizontal_spacing = opts.horizontal_spacing,
            .vertical_spacing = opts.vertical_spacing,
            .alignment = opts.alignment,
            .baseline_alignment = opts.baseline,
        } });
        return .{ .tree = self.tree, .node = next.node };
    }

    pub fn multiColumn(self: Slot, opts: MultiColumnOptions) MultiColumnBuilder {
        const next = self.wrap(.{ .multi_column = .{
            .column_count = @max(1, opts.columns),
            .spacing = opts.spacing,
            .balance_height = opts.balance_height,
        } });
        return .{ .tree = self.tree, .node = next.node };
    }

    /// Creates a paginated Table with automatic header/footer repetition across pages,
    /// constant/relative columns, and ColSpan/RowSpan auto-placement & validation.
    pub fn table(self: Slot, opts: TableOptions) TableBuilder {
        if (self.node == null_node) return .{ .tree = self.tree, .header_node = null_node, .body_node = null_node, .footer_node = null_node };
        const cols_slice = self.tree.addTableColumns(opts.columns);
        const header_node = self.tree.addNode(.{ .table_section = .{
            .cols_start = cols_slice.start,
            .cols_len = cols_slice.len,
        } });
        const body_node = self.tree.addNode(.{ .table_section = .{
            .cols_start = cols_slice.start,
            .cols_len = cols_slice.len,
            .extend_last_cells_to_bottom = opts.extend_last_cells_to_bottom,
        } });
        const footer_node = self.tree.addNode(.{ .table_section = .{
            .cols_start = cols_slice.start,
            .cols_len = cols_slice.len,
        } });

        _ = self.wrap(.{ .decoration = .{
            .before = header_node,
            .content = body_node,
            .after = footer_node,
        } });

        return .{
            .tree = self.tree,
            .header_node = header_node,
            .body_node = body_node,
            .footer_node = footer_node,
        };
    }

    // --- Box Model & Visual Wrappers ---

    pub fn padding(self: Slot, input: geom.EdgeInput) Slot {
        return self.wrap(.{ .padding = input.resolve() });
    }

    pub fn paddingAll(self: Slot, v: f32) Slot {
        return self.wrap(.{ .padding = geom.EdgeInsets.all(v) });
    }

    pub fn background(self: Slot, color: style.Color) Slot {
        return self.wrap(.{ .background = .{ .color = color } });
    }

    pub fn backgroundOpt(self: Slot, color: ?style.Color) Slot {
        if (color) |c| return self.background(c);
        return self;
    }

    pub fn backgroundEx(self: Slot, opts: BackgroundOptions) Slot {
        var grad = opts.gradient;
        if (grad) |*g| {
            g.stops = self.tree.dupeGradientStops(g.stops);
        }
        return self.wrap(.{ .background = .{
            .color = opts.color,
            .gradient = grad,
            .radius = opts.radius,
        } });
    }

    pub fn border(self: Slot, b: style.BorderStyle) Slot {
        return self.wrap(.{ .border = b });
    }

    pub fn box(self: Slot, opts: BoxOptions) Slot {
        var grad = opts.gradient;
        if (grad) |*g| {
            g.stops = self.tree.dupeGradientStops(g.stops);
        }
        return self.wrap(.{ .box = .{
            .padding = opts.padding.resolve(),
            .background = opts.background,
            .gradient = grad,
            .border = opts.border,
            .radius = opts.radius,
            .clip = opts.clip,
            .shadow = opts.shadow,
        } });
    }

    pub fn clip(self: Slot, radius: f32) Slot {
        return self.wrap(.{ .clip = .{ .radius = radius } });
    }

    // --- Size Constraints (coalesced when chained directly!) ---

    pub fn constrained(self: Slot, opts: ConstrainedOptions) Slot {
        return self.wrap(.{ .constrained = .{
            .min_width = opts.width orelse opts.min_width,
            .max_width = opts.width orelse opts.max_width,
            .min_height = opts.height orelse opts.min_height,
            .max_height = opts.height orelse opts.max_height,
            .enforce_when_empty = opts.enforce_when_empty,
        } });
    }

    pub fn width(self: Slot, w: f32) Slot {
        return self.constrained(.{ .width = w });
    }

    pub fn height(self: Slot, h: f32) Slot {
        return self.constrained(.{ .height = h });
    }

    pub fn minWidth(self: Slot, w: f32) Slot {
        return self.constrained(.{ .min_width = w });
    }

    pub fn maxWidth(self: Slot, w: f32) Slot {
        return self.constrained(.{ .max_width = w });
    }

    pub fn minHeight(self: Slot, h: f32) Slot {
        return self.constrained(.{ .min_height = h });
    }

    pub fn maxHeight(self: Slot, h: f32) Slot {
        return self.constrained(.{ .max_height = h });
    }

    pub fn size(self: Slot, w: f32, h: f32) Slot {
        return self.constrained(.{ .width = w, .height = h });
    }

    // --- Alignment, Extend, Shrink, AspectRatio, Transforms ---

    pub fn alignXY(self: Slot, h: ?style.HorizontalAlign, v: ?style.VerticalAlign) Slot {
        return self.wrap(.{ .alignment = .{ .horizontal = h, .vertical = v } });
    }

    pub fn alignLeft(self: Slot) Slot {
        return self.alignXY(.left, null);
    }
    pub fn alignCenter(self: Slot) Slot {
        return self.alignXY(.center, null);
    }
    pub fn alignRight(self: Slot) Slot {
        return self.alignXY(.right, null);
    }
    pub fn alignTop(self: Slot) Slot {
        return self.alignXY(null, .top);
    }
    pub fn alignMiddle(self: Slot) Slot {
        return self.alignXY(null, .middle);
    }
    pub fn alignBottom(self: Slot) Slot {
        return self.alignXY(null, .bottom);
    }

    pub fn extend(self: Slot) Slot {
        return self.wrap(.{ .extend = .{ .horizontal = true, .vertical = true } });
    }
    pub fn extendHorizontal(self: Slot) Slot {
        return self.wrap(.{ .extend = .{ .horizontal = true, .vertical = false } });
    }
    pub fn extendVertical(self: Slot) Slot {
        return self.wrap(.{ .extend = .{ .horizontal = false, .vertical = true } });
    }

    pub fn shrink(self: Slot) Slot {
        return self.wrap(.{ .shrink = .{ .horizontal = true, .vertical = true } });
    }
    pub fn shrinkHorizontal(self: Slot) Slot {
        return self.wrap(.{ .shrink = .{ .horizontal = true, .vertical = false } });
    }
    pub fn shrinkVertical(self: Slot) Slot {
        return self.wrap(.{ .shrink = .{ .horizontal = false, .vertical = true } });
    }

    pub fn unconstrained(self: Slot) Slot {
        return self.wrap(.unconstrained);
    }

    pub fn aspectRatio(self: Slot, ratio: f32, option: style.AspectRatioOption) Slot {
        return self.wrap(.{ .aspect_ratio = .{ .ratio = ratio, .option = option } });
    }

    pub fn translate(self: Slot, dx: f32, dy: f32) Slot {
        return self.wrap(.{ .transform = .{ .translate = .{ .x = dx, .y = dy } } });
    }

    pub fn scale(self: Slot, sx: f32, sy: f32) Slot {
        return self.wrap(.{ .transform = .{ .scale = .{ .x = sx, .y = sy } } });
    }

    pub fn scaleToFit(self: Slot) Slot {
        return self.wrap(.{ .transform = .scale_to_fit });
    }

    pub fn rotate(self: Slot, degrees: f32) Slot {
        return self.wrap(.{ .transform = .{ .rotate = degrees } });
    }

    pub fn rotateRight(self: Slot) Slot {
        return self.wrap(.{ .transform = .rotate_right_90 });
    }

    pub fn rotateLeft(self: Slot) Slot {
        return self.wrap(.{ .transform = .rotate_left_90 });
    }

    // --- Text & Rich Text ---

    /// Places a text block with the given text and style overrides.
    pub fn text(self: Slot, content: []const u8, ts: style.TextStyle) void {
        var rt = self.richText(.{});
        rt.span(content, ts);
    }

    /// Formats text directly into the document arena (zero caller buffer management).
    pub fn print(self: Slot, comptime fmt: []const u8, args: anytype, ts: style.TextStyle) void {
        const formatted = self.tree.fmtStr(fmt, args);
        var rt = self.richText(.{});
        rt.spanBorrowed(formatted, ts);
    }

    /// Starts a multi-span rich text block supporting mixed styles, dynamic page numbers, links, and inline elements.
    pub fn richText(self: Slot, opts: RichTextOptions) RichTextBuilder {
        const next = self.wrap(.{ .text_block = .{
            .alignment = opts.alignment,
            .default_style = opts.style,
            .clamp_lines = opts.clamp_lines,
            .clamp_ellipsis = opts.clamp_ellipsis,
            .paragraph_spacing = opts.paragraph_spacing,
            .first_line_indent = opts.first_line_indent,
        } });
        return .{ .tree = self.tree, .node = next.node };
    }

    // --- Lines & Placeholders ---

    pub fn lineHorizontal(self: Slot, opts: LineOptions) void {
        self.leaf(.{ .line = .{
            .horizontal = true,
            .thickness = opts.thickness,
            .color = opts.color,
            .dash = opts.dash,
        } });
    }

    pub fn lineVertical(self: Slot, opts: LineOptions) void {
        self.leaf(.{ .line = .{
            .horizontal = false,
            .thickness = opts.thickness,
            .color = opts.color,
            .dash = opts.dash,
        } });
    }

    pub fn placeholder(self: Slot, label: []const u8) void {
        self.leaf(.{ .placeholder = .{ .label = self.tree.dupeStr(label) } });
    }

    // --- Media, Custom Canvas & Dynamic Components ---

    /// Places a retained `ImageRef` (obtained via `pagine.Image.retainRef()`).
    pub fn imageRef(self: Slot, ref: tree_mod.ImageRef, opts: ImageOptions) void {
        if (ref.release_fn) |rel| {
            self.tree.registerCleanup(ref.ptr, rel);
        }
        self.leaf(.{ .image = .{
            .ref = ref,
            .scaling = opts.scaling,
            .target_dpi = opts.target_dpi,
            .quality = opts.quality,
        } });
    }

    /// Places a retained `SvgRef` (obtained via `pagine.Svg.retainRef()`).
    pub fn svgRef(self: Slot, ref: tree_mod.SvgRef, opts: SvgOptions) void {
        if (ref.release_fn) |rel| {
            self.tree.registerCleanup(ref.ptr, rel);
        }
        self.leaf(.{ .svg = .{
            .ref = ref,
            .scaling = opts.scaling,
        } });
    }

    /// Draws an inline SVG path `d` string (e.g. icons or vector badges) with zero DOM parsing overhead.
    pub fn svgPath(self: Slot, path_data: [:0]const u8, opts: SvgPathOptions) void {
        self.leaf(.{ .svg_path = .{
            .path_data = self.tree.dupeStrZ(path_data),
            .color = opts.color,
            .stroke_width = opts.stroke_width,
            .fit = opts.fit,
        } });
    }

    /// Low-level custom canvas draw hook. Prefer `pagine.drawCanvas(slot, ctx, fn)` for typed `skia.Canvas`.
    pub fn canvasRaw(self: Slot, ctx: ?*const anyopaque, draw_fn: tree_mod.CanvasDrawFn) void {
        self.leaf(.{ .canvas = .{
            .ctx = ctx,
            .draw_fn = draw_fn,
        } });
    }

    /// Places a page-aware stateful Dynamic component.
    /// `compose_fn` receives `(*State, DynamicContextInfo, Slot) -> DynamicResult` on each page.
    pub fn dynamic(
        self: Slot,
        comptime State: type,
        initial_state: State,
        comptime compose_fn: fn (*State, tree_mod.DynamicContextInfo, Slot) tree_mod.DynamicResult,
    ) void {
        const Trampoline = struct {
            fn call(
                state_bytes: []u8,
                info: tree_mod.DynamicContextInfo,
                scratch_tree: *tree_mod.Tree,
                root_container: NodeId,
            ) tree_mod.DynamicResult {
                const typed_state: *State = @ptrCast(@alignCast(state_bytes.ptr));
                return compose_fn(typed_state, info, .{ .tree = scratch_tree, .node = root_container });
            }
        };
        const raw_bytes = self.tree.dupeBytes(std.mem.asBytes(&initial_state));
        self.leaf(.{ .dynamic = .{
            .initial_state = raw_bytes,
            .state_align = @alignOf(State),
            .compose_fn = Trampoline.call,
        } });
    }

    // --- PDF/UA Semantic Tags & Bookmarks ---

    pub fn semantic(self: Slot, cfg: tree_mod.SemanticTagConfig) Slot {
        return self.wrap(.{ .semantic_tag = .{
            .tag = self.tree.dupeStrZ(cfg.tag),
            .alt = if (cfg.alt) |a| self.tree.dupeStrZ(a) else null,
            .lang = if (cfg.lang) |l| self.tree.dupeStrZ(l) else null,
        } });
    }

    /// Wraps content in a PDF/UA heading tag (`H1`..`H6`) used for accessibility and PDF Outlines (bookmarks).
    pub fn heading(self: Slot, comptime level: u8) Slot {
        comptime std.debug.assert(level >= 1 and level <= 6);
        const tag_name: [:0]const u8 = switch (level) {
            1 => "H1",
            2 => "H2",
            3 => "H3",
            4 => "H4",
            5 => "H5",
            6 => "H6",
            else => unreachable,
        };
        return self.semantic(.{ .tag = tag_name });
    }

    // --- Context, Pagination & Navigation ---

    pub fn defaultTextStyle(self: Slot, ts: style.TextStyle) Slot {
        return self.wrap(.{ .default_text_style = ts });
    }

    pub fn direction(self: Slot, dir: style.ContentDirection) Slot {
        return self.wrap(.{ .direction_setter = dir });
    }

    pub fn pageBreak(self: Slot) void {
        self.leaf(.page_break);
    }

    pub fn showEntire(self: Slot) Slot {
        return self.wrap(.show_entire);
    }

    pub fn ensureSpace(self: Slot, min_height: f32) Slot {
        return self.wrap(.{ .ensure_space = .{ .min_height = min_height } });
    }

    pub fn showOnce(self: Slot) Slot {
        return self.wrap(.show_once);
    }

    pub fn skipOnce(self: Slot) Slot {
        return self.wrap(.skip_once);
    }

    pub fn stopPaging(self: Slot) Slot {
        return self.wrap(.stop_paging);
    }

    pub fn repeat(self: Slot) Slot {
        return self.wrap(.repeat);
    }

    pub fn showIf(self: Slot, condition: bool) Slot {
        if (condition) return self;
        // Detached orphan slot so caller chain compiles cleanly without drawing anything.
        return .{ .tree = self.tree, .node = null_node };
    }

    pub fn showIfFn(self: Slot, ctx: ?*const anyopaque, predicate: tree_mod.ShowIfPredicate) Slot {
        return self.wrap(.{ .show_if = .{ .ctx = ctx, .predicate = predicate } });
    }

    pub fn section(self: Slot, name: []const u8) Slot {
        return self.wrap(.{ .section = .{ .name = self.tree.dupeStr(name) } });
    }

    pub fn sectionLink(self: Slot, name: []const u8) Slot {
        return self.wrap(.{ .section_link = .{ .name = self.tree.dupeStr(name) } });
    }

    pub fn hyperlink(self: Slot, url: []const u8) Slot {
        return self.wrap(.{ .hyperlink = .{ .url = self.tree.dupeStr(url) } });
    }

    pub fn debugArea(self: Slot, label: []const u8, color: style.Color) Slot {
        return self.wrap(.{ .debug_area = .{
            .label = self.tree.dupeStr(label),
            .color = color,
        } });
    }
};

pub const ColumnBuilder = struct {
    tree: *tree_mod.Tree,
    node: NodeId,

    pub fn item(self: ColumnBuilder) Slot {
        if (self.node == null_node) return .{ .tree = self.tree, .node = null_node };
        const c = self.tree.addNode(.container);
        self.tree.appendChild(self.node, c);
        return .{ .tree = self.tree, .node = c };
    }
};

pub const RowBuilder = struct {
    tree: *tree_mod.Tree,
    node: NodeId,

    fn addItem(self: RowBuilder, mode: tree_mod.RowItemMode) Slot {
        if (self.node == null_node) return .{ .tree = self.tree, .node = null_node };
        const ri = self.tree.addNode(.{ .row_item = .{ .mode = mode } });
        self.tree.appendChild(self.node, ri);
        return .{ .tree = self.tree, .node = ri };
    }

    pub fn auto(self: RowBuilder) Slot {
        return self.addItem(.auto);
    }

    pub fn constant(self: RowBuilder, w: f32) Slot {
        return self.addItem(.{ .constant = w });
    }

    pub fn relative(self: RowBuilder, weight: f32) Slot {
        return self.addItem(.{ .relative = weight });
    }
};

pub const DecorationBuilder = struct {
    tree: *tree_mod.Tree,
    node: NodeId,

    fn slotFor(self: DecorationBuilder, comptime field_name: []const u8) Slot {
        if (self.node == null_node) return .{ .tree = self.tree, .node = null_node };
        const dec = &self.tree.getMut(self.node).payload.decoration;
        if (@field(dec, field_name) != null_node) {
            self.tree.fail(error.MultipleChildrenAssigned);
            return .{ .tree = self.tree, .node = null_node };
        }
        const c = self.tree.addNode(.container);
        @field(&self.tree.getMut(self.node).payload.decoration, field_name) = c;
        return .{ .tree = self.tree, .node = c };
    }

    pub fn before(self: DecorationBuilder) Slot {
        return self.slotFor("before");
    }

    pub fn content(self: DecorationBuilder) Slot {
        return self.slotFor("content");
    }

    pub fn after(self: DecorationBuilder) Slot {
        return self.slotFor("after");
    }
};

pub const LayersBuilder = struct {
    tree: *tree_mod.Tree,
    node: NodeId,

    pub fn layer(self: LayersBuilder) Slot {
        if (self.node == null_node) return .{ .tree = self.tree, .node = null_node };
        const l = self.tree.addNode(.{ .layer = .{ .is_primary = false } });
        self.tree.appendChild(self.node, l);
        return .{ .tree = self.tree, .node = l };
    }

    pub fn primaryLayer(self: LayersBuilder) Slot {
        if (self.node == null_node) return .{ .tree = self.tree, .node = null_node };
        const l = self.tree.addNode(.{ .layer = .{ .is_primary = true } });
        self.tree.appendChild(self.node, l);
        return .{ .tree = self.tree, .node = l };
    }
};

pub const RichTextBuilder = struct {
    tree: *tree_mod.Tree,
    node: NodeId,

    pub fn span(self: RichTextBuilder, content: []const u8, ts: style.TextStyle) void {
        self.spanBorrowed(self.tree.dupeStr(content), ts);
    }

    fn spanBorrowed(self: RichTextBuilder, owned_content: []const u8, ts: style.TextStyle) void {
        self.tree.appendTextSpan(self.node, .{ .literal = .{
            .text = owned_content,
            .style = ts,
        } });
    }

    pub fn print(self: RichTextBuilder, comptime fmt: []const u8, args: anytype, ts: style.TextStyle) void {
        const formatted = self.tree.fmtStr(fmt, args);
        self.spanBorrowed(formatted, ts);
    }

    pub fn line(self: RichTextBuilder, content: []const u8, ts: style.TextStyle) void {
        const s = self.tree.fmtStr("{s}\n", .{content});
        self.spanBorrowed(s, ts);
    }

    pub fn emptyLine(self: RichTextBuilder) void {
        self.spanBorrowed("\n", .empty);
    }

    pub fn hyperlink(self: RichTextBuilder, label: []const u8, url: []const u8, ts: style.TextStyle) void {
        self.tree.appendTextSpan(self.node, .{ .hyperlink = .{
            .text = self.tree.dupeStr(label),
            .url = self.tree.dupeStr(url),
            .style = ts,
        } });
    }

    pub fn sectionLink(self: RichTextBuilder, label: []const u8, section_name: []const u8, ts: style.TextStyle) void {
        self.tree.appendTextSpan(self.node, .{ .section_link = .{
            .text = self.tree.dupeStr(label),
            .section_name = self.tree.dupeStr(section_name),
            .style = ts,
        } });
    }

    pub fn currentPageNumber(self: RichTextBuilder, ts: style.TextStyle) void {
        self.tree.appendTextSpan(self.node, .{ .page_number = .{
            .kind = .current_page,
            .style = ts,
        } });
    }

    pub fn totalPages(self: RichTextBuilder, ts: style.TextStyle) void {
        self.tree.appendTextSpan(self.node, .{ .page_number = .{
            .kind = .total_pages,
            .style = ts,
        } });
    }

    pub fn sectionBeginPage(self: RichTextBuilder, section_name: []const u8, ts: style.TextStyle) void {
        self.tree.appendTextSpan(self.node, .{ .page_number = .{
            .kind = .section_begin,
            .section_name = self.tree.dupeStr(section_name),
            .style = ts,
        } });
    }

    pub fn sectionEndPage(self: RichTextBuilder, section_name: []const u8, ts: style.TextStyle) void {
        self.tree.appendTextSpan(self.node, .{ .page_number = .{
            .kind = .section_end,
            .section_name = self.tree.dupeStr(section_name),
            .style = ts,
        } });
    }

    pub fn pageInSection(self: RichTextBuilder, section_name: []const u8, ts: style.TextStyle) void {
        self.tree.appendTextSpan(self.node, .{ .page_number = .{
            .kind = .page_in_section,
            .section_name = self.tree.dupeStr(section_name),
            .style = ts,
        } });
    }

    pub fn totalPagesInSection(self: RichTextBuilder, section_name: []const u8, ts: style.TextStyle) void {
        self.tree.appendTextSpan(self.node, .{ .page_number = .{
            .kind = .total_in_section,
            .section_name = self.tree.dupeStr(section_name),
            .style = ts,
        } });
    }

    pub fn pageNumberFormatted(
        self: RichTextBuilder,
        kind: te.PageNumberKind,
        section_name: ?[]const u8,
        ctx: ?*const anyopaque,
        format_fn: te.PageNumberFormatter,
        ts: style.TextStyle,
    ) void {
        self.tree.appendTextSpan(self.node, .{ .page_number = .{
            .kind = kind,
            .section_name = if (section_name) |n| self.tree.dupeStr(n) else null,
            .format_ctx = ctx,
            .format_fn = format_fn,
            .style = ts,
        } });
    }

    /// Embeds a custom inline layout element (e.g. badge, icon, chip) inside the text flow.
    pub fn element(self: RichTextBuilder, alignment: te.InlineElementAlignment) Slot {
        if (self.node == null_node) return .{ .tree = self.tree, .node = null_node };
        const c = self.tree.addNode(.container);
        self.tree.appendTextSpan(self.node, .{ .inline_element = .{
            .child_node = c,
            .alignment = alignment,
        } });
        return .{ .tree = self.tree, .node = c };
    }
};

pub const InlinedBuilder = struct {
    tree: *tree_mod.Tree,
    node: NodeId,

    pub fn item(self: InlinedBuilder) Slot {
        if (self.node == null_node) return .{ .tree = self.tree, .node = null_node };
        const c = self.tree.addNode(.container);
        self.tree.appendChild(self.node, c);
        return .{ .tree = self.tree, .node = c };
    }
};

pub const MultiColumnBuilder = struct {
    tree: *tree_mod.Tree,
    node: NodeId,

    pub fn content(self: MultiColumnBuilder) Slot {
        if (self.node == null_node) return .{ .tree = self.tree, .node = null_node };
        const mc = &self.tree.getMut(self.node).payload.multi_column;
        if (mc.content != null_node) {
            self.tree.fail(error.MultipleChildrenAssigned);
            return .{ .tree = self.tree, .node = null_node };
        }
        const c = self.tree.addNode(.container);
        self.tree.getMut(self.node).payload.multi_column.content = c;
        return .{ .tree = self.tree, .node = c };
    }

    pub fn spacer(self: MultiColumnBuilder) Slot {
        if (self.node == null_node) return .{ .tree = self.tree, .node = null_node };
        const mc = &self.tree.getMut(self.node).payload.multi_column;
        if (mc.spacer != null_node) {
            self.tree.fail(error.MultipleChildrenAssigned);
            return .{ .tree = self.tree, .node = null_node };
        }
        const c = self.tree.addNode(.container);
        self.tree.getMut(self.node).payload.multi_column.spacer = c;
        return .{ .tree = self.tree, .node = c };
    }
};

pub const TableBuilder = struct {
    tree: *tree_mod.Tree,
    header_node: NodeId,
    body_node: NodeId,
    footer_node: NodeId,

    fn addCell(self: TableBuilder, section_node: NodeId, placement: tbl.CellPlacement) Slot {
        if (section_node == null_node) return .{ .tree = self.tree, .node = null_node };
        const c = self.tree.addNode(.container);
        self.tree.appendTableCell(section_node, .{
            .row = placement.row,
            .col = placement.col,
            .row_span = placement.row_span,
            .col_span = placement.col_span,
            .child = c,
        });
        return .{ .tree = self.tree, .node = c };
    }

    pub fn headerCell(self: TableBuilder) Slot {
        return self.addCell(self.header_node, .{});
    }

    pub fn headerCellAt(self: TableBuilder, placement: tbl.CellPlacement) Slot {
        return self.addCell(self.header_node, placement);
    }

    pub fn cell(self: TableBuilder) Slot {
        return self.addCell(self.body_node, .{});
    }

    pub fn cellAt(self: TableBuilder, placement: tbl.CellPlacement) Slot {
        return self.addCell(self.body_node, placement);
    }

    pub fn footerCell(self: TableBuilder) Slot {
        return self.addCell(self.footer_node, .{});
    }

    pub fn footerCellAt(self: TableBuilder, placement: tbl.CellPlacement) Slot {
        return self.addCell(self.footer_node, placement);
    }
};
