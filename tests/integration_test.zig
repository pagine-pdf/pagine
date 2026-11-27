const std = @import("std");
const pagine = @import("pagine");
const skia = @import("skia");
const support = @import("support");
const test_options = @import("test_options");

const TestAllocator = support.TestAllocator;
const RecordingSink = support.RecordingSink(pagine);
const roboto_ttf = @embedFile("roboto_ttf");

fn initRobotoFonts(opts: pagine.FontRegistry.InitOptions) !pagine.FontRegistry {
    var fonts = try pagine.FontRegistry.init(opts);
    errdefer fonts.deinit();
    try fonts.registerBytes(roboto_ttf, "Roboto");
    return fonts;
}

test "fonts: registerBytes, registerFile, error handling, and colorToSkia bridge" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var reg = try initRobotoFonts(.{});
        defer reg.deinit();
        try std.testing.expectEqual(@as(usize, 1), reg.registered_count);

        // Verify build-injected file path registration works too
        const path_z = try alloc.dupeSentinel(u8, test_options.roboto_font_path, 0);
        defer alloc.free(path_z);
        try reg.registerFile(path_z, "RobotoFromFile");
        try std.testing.expectEqual(@as(usize, 2), reg.registered_count);

        // Invalid font bytes & missing file report explicit errors
        try std.testing.expectError(error.InvalidFontData, reg.registerBytes("not a font", "Bad"));
        try std.testing.expectError(error.FontFileNotFound, reg.registerFile("/nonexistent/pagine-font.ttf", "Missing"));

        const col = pagine.Color.blue_600;
        const sk_col = pagine.colorToSkia(col);
        try std.testing.expectEqual(col.toU32(), sk_col.toU32());
    }

    try ta.expectNoLeaks();
}

test "pdf: multi-page boxes, gradients, dashed borders, and shadows emit exact page count" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();

        var page = doc.addPage(.{
            .size = .a4,
            .margin = .{ .all = pagine.mm(18) },
        });

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

        page.footer().padding(.{ .top = 8 }).lineHorizontal(.{
            .thickness = 1,
            .color = .slate_300,
            .dash = .{ .on = 4, .off = 3 },
        });

        // 18 cards of 90pt + 10pt spacing across ~680pt A4 content height => exactly 3 pages
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
            .title = "pagine Multi-Page Layout",
            .author = "pagine",
        });
        defer pdf.deinit();

        const bytes = pdf.bytes();
        try std.testing.expect(bytes.len > 1024);
        try std.testing.expect(std.mem.startsWith(u8, bytes, "%PDF-"));
        try std.testing.expectEqual(@as(usize, 3), support.countPdfPages(bytes));
    }

    try ta.expectNoLeaks();
}

test "pdf: rich text with CJK, inline badge, hyperlinks, section links, and UTF-16 Emoji link rects" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initRobotoFonts(.{});
        defer fonts.deinit();

        // 1. Direct UTF-16 surrogate pair offset check in SkiaTextEngine:
        //    Emoji (U+1F680 = 2 UTF-16 units) followed by a hyperlink span must yield a valid, non-empty rect to the right.
        {
            var text_eng = pagine.skia_text.SkiaTextEngine.init(alloc, &fonts);
            defer text_eng.deinit();

            var scratch = std.heap.ArenaAllocator.init(alloc);
            defer scratch.deinit();

            var page_ctx: pagine.state.PageContext = .{};
            defer page_ctx.deinit(alloc);
            page_ctx.current_page = 1;
            page_ctx.document_length = 1;
            page_ctx.is_initial_phase = false;

            const spans = [_]pagine.text_engine.TextSpanItem{
                .{ .literal = .{ .text = "Launch \u{1F680} " } },
                .{ .hyperlink = .{ .text = "Docs", .url = "https://example.com" } },
            };
            const shaped = try text_eng.engine().layoutParagraph(.{
                .node_id = 1,
                .config = .{},
                .spans = &spans,
                .inherited_style = .{ .font_families = &.{"Roboto"}, .size = 12 },
                .effective_alignment = .left,
                .direction = .ltr,
                .page_ctx = &page_ctx,
                .inline_sizes = &.{},
                .max_width = 400,
                .scratch = scratch.allocator(),
            });
            // "Launch " (7) + U+1F680 (2 UTF-16 units) + " " (1) = 10; "Docs" = 4 -> [10, 14)
            try std.testing.expectEqual(@as(u32, 10), shaped.span_ranges[1].start);
            try std.testing.expectEqual(@as(u32, 14), shaped.span_ranges[1].end);

            const rects = try text_eng.engine().getRangeRects(shaped.handle.?, shaped.span_ranges[1].start, shaped.span_ranges[1].end, scratch.allocator());
            try std.testing.expect(rects.len >= 1);
            try std.testing.expect(rects[0].left > 30.0);
            try std.testing.expect(rects[0].width() > 10.0);
        }

        // 2. End-to-end multi-page rich text PDF with inline badge, hyperlink, and appendix section link
        {
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
                .title = "pagine Rich Text",
            });
            defer pdf.deinit();

            const bytes = pdf.bytes();
            try std.testing.expect(std.mem.startsWith(u8, bytes, "%PDF-"));
            try std.testing.expect(support.countPdfPages(bytes) >= 2);
            try std.testing.expect(std.mem.indexOf(u8, bytes, "https://github.com/pagine-pdf/pagine") != null);
        }
    }

    try ta.expectNoLeaks();
}

