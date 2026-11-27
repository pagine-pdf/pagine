const std = @import("std");
const geom = @import("geometry.zig");

/// 32-bit ARGB color (`0xAARRGGBB`), bit-identical to `skia.Color` and `SkColor`.
pub const Color = packed struct(u32) {
    b: u8 = 0,
    g: u8 = 0,
    r: u8 = 0,
    a: u8 = 0xFF,

    // Core Neutrals
    pub const transparent: Color = fromArgbU32(0x00000000);
    pub const black: Color = fromHex(0x000000);
    pub const white: Color = fromHex(0xFFFFFF);

    // Slate palette (clean document typography & UI tones)
    pub const slate_50: Color = fromHex(0xF8FAFC);
    pub const slate_100: Color = fromHex(0xF1F5F9);
    pub const slate_200: Color = fromHex(0xE2E8F0);
    pub const slate_300: Color = fromHex(0xCBD5E1);
    pub const slate_400: Color = fromHex(0x94A3B8);
    pub const slate_500: Color = fromHex(0x64748B);
    pub const slate_600: Color = fromHex(0x475569);
    pub const slate_700: Color = fromHex(0x334155);
    pub const slate_800: Color = fromHex(0x1E293B);
    pub const slate_900: Color = fromHex(0x0F172A);

    // Gray palette
    pub const gray_100: Color = fromHex(0xF3F4F6);
    pub const gray_200: Color = fromHex(0xE5E7EB);
    pub const gray_300: Color = fromHex(0xD1D5DB);
    pub const gray_500: Color = fromHex(0x6B7280);
    pub const gray_700: Color = fromHex(0x374151);
    pub const gray_900: Color = fromHex(0x111827);

    // Semantic accents
    pub const blue_50: Color = fromHex(0xEFF6FF);
    pub const blue_100: Color = fromHex(0xDBEAFE);
    pub const blue_500: Color = fromHex(0x3B82F6);
    pub const blue_600: Color = fromHex(0x2563EB);
    pub const blue_700: Color = fromHex(0x1D4ED8);
    pub const blue_900: Color = fromHex(0x1E3A8A);

    pub const green_50: Color = fromHex(0xF0FDF4);
    pub const green_200: Color = fromHex(0xBBF7D0);
    pub const green_600: Color = fromHex(0x16A34A);
    pub const green_700: Color = fromHex(0x15803D);

    pub const amber_50: Color = fromHex(0xFFFBEB);
    pub const amber_200: Color = fromHex(0xFDE68A);
    pub const amber_600: Color = fromHex(0xD97706);
    pub const amber_900: Color = fromHex(0x78350F);

    pub const red_50: Color = fromHex(0xFEF2F2);
    pub const red_200: Color = fromHex(0xFECACA);
    pub const red_500: Color = fromHex(0xEF4444);
    pub const red_600: Color = fromHex(0xDC2626);
    pub const red_700: Color = fromHex(0xB91C1C);

    pub const indigo_600: Color = fromHex(0x4F46E5);
    pub const teal_600: Color = fromHex(0x0D9488);

    pub inline fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .a = 0xFF, .r = r, .g = g, .b = b };
    }

    pub inline fn fromArgb(a: u8, r: u8, g: u8, b: u8) Color {
        return .{ .a = a, .r = r, .g = g, .b = b };
    }

    /// Creates an opaque color from a 24-bit RGB hex literal (e.g. `0x2563EB`).
    pub inline fn fromHex(rgb: u24) Color {
        return .{
            .a = 0xFF,
            .r = @truncate(rgb >> 16),
            .g = @truncate(rgb >> 8),
            .b = @truncate(rgb),
        };
    }

    pub inline fn fromArgbU32(argb: u32) Color {
        return @fromBackingInt(argb);
    }

    pub inline fn toU32(self: Color) u32 {
        return @backingInt(self);
    }

    pub inline fn withAlpha(self: Color, alpha: u8) Color {
        return .{ .a = alpha, .r = self.r, .g = self.g, .b = self.b };
    }

    pub inline fn withOpacity(self: Color, opacity: f32) Color {
        const clamped = std.math.clamp(opacity, 0.0, 1.0);
        return self.withAlpha(@intFromFloat(@round(clamped * 255.0)));
    }

    pub inline fn isTransparent(self: Color) bool {
        return self.a == 0;
    }

    pub inline fn eql(self: Color, other: Color) bool {
        return self.toU32() == other.toU32();
    }
};

