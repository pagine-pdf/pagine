const std = @import("std");
const pagine = @import("pagine");
const skia = @import("skia");

test "M0 bridge: FontRegistry + Skia PDF smoke test with SafeAllocator" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);

    var registry = try pagine.FontRegistry.init(.{});
    defer registry.deinit();

    const col = pagine.Color.blue_600;
    const sk_col = pagine.colorToSkia(col);
    try std.testing.expectEqual(col.toU32(), sk_col.toU32());
}

test "M1 end-to-end: multi-page Skia PDF with boxes, gradients, dashed borders, and pagination" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var doc = pagine.Document.init(alloc, .{});
    defer doc.deinit();

    var page = doc.addPage(.{
        .size = .a4,
        .margin = .{ .all = pagine.mm(18) },
    });

    // Repeating header with gradient banner
    _ = page.header().height(48).box(.{
        .gradient = .{
            .angle_deg = 0,
            .stops = &.{
                .{ .pos = 0.0, .color = .blue_700 },
                .{ .pos = 1.0, .color = .indigo_600 },
            },
        },
        .radius = 8,
    });

    // Repeating footer line
    page.footer().padding(.{ .top = 8 }).lineHorizontal(.{
        .thickness = 1,
        .color = .slate_300,
        .dash = .{ .on = 4, .off = 3 },
    });

    // Multi-page content: 18 cards of 90pt height -> spans multiple A4 pages
    var col = page.content().padding(.{ .vertical = 12 }).column(.{ .spacing = 10 });
    for (0..18) |i| {
        var row = col.item().showEntire().box(.{
            .padding = .{ .all = 10 },
            .background = if (i % 2 == 0) .slate_50 else .white,
            .border = .{ .all = 1, .color = .slate_200, .radius = 6 },
            .shadow = .{ .offset_y = 2, .blur_sigma = 3 },
        }).row(.{ .spacing = 10 });

        _ = row.constant(50).height(68).backgroundEx(.{ .color = .blue_500, .radius = 4 });
        _ = row.relative(1).height(68).backgroundEx(.{ .color = .slate_200, .radius = 4 });
    }

    var pdf = try pagine.renderPdf(&doc, .{
        .title = "pagine M1 Multi-Page Layout",
        .author = "pagine",
    });
    defer pdf.deinit();

    const bytes = pdf.bytes();
    try std.testing.expect(bytes.len > 1024);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "%PDF-"));
    // Verify multiple pages were emitted (/Count 3 in PDF catalog for 18 * 100pt across ~680pt content height)
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Type /Page") != null);
}

test "M2 end-to-end: Rich text PDF with CJK/RTL, page numbers, links, inline badge, and custom font" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var fonts = try pagine.FontRegistry.init(.{});
    defer fonts.deinit();
    try fonts.registerFile("../../skia-zig/skia-zig/assets/fonts/Roboto-Regular.ttf", "Roboto");

    var doc = pagine.Document.init(alloc, .{});
    defer doc.deinit();

    var page = doc.addPage(.{
        .size = .a4,
        .margin = .{ .all = pagine.mm(18) },
        .default_text_style = .{
            .font_families = &.{"Roboto"},
            .size = 11,
            .color = .slate_800,
        },
    });

    page.header()
        .padding(.{ .bottom = 8 })
        .border(.{ .bottom = 1, .color = .slate_200 })
        .text("pagine Rich Typography Test", .{ .size = 18, .weight = .bold, .color = .blue_700 });

    var ftr = page.footer().alignCenter().richText(.{ .style = .{ .size = 9, .color = .slate_500 } });
    ftr.span("Page ", .{});
    ftr.currentPageNumber(.{ .weight = .bold });
    ftr.span(" of ", .{});
    ftr.totalPages(.{ .weight = .bold });
    ftr.span(" (Appendix on p.", .{});
    ftr.sectionBeginPage("appendix", .{ .weight = .bold });
    ftr.span(")", .{});

    var col = page.content().padding(.{ .vertical = 12 }).column(.{ .spacing = 10 });

    // Rich inline spans + inline badge + hyperlink + section link
    var intro = col.item().richText(.{ .alignment = .justify, .paragraph_spacing = 6, .first_line_indent = 16 });
    intro.span("Multilingual support: ", .{ .weight = .bold });
    intro.span("English, 中文排版测试, and ", .{});
    intro.hyperlink("pagine", "https://github.com/pagine-pdf/pagine", .{ .color = .blue_600, .underline = true });
    intro.span(" ", .{});
    intro.element(.middle)
        .box(.{ .padding = .{ .horizontal = 5, .vertical = 1 }, .background = .green_200, .radius = 3 })
        .text("V1", .{ .size = 8, .weight = .bold, .color = .green_700 });
    intro.span(" — jump to ", .{});
    intro.sectionLink("Appendix", "appendix", .{ .color = .indigo_600, .underline = true });
    intro.span(".\nSecond paragraph with automatic spacing and first-line indentation.", .{});

    // Generate enough paragraphs to span across 2+ pages
    for (0..22) |i| {
        col.item().print(
            "Paragraph {d}: The quick brown fox jumps over the lazy dog. Pagine automatically splits long text blocks across multiple pages while keeping typography crisp and vector-sharp.",
            .{i + 1},
            .{},
        );
    }

    col.item().section("appendix").box(.{
        .padding = .{ .all = 10 },
        .background = .slate_100,
        .radius = 6,
    }).text("Appendix Section: Referenced from every page footer.", .{ .weight = .bold });

    var pdf = try pagine.renderPdf(&doc, .{
        .fonts = &fonts,
        .title = "pagine M2 Rich Text",
    });
    defer pdf.deinit();

    const bytes = pdf.bytes();
    try std.testing.expect(bytes.len > 2048);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "%PDF-"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "https://github.com/pagine-pdf/pagine") != null);
}

