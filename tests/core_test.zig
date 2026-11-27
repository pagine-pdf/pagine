const std = @import("std");
const core = @import("core");

test "geometry unit conversions and page sizes" {
    try std.testing.expectApproxEqAbs(@as(f32, 72.0), core.inch(1.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 28.346457), core.cm(1.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 28.346457), core.mm(10.0), 1e-3);

    const a4_land = core.PageSize.a4.landscape();
    try std.testing.expect(a4_land.width > a4_land.height);
    try std.testing.expectApproxEqAbs(core.PageSize.a4.height, a4_land.width, 1e-3);
    try std.testing.expectApproxEqAbs(core.PageSize.a4.width, a4_land.height, 1e-3);

    const insets = (core.EdgeInput{ .all = 10, .horizontal = 20, .left = 4 }).resolve();
    try std.testing.expectEqual(@as(f32, 10), insets.top);
    try std.testing.expectEqual(@as(f32, 10), insets.bottom);
    try std.testing.expectEqual(@as(f32, 20), insets.right);
    try std.testing.expectEqual(@as(f32, 4), insets.left);
}

test "color packed ARGB layout and TextStyle inheritance" {
    const c = core.Color.fromHex(0x2563EB);
    try std.testing.expectEqual(@as(u32, 0xFF2563EB), c.toU32());
    try std.testing.expectEqual(@as(u8, 0x80), c.withAlpha(0x80).a);

    const parent: core.TextStyle = .{
        .size = 11,
        .color = .slate_800,
        .weight = .normal,
        .underline = true,
    };
    const child: core.TextStyle = .{
        .weight = .bold,
        .size = 14,
    };
    const merged = child.inheritFrom(parent).resolve();
    try std.testing.expectEqual(@as(f32, 14), merged.size);
    try std.testing.expectEqual(core.FontWeight.bold, merged.weight);
    try std.testing.expect(merged.color.eql(.slate_800));
    try std.testing.expect(merged.underline);
}

test "M1: Column automatic multi-page pagination with repeating header & footer" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var doc = core.Document.init(alloc, .{});
    defer doc.deinit();

    // Page: 200x200, margin=10 -> inner=180x180
    // Header=20, Footer=20 -> content area = 180x140
    var page = doc.addPage(.{
        .size = .{ .fixed = .{ .width = 200, .height = 200 } },
        .margin = .{ .all = 10 },
        .background_color = .transparent,
    });
    _ = page.header().height(20).background(.blue_500);
    _ = page.footer().height(20).background(.slate_500);

    // 7 items * 40pt height + 5pt spacing:
    // Per page (140pt): 40 + 5 + 40 + 5 + 40 = 130 <= 140 (3 items/page) -> 3 pages (3, 3, 1)
    var col = page.content().column(.{ .spacing = 5 });
    for (0..7) |_| {
        _ = col.item().height(40).background(.green_600);
    }

    var rec = core.RecordingSink.init(alloc);
    defer rec.deinit();

    const stats = try doc.renderToSink(rec.sink(), .{});
    try std.testing.expectEqual(@as(u32, 3), stats.page_count);
    try std.testing.expectEqual(@as(usize, 3), rec.pages.items.len);

    // Page 1: header + 3 items + footer = 5 rects
    try std.testing.expectEqual(@as(usize, 5), rec.pages.items[0].rects.items.len);
    // Page 2: header + 3 items + footer = 5 rects
    try std.testing.expectEqual(@as(usize, 5), rec.pages.items[1].rects.items.len);
    // Page 3: header + 1 item + footer = 3 rects
    try std.testing.expectEqual(@as(usize, 3), rec.pages.items[2].rects.items.len);

    // Verify exact Y positions on Page 1 (margin=10, header=20, items at 30, 75, 120, footer at 170)
    const p1_rects = rec.pages.items[0].rects.items;
    try std.testing.expectApproxEqAbs(@as(f32, 10), p1_rects[0].rect.top, 0.01); // header
    try std.testing.expectApproxEqAbs(@as(f32, 30), p1_rects[1].rect.top, 0.01); // item 0
    try std.testing.expectApproxEqAbs(@as(f32, 75), p1_rects[2].rect.top, 0.01); // item 1
    try std.testing.expectApproxEqAbs(@as(f32, 120), p1_rects[3].rect.top, 0.01); // item 2
    try std.testing.expectApproxEqAbs(@as(f32, 170), p1_rects[4].rect.top, 0.01); // footer
}

