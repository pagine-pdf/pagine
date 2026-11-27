const std = @import("std");
const tree_mod = @import("tree.zig");
const NodeId = tree_mod.NodeId;
const null_node = tree_mod.null_node;

pub const SectionLocation = struct {
    document_id: u32,
    name: []const u8,
    page_start: u32,
    page_end: u32,

    pub inline fn pageCount(self: SectionLocation) u32 {
        return self.page_end - self.page_start + 1;
    }
};

/// Cross-pass pagination context tracking current page, total pages, and named section spans.
pub const PageContext = struct {
    is_initial_phase: bool = true,
    document_length: u32 = 0,
    current_document_id: u32 = 0,
    current_page: u32 = 0,
    locations: std.ArrayList(SectionLocation) = .empty,

    pub fn deinit(self: *PageContext, allocator: std.mem.Allocator) void {
        self.locations.deinit(allocator);
        self.* = undefined;
    }

    pub fn proceedToRenderPhase(self: *PageContext) void {
        self.is_initial_phase = false;
        self.current_page = 0;
    }

    pub fn incrementPage(self: *PageContext) void {
        self.current_page += 1;
        self.document_length = @max(self.document_length, self.current_page);
    }

    pub fn decrementPage(self: *PageContext) void {
        if (self.current_page > 0) self.current_page -= 1;
    }

    pub fn totalPages(self: *const PageContext) ?u32 {
        return if (self.is_initial_phase) null else self.document_length;
    }

    pub fn recordSectionPage(self: *PageContext, allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}!void {
        for (self.locations.items) |*loc| {
            if (loc.document_id == self.current_document_id and std.mem.eql(u8, loc.name, name)) {
                if (self.current_page > loc.page_end) loc.page_end = self.current_page;
                return;
            }
        }
        try self.locations.append(allocator, .{
            .document_id = self.current_document_id,
            .name = name,
            .page_start = self.current_page,
            .page_end = self.current_page,
        });
    }

    pub fn getSection(self: *const PageContext, name: []const u8) ?SectionLocation {
        for (self.locations.items) |loc| {
            if (loc.document_id == self.current_document_id and std.mem.eql(u8, loc.name, name)) {
                return loc;
            }
        }
        return null;
    }
};

