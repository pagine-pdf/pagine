const std = @import("std");
const geom = @import("../geometry.zig");
const style = @import("../style.zig");

pub const ColumnDef = struct {
    constant: f32 = 0,
    relative: f32 = 0,

    pub inline fn fixed(width: f32) ColumnDef {
        return .{ .constant = width, .relative = 0 };
    }

    pub inline fn rel(weight: f32) ColumnDef {
        return .{ .constant = 0, .relative = weight };
    }
};

pub const CellPlacement = struct {
    row: u32 = 0, // 1-based; 0 = auto-place
    col: u32 = 0, // 1-based; 0 = auto-place
    row_span: u32 = 1,
    col_span: u32 = 1,
};

pub const TableCell = struct {
    row: u32 = 0,
    col: u32 = 0,
    row_span: u32 = 1,
    col_span: u32 = 1,
    z_index: u32 = 0,
    child: u32,
};

pub const TableSectionConfig = struct {
    cols_start: u32 = 0,
    cols_len: u32 = 0,
    cells_start: u32 = 0,
    cells_len: u32 = 0,
    extend_last_cells_to_bottom: bool = false,
};

pub const PlannedTable = struct {
    /// Cells sorted by `(end_row, col, z_index)` for fast top-to-bottom layout.
    sorted_indices: []u32,
    starting_rows_count: u32,
    total_rows_count: u32,
    max_row_span: u32,
};

fn cellsCollide(a: TableCell, b: TableCell) bool {
    return a.col < b.col + b.col_span and
        a.col + a.col_span > b.col and
        a.row < b.row + b.row_span and
        a.row + a.row_span > b.row;
}