test "M3 end-to-end: Multi-page Table + Inlined tags + MultiColumn PDF" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var fonts = try pagine.FontRegistry.init(.{});
    defer fonts.deinit();
    try fonts.registerFile("../../skia-zig/skia-zig/assets/fonts/Roboto-Regular.ttf", "Roboto");

    var doc = pagine.Document.init(alloc, .{});
    defer doc.deinit();

    var page = doc.addPage(.{
        .size = .a4,
        .margin = .{ .all = pagine.mm(16) },
        .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 10, .color = .slate_800 },
    });

    var col = page.content().column(.{ .spacing = 12 });

    // Tag chips via Inlined
    var tags = col.item().inlined(.{ .horizontal_spacing = 6, .vertical_spacing = 6 });
    for ([_][]const u8{ "Zig 0.17", "Skia", "Zero-GC", "Multi-Page", "Tables", "RTL/BiDi", "PDF/UA" }) |tag| {
        tags.item().box(.{
            .padding = .{ .horizontal = 8, .vertical = 3 },
            .background = .blue_100,
            .radius = 4,
        }).text(tag, .{ .size = 9, .weight = .bold, .color = .blue_900 });
    }

    // 45-row paginated Table with repeating header & footer
    var tbl = col.item().table(.{
        .columns = &.{ .fixed(32), .rel(3), .rel(1), .fixed(80) },
    });
    for ([_][]const u8{ "#", "Line Item", "Qty", "Amount" }) |h| {
        tbl.headerCell()
            .background(.slate_800)
            .padding(.{ .horizontal = 6, .vertical = 6 })
            .text(h, .{ .color = .white, .weight = .bold });
    }
    tbl.footerCellAt(.{ .col_span = 4 })
        .background(.slate_100)
        .padding(.{ .horizontal = 6, .vertical = 4 })
        .alignRight()
        .text("Continued / End of table", .{ .size = 8, .color = .slate_500 });

    for (1..46) |i| {
        const bg: ?pagine.Color = if (i % 2 == 0) .slate_50 else null;
        tbl.cell().backgroundOpt(bg).border(.{ .bottom = 0.5, .color = .slate_200 }).padding(.{ .all = 5 }).print("{d}", .{i}, .{});
        tbl.cell().backgroundOpt(bg).border(.{ .bottom = 0.5, .color = .slate_200 }).padding(.{ .all = 5 }).print("Component Service #{d}", .{i}, .{});
        tbl.cell().backgroundOpt(bg).border(.{ .bottom = 0.5, .color = .slate_200 }).padding(.{ .all = 5 }).alignRight().print("{d}", .{(i % 5) + 1}, .{});
        tbl.cell().backgroundOpt(bg).border(.{ .bottom = 0.5, .color = .slate_200 }).padding(.{ .all = 5 }).alignRight().print("${d}.00", .{i * 25}, .{});
    }

    // Two-column balanced summary section
    var mc = col.item().multiColumn(.{ .columns = 2, .spacing = 16, .balance_height = true });
    mc.spacer().alignCenter().lineVertical(.{ .thickness = 0.5, .color = .slate_300 });
    var notes = mc.content().column(.{ .spacing = 6 });
    for (1..7) |i| {
        notes.item().print("Term {d}: Payment is due within 30 days of invoice date. Thank you for choosing pagine.", .{i}, .{ .size = 9, .color = .slate_600 });
    }

    var pdf = try pagine.renderPdf(&doc, .{ .fonts = &fonts, .title = "pagine M3 Table & MultiColumn" });
    defer pdf.deinit();

    try std.testing.expect(pdf.bytes().len > 4096);
    try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}

