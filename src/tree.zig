const std = @import("std");
const geom = @import("geometry.zig");
const style = @import("style.zig");
const te = @import("layout/text_engine.zig");
const tbl = @import("layout/table.zig");

pub const NodeId = u32;
pub const null_node: NodeId = std.math.maxInt(u32);

pub const ComposeError = error{
    OutOfMemory,
    MultipleChildrenAssigned,
    DuplicatePageSlot,
    InvalidTableConfiguration,
    InvalidColumnDefinition,
    InvalidConstraint,
};

pub const RowItemMode = union(enum) {
    auto,
    constant: f32,
    relative: f32,
};

pub const ShowIfContext = struct {
    page_number: u32,
    total_pages: ?u32,
};

pub const ShowIfPredicate = *const fn (ctx: ?*const anyopaque, info: ShowIfContext) bool;

pub const BoxConfig = struct {
    padding: geom.EdgeInsets = .zero,
    background: ?style.Color = null,
    gradient: ?style.LinearGradient = null,
    border: ?style.BorderStyle = null,
    radius: f32 = 0,
    clip: bool = false,
    shadow: ?style.ShadowStyle = null,
};

pub const PageConfig = struct {
    size_mode: geom.PageSizeMode = .a4,
    margin: geom.EdgeInsets = .zero,
    background_color: style.Color = style.Color.white,
    default_text_style: style.TextStyle = .empty,
    direction: ?style.ContentDirection = null,
    background: NodeId = null_node,
    foreground: NodeId = null_node,
    header: NodeId = null_node,
    content: NodeId = null_node,
    footer: NodeId = null_node,
};

pub const InlinedAlignment = enum(u8) {
    left,
    center,
    right,
    justify,
    space_around,
};

pub const ImageRef = struct {
    ptr: *anyopaque,
    width: f32,
    height: f32,
    release_fn: ?*const fn (*anyopaque) void = null,
};

pub const SvgRef = struct {
    ptr: *anyopaque,
    width: f32,
    height: f32,
    release_fn: ?*const fn (*anyopaque) void = null,
};

pub const CanvasDrawFn = *const fn (ctx: ?*const anyopaque, raw_canvas: *anyopaque, size: geom.Size) void;

pub const MeasureResult = struct {
    size: geom.Size = .zero,
    fits_completely: bool = false,
    wraps: bool = false,
};

pub const DynamicMeasureFn = *const fn (
    ctx: *anyopaque,
    sub_tree: *const Tree,
    root_node: NodeId,
    available: geom.Size,
) MeasureResult;

pub const DynamicContextInfo = struct {
    page_number: u32,
    total_pages: ?u32,
    available_size: geom.Size,
    direction: style.ContentDirection,
    text_style: style.TextStyle,
    _allocator: ?std.mem.Allocator = null,
    _measure_ctx: ?*anyopaque = null,
    _measure_fn: ?DynamicMeasureFn = null,

    /// Measures an arbitrary candidate subtree against `available` without emitting it to the page.
    /// Ideal for packing variable-height rows and computing exact per-page subtotals inside `Dynamic`.
    /// `build_fn` may accept either `(user_ctx, Slot) void` or `(Slot) void` (when `user_ctx` is `{}`).
    pub fn measureElement(
        self: DynamicContextInfo,
        available: geom.Size,
        user_ctx: anytype,
        comptime build_fn: anytype,
    ) MeasureResult {
        const SlotType = @import("builder.zig").Slot;
        const measure_fn = self._measure_fn orelse return .{ .size = .zero, .fits_completely = false, .wraps = true };
        const m_ctx = self._measure_ctx orelse return .{ .size = .zero, .fits_completely = false, .wraps = true };
        const alloc = self._allocator orelse return .{ .size = .zero, .fits_completely = false, .wraps = true };

        var tmp_tree = Tree.init(alloc);
        defer tmp_tree.deinit();
        const root = tmp_tree.addNode(.container);
        const slot: SlotType = .{ .tree = &tmp_tree, .node = root };
        if (@TypeOf(user_ctx) == void) {
            build_fn(slot);
        } else {
            build_fn(user_ctx, slot);
        }
        if (tmp_tree.compose_error != null) return .{ .size = .zero, .fits_completely = false, .wraps = true };
        return measure_fn(m_ctx, &tmp_tree, root, available);
    }
};