test "backends: Image, SVG, svgPath, drawCanvas, PDF/UA, PNG/JPEG/WebP, SVG export, and decode errors" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initRobotoFonts(.{});
        defer fonts.deinit();

        // Corrupt media inputs must return explicit errors cleanly
        try std.testing.expectError(error.DecodeFailed, pagine.Image.fromBytes("corrupt-image-bytes"));
        try std.testing.expectError(error.SvgParseFailed, pagine.Svg.fromBytes("not xml", &fonts));

        // 1. In-memory PNG raster image
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

        // 2. Vector SVG badge
        const svg_xml =
            \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 40" width="100" height="40">
            \\  <rect x="2" y="2" width="96" height="36" rx="8" fill="#16A34A"/>
            \\  <circle cx="22" cy="20" r="8" fill="#FFFFFF"/>
            \\</svg>
        ;
        var svg = try pagine.Svg.fromBytes(svg_xml, &fonts);
        defer svg.deinit();

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
        media_row.constant(32).height(32).svgPath("M12 2L2 22h20Z", .{ .color = .blue_600 });
        media_row.constant(32).height(32).svgPath("M4 12h16M12 4v16", .{ .color = .green_600, .stroke_width = 2.5 });

        col.item().heading(2).text("Native Skia Canvas Chart", .{ .size = 13, .weight = .bold });
        const chart_slot = col.item().semantic(.{ .tag = "Figure", .alt = "Quarterly bar chart" }).height(110);
        pagine.drawCanvas(chart_slot, &chart_data, drawChart);

        // PDF with PDF/UA structure tree
        var pdf = try pagine.renderPdf(&doc, .{
            .fonts = &fonts,
            .title = "pagine Media & PDF/UA",
            .lang = "en-US",
            .outline = .structure_element_headers,
            .check_missing_glyphs = true,
        });
        defer pdf.deinit();
        try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        try std.testing.expectEqual(@as(usize, 1), support.countPdfPages(pdf.bytes()));
        try std.testing.expect(std.mem.indexOf(u8, pdf.bytes(), "/StructTreeRoot") != null);

        // PNG, JPEG, and WebP raster backends
        var png_pages = try pagine.renderImages(&doc, .{ .fonts = &fonts, .format = .png, .dpi = 96 });
        defer png_pages.deinit();
        try std.testing.expectEqual(@as(usize, 1), png_pages.items.len);
        try std.testing.expect(std.mem.startsWith(u8, png_pages.items[0].bytes(), "\x89PNG\r\n\x1a\n"));

        var jpg_pages = try pagine.renderImages(&doc, .{ .fonts = &fonts, .format = .jpeg, .dpi = 72, .quality = 80 });
        defer jpg_pages.deinit();
        try std.testing.expectEqual(@as(usize, 1), jpg_pages.items.len);
        try std.testing.expect(std.mem.startsWith(u8, jpg_pages.items[0].bytes(), "\xFF\xD8\xFF"));

        var webp_pages = try pagine.renderImages(&doc, .{ .fonts = &fonts, .format = .webp, .dpi = 72, .quality = 80 });
        defer webp_pages.deinit();
        try std.testing.expectEqual(@as(usize, 1), webp_pages.items.len);
        try std.testing.expect(std.mem.startsWith(u8, webp_pages.items[0].bytes(), "RIFF"));
        try std.testing.expect(std.mem.indexOf(u8, webp_pages.items[0].bytes()[0..16], "WEBP") != null);

        // SVG vector backend
        var svg_pages = try pagine.renderSvg(&doc, .{ .fonts = &fonts });
        defer svg_pages.deinit();
        try std.testing.expectEqual(@as(usize, 1), svg_pages.items.len);
        try std.testing.expect(std.mem.indexOf(u8, svg_pages.items[0].bytes(), "<svg") != null);
    }

    try ta.expectNoLeaks();
}

