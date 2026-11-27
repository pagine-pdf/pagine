const std = @import("std");

/// Floating-point tolerance matching QuestPDF's layout epsilon (in points, 1/72 inch).
pub const epsilon: f32 = 1e-3;

/// Large finite bound representing unconstrained layout space (avoids Inf/NaN arithmetic).
pub const max_dimension: f32 = 14_400.0; // 200 inches (PDF spec max user-space unit)

pub const Unit = enum {
    point,
    millimeter,
    centimeter,
    inch,

    pub inline fn toPoints(self: Unit, value: f32) f32 {
        return switch (self) {
            .point => value,
            .inch => value * 72.0,
            .centimeter => value * (72.0 / 2.54),
            .millimeter => value * (72.0 / 25.4),
        };
    }

    pub inline fn fromPoints(self: Unit, pts: f32) f32 {
        return switch (self) {
            .point => pts,
            .inch => pts / 72.0,
            .centimeter => pts / (72.0 / 2.54),
            .millimeter => pts / (72.0 / 25.4),
        };
    }
};

/// Convenience unit conversion helpers returning points (1 pt = 1/72 inch).
pub inline fn pt(v: f32) f32 {
    return v;
}

pub inline fn mm(v: f32) f32 {
    return Unit.millimeter.toPoints(v);
}

pub inline fn cm(v: f32) f32 {
    return Unit.centimeter.toPoints(v);
}

pub inline fn inch(v: f32) f32 {
    return Unit.inch.toPoints(v);
}

pub inline fn approxEq(a: f32, b: f32) bool {
    return @abs(a - b) <= epsilon;
}

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero: Point = .{ .x = 0, .y = 0 };

    pub inline fn init(x: f32, y: f32) Point {
        return .{ .x = x, .y = y };
    }

    pub inline fn add(self: Point, other: Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub inline fn neg(self: Point) Point {
        return .{ .x = -self.x, .y = -self.y };
    }
};

pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,

    pub const zero: Size = .{ .width = 0, .height = 0 };
    pub const max: Size = .{ .width = max_dimension, .height = max_dimension };

    pub inline fn init(width: f32, height: f32) Size {
        return .{ .width = width, .height = height };
    }

    pub inline fn isNegative(self: Size) bool {
        return self.width < -epsilon or self.height < -epsilon;
    }

    pub inline fn isZero(self: Size) bool {
        return @abs(self.width) <= epsilon and @abs(self.height) <= epsilon;
    }

    pub inline fn eql(self: Size, other: Size) bool {
        return approxEq(self.width, other.width) and approxEq(self.height, other.height);
    }

    pub inline fn clampPositive(self: Size) Size {
        return .{
            .width = @max(0.0, self.width),
            .height = @max(0.0, self.height),
        };
    }
};

pub const Rect = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub inline fn fromXYWH(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
    }

    pub inline fn fromOriginSize(origin: Point, size: Size) Rect {
        return fromXYWH(origin.x, origin.y, size.width, size.height);
    }

    pub inline fn width(self: Rect) f32 {
        return self.right - self.left;
    }

    pub inline fn height(self: Rect) f32 {
        return self.bottom - self.top;
    }
};

/// Per-side spacing (in points) for margins and paddings.
/// Supports symmetric shorthands via `.horizontal` / `.vertical` or `.all(v)`.
pub const EdgeInsets = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub const zero: EdgeInsets = .{};

    pub inline fn all(v: f32) EdgeInsets {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub inline fn symmetric(horizontal_val: f32, vertical_val: f32) EdgeInsets {
        return .{
            .top = vertical_val,
            .right = horizontal_val,
            .bottom = vertical_val,
            .left = horizontal_val,
        };
    }

    pub inline fn horizontal(v: f32) EdgeInsets {
        return .{ .left = v, .right = v };
    }

    pub inline fn vertical(v: f32) EdgeInsets {
        return .{ .top = v, .bottom = v };
    }

    pub inline fn totalHorizontal(self: EdgeInsets) f32 {
        return self.left + self.right;
    }

    pub inline fn totalVertical(self: EdgeInsets) f32 {
        return self.top + self.bottom;
    }

    pub inline fn isZero(self: EdgeInsets) bool {
        return approxEq(self.top, 0) and approxEq(self.right, 0) and approxEq(self.bottom, 0) and approxEq(self.left, 0);
    }
};