pub const DynamicResult = struct {
    has_more_content: bool = false,
};

/// Erased dynamic component callback invoked once per page fragment with mutable state bytes and a scratch Tree/Slot.
pub const DynamicComposeFn = *const fn (
    state_bytes: []u8,
    info: DynamicContextInfo,
    scratch_tree: *Tree,
    root_container: NodeId,
) DynamicResult;

pub const DynamicConfig = struct {
    initial_state: []const u8,
    state_align: u16 = 8,
    compose_fn: DynamicComposeFn,
};

pub const SemanticTagConfig = struct {
    /// Standard PDF/UA structure type string (e.g. "H1", "H2", "P", "Table", "Figure", "Artifact").
    tag: [:0]const u8,
    alt: ?[:0]const u8 = null,
    lang: ?[:0]const u8 = null,
};

pub const NodePayload = union(enum) {
    empty,
    container,
    page: PageConfig,

    // Multi-child containers (children stored via intrusive first_child/next_sibling list)
    column: struct {
        spacing: f32 = 0,
    },
    row: struct {
        spacing: f32 = 0,
    },
    row_item: struct {
        mode: RowItemMode,
    },
    decoration: struct {
        before: NodeId = null_node,
        content: NodeId = null_node,
        after: NodeId = null_node,
    },
    layers,
    layer: struct {
        is_primary: bool = false,
    },
    inlined: struct {
        horizontal_spacing: f32 = 0,
        vertical_spacing: f32 = 0,
        alignment: ?InlinedAlignment = null,
        baseline_alignment: style.VerticalAlign = .top,
    },
    multi_column: struct {
        column_count: u32 = 2,
        spacing: f32 = 0,
        balance_height: bool = false,
        content: NodeId = null_node,
        spacer: NodeId = null_node,
    },
    table_section: tbl.TableSectionConfig,

    // Box model & visual wrappers (single child via first_child)
    padding: geom.EdgeInsets,
    background: struct {
        color: ?style.Color = null,
        gradient: ?style.LinearGradient = null,
        radius: f32 = 0,
    },
    border: style.BorderStyle,
    box: BoxConfig,
    constrained: struct {
        min_width: ?f32 = null,
        max_width: ?f32 = null,
        min_height: ?f32 = null,
        max_height: ?f32 = null,
        enforce_when_empty: bool = false,
    },
    alignment: struct {
        horizontal: ?style.HorizontalAlign = null,
        vertical: ?style.VerticalAlign = null,
    },
    extend: struct {
        horizontal: bool = true,
        vertical: bool = true,
    },
    shrink: struct {
        horizontal: bool = true,
        vertical: bool = true,
    },
    unconstrained,
    aspect_ratio: struct {
        ratio: f32,
        option: style.AspectRatioOption = .fit_width,
    },
    clip: struct {
        radius: f32 = 0,
    },
    transform: union(enum) {
        translate: geom.Point,
        scale: struct { x: f32, y: f32 },
        scale_to_fit,
        rotate: f32,
        rotate_right_90,
        rotate_left_90,
    },
    line: struct {
        horizontal: bool,
        thickness: f32 = 1.0,
        color: style.Color = style.Color.black,
        dash: ?style.DashPattern = null,
    },

    // Inherited context wrappers
    default_text_style: style.TextStyle,
    direction_setter: style.ContentDirection,

    // Pagination & visibility controls
    page_break,
    show_entire,
    ensure_space: struct {
        min_height: f32,
    },
    show_once,
    skip_once,
    stop_paging,
    repeat,
    show_if: struct {
        ctx: ?*const anyopaque = null,
        predicate: ShowIfPredicate,
    },

    // Navigation & semantics
    section: struct {
        name: []const u8,
    },
    section_link: struct {
        name: []const u8,
    },
    hyperlink: struct {
        url: []const u8,
    },
    debug_area: struct {
        label: []const u8,
        color: style.Color = style.Color.red_500,
    },

    // M2+ payloads (placed here so NodeId stays compact & uniform across milestones)
    text_block: te.TextBlockConfig,
    image: struct {
        ref: ImageRef,
        scaling: style.ImageScaling = .fit_width,
        target_dpi: ?f32 = null,
        quality: ?style.ImageCompressionQuality = null,
    },
    svg: struct {
        ref: SvgRef,
        scaling: style.ImageScaling = .fit_area,
    },
    svg_path: struct {
        path_data: [:0]const u8,
        color: style.Color = style.Color.black,
        stroke_width: ?f32 = null,
        fit: bool = true,
    },
    canvas: struct {
        ctx: ?*const anyopaque = null,
        draw_fn: CanvasDrawFn,
    },
    dynamic: DynamicConfig,
    semantic_tag: SemanticTagConfig,
    placeholder: struct {
        label: []const u8 = "",
    },
};