test "pdf: mergePdf combines documents in continuous and independent modes with exact page count" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initRobotoFonts(.{});
        defer fonts.deinit();

        var d1 = pagine.Document.init(alloc, .{});
        defer d1.deinit();
        {
            var p = d1.addPage(.{ .size = .a4, .margin = .{ .all = 36 }, .default_text_style = .{ .font_families = &.{"Roboto"} } });
            var ftr = p.footer().richText(.{});
            ftr.currentPageNumber(.{});
            ftr.span("/", .{});
            ftr.totalPages(.{});
            p.content().text("Document 1 Cover", .{ .size = 20, .weight = .bold });
        }

        var d2 = pagine.Document.init(alloc, .{});
        defer d2.deinit();
        {
            var p = d2.addPage(.{ .size = .a4, .margin = .{ .all = 36 }, .default_text_style = .{ .font_families = &.{"Roboto"} } });
            var ftr = p.footer().richText(.{});
            ftr.currentPageNumber(.{});
            ftr.span("/", .{});
            ftr.totalPages(.{});
            var col = p.content().column(.{});
            col.item().text("Document 2 Page 1", .{ .size = 16 });
            col.item().pageBreak();
            col.item().text("Document 2 Page 2", .{ .size = 16 });
        }

        const docs = [_]*const pagine.Document{ &d1, &d2 };
        for ([_]pagine.MergePageNumberStrategy{ .continuous, .independent }) |strategy| {
            var merged = try pagine.mergePdf(alloc, &docs, strategy, .{
                .fonts = &fonts,
                .title = "Merged PDF",
            });
            defer merged.deinit();

            try std.testing.expect(std.mem.startsWith(u8, merged.bytes(), "%PDF-"));
            try std.testing.expectEqual(@as(usize, 3), support.countPdfPages(merged.bytes()));
        }
    }

    try ta.expectNoLeaks();
}

test "fonts: check_missing_glyphs catches unmapped codepoint when fallback is disabled" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initRobotoFonts(.{
            .enable_system_fonts = false,
            .enable_font_fallback = false,
        });
        defer fonts.deinit();

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

    try ta.expectNoLeaks();
}

test "images: DPI-aware downsampling compresses opaque photos as JPEG and preserves alpha PNG" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        // 1. Opaque 800x800 noisy photo -> downsampling + JPEG compression shrinks PDF by > 5x
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

        var opaque_img = blk: {
            var raw = try skia.Image.fromRasterCopy(skia.Pixmap.init(info, pixels, row_bytes));
            defer raw.deinit();
            var png = try raw.encodePng(null, 6);
            defer png.deinit();
            break :blk try pagine.Image.fromBytes(png.bytes());
        };
        defer opaque_img.deinit();

        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();
        var col = doc.addPage(.{ .size = .a4, .margin = .{ .all = 36 } }).content().column(.{ .spacing = 12 });
        col.item().size(100, 100).imageRef(opaque_img.retainRef(), .{ .scaling = .fit_area });
        col.item().size(100, 100).imageRef(opaque_img.retainRef(), .{ .scaling = .fit_area });

        var pdf_orig = try pagine.renderPdf(&doc, .{ .use_original_images = true });
        defer pdf_orig.deinit();
        var pdf_opt = try pagine.renderPdf(&doc, .{
            .raster_dpi = 72.0,
            .encoding_quality = 75,
            .use_original_images = false,
        });
        defer pdf_opt.deinit();

        try std.testing.expect(std.mem.startsWith(u8, pdf_opt.bytes(), "%PDF-"));
        try std.testing.expect(pdf_opt.bytes().len * 5 < pdf_orig.bytes().len);

        // 2. Transparent 256x256 PNG must remain transparent (not flattened to opaque JPEG!)
        var alpha_img = blk: {
            var surf = try skia.Surface.makeRasterN32Premul(256, 256);
            defer surf.deinit();
            surf.canvas().clear(.transparent);
            var paint = skia.Paint.init(.{ .color = skia.Color.fromArgb(0x80, 0xFF, 0x00, 0x00) });
            defer paint.deinit();
            surf.canvas().drawRect(.fromXYWH(64, 64, 128, 128), paint);
            var snap = try surf.makeImageSnapshot();
            defer snap.deinit();
            var png = try snap.encodePng(null, 6);
            defer png.deinit();
            break :blk try pagine.Image.fromBytes(png.bytes());
        };
        defer alpha_img.deinit();

        var alpha_doc = pagine.Document.init(alloc, .{});
        defer alpha_doc.deinit();
        alpha_doc.addPage(.{ .size = .{ .fixed = .{ .width = 100, .height = 100 } } })
            .content()
            .size(64, 64)
            .imageRef(alpha_img.retainRef(), .{ .scaling = .fit_area });

        var pdf_alpha = try pagine.renderPdf(&alpha_doc, .{
            .raster_dpi = 72.0,
            .encoding_quality = 75,
            .use_original_images = false,
        });
        defer pdf_alpha.deinit();
        // Transparent PNG stays FlateDecode + SMask (never DCTDecode JPEG)
        try std.testing.expect(std.mem.indexOf(u8, pdf_alpha.bytes(), "/SMask") != null);
        try std.testing.expect(std.mem.indexOf(u8, pdf_alpha.bytes(), "/DCTDecode") == null);
    }

    try ta.expectNoLeaks();
}