test "M1: ShowOnce and SkipOnce inside repeating header across pages" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var doc = core.Document.init(alloc, .{});
    defer doc.deinit();

    var page = doc.addPage(.{
        .size = .{ .fixed = .{ .width = 200, .height = 100 } },
        .background_color = .transparent,
    });
    var hdr = page.header().column(.{});
    _ = hdr.item().showOnce().height(20).background(.red_500); // page 1 only
    _ = hdr.item().skipOnce().height(15).background(.blue_500); // page 2+

    var col = page.content().column(.{});
    _ = col.item().height(50).background(.green_600);
    col.item().pageBreak();
    _ = col.item().height(50).background(.green_600);

    var rec = core.RecordingSink.init(alloc);
    defer rec.deinit();

    const stats = try doc.renderToSink(rec.sink(), .{});
    try std.testing.expectEqual(@as(u32, 2), stats.page_count);

    // Page 1 header has red_500 (ShowOnce), Page 2 header has blue_500 (SkipOnce)
    try std.testing.expect(rec.pages.items[0].rects.items[0].color.eql(.red_500));
    try std.testing.expect(rec.pages.items[1].rects.items[0].color.eql(.blue_500));
}

test "M1: Row constant/relative/auto sizing and RTL mirroring" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var doc = core.Document.init(alloc, .{});
    defer doc.deinit();

    // LTR page width = 320, spacing = 10 (2 gaps = 20), constant = 60, auto = 40 -> relative remaining = 200 (1:3 => 50, 150)
    var p_ltr = doc.addPage(.{
        .size = .{ .fixed = .{ .width = 330, .height = 100 } },
        .background_color = .transparent,
    });
    var r = p_ltr.content().row(.{ .spacing = 10 });
    _ = r.constant(60).height(30).background(.red_500);
    _ = r.auto().size(40, 30).background(.green_600);
    _ = r.relative(1).height(30).background(.blue_500);
    _ = r.relative(3).height(30).background(.amber_600);

    // RTL page with 2 constant items (40 and 80) on 200px width
    var p_rtl = doc.addPage(.{
        .size = .{ .fixed = .{ .width = 200, .height = 100 } },
        .background_color = .transparent,
        .direction = .rtl,
    });
    var rr = p_rtl.content().row(.{ .spacing = 10 });
    _ = rr.constant(40).height(20).background(.red_500);
    _ = rr.constant(80).height(20).background(.blue_500);

    var rec = core.RecordingSink.init(alloc);
    defer rec.deinit();

    const stats = try doc.renderToSink(rec.sink(), .{});
    try std.testing.expectEqual(@as(u32, 2), stats.page_count);

    // LTR: 330 - 30(spacing) - 60 - 40 = 200 -> rel(1)=50, rel(3)=150
    const p1 = rec.pages.items[0].rects.items;
    try std.testing.expectApproxEqAbs(@as(f32, 0), p1[0].rect.left, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), p1[0].rect.width(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 70), p1[1].rect.left, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), p1[1].rect.width(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), p1[2].rect.left, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), p1[2].rect.width(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 180), p1[3].rect.left, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), p1[3].rect.width(), 0.01);

    // RTL: first item (w=40) at x=160..200, second item (w=80) at x=70..150
    const p2 = rec.pages.items[1].rects.items;
    try std.testing.expectApproxEqAbs(@as(f32, 160), p2[0].rect.left, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 70), p2[1].rect.left, 0.01);
}

test "M1: ShowEntire, EnsureSpace, ContinuousSize, LayoutOverflow, and sticky compose errors" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    // 1. ContinuousSize adjusts page height to content
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var page = doc.addPage(.{ .size = .{ .continuous = 250 }, .margin = .{ .all = 10 } });
        var col = page.content().column(.{ .spacing = 10 });
        _ = col.item().height(50).background(.blue_500);
        _ = col.item().height(70).background(.green_600);

        var rec = core.RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 1), stats.page_count);
        try std.testing.expectApproxEqAbs(@as(f32, 250), rec.pages.items[0].size.width, 0.01);
        // 10(top) + 50 + 10(spacing) + 70 + 10(bottom) = 150
        try std.testing.expectApproxEqAbs(@as(f32, 150), rec.pages.items[0].size.height, 0.01);
    }

    // 2. LayoutOverflow prevents infinite pagination loops
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var page = doc.addPage(.{ .size = .{ .fixed = .{ .width = 200, .height = 100 } } });
        _ = page.content().showEntire().height(150).background(.red_500);

        var rec = core.RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.LayoutOverflow, doc.renderToSink(rec.sink(), .{}));
    }

    // 3. Sticky error detects multiple children assigned to a single Slot
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var page = doc.addPage(.{});
        const slot = page.content();
        _ = slot.height(10);
        _ = slot.height(20);
        try std.testing.expectError(error.MultipleChildrenAssigned, doc.validate());
    }
}