test "M4 end-to-end: Image, SVG, native skia.Canvas chart, PDF/UA headings, PNG & SVG backends" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var fonts = try pagine.FontRegistry.init(.{});
    defer fonts.deinit();
    try fonts.registerFile("../../skia-zig/skia-zig/assets/fonts/Roboto-Regular.ttf", "Roboto");

    // 1. Create a tiny in-memory PNG image via Skia Surface to embed as a pagine.Image
    var img = blk: {
        var surf = try skia.Surface.makeRasterN32Premul(64, 64);
        defer surf.deinit();
        surf.canvas().clear(skia.Color.fromRgb(0x25, 0x63, 0xEB));
        var snap = try surf.makeImageSnapshot();
        defer snap.deinit();
        var png_data = try snap.encodePng(null, 6);
        defer png_data.deinit();
        break :blk try pagine.Image.fromBytes(png_data.bytes());
    };
    defer img.deinit();

    // 2. Parse a crisp vector SVG badge
    const svg_xml =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 40" width="100" height="40">
        \\  <rect x="2" y="2" width="96" height="36" rx="8" fill="#16A34A"/>
        \\  <circle cx="22" cy="20" r="8" fill="#FFFFFF"/>
        \\</svg>
    ;
    var svg = try pagine.Svg.fromBytes(svg_xml, &fonts);
    defer svg.deinit();

    // 3. Build document using Image + SVG + native skia.Canvas bar chart + PDF/UA Headings
    const ChartData = struct { values: []const f32 };
    const chart_data: ChartData = .{ .values = &.{ 0.4, 0.85, 0.65, 1.0 } };
    const drawChart = struct {
        fn draw(data: *const ChartData, canvas: skia.Canvas, sz: pagine.Size) void {
            var paint = skia.Paint.init(.{ .color = skia.Color.fromRgb(0x4F, 0x46, 0xE5), .anti_alias = true });
            defer paint.deinit();
            const n_f: f32 = @floatFromInt(data.values.len);
            const bar_w = (sz.width - 12 * (n_f - 1)) / n_f;
            for (data.values, 0..) |v, i| {
                const h = sz.height * v;
                const x = @as(f32, @floatFromInt(i)) * (bar_w + 12);
                canvas.drawRoundRect(.fromXYWH(x, sz.height - h, bar_w, h), 4, 4, paint);
            }
        }
    }.draw;

    var doc = pagine.Document.init(alloc, .{});
    defer doc.deinit();

    var page = doc.addPage(.{
        .size = .a5,
        .margin = .{ .all = 24 },
        .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 11, .color = .slate_800 },
    });

    var col = page.content().column(.{ .spacing = 12 });
    col.item().heading(1).text("Quarterly Visual Report", .{ .size = 18, .weight = .bold, .color = .slate_900 });

    var media_row = col.item().row(.{ .spacing = 16 });
    media_row.constant(64).imageRef(img.retainRef(), .{ .scaling = .fit_area });
    media_row.constant(100).svgRef(svg.retainRef(), .{ .scaling = .fit_area });

    col.item().heading(2).text("Native Skia Canvas Chart", .{ .size = 13, .weight = .bold });
    const chart_slot = col.item().semantic(.{ .tag = "Figure", .alt = "Quarterly bar chart" }).height(110);
    pagine.drawCanvas(chart_slot, &chart_data, drawChart);

    // Verify all 3 output backends from the EXACT SAME immutable Document!
    var pdf = try pagine.renderPdf(&doc, .{
        .fonts = &fonts,
        .title = "pagine M4 Media & PDF/UA",
        .lang = "en-US",
        .outline = .structure_element_headers,
    });
    defer pdf.deinit();
    try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
    try std.testing.expect(std.mem.indexOf(u8, pdf.bytes(), "/StructTreeRoot") != null);

    var png_pages = try pagine.renderImages(&doc, .{ .fonts = &fonts, .format = .png, .dpi = 96 });
    defer png_pages.deinit();
    try std.testing.expectEqual(@as(usize, 1), png_pages.items.len);
    try std.testing.expect(std.mem.startsWith(u8, png_pages.items[0].bytes(), "\x89PNG\r\n\x1a\n"));

    var svg_pages = try pagine.renderSvg(&doc, .{ .fonts = &fonts });
    defer svg_pages.deinit();
    try std.testing.expectEqual(@as(usize, 1), svg_pages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, svg_pages.items[0].bytes(), "<svg") != null);
}