pub const Node = struct {
    payload: NodePayload,
    /// For single-child wrappers: the sole child (or `null_node`).
    /// For multi-child containers (`column`, `row`, `layers`): head of intrusive child list.
    first_child: NodeId = null_node,
    /// Tail of intrusive child list (used for O(1) append on multi-child containers).
    last_child: NodeId = null_node,
    /// Next sibling in parent's intrusive child list.
    next_sibling: NodeId = null_node,
    /// Count of direct children in intrusive list.
    child_count: u32 = 0,
    /// Index into externalized `StateStore` (assigned during pre-layout freeze).
    state_slot: u32 = null_node,
    /// Optional source code location for layout overflow diagnostics.
    source_loc: ?std.builtin.SourceLocation = null,
};

pub const CleanupEntry = struct {
    ptr: *anyopaque,
    release_fn: *const fn (*anyopaque) void,
};

/// Arena-backed immutable-after-compose flat node tree.
/// Uses a sticky error latch so builder chains stay ergonomic without per-call `try`.
pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node),
    pages: std.ArrayList(NodeId),
    text_spans: std.ArrayList(te.TextSpanItem),
    table_cols: std.ArrayList(tbl.ColumnDef),
    table_cells: std.ArrayList(tbl.TableCell),
    cleanups: std.ArrayList(CleanupEntry),
    compose_error: ?ComposeError = null,

    pub fn init(backing: std.mem.Allocator) Tree {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .nodes = .empty,
            .pages = .empty,
            .text_spans = .empty,
            .table_cols = .empty,
            .table_cells = .empty,
            .cleanups = .empty,
            .compose_error = null,
        };
    }

    pub fn deinit(self: *Tree) void {
        for (self.cleanups.items) |c| {
            c.release_fn(c.ptr);
        }
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn registerCleanup(self: *Tree, ptr: *anyopaque, release_fn: *const fn (*anyopaque) void) void {
        self.cleanups.append(self.allocator(), .{ .ptr = ptr, .release_fn = release_fn }) catch {
            release_fn(ptr);
            self.fail(error.OutOfMemory);
        };
    }

    pub inline fn allocator(self: *Tree) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub inline fn fail(self: *Tree, err: ComposeError) void {
        if (self.compose_error == null) {
            self.compose_error = err;
        }
    }

    pub inline fn checkError(self: *const Tree) ComposeError!void {
        if (self.compose_error) |err| return err;
    }

    pub fn addNode(self: *Tree, payload: NodePayload) NodeId {
        if (self.compose_error != null) return null_node;
        const id: NodeId = @intCast(self.nodes.items.len);
        self.nodes.append(self.allocator(), .{ .payload = payload }) catch {
            self.fail(error.OutOfMemory);
            return null_node;
        };
        return id;
    }

    pub fn get(self: *const Tree, id: NodeId) *const Node {
        std.debug.assert(id < self.nodes.items.len);
        return &self.nodes.items[id];
    }

    pub fn getMut(self: *Tree, id: NodeId) *Node {
        std.debug.assert(id < self.nodes.items.len);
        return &self.nodes.items[id];
    }

    /// Attaches `child` as the single child of `parent`. Records `MultipleChildrenAssigned` on overwrite.
    pub fn attachSingleChild(self: *Tree, parent: NodeId, child: NodeId) void {
        if (self.compose_error != null or parent == null_node or child == null_node) return;
        const p = self.getMut(parent);
        if (p.first_child != null_node) {
            self.fail(error.MultipleChildrenAssigned);
            return;
        }
        p.first_child = child;
        p.last_child = child;
        p.child_count = 1;
    }

    /// Appends `child` to a multi-child container (`column`, `row`, `layers`) in O(1).
    pub fn appendChild(self: *Tree, parent: NodeId, child: NodeId) void {
        if (self.compose_error != null or parent == null_node or child == null_node) return;
        const p = self.getMut(parent);
        if (p.first_child == null_node) {
            p.first_child = child;
            p.last_child = child;
            p.child_count = 1;
        } else {
            const prev_last = p.last_child;
            self.getMut(prev_last).next_sibling = child;
            p.last_child = child;
            p.child_count += 1;
        }
    }

    pub fn addPageNode(self: *Tree, cfg: PageConfig) NodeId {
        const id = self.addNode(.{ .page = cfg });
        if (id == null_node) return null_node;
        self.pages.append(self.allocator(), id) catch {
            self.fail(error.OutOfMemory);
            return null_node;
        };
        return id;
    }

    pub fn dupeStr(self: *Tree, s: []const u8) []const u8 {
        if (self.compose_error != null or s.len == 0) return "";
        return self.allocator().dupe(u8, s) catch {
            self.fail(error.OutOfMemory);
            return "";
        };
    }

    pub fn dupeStrZ(self: *Tree, s: [:0]const u8) [:0]const u8 {
        if (self.compose_error != null or s.len == 0) return "";
        return self.allocator().dupeSentinel(u8, s, 0) catch {
            self.fail(error.OutOfMemory);
            return "";
        };
    }

    pub fn dupeBytes(self: *Tree, bytes: []const u8) []const u8 {
        if (self.compose_error != null or bytes.len == 0) return &.{};
        return self.allocator().dupe(u8, bytes) catch {
            self.fail(error.OutOfMemory);
            return &.{};
        };
    }

    pub fn fmtStr(self: *Tree, comptime fmt: []const u8, args: anytype) []const u8 {
        if (self.compose_error != null) return "";
        return self.allocator().print(fmt, args) catch {
            self.fail(error.OutOfMemory);
            return "";
        };
    }

    pub fn dupeGradientStops(self: *Tree, stops: []const style.GradientStop) []const style.GradientStop {
        if (self.compose_error != null or stops.len == 0) return &.{};
        return self.allocator().dupe(style.GradientStop, stops) catch {
            self.fail(error.OutOfMemory);
            return &.{};
        };
    }

    /// Appends a `TextSpanItem` to `text_block_node`. Note: spans of a single `TextBlock` must be
    /// appended contiguously (true for scoped `RichTextBuilder` usage; falls back to copying if interleaved).
    pub fn appendTextSpan(self: *Tree, text_block_node: NodeId, item: te.TextSpanItem) void {
        if (self.compose_error != null or text_block_node == null_node) return;
        const cfg = &self.getMut(text_block_node).payload.text_block;
        if (item == .page_number) cfg.has_dynamic_page_number = true;

        if (cfg.spans_len == 0) {
            cfg.spans_start = @intCast(self.text_spans.items.len);
            self.text_spans.append(self.allocator(), item) catch {
                self.fail(error.OutOfMemory);
                return;
            };
            cfg.spans_len = 1;
            return;
        }

        const expected_end = cfg.spans_start + cfg.spans_len;
        if (expected_end == self.text_spans.items.len) {
            self.text_spans.append(self.allocator(), item) catch {
                self.fail(error.OutOfMemory);
                return;
            };
            cfg.spans_len += 1;
        } else {
            // Interleaved append (e.g. nested RichText inside inline_element): relocate old spans contiguously.
            const new_start: u32 = @intCast(self.text_spans.items.len);
            const old_len = cfg.spans_len;
            self.text_spans.ensureUnusedCapacity(self.allocator(), old_len + 1) catch {
                self.fail(error.OutOfMemory);
                return;
            };
            for (0..old_len) |i| {
                self.text_spans.appendAssumeCapacity(self.text_spans.items[cfg.spans_start + i]);
            }
            self.text_spans.appendAssumeCapacity(item);
            cfg.spans_start = new_start;
            cfg.spans_len = old_len + 1;
        }
    }

    pub inline fn getTextSpans(self: *const Tree, cfg: te.TextBlockConfig) []const te.TextSpanItem {
        if (cfg.spans_len == 0) return &.{};
        return self.text_spans.items[cfg.spans_start .. cfg.spans_start + cfg.spans_len];
    }

    pub fn addTableColumns(self: *Tree, cols: []const tbl.ColumnDef) struct { start: u32, len: u32 } {
        if (self.compose_error != null or cols.len == 0) {
            if (cols.len == 0) self.fail(error.InvalidColumnDefinition);
            return .{ .start = 0, .len = 0 };
        }
        const start: u32 = @intCast(self.table_cols.items.len);
        self.table_cols.appendSlice(self.allocator(), cols) catch {
            self.fail(error.OutOfMemory);
            return .{ .start = 0, .len = 0 };
        };
        return .{ .start = start, .len = @intCast(cols.len) };
    }

    pub fn appendTableCell(self: *Tree, section_node: NodeId, cell: tbl.TableCell) void {
        if (self.compose_error != null or section_node == null_node) return;
        const cfg = &self.getMut(section_node).payload.table_section;
        if (cfg.cells_len == 0) {
            cfg.cells_start = @intCast(self.table_cells.items.len);
            self.table_cells.append(self.allocator(), cell) catch {
                self.fail(error.OutOfMemory);
                return;
            };
            cfg.cells_len = 1;
            return;
        }
        const expected_end = cfg.cells_start + cfg.cells_len;
        if (expected_end == self.table_cells.items.len) {
            self.table_cells.append(self.allocator(), cell) catch {
                self.fail(error.OutOfMemory);
                return;
            };
            cfg.cells_len += 1;
        } else {
            const new_start: u32 = @intCast(self.table_cells.items.len);
            const old_len = cfg.cells_len;
            self.table_cells.ensureUnusedCapacity(self.allocator(), old_len + 1) catch {
                self.fail(error.OutOfMemory);
                return;
            };
            for (0..old_len) |i| {
                self.table_cells.appendAssumeCapacity(self.table_cells.items[cfg.cells_start + i]);
            }
            self.table_cells.appendAssumeCapacity(cell);
            cfg.cells_start = new_start;
            cfg.cells_len = old_len + 1;
        }
    }

    pub inline fn getTableColumns(self: *const Tree, cfg: tbl.TableSectionConfig) []const tbl.ColumnDef {
        if (cfg.cols_len == 0) return &.{};
        return self.table_cols.items[cfg.cols_start .. cfg.cols_start + cfg.cols_len];
    }

    pub inline fn getTableCells(self: *const Tree, cfg: tbl.TableSectionConfig) []const tbl.TableCell {
        if (cfg.cells_len == 0) return &.{};
        return self.table_cells.items[cfg.cells_start .. cfg.cells_start + cfg.cells_len];
    }
};