test "M2: Multi-page text splitting, two-pass Page X / Y, and Section references" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var doc = core.Document.init(alloc, .{});
    defer doc.deinit();

    // 100pt wide, 90pt tall; footer=20 -> content=70pt (~4 lines of 14.4pt height per page)
    var page = doc.addPage(.{
        .size = .{ .fixed = .{ .width = 100, .height = 90 } },
        .default_text_style = .{ .size = 12 },
    });

    var ftr = page.footer().alignCenter().richText(.{});
    ftr.span("P", .{});
    ftr.currentPageNumber(.{});
    ftr.span("/", .{});
    ftr.totalPages(.{});
    ftr.span(" S:", .{});
    ftr.sectionBeginPage("ch2", .{});

    var col = page.content().column(.{});
    // Long multi-line text (~12 lines at 16 chars/line -> splits across multiple pages)
    col.item().text(
        "Line01\nLine02\nLine03\nLine04\nLine05\nLine06\nLine07\nLine08",
        .{},
    );
    var ch2 = col.item().section("ch2").richText(.{});
    ch2.hyperlink("Docs", "https://example.com", .{ .underline = true });
    ch2.span(" ", .{});
    ch2.sectionLink("Back", "ch2", .{});

    var rec = core.RecordingSink.init(alloc);
    defer rec.deinit();
    var mock_text = core.MockTextEngine.init(alloc);
    defer mock_text.deinit();

    const stats = try doc.renderToSink(rec.sink(), .{
        .text_engine = mock_text.engine(),
    });
    try std.testing.expect(stats.page_count >= 2);

    // Check Pass 2 resolved footer contains real total pages & section start page
    var found_resolved_footer = false;
    const expected_p1 = try std.fmt.allocPrint(alloc, "P1/{d} S:{d}", .{ stats.page_count, stats.page_count });
    defer alloc.free(expected_p1);
    for (mock_text.rendered_texts.items) |txt| {
        if (std.mem.eql(u8, txt, expected_p1)) {
            found_resolved_footer = true;
            break;
        }
    }
    try std.testing.expect(found_resolved_footer);

    // Verify hyperlink & section destination recorded on last page
    const last_page = rec.pages.items[rec.pages.items.len - 1];
    try std.testing.expectEqual(@as(usize, 1), last_page.urls.items.len);
    try std.testing.expectEqualStrings("https://example.com", last_page.urls.items[0]);
    try std.testing.expectEqual(@as(usize, 1), last_page.dests.items.len);
    try std.testing.expectEqualStrings("ch2", last_page.dests.items[0]);
    try std.testing.expectEqual(@as(usize, 1), last_page.links.items.len);
}