test "snapshot cache: SkPicture enabled vs disabled renders identical raster pixels" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initRobotoFonts(.{});
        defer fonts.deinit();

        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();

        var page = doc.addPage(.{
            .size = .a5,
            .margin = .{ .all = 24 },
            .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 10, .color = .slate_800 },
        });
        page.header().padding(.{ .bottom = 6 }).text("Snapshot Equivalence Header", .{ .size = 12, .weight = .bold });
        var ftr = page.footer().alignRight().richText(.{ .style = .{ .size = 9 } });
        ftr.span("Page ", .{});
        ftr.currentPageNumber(.{});
        ftr.span(" / ", .{});
        ftr.totalPages(.{});

        // Static multi-page table body -> qualifies for Pass 1 SkPicture snapshot recording & Pass 2 replay
        var tbl = page.content().table(.{ .columns = &.{ .fixed(30), .rel(1), .fixed(60) } });
        tbl.headerCell().background(.slate_800).paddingAll(4).text("#", .{ .color = .white, .weight = .bold });
        tbl.headerCell().background(.slate_800).paddingAll(4).text("Item", .{ .color = .white, .weight = .bold });
        tbl.headerCell().background(.slate_800).paddingAll(4).alignRight().text("Price", .{ .color = .white, .weight = .bold });
        for (1..35) |i| {
            const bg: ?pagine.Color = if (i % 2 == 0) .slate_50 else null;
            tbl.cell().backgroundOpt(bg).paddingAll(4).print("{d}", .{i}, .{});
            tbl.cell().backgroundOpt(bg).paddingAll(4).print("Static Row #{d}", .{i}, .{});
            tbl.cell().backgroundOpt(bg).paddingAll(4).alignRight().print("${d}.00", .{i * 10}, .{});
        }

        var png_cached = try pagine.renderImages(&doc, .{
            .fonts = &fonts,
            .format = .png,
            .dpi = 72,
            .enable_snapshot_cache = true,
        });
        defer png_cached.deinit();

        var png_uncached = try pagine.renderImages(&doc, .{
            .fonts = &fonts,
            .format = .png,
            .dpi = 72,
            .enable_snapshot_cache = false,
        });
        defer png_uncached.deinit();

        try std.testing.expect(png_cached.items.len >= 2);
        try std.testing.expectEqual(png_uncached.items.len, png_cached.items.len);
        for (png_uncached.items, png_cached.items) |expected, actual| {
            try std.testing.expectEqualSlices(u8, expected.bytes(), actual.bytes());
        }
    }

    try ta.expectNoLeaks();
}

