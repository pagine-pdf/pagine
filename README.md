# pagine

[English](README.md) | [简体中文](README.zh_CN.md)

Idiomatic, high-performance **declarative paginated document engine for Zig 0.17+**, inspired by .NET's QuestPDF and powered by [skia-zig](https://github.com/skia-zig/skia-zig).

## Highlights

- **Zig-Idiomatic DX (Zero Closures, Zero Hot-Path `try`)**: Scoped builder handles (`Slot`, `ColumnBuilder`, `RowBuilder`, `TableBuilder`, `RichTextBuilder`) compose naturally with native Zig `for`, `if`, `switch`, local variables, Arena formatting (`slot.print(...)`), and sticky error collection.
- **High-Performance Architecture**:
  - Contiguous Arena-allocated flat `NodeId` tree (zero GC, O(1) teardown, cache-friendly traversal).
  - Immutable tree + externalized flat `StateStore` (`checkpoint`/`restore` via `@memcpy` — no proxy tree rewriting).
  - Two-pass pagination engine resolving `totalPages()`, section page ranges, and clickable internal links.
- **Comprehensive Layout & Pagination Toolkit**:
  - Multi-`PageSet` documents (fixed, continuous roll, flexible bounds; 5 page slots: `background`, `header`, `content`, `footer`, `foreground`) + `mergePdf` (continuous or independent page numbering).
  - Containers: `Column`, `Row` (`constant`/`relative`/`auto`), `Table` (`ColSpan`/`RowSpan` auto-placement & validation, repeating headers/footers, extend-last-cells), `Decoration`, `Layers`, `Inlined` flow-wrap, `MultiColumn` (with binary-search height balancing).
  - Pagination controls: `pageBreak`, `showEntire`, `ensureSpace`, `showOnce`, `skipOnce`, `stopPaging`, `repeat`, `showIf`, and stateful page-aware `dynamic` components.
  - Rich Typography via `SkParagraph` (HarfBuzz + ICU BiDi/RTL/CJK, style inheritance, paragraph spacing, first-line indent, line clamping, inline hyperlinks/section links, inline embedded widgets).
- **Beyond QuestPDF via Skia**:
  - Rounded corners, dashed borders, linear gradients, drop shadows, and fused `.box(...)` containers.
  - First-class typed `pagine.drawCanvas(slot, ctx, drawFn)` escape hatch exposing `skia.Canvas` directly inside layout.
  - PDF/UA accessibility structure tags (`heading(1..6)`, `semantic(...)`) & PDF Outline bookmarks.
  - Multi-backend export from the same immutable `Document`: **PDF** (incl. PDF/A & PDF/UA), **PNG / JPEG / WebP**, and per-page **SVG**.
- **Actionable Overflow Diagnostics**: Detects constraint conflicts immediately (`error.LayoutOverflow`) and formats a constraint trace with optional `@src()` file/line locations.

## Quick Start

```zig
const std = @import("std");
const pagine = @import("pagine");

pub fn buildDoc(allocator: std.mem.Allocator) !pagine.skia.Data {
    var doc = pagine.Document.init(allocator, .{});
    defer doc.deinit();

    var page = doc.addPage(.{
        .size = .a4,
        .margin = .{ .all = pagine.mm(18) },
        .default_text_style = .{ .size = 10, .color = .slate_800 },
    });

    page.header().text("Hello pagine!", .{ .size = 20, .weight = .bold, .color = .blue_700 });

    var col = page.content().padding(.{ .vertical = 12 }).column(.{ .spacing = 8 });
    col.item().text("Declarative, high-performance PDF generation in Zig 0.17.", .{});

    var ftr = page.footer().alignCenter().richText(.{});
    ftr.span("Page ", .{});
    ftr.currentPageNumber(.{ .weight = .bold });
    ftr.span(" / ", .{});
    ftr.totalPages(.{ .weight = .bold });

    return try pagine.renderPdf(&doc, .{ .title = "Hello pagine" });
}
```

## Build, Test & Benchmark

```bash
# Pure-Zig layout core unit tests (no Skia link required)
zig build test-core

# Full unit + Skia integration test suite (with SafeAllocator leak checks)
zig build test

# Build & run curated examples
zig build examples
zig build run-invoice -- /tmp/invoice.pdf
zig build run-report -- /tmp/report.pdf

# ReleaseFast throughput benchmark
zig build bench

# Formatting check
zig build fmt-check
```

## Documentation

- [Architecture & Design (中文)](docs/ARCHITECTURE.md) · [User Guide (中文)](docs/GUIDE.md) · [Progress](docs/PROGRESS.md)

## License

MIT — Copyright (c) 2026 Dacheng Gao. See [LICENSE](LICENSE).
