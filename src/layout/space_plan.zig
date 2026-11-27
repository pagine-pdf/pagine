const geom = @import("../geometry.zig");
const Size = geom.Size;

pub const SpacePlanKind = enum(u8) {
    /// Element is empty or already completely rendered on earlier pages.
    empty,
    /// Element cannot fit (even partially) into the available space; triggers page wrap or overflow error.
    wrap,
    /// Element fits partially on this page and retains stateful content for subsequent pages.
    partial_render,
    /// Element fits completely on this page.
    full_render,
};

pub const SpacePlan = struct {
    kind: SpacePlanKind,
    size: Size = .zero,
    wrap_reason: ?[]const u8 = null,

    pub inline fn empty() SpacePlan {
        return .{ .kind = .empty, .size = .zero };
    }

    pub inline fn wrap(reason: []const u8) SpacePlan {
        return .{ .kind = .wrap, .size = .zero, .wrap_reason = reason };
    }

    pub inline fn partial(size: Size) SpacePlan {
        return .{ .kind = .partial_render, .size = size };
    }

    pub inline fn full(size: Size) SpacePlan {
        return .{ .kind = .full_render, .size = size };
    }

    pub inline fn isDone(self: SpacePlan) bool {
        return self.kind == .empty or self.kind == .full_render;
    }
};