/// Externalized flat pagination state buffer.
/// Keeps the document `Tree` 100% immutable during rendering and enables O(N) memcpy checkpoints
/// for speculative layout (`MultiColumn` height balancing, `Dynamic` components, Pass 1 -> Pass 2 reset).
pub const StateStore = struct {
    /// Soft-resettable u32 slots (e.g. Column current_index, TextBlock line index, Table current_row).
    u32_slots: []u32,
    /// Soft-resettable bool slots (e.g. RowItem is_rendered, PageBreak, Section, TableCell, Image, Dynamic).
    bool_slots: []bool,
    /// Hard-reset-only bool slots (ShowOnce, SkipOnce, EnsureSpace — preserved across RepeatContent).
    hard_bool_slots: []bool,
    /// Flat aligned byte buffer for Dynamic component user state.
    dyn_bytes: []align(16) u8,
    /// Initial snapshot of `dyn_bytes` for instant O(N) reset across passes.
    initial_dyn_bytes: []align(16) u8,
    /// Node-to-state-slot mapping (parallel to `tree.nodes`).
    node_slots: []u32,
    /// Secondary slot mapping for nodes needing both u32/bytes and bool ranges (e.g. `table_section`, `dynamic`).
    node_aux_slots: []u32,

    pub const Checkpoint = struct {
        u32_copy: []u32,
        bool_copy: []bool,
        hard_bool_copy: []bool,
        dyn_copy: []u8,
    };

    pub fn initForTree(allocator: std.mem.Allocator, tree: *const tree_mod.Tree) error{OutOfMemory}!StateStore {
        const count = tree.nodes.items.len;
        const node_slots = try allocator.alloc(u32, count);
        errdefer allocator.free(node_slots);
        @memset(node_slots, null_node);

        const node_aux_slots = try allocator.alloc(u32, count);
        errdefer allocator.free(node_aux_slots);
        @memset(node_aux_slots, null_node);

        var u32_count: u32 = 0;
        var bool_count: u32 = 0;
        var hard_bool_count: u32 = 0;
        var dyn_len: usize = 0;

        for (tree.nodes.items, 0..) |node, idx| {
            switch (node.payload) {
                .column, .inlined => {
                    node_slots[idx] = u32_count;
                    u32_count += 1;
                },
                .text_block => {
                    // 3 slots: [0]=current_line_index, [1]=@bitCast(current_top_offset), [2]=is_rendered
                    node_slots[idx] = u32_count;
                    u32_count += 3;
                },
                .table_section => |ts| {
                    // 1 u32 slot (current_row_offset: 0 => row 1) + cells_len bool slots (cell.is_rendered)
                    node_slots[idx] = u32_count;
                    u32_count += 1;
                    node_aux_slots[idx] = bool_count;
                    bool_count += ts.cells_len;
                },
                .dynamic => |dyn| {
                    // Align to 16 bytes so any Zig struct alignment is satisfied
                    dyn_len = std.mem.alignForward(usize, dyn_len, 16);
                    node_slots[idx] = @intCast(dyn_len);
                    dyn_len += dyn.initial_state.len;
                    node_aux_slots[idx] = bool_count; // is_rendered bool
                    bool_count += 1;
                },
                .row_item, .page_break, .section, .image, .svg, .svg_path, .canvas => {
                    node_slots[idx] = bool_count;
                    bool_count += 1;
                },
                .show_once, .skip_once, .ensure_space => {
                    node_slots[idx] = hard_bool_count;
                    hard_bool_count += 1;
                },
                else => {},
            }
        }

        const u32_slots = try allocator.alloc(u32, u32_count);
        errdefer allocator.free(u32_slots);
        @memset(u32_slots, 0);

        const bool_slots = try allocator.alloc(bool, bool_count);
        errdefer allocator.free(bool_slots);
        @memset(bool_slots, false);

        const hard_bool_slots = try allocator.alloc(bool, hard_bool_count);
        errdefer allocator.free(hard_bool_slots);
        @memset(hard_bool_slots, false);

        const dyn_bytes = try allocator.alignedAlloc(u8, .@"16", dyn_len);
        errdefer allocator.free(dyn_bytes);
        const initial_dyn_bytes = try allocator.alignedAlloc(u8, .@"16", dyn_len);
        errdefer allocator.free(initial_dyn_bytes);

        for (tree.nodes.items, 0..) |node, idx| {
            if (node.payload == .dynamic) {
                const dyn = node.payload.dynamic;
                const off = node_slots[idx];
                @memcpy(initial_dyn_bytes[off .. off + dyn.initial_state.len], dyn.initial_state);
            }
        }
        @memcpy(dyn_bytes, initial_dyn_bytes);

        return .{
            .u32_slots = u32_slots,
            .bool_slots = bool_slots,
            .hard_bool_slots = hard_bool_slots,
            .dyn_bytes = dyn_bytes,
            .initial_dyn_bytes = initial_dyn_bytes,
            .node_slots = node_slots,
            .node_aux_slots = node_aux_slots,
        };
    }

    pub fn deinit(self: *StateStore, allocator: std.mem.Allocator) void {
        allocator.free(self.initial_dyn_bytes);
        allocator.free(self.dyn_bytes);
        allocator.free(self.hard_bool_slots);
        allocator.free(self.bool_slots);
        allocator.free(self.u32_slots);
        allocator.free(self.node_aux_slots);
        allocator.free(self.node_slots);
        self.* = undefined;
    }

    /// Resets pagination state. Pass `hard = true` between rendering passes;
    /// pass `hard = false` when repeating a subtree (`Repeat`) across pages.
    pub fn resetAll(self: *StateStore, hard: bool) void {
        @memset(self.u32_slots, 0);
        @memset(self.bool_slots, false);
        @memcpy(self.dyn_bytes, self.initial_dyn_bytes);
        if (hard) {
            @memset(self.hard_bool_slots, false);
        }
    }

    /// Resets only the state belonging to nodes within `subtree_root` (used by `Repeat`).
    pub fn resetSubtree(self: *StateStore, tree: *const tree_mod.Tree, root: NodeId, hard: bool) void {
        if (root == null_node) return;
        const node = tree.get(root);
        const slot = self.node_slots[root];
        if (slot != null_node) {
            switch (node.payload) {
                .column, .inlined => self.u32_slots[slot] = 0,
                .text_block => {
                    self.u32_slots[slot] = 0;
                    self.u32_slots[slot + 1] = 0;
                    self.u32_slots[slot + 2] = 0;
                },
                .table_section => |ts| {
                    self.u32_slots[slot] = 0;
                    const aux = self.node_aux_slots[root];
                    @memset(self.bool_slots[aux .. aux + ts.cells_len], false);
                },
                .dynamic => |dyn| {
                    const aux = self.node_aux_slots[root];
                    self.bool_slots[aux] = false;
                    @memcpy(self.dyn_bytes[slot .. slot + dyn.initial_state.len], self.initial_dyn_bytes[slot .. slot + dyn.initial_state.len]);
                },
                .row_item, .page_break, .section, .image, .svg, .svg_path, .canvas => self.bool_slots[slot] = false,
                .show_once, .skip_once, .ensure_space => if (hard) {
                    self.hard_bool_slots[slot] = false;
                },
                else => {},
            }
        }
        switch (node.payload) {
            .page => |p| {
                self.resetSubtree(tree, p.background, hard);
                self.resetSubtree(tree, p.header, hard);
                self.resetSubtree(tree, p.content, hard);
                self.resetSubtree(tree, p.footer, hard);
                self.resetSubtree(tree, p.foreground, hard);
            },
            .decoration => |d| {
                self.resetSubtree(tree, d.before, hard);
                self.resetSubtree(tree, d.content, hard);
                self.resetSubtree(tree, d.after, hard);
            },
            .multi_column => |mc| {
                self.resetSubtree(tree, mc.content, hard);
                self.resetSubtree(tree, mc.spacer, hard);
            },
            .table_section => |ts| {
                for (tree.getTableCells(ts)) |cell| {
                    self.resetSubtree(tree, cell.child, hard);
                }
            },
            .text_block => |tb| {
                for (tree.getTextSpans(tb)) |span| {
                    if (span == .inline_element) {
                        self.resetSubtree(tree, span.inline_element.child_node, hard);
                    }
                }
            },
            else => {
                var child = node.first_child;
                while (child != null_node) {
                    self.resetSubtree(tree, child, hard);
                    child = tree.get(child).next_sibling;
                }
            },
        }
    }

    pub fn checkpoint(self: *const StateStore, scratch: std.mem.Allocator) error{OutOfMemory}!Checkpoint {
        return .{
            .u32_copy = try scratch.dupe(u32, self.u32_slots),
            .bool_copy = try scratch.dupe(bool, self.bool_slots),
            .hard_bool_copy = try scratch.dupe(bool, self.hard_bool_slots),
            .dyn_copy = try scratch.dupe(u8, self.dyn_bytes),
        };
    }

    pub fn restore(self: *StateStore, cp: Checkpoint) void {
        @memcpy(self.u32_slots, cp.u32_copy);
        @memcpy(self.bool_slots, cp.bool_copy);
        @memcpy(self.hard_bool_slots, cp.hard_bool_copy);
        @memcpy(self.dyn_bytes, cp.dyn_copy);
    }

    pub inline fn getDynSlice(self: *StateStore, node: NodeId, len: usize) []u8 {
        const off = self.node_slots[node];
        return self.dyn_bytes[off .. off + len];
    }

    pub inline fn getU32(self: *const StateStore, node: NodeId) u32 {
        return self.u32_slots[self.node_slots[node]];
    }

    pub inline fn setU32(self: *StateStore, node: NodeId, val: u32) void {
        self.u32_slots[self.node_slots[node]] = val;
    }

    pub inline fn getU32At(self: *const StateStore, node: NodeId, offset: u32) u32 {
        return self.u32_slots[self.node_slots[node] + offset];
    }

    pub inline fn setU32At(self: *StateStore, node: NodeId, offset: u32, val: u32) void {
        self.u32_slots[self.node_slots[node] + offset] = val;
    }

    pub inline fn getBool(self: *const StateStore, node: NodeId) bool {
        return self.bool_slots[self.node_slots[node]];
    }

    pub inline fn setBool(self: *StateStore, node: NodeId, val: bool) void {
        self.bool_slots[self.node_slots[node]] = val;
    }

    pub inline fn getAuxBool(self: *const StateStore, node: NodeId, idx: usize) bool {
        return self.bool_slots[self.node_aux_slots[node] + idx];
    }

    pub inline fn setAuxBool(self: *StateStore, node: NodeId, idx: usize, val: bool) void {
        self.bool_slots[self.node_aux_slots[node] + idx] = val;
    }

    pub inline fn getHardBool(self: *const StateStore, node: NodeId) bool {
        return self.hard_bool_slots[self.node_slots[node]];
    }

    pub inline fn setHardBool(self: *StateStore, node: NodeId, val: bool) void {
        self.hard_bool_slots[self.node_slots[node]] = val;
    }
};