test "M3: Table multi-page pagination with repeating header, ColSpan/RowSpan, and validation" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    // 1. Multi-page table with repeating header (20pt) + footer (10pt) and 10 body rows of 30pt on 160pt page
    // Available for body per page: 160 - 20 - 10 = 130 -> 4 rows/page (120pt) -> 3 pages (4, 4, 2)
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 160 } },
            .background_color = .transparent,
        });

        var tbl = page.content().table(.{
            .columns = &.{ .fixed(40), .rel(1), .rel(1) },
        });
        // Header row (3 cells, 20pt tall)
        _ = tbl.headerCell().height(20).background(.blue_700);
        _ = tbl.headerCellAt(.{ .col_span = 2 }).height(20).background(.blue_600);
        // Footer row (spans all 3 columns, 10pt tall)
        _ = tbl.footerCellAt(.{ .col_span = 3 }).height(10).background(.slate_300);

        // 10 body rows of 30pt height
        for (0..10) |_| {
            _ = tbl.cell().height(30).background(.slate_100);
            _ = tbl.cell().height(30).background(.slate_50);
            _ = tbl.cell().height(30).background(.slate_100);
        }

        var rec = core.RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 3), stats.page_count);

        // Page 1: 2 header rects + 4*3 body rects + 1 footer rect = 15
        try std.testing.expectEqual(@as(usize, 15), rec.pages.items[0].rects.items.len);
        // Page 2: 2 header + 12 body + 1 footer = 15
        try std.testing.expectEqual(@as(usize, 15), rec.pages.items[1].rects.items.len);
        // Page 3: 2 header + 2*3 body + 1 footer = 9
        try std.testing.expectEqual(@as(usize, 9), rec.pages.items[2].rects.items.len);
    }

    // 2. RowSpan + ColSpan auto-placement & height equalization
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 200 } },
            .background_color = .transparent,
        });
        var tbl = page.content().table(.{ .columns = &.{ .rel(1), .rel(1) } });
        // Row 1-2 Col 1 spans 2 rows; Row 1 Col 2 (30pt) and Row 2 Col 2 (40pt) -> total height = 70pt
        // Background outside minHeight fills the full equalized cell height (70pt).
        _ = tbl.cellAt(.{ .row_span = 2 }).background(.blue_500).minHeight(20);
        _ = tbl.cell().height(30).background(.green_600);
        _ = tbl.cell().height(40).background(.amber_600);

        var rec = core.RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 1), stats.page_count);
        const rects = rec.pages.items[0].rects.items;
        try std.testing.expectEqual(@as(usize, 3), rects.len);
        // First cell (row_span=2) stretched to 70pt height!
        try std.testing.expectApproxEqAbs(@as(f32, 70), rects[0].rect.height(), 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 100), rects[1].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 30), rects[2].rect.top, 0.01);
    }

    // 3. Invalid ColSpan exceeding columns triggers InvalidTableConfiguration
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var page = doc.addPage(.{});
        var tbl = page.content().table(.{ .columns = &.{ .rel(1), .rel(1) } });
        _ = tbl.cellAt(.{ .col_span = 3 }).height(20);
        var rec = core.RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.InvalidTableConfiguration, doc.renderToSink(rec.sink(), .{}));
    }
}

test "M3: Inlined flow-wrap and MultiColumn balanced height pagination" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    // 1. Inlined wraps 5 chips of 50x20 into 2 lines on 160px width (3 on line 1, 2 on line 2)
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 160, .height = 100 } },
            .background_color = .transparent,
        });
        var inl = page.content().inlined(.{ .horizontal_spacing = 5, .vertical_spacing = 8 });
        for (0..5) |_| {
            _ = inl.item().size(50, 20).background(.blue_500);
        }

        var rec = core.RecordingSink.init(alloc);
        defer rec.deinit();
        _ = try doc.renderToSink(rec.sink(), .{});
        const rects = rec.pages.items[0].rects.items;
        try std.testing.expectEqual(@as(usize, 5), rects.len);
        try std.testing.expectApproxEqAbs(@as(f32, 0), rects[0].rect.top, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 55), rects[1].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 110), rects[2].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 28), rects[3].rect.top, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 0), rects[3].rect.left, 0.01);
    }

    // 2. MultiColumn with 2 columns & balance_height splits 4 items of 30pt evenly (2 left, 2 right)
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 210, .height = 300 } },
            .background_color = .transparent,
        });
        var mc = page.content().multiColumn(.{
            .columns = 2,
            .spacing = 10,
            .balance_height = true,
        });
        var col = mc.content().column(.{});
        for (0..4) |_| {
            _ = col.item().height(30).background(.indigo_600);
        }

        var rec = core.RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 1), stats.page_count);
        const rects = rec.pages.items[0].rects.items;
        try std.testing.expectEqual(@as(usize, 4), rects.len);
        // First 2 in left column (x=0), last 2 in right column (x=110)
        try std.testing.expectApproxEqAbs(@as(f32, 0), rects[0].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 0), rects[1].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 110), rects[2].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 110), rects[3].rect.left, 0.01);
    }
}