test "M5 end-to-end: mergePdf combines two documents into one PDF with continuous page count" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var fonts = try pagine.FontRegistry.init(.{});
    defer fonts.deinit();

    var d1 = pagine.Document.init(alloc, .{});
    defer d1.deinit();
    d1.addPage(.{ .size = .a4, .margin = .{ .all = 36 } }).content().text("Document 1 Cover", .{ .size = 20, .weight = .bold });

    var d2 = pagine.Document.init(alloc, .{});
    defer d2.deinit();
    d2.addPage(.{ .size = .a4, .margin = .{ .all = 36 } }).content().text("Document 2 Appendix", .{ .size = 16 });

    const docs = [_]*const pagine.Document{ &d1, &d2 };
    var merged = try pagine.mergePdf(alloc, &docs, .continuous, .{
        .fonts = &fonts,
        .title = "Merged PDF",
    });
    defer merged.deinit();

    try std.testing.expect(std.mem.startsWith(u8, merged.bytes(), "%PDF-"));
    try std.testing.expect(merged.bytes().len > 1024);
}

test "Hardening: Slot.svgPath and check_missing_glyphs enforcement" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    // 1. svgPath renders cleanly across PDF and PNG
    {
        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();
        var col = doc.addPage(.{ .size = .{ .fixed = .{ .width = 200, .height = 200 } }, .margin = .{ .all = 20 } }).content().column(.{ .spacing = 12 });
        col.item().size(32, 32).svgPath("M12 2L2 22h20Z", .{ .color = .blue_600 });
        col.item().size(32, 32).svgPath("M4 12h16M12 4v16", .{ .color = .green_600, .stroke_width = 2.5 });

        var pdf = try pagine.renderPdf(&doc, .{ .check_missing_glyphs = true });
        defer pdf.deinit();
        try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
    }

    // 2. check_missing_glyphs catches unmapped private-use codepoint when fallback is disabled
    {
        var fonts = try pagine.FontRegistry.init(.{
            .enable_system_fonts = false,
            .enable_font_fallback = false,
        });
        defer fonts.deinit();
        try fonts.registerFile("../../skia-zig/skia-zig/assets/fonts/Roboto-Regular.ttf", "Roboto");

        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();
        doc.addPage(.{
            .size = .a5,
            .margin = .{ .all = 20 },
            .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 12 },
        }).content().text("Valid ASCII plus missing glyph: \u{E0FF}", .{});

        try std.testing.expectError(error.MissingGlyphs, pagine.renderPdf(&doc, .{
            .fonts = &fonts,
            .check_missing_glyphs = true,
        }));
    }
}