test "concurrency: 4 threads render both independent documents and one shared immutable Document" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    const WorkerResult = struct {
        err: ?anyerror = null,
        pdf_len: usize = 0,
        page_count: usize = 0,
    };

    const buildTableDoc = struct {
        fn build(a: std.mem.Allocator, title: []const u8) pagine.Document {
            var doc = pagine.Document.init(a, .{});
            var page = doc.addPage(.{
                .size = .a4,
                .margin = .{ .all = 36 },
                .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 10, .color = .slate_800 },
            });
            page.header().padding(.{ .bottom = 6 }).text(title, .{ .size = 14, .weight = .bold });
            var ftr = page.footer().alignRight().richText(.{ .style = .{ .size = 9, .color = .slate_500 } });
            ftr.span("Page ", .{});
            ftr.currentPageNumber(.{});
            ftr.span(" / ", .{});
            ftr.totalPages(.{});

            var tbl = page.content().table(.{ .columns = &.{ .fixed(36), .rel(2), .rel(1) } });
            tbl.headerCell().background(.slate_800).paddingAll(4).text("#", .{ .color = .white, .weight = .bold });
            tbl.headerCell().background(.slate_800).paddingAll(4).text("Task", .{ .color = .white, .weight = .bold });
            tbl.headerCell().background(.slate_800).paddingAll(4).text("Tag", .{ .color = .white, .weight = .bold });
            for (1..61) |row| {
                tbl.cell().paddingAll(4).print("{d}", .{row}, .{});
                tbl.cell().paddingAll(4).print("Concurrent row payload #{d}", .{row}, .{});
                tbl.cell().paddingAll(4).print("R-{d}", .{row % 5}, .{});
            }
            return doc;
        }
    }.build;

    // 1. Shared immutable `*const Document` rendered concurrently by 4 threads (verifies externalized StateStore)
    {
        var shared_doc = buildTableDoc(alloc, "Shared Immutable Document");
        defer shared_doc.deinit();

        const SharedWorker = struct {
            fn run(doc: *const pagine.Document, out: *WorkerResult) void {
                runInner(doc, out) catch |err| {
                    out.err = err;
                };
            }
            fn runInner(doc: *const pagine.Document, out: *WorkerResult) !void {
                var fonts = try initRobotoFonts(.{ .enable_paragraph_cache = false });
                defer fonts.deinit();
                var pdf = try pagine.renderPdf(doc, .{ .fonts = &fonts });
                defer pdf.deinit();
                if (!std.mem.startsWith(u8, pdf.bytes(), "%PDF-")) return error.InvalidPdfHeader;
                out.pdf_len = pdf.bytes().len;
                out.page_count = support.countPdfPages(pdf.bytes());
            }
        };

        var results: [4]WorkerResult = @splat(.{});
        var threads: [4]std.Thread = undefined;
        for (0..4) |i| {
            threads[i] = try std.Thread.spawn(.{}, SharedWorker.run, .{ &shared_doc, &results[i] });
        }
        for (threads) |t| t.join();

        for (results) |r| {
            if (r.err) |e| return e;
            try std.testing.expect(r.pdf_len > 2048);
            try std.testing.expectEqual(results[0].page_count, r.page_count);
            try std.testing.expect(r.page_count >= 2);
        }
    }

    // 2. Independent documents composed & rendered concurrently across 4 threads
    {
        const IndepWorker = struct {
            fn run(a: std.mem.Allocator, out: *WorkerResult) void {
                runInner(a, out) catch |err| {
                    out.err = err;
                };
            }
            fn runInner(a: std.mem.Allocator, out: *WorkerResult) !void {
                var fonts = try initRobotoFonts(.{ .enable_paragraph_cache = false });
                defer fonts.deinit();
                var doc = buildTableDoc(a, "Independent Worker Doc");
                defer doc.deinit();
                var pdf = try pagine.renderPdf(&doc, .{ .fonts = &fonts });
                defer pdf.deinit();
                if (!std.mem.startsWith(u8, pdf.bytes(), "%PDF-")) return error.InvalidPdfHeader;
                out.pdf_len = pdf.bytes().len;
                out.page_count = support.countPdfPages(pdf.bytes());
            }
        };

        var results: [4]WorkerResult = @splat(.{});
        var threads: [4]std.Thread = undefined;
        for (0..4) |i| {
            threads[i] = try std.Thread.spawn(.{}, IndepWorker.run, .{ alloc, &results[i] });
        }
        for (threads) |t| t.join();

        for (results) |r| {
            if (r.err) |e| return e;
            try std.testing.expect(r.pdf_len > 2048);
            try std.testing.expect(r.page_count >= 2);
        }
    }

    try ta.expectNoLeaks();
}