test "M4: Dynamic stateful page-aware component paginates cleanly across two passes" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    const PagedListState = struct {
        cursor: u32 = 0,
        total_items: u32 = 5,
    };

    const composeFn = struct {
        fn run(st: *PagedListState, info: core.tree.DynamicContextInfo, slot: core.Slot) core.tree.DynamicResult {
            // Emit up to 2 items per page (each 30pt tall)
            var col = slot.column(.{ .spacing = 5 });
            var emitted: u32 = 0;
            while (st.cursor < st.total_items and emitted < 2) : ({
                st.cursor += 1;
                emitted += 1;
            }) {
                const col_color: core.Color = if (info.page_number % 2 == 1) .blue_500 else .green_600;
                _ = col.item().height(30).background(col_color);
            }
            return .{ .has_more_content = st.cursor < st.total_items };
        }
    }.run;

    var doc = core.Document.init(alloc, .{});
    defer doc.deinit();
    var page = doc.addPage(.{
        .size = .{ .fixed = .{ .width = 200, .height = 100 } },
        .background_color = .transparent,
    });
    page.content().dynamic(PagedListState, .{ .total_items = 5 }, composeFn);

    var rec = core.RecordingSink.init(alloc);
    defer rec.deinit();
    const stats = try doc.renderToSink(rec.sink(), .{});
    // 5 items at 2/page -> 3 pages (2, 2, 1)
    try std.testing.expectEqual(@as(u32, 3), stats.page_count);
    try std.testing.expectEqual(@as(usize, 2), rec.pages.items[0].rects.items.len);
    try std.testing.expectEqual(@as(usize, 2), rec.pages.items[1].rects.items.len);
    try std.testing.expectEqual(@as(usize, 1), rec.pages.items[2].rects.items.len);
    try std.testing.expect(rec.pages.items[0].rects.items[0].color.eql(.blue_500));
    try std.testing.expect(rec.pages.items[1].rects.items[0].color.eql(.green_600));
}

test "M5: LayoutOverflow diagnostic trace includes root cause and @src() location" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var doc = core.Document.init(alloc, .{});
    defer doc.deinit();

    var page = doc.addPage(.{ .size = .{ .fixed = .{ .width = 200, .height = 100 } } });
    _ = page.content().source(@src()).showEntire().height(180).background(.red_500);

    var diag: core.LayoutDiagnostic = .{ .allocator = alloc };
    defer diag.deinit();

    var rec = core.RecordingSink.init(alloc);
    defer rec.deinit();

    try std.testing.expectError(error.LayoutOverflow, doc.renderToSink(rec.sink(), .{
        .diagnostic = &diag,
    }));
    try std.testing.expectEqual(@as(u32, 1), diag.page_number);
    try std.testing.expect(std.mem.indexOf(u8, diag.report, "[WRAP]") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.report, "ShowEntire") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.report, "core_test.zig") != null);
}

test "M5: Merged documents support continuous and independent page numbering" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var d1 = core.Document.init(alloc, .{});
    defer d1.deinit();
    _ = d1.addPage(.{ .size = .{ .fixed = .{ .width = 100, .height = 100 } } }).content().height(20).background(.blue_500);

    var d2 = core.Document.init(alloc, .{});
    defer d2.deinit();
    var p2 = d2.addPage(.{ .size = .{ .fixed = .{ .width = 100, .height = 100 } } });
    var col2 = p2.content().column(.{});
    _ = col2.item().height(60).background(.green_600);
    _ = col2.item().height(60).background(.green_600);

    const trees = [_]*const core.tree.Tree{ &d1.tree, &d2.tree };

    var rec = core.RecordingSink.init(alloc);
    defer rec.deinit();
    const st = try core.engine.renderMergedTrees(alloc, &trees, rec.sink(), .continuous, .{});
    try std.testing.expectEqual(@as(u32, 3), st.page_count);
    try std.testing.expectEqual(@as(usize, 3), rec.pages.items.len);
}

test "Hardening: Table detects overlapping explicit cells with InvalidTableConfiguration" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    // Case 1: Horizontal ColSpan collision
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var tbl = doc.addPage(.{ .size = .{ .fixed = .{ .width = 200, .height = 200 } } }).content().table(.{
            .columns = &.{ .rel(1), .rel(1) },
        });
        _ = tbl.cellAt(.{ .row = 1, .col = 1, .col_span = 2 }).height(20);
        _ = tbl.cellAt(.{ .row = 1, .col = 2 }).height(20);

        var rec = core.RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.InvalidTableConfiguration, doc.renderToSink(rec.sink(), .{}));
    }

    // Case 2: Vertical RowSpan collision
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var tbl = doc.addPage(.{ .size = .{ .fixed = .{ .width = 200, .height = 200 } } }).content().table(.{
            .columns = &.{ .rel(1), .rel(1) },
        });
        _ = tbl.cellAt(.{ .row = 1, .col = 1, .row_span = 2 }).height(40);
        _ = tbl.cellAt(.{ .row = 2, .col = 1 }).height(20);

        var rec = core.RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.InvalidTableConfiguration, doc.renderToSink(rec.sink(), .{}));
    }
}