pub const ContentDirection = enum(u8) {
    ltr = 0,
    rtl = 1,
};

pub const HorizontalAlign = enum(u8) {
    left,
    center,
    right,
    start,
    end,
};

pub const VerticalAlign = enum(u8) {
    top,
    middle,
    bottom,
};

pub const TextAlign = enum(u8) {
    left,
    right,
    center,
    justify,
    start,
    end,
};

pub const FontWeight = enum(i32) {
    thin = 100,
    extra_light = 200,
    light = 300,
    normal = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
};

pub const FontSlant = enum(u8) {
    upright = 0,
    italic = 1,
    oblique = 2,
};

pub const FontPosition = enum(u8) {
    normal = 0,
    superscript = 1,
    subscript = 2,
};

pub const TextDecorationStyle = enum(u8) {
    solid = 0,
    double = 1,
    dotted = 2,
    dashed = 3,
    wavy = 4,
};

pub const FontFeature = struct {
    name: [:0]const u8,
    value: i32 = 1,
};

/// Inheritable text style specification. Null fields inherit from ancestor `DefaultTextStyle`.
pub const TextStyle = struct {
    color: ?Color = null,
    background: ?Color = null,
    font_families: ?[]const [:0]const u8 = null,
    size: ?f32 = null,
    line_height: ?f32 = null,
    letter_spacing: ?f32 = null,
    word_spacing: ?f32 = null,
    weight: ?FontWeight = null,
    slant: ?FontSlant = null,
    position: ?FontPosition = null,
    underline: ?bool = null,
    strikethrough: ?bool = null,
    overline: ?bool = null,
    decoration_color: ?Color = null,
    decoration_style: ?TextDecorationStyle = null,
    decoration_thickness: ?f32 = null,
    font_features: ?[]const FontFeature = null,
    locale: ?[:0]const u8 = null,

    pub const empty: TextStyle = .{};

    /// Overlays `self` on top of `parent` (non-null fields in `self` win).
    pub fn inheritFrom(self: TextStyle, parent: TextStyle) TextStyle {
        return .{
            .color = self.color orelse parent.color,
            .background = self.background orelse parent.background,
            .font_families = self.font_families orelse parent.font_families,
            .size = self.size orelse parent.size,
            .line_height = self.line_height orelse parent.line_height,
            .letter_spacing = self.letter_spacing orelse parent.letter_spacing,
            .word_spacing = self.word_spacing orelse parent.word_spacing,
            .weight = self.weight orelse parent.weight,
            .slant = self.slant orelse parent.slant,
            .position = self.position orelse parent.position,
            .underline = self.underline orelse parent.underline,
            .strikethrough = self.strikethrough orelse parent.strikethrough,
            .overline = self.overline orelse parent.overline,
            .decoration_color = self.decoration_color orelse parent.decoration_color,
            .decoration_style = self.decoration_style orelse parent.decoration_style,
            .decoration_thickness = self.decoration_thickness orelse parent.decoration_thickness,
            .font_features = self.font_features orelse parent.font_features,
            .locale = self.locale orelse parent.locale,
        };
    }

    pub fn resolve(self: TextStyle) ResolvedTextStyle {
        const col = self.color orelse Color.black;
        return .{
            .color = col,
            .background = self.background orelse Color.transparent,
            .font_families = self.font_families orelse &.{},
            .size = self.size orelse 12.0,
            .line_height = self.line_height,
            .letter_spacing = self.letter_spacing orelse 0.0,
            .word_spacing = self.word_spacing orelse 0.0,
            .weight = self.weight orelse .normal,
            .slant = self.slant orelse .upright,
            .position = self.position orelse .normal,
            .underline = self.underline orelse false,
            .strikethrough = self.strikethrough orelse false,
            .overline = self.overline orelse false,
            .decoration_color = self.decoration_color orelse col,
            .decoration_style = self.decoration_style orelse .solid,
            .decoration_thickness = self.decoration_thickness orelse 1.0,
            .font_features = self.font_features orelse &.{},
            .locale = self.locale,
        };
    }
};

