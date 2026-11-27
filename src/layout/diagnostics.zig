const std = @import("std");
const geom = @import("../geometry.zig");
const tree_mod = @import("../tree.zig");
const state_mod = @import("../state.zig");
const sp = @import("space_plan.zig");

const NodeId = tree_mod.NodeId;
const null_node = tree_mod.null_node;

/// Structured overflow diagnostic report produced when `error.LayoutOverflow` occurs.
pub const LayoutDiagnostic = struct {
    allocator: std.mem.Allocator,
    page_number: u32 = 0,
    reason: []const u8 = "",
    report: []u8 = &.{},

    pub fn deinit(self: *LayoutDiagnostic) void {
        if (self.report.len > 0) self.allocator.free(self.report);
        self.report = &.{};
    }
};

pub fn nodeKindName(payload: tree_mod.NodePayload) []const u8 {
    return switch (payload) {
        .empty => "Empty",
        .container => "Container",
        .page => "Page",
        .column => "Column",
        .row => "Row",
        .row_item => "RowItem",
        .decoration => "Decoration",
        .layers => "Layers",
        .layer => "Layer",
        .inlined => "Inlined",
        .multi_column => "MultiColumn",
        .table_section => "TableSection",
        .padding => "Padding",
        .background => "Background",
        .border => "Border",
        .box => "Box",
        .constrained => "Constrained",
        .alignment => "Alignment",
        .extend => "Extend",
        .shrink => "Shrink",
        .unconstrained => "Unconstrained",
        .aspect_ratio => "AspectRatio",
        .clip => "Clip",
        .transform => "Transform",
        .line => "Line",
        .default_text_style => "DefaultTextStyle",
        .direction_setter => "Direction",
        .page_break => "PageBreak",
        .show_entire => "ShowEntire",
        .ensure_space => "EnsureSpace",
        .show_once => "ShowOnce",
        .skip_once => "SkipOnce",
        .stop_paging => "StopPaging",
        .repeat => "Repeat",
        .show_if => "ShowIf",
        .section => "Section",
        .section_link => "SectionLink",
        .hyperlink => "Hyperlink",
        .debug_area => "DebugArea",
        .text_block => "TextBlock",
        .image => "Image",
        .svg => "Svg",
        .svg_path => "SvgPath",
        .canvas => "Canvas",
        .dynamic => "Dynamic",
        .semantic_tag => "SemanticTag",
        .placeholder => "Placeholder",
    };
}

/// Formats a readable subtree trace identifying the root-cause node(s) returning `SpacePlanKind.wrap`.
pub fn formatOverflowReport(
    allocator: std.mem.Allocator,
    tree: *const tree_mod.Tree,
    ctx: anytype,
    root_page: NodeId,
    page_number: u32,
    root_reason: ?[]const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const header = try allocator.print(
        "LayoutOverflow on page {d}: {s}\nConstraint trace:\n",
        .{ page_number, root_reason orelse "conflicting size constraints" },
    );
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    try traceNode(allocator, &out, tree, ctx, root_page, geom.Size.max, 0, 24);
    return out.toOwnedSlice(allocator);
}

fn traceNode(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tree: *const tree_mod.Tree,
    ctx: anytype,
    id: NodeId,
    available: geom.Size,
    depth: usize,
    max_depth: usize,
) !void {
    if (id == null_node or depth > max_depth) return;

    const node = tree.get(id);
    const plan: sp.SpacePlan = ctx.measure(id, available);

    for (0..depth) |_| try out.appendSlice(allocator, "  ");
    const badge = switch (plan.kind) {
        .wrap => "[WRAP]",
        .partial_render => "[PARTIAL]",
        .full_render => "[FULL]",
        .empty => "[EMPTY]",
    };

    const line = try allocator.print(
        "{s} {s} (avail={d:.1}x{d:.1} -> {d:.1}x{d:.1})",
        .{ badge, nodeKindName(node.payload), available.width, available.height, plan.size.width, plan.size.height },
    );
    defer allocator.free(line);
    try out.appendSlice(allocator, line);

    if (node.source_loc) |loc| {
        const src_str = try allocator.print(" @ {s}:{d}", .{ loc.file, loc.line });
        defer allocator.free(src_str);
        try out.appendSlice(allocator, src_str);
    }

    if (plan.kind == .wrap) {
        if (plan.wrap_reason) |r| {
            const r_str = try allocator.print(" -- {s}", .{r});
            defer allocator.free(r_str);
            try out.appendSlice(allocator, r_str);
        }
    }
    try out.append(allocator, '\n');

    // Only descend into wrapping / structural containers to keep the trace focused on the culprit
    if (plan.kind != .wrap) return;

    switch (node.payload) {
        .page => |p| {
            const max_sz = p.size_mode.maxSize();
            const inner = geom.Size.init(
                @max(0, max_sz.width - p.margin.totalHorizontal()),
                @max(0, max_sz.height - p.margin.totalVertical()),
            );
            if (p.header != null_node) try traceNode(allocator, out, tree, ctx, p.header, inner, depth + 1, max_depth);
            if (p.content != null_node) try traceNode(allocator, out, tree, ctx, p.content, inner, depth + 1, max_depth);
            if (p.footer != null_node) try traceNode(allocator, out, tree, ctx, p.footer, inner, depth + 1, max_depth);
        },
        .padding => |insets| {
            const inner = geom.Size.init(
                @max(0, available.width - insets.totalHorizontal()),
                @max(0, available.height - insets.totalVertical()),
            );
            try traceNode(allocator, out, tree, ctx, node.first_child, inner, depth + 1, max_depth);
        },
        .box => |b| {
            const inner = geom.Size.init(
                @max(0, available.width - b.padding.totalHorizontal()),
                @max(0, available.height - b.padding.totalVertical()),
            );
            try traceNode(allocator, out, tree, ctx, node.first_child, inner, depth + 1, max_depth);
        },
        .constrained => |c| {
            const inner = geom.Size.init(
                if (c.max_width) |mw| @min(mw, available.width) else available.width,
                if (c.max_height) |mh| @min(mh, available.height) else available.height,
            );
            try traceNode(allocator, out, tree, ctx, node.first_child, inner, depth + 1, max_depth);
        },
        .decoration => |d| {
            if (d.before != null_node) try traceNode(allocator, out, tree, ctx, d.before, available, depth + 1, max_depth);
            if (d.content != null_node) try traceNode(allocator, out, tree, ctx, d.content, available, depth + 1, max_depth);
            if (d.after != null_node) try traceNode(allocator, out, tree, ctx, d.after, available, depth + 1, max_depth);
        },
        else => {
            var child = node.first_child;
            var shown: usize = 0;
            while (child != null_node and shown < 8) : ({
                child = tree.get(child).next_sibling;
                shown += 1;
            }) {
                try traceNode(allocator, out, tree, ctx, child, available, depth + 1, max_depth);
            }
        },
    }
}