/// Ergonomic padding/margin argument supporting both explicit sides and axis shortcuts.
pub const EdgeInput = struct {
    all: ?f32 = null,
    horizontal: ?f32 = null,
    vertical: ?f32 = null,
    top: ?f32 = null,
    right: ?f32 = null,
    bottom: ?f32 = null,
    left: ?f32 = null,

    pub inline fn resolve(self: EdgeInput) EdgeInsets {
        const base = self.all orelse 0;
        const h = self.horizontal orelse base;
        const v = self.vertical orelse base;
        return .{
            .top = self.top orelse v,
            .right = self.right orelse h,
            .bottom = self.bottom orelse v,
            .left = self.left orelse h,
        };
    }
};

/// Standard and custom page dimensions (in points, 1/72 inch).
pub const PageSize = struct {
    width: f32,
    height: f32,

    // ISO 216 A-series (portrait)
    pub const a3: PageSize = .{ .width = 841.89, .height = 1190.55 };
    pub const a4: PageSize = .{ .width = 595.28, .height = 841.89 };
    pub const a5: PageSize = .{ .width = 419.53, .height = 595.28 };
    pub const a6: PageSize = .{ .width = 297.64, .height = 419.53 };

    // ISO B-series
    pub const b4: PageSize = .{ .width = 708.66, .height = 1000.63 };
    pub const b5: PageSize = .{ .width = 498.90, .height = 708.66 };

    // North American
    pub const letter: PageSize = .{ .width = 612.0, .height = 792.0 };
    pub const legal: PageSize = .{ .width = 612.0, .height = 1008.0 };
    pub const tabloid: PageSize = .{ .width = 792.0, .height = 1224.0 };
    pub const executive: PageSize = .{ .width = 522.0, .height = 756.0 };
    pub const postcard: PageSize = .{ .width = 288.0, .height = 432.0 };

    pub inline fn custom(width: f32, height: f32, unit: Unit) PageSize {
        return .{ .width = unit.toPoints(width), .height = unit.toPoints(height) };
    }

    pub inline fn landscape(self: PageSize) PageSize {
        return .{
            .width = @max(self.width, self.height),
            .height = @min(self.width, self.height),
        };
    }

    pub inline fn portrait(self: PageSize) PageSize {
        return .{
            .width = @min(self.width, self.height),
            .height = @max(self.width, self.height),
        };
    }

    pub inline fn toSize(self: PageSize) Size {
        return .{ .width = self.width, .height = self.height };
    }
};

/// Page sizing mode: fixed size, continuous roll (fixed width, auto height), or flexible min/max bounds.
pub const PageSizeMode = union(enum) {
    fixed: PageSize,
    continuous: f32, // width in points
    flexible: struct { min: PageSize, max: PageSize },

    pub const a4: PageSizeMode = .{ .fixed = PageSize.a4 };
    pub const a4_landscape: PageSizeMode = .{ .fixed = PageSize.a4.landscape() };
    pub const letter: PageSizeMode = .{ .fixed = PageSize.letter };
    pub const letter_landscape: PageSizeMode = .{ .fixed = PageSize.letter.landscape() };
    pub const a5: PageSizeMode = .{ .fixed = PageSize.a5 };
    pub const postcard: PageSizeMode = .{ .fixed = PageSize.postcard };

    pub inline fn minSize(self: PageSizeMode) Size {
        return switch (self) {
            .fixed => |s| s.toSize(),
            .continuous => |w| .{ .width = w, .height = 0 },
            .flexible => |f| f.min.toSize(),
        };
    }

    pub inline fn maxSize(self: PageSizeMode) Size {
        return switch (self) {
            .fixed => |s| s.toSize(),
            .continuous => |w| .{ .width = w, .height = max_dimension },
            .flexible => |f| f.max.toSize(),
        };
    }
};
