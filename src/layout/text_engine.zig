const std = @import("std");
const geom = @import("../geometry.zig");
const style = @import("../style.zig");
const state_mod = @import("../state.zig");

pub const InlineElementAlignment = enum(u8) {
    above_baseline = 0,
    below_baseline = 1,
    top = 2,
    bottom = 3,
    middle = 4,
};

pub const PageNumberKind = enum(u8) {
    current_page,
    total_pages,
    section_begin,
    section_end,
    page_in_section,
    total_in_section,
};

/// Custom page number formatter. `page_num` is `null` during Pass 1 when unknown (return placeholder width e.g. "999").
pub const PageNumberFormatter = *const fn (ctx: ?*const anyopaque, page_num: ?u32, buf: []u8) []const u8;

pub const TextSpanItem = union(enum) {
    literal: struct {
        text: []const u8,
        style: style.TextStyle = .empty,
    },
    hyperlink: struct {
        text: []const u8,
        url: []const u8,
        style: style.TextStyle = .empty,
    },
    section_link: struct {
        text: []const u8,
        section_name: []const u8,
        style: style.TextStyle = .empty,
    },
    page_number: struct {
        kind: PageNumberKind,
        section_name: ?[]const u8 = null,
        format_ctx: ?*const anyopaque = null,
        format_fn: ?PageNumberFormatter = null,
        style: style.TextStyle = .empty,
    },
    inline_element: struct {
        child_node: u32,
        alignment: InlineElementAlignment = .above_baseline,
    },
};

pub const TextBlockConfig = struct {
    spans_start: u32 = 0,
    spans_len: u32 = 0,
    alignment: ?style.TextAlign = null,
    default_style: style.TextStyle = .empty,
    clamp_lines: ?u32 = null,
    clamp_ellipsis: [:0]const u8 = "…",
    paragraph_spacing: f32 = 0,
    first_line_indent: f32 = 0,
    has_dynamic_page_number: bool = false,
};

pub const LineMetric = struct {
    width: f32,
    height: f32,
    baseline: f32 = 0,
};

pub const TextRange = struct {
    start: u32,
    end: u32,
};

pub const ShapedLayout = struct {
    /// Opaque backend handle passed to `RenderSink.drawParagraph` (e.g. `*skia.paragraph.Paragraph`).
    handle: ?*anyopaque = null,
    lines: []const LineMetric = &.{},
    placeholder_rects: []const geom.Rect = &.{},
    /// Parallel to input `spans`: UTF-8 byte range of each link span inside the laid-out paragraph.
    span_ranges: []const TextRange = &.{},
    max_line_width: f32 = 0,
    contains_only_whitespace: bool = false,
    /// Number of codepoints that could not be mapped to any glyph (`SkParagraph::unresolvedGlyphs`).
    unresolved_glyphs: i32 = 0,
};

pub const LayoutRequest = struct {
    node_id: u32,
    is_ephemeral: bool = false,
    config: TextBlockConfig,
    spans: []const TextSpanItem,
    inherited_style: style.TextStyle,
    effective_alignment: style.TextAlign,
    direction: style.ContentDirection,
    page_ctx: *const state_mod.PageContext,
    /// Pre-measured sizes parallel to `.inline_element` occurrences in `spans`.
    inline_sizes: []const geom.Size,
    max_width: f32,
    scratch: std.mem.Allocator,
};

/// Decoupled text shaping & measurement interface.
/// Production builds use `SkiaTextEngine`; pure-Zig unit tests inject a test fake via `RenderOptions.text_engine`.
pub const TextEngine = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        layoutParagraph: *const fn (ptr: *anyopaque, req: LayoutRequest) anyerror!ShapedLayout,
        getRangeRects: *const fn (ptr: *anyopaque, handle: *anyopaque, start: u32, end: u32, scratch: std.mem.Allocator) anyerror![]const geom.Rect,
        evict: ?*const fn (ptr: *anyopaque, node_id: u32) void = null,
    };

    pub inline fn layoutParagraph(self: TextEngine, req: LayoutRequest) anyerror!ShapedLayout {
        return self.vtable.layoutParagraph(self.ptr, req);
    }

    pub inline fn getRangeRects(self: TextEngine, handle: *anyopaque, start: u32, end: u32, scratch: std.mem.Allocator) anyerror![]const geom.Rect {
        return self.vtable.getRangeRects(self.ptr, handle, start, end, scratch);
    }

    /// Releases cached backend paragraph memory for a finished non-repeating `TextBlock`.
    pub inline fn evict(self: TextEngine, node_id: u32) void {
        if (self.vtable.evict) |f| f(self.ptr, node_id);
    }
};

/// Resolves a dynamic `PageNumberKind` against `PageContext` into a printable slice in `buf`.
pub fn formatPageNumber(
    item: @FieldType(TextSpanItem, "page_number"),
    page_ctx: *const state_mod.PageContext,
    buf: []u8,
) []const u8 {
    const num: ?u32 = switch (item.kind) {
        .current_page => page_ctx.current_page,
        .total_pages => page_ctx.totalPages(),
        .section_begin => if (item.section_name) |n| (if (page_ctx.getSection(n)) |loc| loc.page_start else null) else null,
        .section_end => if (item.section_name) |n| (if (page_ctx.getSection(n)) |loc| loc.page_end else null) else null,
        .page_in_section => if (item.section_name) |n| (if (page_ctx.getSection(n)) |loc|
            (if (page_ctx.current_page >= loc.page_start) page_ctx.current_page - loc.page_start + 1 else 1)
        else
            null) else null,
        .total_in_section => if (item.section_name) |n| (if (page_ctx.getSection(n)) |loc| loc.pageCount() else null) else null,
    };

    if (item.format_fn) |fmt_fn| {
        return fmt_fn(item.format_ctx, num, buf);
    }
    if (num) |v| {
        return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0";
    }
    // Pass 1 placeholder of typical width (matches QuestPDF)
    return "000";
}