test "Hardening: Table with multi-page RowSpan and nested ShowEntire/EnsureSpace" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    var doc = core.Document.init(alloc, .{});
    defer doc.deinit();

    var tbl = doc.addPage(.{
        .size = .{ .fixed = .{ .width = 200, .height = 100 } },
        .background_color = .transparent,
    }).content().table(.{
        .columns = &.{ .fixed(80), .rel(1) },
    });

    // Row 1: 45pt tall
    _ = tbl.cellAt(.{ .row = 1, .col = 1 }).background(.slate_200).minHeight(45);
    _ = tbl.cellAt(.{ .row = 1, .col = 2 }).background(.blue_500).minHeight(45);

    // Row 2-3: ShowEntire 60pt block won't fit in remaining 55pt -> moves cleanly to page 2
    _ = tbl.cellAt(.{ .row = 2, .col = 1, .row_span = 2 }).showEntire().background(.green_600).minHeight(60);
    _ = tbl.cellAt(.{ .row = 2, .col = 2 }).ensureSpace(30).background(.amber_600).minHeight(30);
    _ = tbl.cellAt(.{ .row = 3, .col = 2 }).background(.red_500).minHeight(30);

    var rec = core.RecordingSink.init(alloc);
    defer rec.deinit();
    const st = try doc.renderToSink(rec.sink(), .{});
    try std.testing.expectEqual(@as(u32, 2), st.page_count);
    // Page 1 renders Row 1 (2 cells); Page 2 renders Row 2-3 (3 cells)
    try std.testing.expectEqual(@as(usize, 2), rec.pages.items[0].rects.items.len);
    try std.testing.expectEqual(@as(usize, 3), rec.pages.items[1].rects.items.len);
}

test "Hardening: Dynamic uses measureElement to pack variable-height items with per-page subtotal" {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa.deinit() == 0);
    const alloc = gpa.allocator();

    const Item = struct { h: f32, amount: u32 };
    const items = [_]Item{
        .{ .h = 35, .amount = 10 },
        .{ .h = 35, .amount = 20 },
        .{ .h = 35, .amount = 30 },
        .{ .h = 25, .amount = 40 },
        .{ .h = 25, .amount = 50 },
    };

    const State = struct {
        cursor: usize = 0,
        items: []const Item,
    };

    const buildItem = struct {
        fn build(it: Item, s: core.Slot) void {
            _ = s.height(it.h).background(.blue_500);
        }
    }.build;

    const buildSubtotal = struct {
        fn build(s: core.Slot) void {
            _ = s.height(20).background(.green_600);
        }
    }.build;

    const compose = struct {
        fn run(st: *State, info: core.tree.DynamicContextInfo, slot: core.Slot) core.tree.DynamicResult {
            const footer_m = info.measureElement(info.available_size, {}, buildSubtotal);
            var remaining_h = info.available_size.height - footer_m.size.height;

            var col = slot.column(.{});
            while (st.cursor < st.items.len) {
                const it = st.items[st.cursor];
                const probe = info.measureElement(.{ .width = info.available_size.width, .height = remaining_h }, it, buildItem);
                if (!probe.fits_completely) break;
                buildItem(it, col.item());
                remaining_h -= probe.size.height;
                st.cursor += 1;
            }
            buildSubtotal(col.item());
            return .{ .has_more_content = st.cursor < st.items.len };
        }
    }.run;

    var doc = core.Document.init(alloc, .{});
    defer doc.deinit();
    doc.addPage(.{
        .size = .{ .fixed = .{ .width = 200, .height = 100 } },
        .background_color = .transparent,
    }).content().dynamic(State, .{ .items = &items }, compose);

    var rec = core.RecordingSink.init(alloc);
    defer rec.deinit();
    const st = try doc.renderToSink(rec.sink(), .{});
    // Available per page minus 20pt subtotal = 80pt:
    // Page 1: [35, 35] + subtotal = 3 rects
    // Page 2: [35, 25] + subtotal = 3 rects
    // Page 3: [25]     + subtotal = 2 rects
    try std.testing.expectEqual(@as(u32, 3), st.page_count);
    try std.testing.expectEqual(@as(usize, 3), rec.pages.items[0].rects.items.len);
    try std.testing.expectEqual(@as(usize, 3), rec.pages.items[1].rects.items.len);
    try std.testing.expectEqual(@as(usize, 2), rec.pages.items[2].rects.items.len);
}
