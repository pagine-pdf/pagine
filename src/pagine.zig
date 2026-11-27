//! pagine: Idiomatic, high-performance declarative paginated document engine for Zig 0.17+ on Skia.

pub const skia = @import("skia");
pub const core = @import("core.zig");
pub const geometry = @import("geometry.zig");
pub const style = @import("style.zig");
pub const tree = @import("tree.zig");
pub const state = @import("state.zig");
pub const builder = @import("builder.zig");
pub const engine = @import("layout/engine.zig");
pub const text_engine = @import("layout/text_engine.zig");
pub const table = @import("layout/table.zig");
pub const diagnostics = @import("layout/diagnostics.zig");
pub const fonts = @import("fonts.zig");
pub const media = @import("media.zig");
pub const pdf_backend = @import("backend/pdf.zig");
pub const image_backend = @import("backend/image.zig");
pub const svg_backend = @import("backend/svg.zig");
pub const skia_canvas = @import("backend/skia_canvas.zig");
pub const skia_text = @import("backend/skia_text.zig");
pub const sink = @import("backend/sink.zig");

// Top-level ergonomic re-exports
pub const Unit = geometry.Unit;
pub const pt = geometry.pt;
pub const mm = geometry.mm;
pub const cm = geometry.cm;
pub const inch = geometry.inch;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const EdgeInsets = geometry.EdgeInsets;
pub const EdgeInput = geometry.EdgeInput;
pub const PageSize = geometry.PageSize;
pub const PageSizeMode = geometry.PageSizeMode;

pub const Color = style.Color;
pub const ContentDirection = style.ContentDirection;
pub const HorizontalAlign = style.HorizontalAlign;
pub const VerticalAlign = style.VerticalAlign;
pub const TextAlign = style.TextAlign;
pub const FontWeight = style.FontWeight;
pub const FontSlant = style.FontSlant;
pub const FontPosition = style.FontPosition;
pub const TextDecorationStyle = style.TextDecorationStyle;
pub const FontFeature = style.FontFeature;
pub const TextStyle = style.TextStyle;
pub const ResolvedTextStyle = style.ResolvedTextStyle;
pub const CornerRadius = style.CornerRadius;
pub const DashPattern = style.DashPattern;
pub const BorderStyle = style.BorderStyle;
pub const GradientStop = style.GradientStop;
pub const LinearGradient = style.LinearGradient;
pub const ShadowStyle = style.ShadowStyle;
pub const AspectRatioOption = style.AspectRatioOption;
pub const ImageScaling = style.ImageScaling;
pub const ImageCompressionQuality = style.ImageCompressionQuality;

pub const Document = builder.Document;
pub const PageBuilder = builder.PageBuilder;
pub const Slot = builder.Slot;
pub const ColumnBuilder = builder.ColumnBuilder;
pub const RowBuilder = builder.RowBuilder;
pub const DecorationBuilder = builder.DecorationBuilder;
pub const LayersBuilder = builder.LayersBuilder;
pub const RichTextBuilder = builder.RichTextBuilder;
pub const TableBuilder = builder.TableBuilder;
pub const InlinedBuilder = builder.InlinedBuilder;
pub const MultiColumnBuilder = builder.MultiColumnBuilder;
pub const TableColumn = table.ColumnDef;
pub const CellPlacement = table.CellPlacement;
pub const InlinedAlignment = tree.InlinedAlignment;
pub const FontRegistry = fonts.FontRegistry;
pub const Image = media.Image;
pub const Svg = media.Svg;
pub const PdfOptions = pdf_backend.PdfOptions;
pub const ImageFormat = image_backend.ImageFormat;
pub const ImageRenderOptions = image_backend.ImageRenderOptions;
pub const SvgRenderOptions = svg_backend.SvgRenderOptions;
pub const RenderedPages = image_backend.RenderedPages;
pub const DynamicContextInfo = tree.DynamicContextInfo;
pub const DynamicResult = tree.DynamicResult;
pub const LayoutDiagnostic = diagnostics.LayoutDiagnostic;
pub const MergePageNumberStrategy = engine.MergePageNumberStrategy;

pub const renderPdf = pdf_backend.renderPdf;
pub const mergePdf = pdf_backend.mergePdf;
pub const renderImages = image_backend.renderImages;
pub const renderSvg = svg_backend.renderSvg;

/// Typed native `skia.Canvas` escape hatch: draw custom charts, barcodes, paths, or shaders directly into any layout slot!
pub fn drawCanvas(
    slot: Slot,
    ctx: anytype,
    comptime draw_fn: fn (@TypeOf(ctx), skia.Canvas, Size) void,
) void {
    const CtxPtr = @TypeOf(ctx);
    comptime if (@typeInfo(CtxPtr) != .pointer and CtxPtr != void) {
        @compileError("drawCanvas ctx must be a pointer (e.g. &my_data) or void");
    };
    const Trampoline = struct {
        fn call(raw_ctx: ?*const anyopaque, raw_canvas: *anyopaque, sz: Size) void {
            const canvas: skia.Canvas = .{ .ptr = @ptrCast(@alignCast(raw_canvas)) };
            if (CtxPtr == void) {
                draw_fn({}, canvas, sz);
            } else {
                const typed: CtxPtr = @ptrCast(@alignCast(raw_ctx.?));
                draw_fn(typed, canvas, sz);
            }
        }
    };
    const raw_ptr: ?*const anyopaque = if (CtxPtr == void) null else @ptrCast(ctx);
    slot.canvasRaw(raw_ptr, Trampoline.call);
}

pub inline fn colorToSkia(col: Color) skia.Color {
    return skia_canvas.toSkiaColor(col);
}