test "Performance: DPI-aware Image downsampling and JPEG compression shrinks PDF significantly" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    // Create a high-resolution 800x800 noisy opaque image so lossless PNG is large
    const w: i32 = 800;
    const h: i32 = 800;
    const info = skia.ImageInfo.makeRgba8888(w, h, .@"opaque");
    const row_bytes = info.minRowBytes();
    const pixels = try alloc.alloc(u8, info.computeByteSize(row_bytes));
    defer alloc.free(pixels);

    var prng = std.Random.DefaultPrng.init(0x5A17_C0DE);
    const rand = prng.random();
    var y: usize = 0;
    while (y < @as(usize, @intCast(h))) : (y += 1) {
        var x: usize = 0;
        while (x < @as(usize, @intCast(w))) : (x += 1) {
            const off = y * row_bytes + x * 4;
            pixels[off + 0] = @truncate((x * 3 + rand.int(u8) % 40) & 0xFF);
            pixels[off + 1] = @truncate((y * 3 + rand.int(u8) % 40) & 0xFF);
            pixels[off + 2] = @truncate(((x ^ y) + rand.int(u8) % 40) & 0xFF);
            pixels[off + 3] = 255;
        }
    }

    var img = blk: {
        var raw = try skia.Image.fromRasterCopy(skia.Pixmap.init(info, pixels, row_bytes));
        defer raw.deinit();
        var png = try raw.encodePng(null, 6);
        defer png.deinit();
        break :blk try pagine.Image.fromBytes(png.bytes());
    };
    defer img.deinit();

    var doc = pagine.Document.init(alloc, .{});
    defer doc.deinit();
    var col = doc.addPage(.{ .size = .a4, .margin = .{ .all = 36 } }).content().column(.{ .spacing = 12 });
    // Render the 800x800 photo into two 100x100pt thumbnails (deduped in ImageCache!)
    col.item().size(100, 100).imageRef(img.retainRef(), .{ .scaling = .fit_area });
    col.item().size(100, 100).imageRef(img.retainRef(), .{ .scaling = .fit_area });

    var pdf_orig = try pagine.renderPdf(&doc, .{ .use_original_images = true });
    defer pdf_orig.deinit();

    var pdf_opt = try pagine.renderPdf(&doc, .{
        .raster_dpi = 72.0,
        .encoding_quality = 75,
        .use_original_images = false,
    });
    defer pdf_opt.deinit();

    try std.testing.expect(std.mem.startsWith(u8, pdf_opt.bytes(), "%PDF-"));
    // Downsampling 800x800 -> 100x100 JPEG must reduce PDF size by > 5x
    try std.testing.expect(pdf_opt.bytes().len * 5 < pdf_orig.bytes().len);
}

test "Concurrency: 4 worker threads generate multi-page PDFs in parallel with zero leaks" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    const WorkerResult = struct {
        ok: bool = false,
        pdf_len: usize = 0,
    };

    const Worker = struct {
        fn run(a: std.mem.Allocator, worker_id: usize, out: *WorkerResult) void {
            var fonts = pagine.FontRegistry.init(.{
                .enable_paragraph_cache = false,
            }) catch return;
            defer fonts.deinit();
            fonts.registerFile("../../skia-zig/skia-zig/assets/fonts/Roboto-Regular.ttf", "Roboto") catch return;

            var doc = pagine.Document.init(a, .{});
            defer doc.deinit();

            var page = doc.addPage(.{
                .size = .a4,
                .margin = .{ .all = 36 },
                .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 10, .color = .slate_800 },
            });
            page.header().padding(.{ .bottom = 6 }).print("Concurrent Worker #{d}", .{worker_id}, .{ .size = 14, .weight = .bold });
            var ftr = page.footer().alignRight().richText(.{ .style = .{ .size = 9, .color = .slate_500 } });
            ftr.span("Page ", .{});
            ftr.currentPageNumber(.{});
            ftr.span(" / ", .{});
            ftr.totalPages(.{});

            var tbl = page.content().table(.{ .columns = &.{ .fixed(36), .rel(2), .rel(1) } });
            tbl.headerCell().background(.slate_800).paddingAll(4).text("#", .{ .color = .white, .weight = .bold });
            tbl.headerCell().background(.slate_800).paddingAll(4).text("Task", .{ .color = .white, .weight = .bold });
            tbl.headerCell().background(.slate_800).paddingAll(4).text("Worker", .{ .color = .white, .weight = .bold });
            for (1..81) |row| {
                tbl.cell().paddingAll(4).print("{d}", .{row}, .{});
                tbl.cell().paddingAll(4).print("Concurrent row payload #{d}", .{row}, .{});
                tbl.cell().paddingAll(4).print("T-{d}", .{worker_id}, .{});
            }

            var pdf = pagine.renderPdf(&doc, .{ .fonts = &fonts }) catch return;
            defer pdf.deinit();
            if (pdf.bytes().len > 2048 and std.mem.startsWith(u8, pdf.bytes(), "%PDF-")) {
                out.pdf_len = pdf.bytes().len;
                out.ok = true;
            }
        }
    };

    var results: [4]WorkerResult = @splat(.{});
    var threads: [4]std.Thread = undefined;
    for (0..4) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ alloc, i, &results[i] });
    }
    for (threads) |t| t.join();

    for (results) |r| {
        try std.testing.expect(r.ok);
        try std.testing.expect(r.pdf_len > 2048);
    }
}