/// Resolves auto-placed cell coordinates (`row == 0` or `col == 0`), validates spans/overlaps,
/// and computes sorted traversal order (runs in scratch memory without mutating the immutable Tree).
pub fn planAndValidate(
    scratch: std.mem.Allocator,
    cols_count: u32,
    raw_cells: []const TableCell,
) !struct { resolved: []TableCell, plan: PlannedTable } {
    if (cols_count == 0) return error.InvalidTableConfiguration;

    const resolved = try scratch.dupe(TableCell, raw_cells);
    if (resolved.len == 0) {
        return .{
            .resolved = resolved,
            .plan = .{
                .sorted_indices = &.{},
                .starting_rows_count = 0,
                .total_rows_count = 0,
                .max_row_span = 1,
            },
        };
    }

    var window: std.ArrayList(TableCell) = .empty;
    var cur_col: u32 = 1;
    var cur_row: u32 = 1;

    for (resolved, 0..) |*cell, idx| {
        if (cell.row_span == 0 or cell.col_span == 0) return error.InvalidTableConfiguration;
        if (cell.col_span > cols_count) return error.InvalidTableConfiguration;
        cell.z_index = @intCast(idx);

        // Trim finished rows from active collision window
        if (window.items.len > @max(cols_count, 16)) {
            var write: usize = 0;
            for (window.items) |w_cell| {
                if (w_cell.row + w_cell.row_span > cur_row) {
                    window.items[write] = w_cell;
                    write += 1;
                }
            }
            window.items.len = write;
        }

        // Normalize partial explicit coordinates
        if (cell.row != 0 and cell.col == 0) cell.col = 1;
        if (cell.col != 0 and cell.row == 0) cell.row = 1;

        if (cell.row != 0 and cell.col != 0) {
            if (cell.col + cell.col_span - 1 > cols_count) return error.InvalidTableConfiguration;
            try window.append(scratch, cell.*);
            cur_col = cell.col;
            cur_row = cell.row;
            continue;
        }

        // Auto-place: scan from (cur_col, cur_row) left-to-right, top-to-bottom
        var x = cur_col;
        var y = cur_row;
        while (true) {
            if (x + cell.col_span - 1 <= cols_count) {
                cell.col = x;
                cell.row = y;
                var collides = false;
                for (window.items) |n| {
                    if (cellsCollide(cell.*, n)) {
                        collides = true;
                        break;
                    }
                }
                if (!collides) {
                    try window.append(scratch, cell.*);
                    cur_col = x;
                    cur_row = y;
                    break;
                }
            }
            x += 1;
            if (x > cols_count) {
                x = 1;
                y += 1;
            }
        }
    }

    // Validate bounds and detect any overlapping cells (explicit or auto-placed) in O(N log N)
    var starting_rows: u32 = 0;
    var total_rows: u32 = 0;
    var max_row_span: u32 = 1;

    for (resolved) |c| {
        if (c.col == 0 or c.row == 0 or c.col + c.col_span - 1 > cols_count) {
            return error.InvalidTableConfiguration;
        }
        starting_rows = @max(starting_rows, c.row);
        total_rows = @max(total_rows, c.row + c.row_span - 1);
        max_row_span = @max(max_row_span, c.row_span);
    }

    // Sweep-line overlap check sorted by (row, col): exact for arbitrary spans in O(N log N)
    {
        const row_order = try scratch.alloc(u32, resolved.len);
        for (row_order, 0..) |*slot, i| slot.* = @intCast(i);
        const RowSortCtx = struct {
            cells: []const TableCell,
            pub fn lessThan(ctx: @This(), a_idx: u32, b_idx: u32) bool {
                const a = ctx.cells[a_idx];
                const b = ctx.cells[b_idx];
                if (a.row != b.row) return a.row < b.row;
                if (a.col != b.col) return a.col < b.col;
                return a.z_index < b.z_index;
            }
        };
        std.mem.sort(u32, row_order, RowSortCtx{ .cells = resolved }, RowSortCtx.lessThan);

        const col_occupied_until = try scratch.alloc(u32, cols_count);
        @memset(col_occupied_until, 0);
        for (row_order) |ci| {
            const c = resolved[ci];
            const end_r = c.row + c.row_span - 1;
            const c_start: usize = c.col - 1;
            const c_end: usize = c_start + c.col_span;
            for (c_start..c_end) |col_idx| {
                if (col_occupied_until[col_idx] >= c.row) {
                    return error.InvalidTableConfiguration;
                }
                col_occupied_until[col_idx] = end_r;
            }
        }
    }

    const sorted = try scratch.alloc(u32, resolved.len);
    for (sorted, 0..) |*slot, i| slot.* = @intCast(i);

    const SortCtx = struct {
        cells: []const TableCell,
        pub fn lessThan(ctx: @This(), a_idx: u32, b_idx: u32) bool {
            const a = ctx.cells[a_idx];
            const b = ctx.cells[b_idx];
            const a_end = a.row + a.row_span - 1;
            const b_end = b.row + b.row_span - 1;
            if (a_end != b_end) return a_end < b_end;
            if (a.row != b.row) return a.row < b.row;
            if (a.col != b.col) return a.col < b.col;
            return a.z_index < b.z_index;
        }
    };
    std.mem.sort(u32, sorted, SortCtx{ .cells = resolved }, SortCtx.lessThan);

    return .{
        .resolved = resolved,
        .plan = .{
            .sorted_indices = sorted,
            .starting_rows_count = starting_rows,
            .total_rows_count = total_rows,
            .max_row_span = max_row_span,
        },
    };
}

/// Binary searches `sorted_indices` (ordered by ascending `end_row`) for the first entry with `end_row >= target_row`.
pub fn lowerBoundByEndRow(resolved: []const TableCell, sorted_indices: []const u32, target_row: u32) usize {
    var lo: usize = 0;
    var hi: usize = sorted_indices.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const c = resolved[sorted_indices[mid]];
        const end_r = c.row + c.row_span - 1;
        if (end_r < target_row) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// Computes cumulative column X offsets (`len = cols.len + 1`) for the given available width.
pub fn computeColumnOffsets(
    scratch: std.mem.Allocator,
    cols: []const ColumnDef,
    available_width: f32,
) !struct { offsets: []f32, total_width: f32 } {
    var const_sum: f32 = 0;
    var rel_sum: f32 = 0;
    for (cols) |c| {
        const_sum += c.constant;
        rel_sum += c.relative;
    }
    const per_rel: f32 = if (rel_sum > 0) (available_width - const_sum) / rel_sum else 0;

    const offsets = try scratch.alloc(f32, cols.len + 1);
    offsets[0] = 0;
    for (cols, 0..) |c, i| {
        const w = c.constant + c.relative * per_rel;
        offsets[i + 1] = offsets[i] + w;
    }
    return .{ .offsets = offsets, .total_width = offsets[cols.len] };
}