test "regression: SkiaTextEngine shrink-to-fit width does not spuriously wrap in Row.auto or Alignment" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initRobotoFonts(.{});
        defer fonts.deinit();

        // 1. Direct idempotency check via public TextEngine contract
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

        // 2. End-to-end report-like layout verified strictly via observable RecordingSink geometry
        {
            var doc = pagine.Document.init(alloc, .{});
            defer doc.deinit();

            {
                var cover = doc.addPage(.{
                    .size = .a4,
                    .margin = .{ .all = 36 },
                    .background_color = .transparent,
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
                    .background_color = .transparent,
                    .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 10.5 },
                });
                var hdr = body.header().background(.slate_100).row(.{});
                hdr.relative(1).text("FY2026 Engineering Report", .{ .size = 9, .weight = .bold });
                hdr.auto().alignRight().text("pagine-pdf/pagine", .{ .size = 9 });

                var ftr = body.footer().background(.blue_50).alignCenter().padding(.{ .top = 8 }).richText(.{ .style = .{ .size = 9 } });
                ftr.span("Page ", .{});
                ftr.currentPageNumber(.{ .weight = .bold });
                ftr.span(" / ", .{});
                ftr.totalPages(.{ .weight = .bold });

                body.content().section("sec_kpi").text("Section body", .{});
            }

            var text_eng = pagine.skia_text.SkiaTextEngine.init(alloc, &fonts);
            defer text_eng.deinit();

            var rec = RecordingSink.init(alloc);
            defer rec.deinit();

            const stats = try doc.renderToSink(rec.sink(), .{ .text_engine = text_eng.engine() });
            try std.testing.expectEqual(@as(u32, 2), stats.page_count);

            // Page 1 TOC row stays single-line (<18pt)
            try std.testing.expectEqual(@as(usize, 1), rec.pages.items[0].rects.items.len);
            try std.testing.expect(rec.pages.items[0].rects.items[0].rect.height() < 18.0);
            // Page 2 header stays single-line (<16pt) and footer (8pt top padding + 9pt line) stays single-line (<24pt)
            try std.testing.expectEqual(@as(usize, 2), rec.pages.items[1].rects.items.len);
            try std.testing.expect(rec.pages.items[1].rects.items[0].rect.height() < 16.0);
            try std.testing.expect(rec.pages.items[1].rects.items[1].rect.height() < 24.0);
        }
    }

    try ta.expectNoLeaks();
}

test "typography: letter_spacing and word_spacing use absolute point (pt) units" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initRobotoFonts(.{});
        defer fonts.deinit();

        var text_eng = pagine.skia_text.SkiaTextEngine.init(alloc, &fonts);
        defer text_eng.deinit();

        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();

        var page_ctx: pagine.state.PageContext = .{};
        defer page_ctx.deinit(alloc);
        page_ctx.current_page = 1;
        page_ctx.document_length = 1;
        page_ctx.is_initial_phase = false;
        const spans = [_]pagine.text_engine.TextSpanItem{
            .{ .literal = .{ .text = "ABCD EFGH" } },
        };

        const base_req: pagine.text_engine.LayoutRequest = .{
            .node_id = 1,
            .config = .{},
            .spans = &spans,
            .inherited_style = .{ .font_families = &.{"Roboto"}, .size = 20.0 },
            .effective_alignment = .left,
            .direction = .ltr,
            .page_ctx = &page_ctx,
            .inline_sizes = &.{},
            .max_width = pagine.geometry.max_dimension,
            .scratch = scratch.allocator(),
        };
        const base_layout = try text_eng.engine().layoutParagraph(base_req);

        // 1.0 pt letter_spacing over 9 chars adds ~9 pt total (NOT 1.0 * 20 * 9 = 180 pt).
        var ls_req = base_req;
        ls_req.node_id = 2;
        ls_req.inherited_style.letter_spacing = 1.0;
        const ls_layout = try text_eng.engine().layoutParagraph(ls_req);
        const ls_delta = ls_layout.max_line_width - base_layout.max_line_width;
        try std.testing.expect(ls_delta > 4.0 and ls_delta < 16.0);

        // 5.0 pt word_spacing over 1 space adds ~5 pt (NOT 5.0 * 20 = 100 pt).
        var ws_req = base_req;
        ws_req.node_id = 3;
        ws_req.inherited_style.word_spacing = 5.0;
        const ws_layout = try text_eng.engine().layoutParagraph(ws_req);
        const ws_delta = ws_layout.max_line_width - base_layout.max_line_width;
        try std.testing.expect(ws_delta > 2.5 and ws_delta < 10.0);
    }

    try ta.expectNoLeaks();
}