pub const ResolvedTextStyle = struct {
    color: Color,
    background: Color,
    font_families: []const [:0]const u8,
    size: f32,
    line_height: ?f32,
    letter_spacing: f32,
    word_spacing: f32,
    weight: FontWeight,
    slant: FontSlant,
    position: FontPosition,
    underline: bool,
    strikethrough: bool,
    overline: bool,
    decoration_color: Color,
    decoration_style: TextDecorationStyle,
    decoration_thickness: f32,
    font_features: []const FontFeature,
    locale: ?[:0]const u8,

    pub fn effectiveFontSize(self: ResolvedTextStyle) f32 {
        return switch (self.position) {
            .normal => self.size,
            .superscript, .subscript => self.size * 0.6,
        };
    }

    pub fn effectiveBaselineShift(self: ResolvedTextStyle) f32 {
        return switch (self.position) {
            .normal => 0.0,
            .superscript => -self.size * 0.35,
            .subscript => self.size * 0.25,
        };
    }
};

pub const CornerRadius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub const zero: CornerRadius = .{};

    pub inline fn all(r: f32) CornerRadius {
        return .{ .top_left = r, .top_right = r, .bottom_right = r, .bottom_left = r };
    }

    pub inline fn isZero(self: CornerRadius) bool {
        return geom.approxEq(self.top_left, 0) and
            geom.approxEq(self.top_right, 0) and
            geom.approxEq(self.bottom_right, 0) and
            geom.approxEq(self.bottom_left, 0);
    }

    pub inline fn isUniform(self: CornerRadius) bool {
        return geom.approxEq(self.top_left, self.top_right) and
            geom.approxEq(self.top_left, self.bottom_right) and
            geom.approxEq(self.top_left, self.bottom_left);
    }
};

pub const DashPattern = struct {
    on: f32 = 4.0,
    off: f32 = 3.0,
    phase: f32 = 0.0,
};

pub const BorderStyle = struct {
    all: ?f32 = null,
    horizontal: ?f32 = null,
    vertical: ?f32 = null,
    top: ?f32 = null,
    right: ?f32 = null,
    bottom: ?f32 = null,
    left: ?f32 = null,
    color: Color = Color.black,
    radius: f32 = 0,
    dash: ?DashPattern = null,

    pub inline fn resolvedSides(self: BorderStyle) geom.EdgeInsets {
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

pub const GradientStop = struct {
    pos: f32,
    color: Color,
};

pub const LinearGradient = struct {
    angle_deg: f32 = 0.0, // 0 = left-to-right, 90 = top-to-bottom
    stops: []const GradientStop,
};

pub const ShadowStyle = struct {
    color: Color = Color.fromArgb(0x33, 0x00, 0x00, 0x00),
    offset_x: f32 = 0,
    offset_y: f32 = 2,
    blur_sigma: f32 = 4,
};

pub const AspectRatioOption = enum(u8) {
    fit_width,
    fit_height,
    fit_area,
};

pub const ImageScaling = enum(u8) {
    fit_width,
    fit_height,
    fit_area,
    fit_unproportionally,
};

pub const ImageCompressionQuality = enum(u8) {
    very_low = 20,
    low = 40,
    medium = 60,
    high = 80,
    very_high = 90,
    best = 100,
};