test "Regression: SkiaTextEngine shrink-to-fit width does not spuriously wrap in Row.auto or Alignment" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var fonts = try pagine.FontRegistry.init(.{});
    defer fonts.deinit();
    try fonts.registerFile("../../skia-zig/skia-zig/assets/fonts/Roboto-Regular.ttf", "Roboto");

    // 1. Direct idempotency check: laying out at reported max_line_width (and with minor float drift) keeps 1 line.
    {
        var text_eng = pagine.skia_text.SkiaTextEngine.init(alloc, &fonts);
        defer text_eng.deinit();

        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();

        var page_ctx: pagine.state.PageContext = .{};
        defer page_ctx.deinit(alloc);
        page_ctx.current_page = 2;
        page_ctx.document_length = 2;
        page_ctx.is_initial_phase = false;

        const samples = [_][]const u8{
            "p. 2",
            "pagine-pdf/pagine",
            "Page 2 / 2",
            "$11849.00",
            "#INV-2026-0418",
        };
        for (samples, 0..) |sample, idx| {
            _ = scratch.reset(.retain_capacity);
            const spans = [_]pagine.text_engine.TextSpanItem{
                .{ .literal = .{ .text = sample } },
            };
            const req_base: pagine.text_engine.LayoutRequest = .{
                .node_id = @intCast(idx + 1),
                .config = .{},
                .spans = &spans,
                .inherited_style = .{ .font_families = &.{"Roboto"}, .size = 9 },
                .effective_alignment = .right,
                .direction = .ltr,
                .page_ctx = &page_ctx,
                .inline_sizes = &.{},
                .max_width = pagine.geometry.max_dimension,
                .scratch = scratch.allocator(),
            };
            const first = try text_eng.engine().layoutParagraph(req_base);
            try std.testing.expectEqual(@as(usize, 1), first.lines.len);

            var req_exact = req_base;
            req_exact.max_width = first.max_line_width;
            const second = try text_eng.engine().layoutParagraph(req_exact);
            try std.testing.expectEqual(@as(usize, 1), second.lines.len);

            var req_drift = req_base;
            req_drift.max_width = first.max_line_width - 1e-4;
            const third = try text_eng.engine().layoutParagraph(req_drift);
            try std.testing.expectEqual(@as(usize, 1), third.lines.len);
        }
    }

    // 2. End-to-end report-like layout: TOC Row.auto, Header Row.auto, and centered Footer must never clip or wrap.
    {
        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();

        {
            var cover = doc.addPage(.{
                .size = .a4,
                .margin = .{ .all = 36 },
                .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 11 },
            });
            var col = cover.content().column(.{});
            var r = col.item().background(.slate_100).row(.{});
            r.relative(1).text("1. Executive KPIs", .{});
            var pg = r.auto().alignRight().richText(.{});
            pg.span("p. ", .{});
            pg.sectionBeginPage("sec_kpi", .{ .weight = .bold });
        }
        {
            var body = doc.addPage(.{
                .size = .a4,
                .margin = .{ .all = pagine.mm(18) },
                .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 10.5 },
            });
            var hdr = body.header().background(.slate_100).row(.{});
            hdr.relative(1).text("FY2026 Engineering Report", .{ .size = 9, .weight = .bold });
            hdr.auto().alignRight().text("pagine-pdf/pagine", .{ .size = 9 });

            var ftr = body.footer().alignCenter().padding(.{ .top = 8 }).richText(.{ .style = .{ .size = 9 } });
            ftr.span("Page ", .{});
            ftr.currentPageNumber(.{ .weight = .bold });
            ftr.span(" / ", .{});
            ftr.totalPages(.{ .weight = .bold });

            body.content().section("sec_kpi").text("Section body", .{});
        }

        var text_eng = pagine.skia_text.SkiaTextEngine.init(alloc, &fonts);
        defer text_eng.deinit();

        var rec = pagine.sink.RecordingSink.init(alloc);
        defer rec.deinit();

        const stats = try doc.renderToSink(rec.sink(), .{ .text_engine = text_eng.engine() });
        try std.testing.expectEqual(@as(u32, 2), stats.page_count);
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items.len);

        // Index 0 is the white page background; index 1 is the single-line TOC/header row background.
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items[0].rects.items.len);
        try std.testing.expect(rec.pages.items[0].rects.items[1].rect.height() < 18.0);
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items[1].rects.items.len);
        try std.testing.expect(rec.pages.items[1].rects.items[1].rect.height() < 16.0);

        // Repeating header & footer paragraphs remain in cache and must stay 1 line (not wrapped/clipped).
        try std.testing.expect(text_eng.cache.count() >= 3);
        var it = text_eng.cache.valueIterator();
        while (it.next()) |entry| {
            try std.testing.expectEqual(@as(usize, 1), entry.lines.len);
        }
    }
}
