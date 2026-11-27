const std = @import("std");
const core = @import("core");
const support = @import("support");

const TestAllocator = support.TestAllocator;
const RecordingSink = support.RecordingSink(core);
const MockTextEngine = support.MockTextEngine(core);

test "geometry: unit conversions, page sizes, and edge insets precedence" {
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

test "style: Color ARGB layout and TextStyle inheritance" {
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

test "column: automatic multi-page pagination with repeating header and footer" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
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

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();

        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expect(!rec.oom);
        try std.testing.expectEqual(@as(u32, 3), stats.page_count);
        try std.testing.expectEqual(@as(usize, 3), rec.pages.items.len);

        // Page 1: header + 3 items + footer = 5 rects; Page 2: 5; Page 3: 3
        try std.testing.expectEqual(@as(usize, 5), rec.pages.items[0].rects.items.len);
        try std.testing.expectEqual(@as(usize, 5), rec.pages.items[1].rects.items.len);
        try std.testing.expectEqual(@as(usize, 3), rec.pages.items[2].rects.items.len);

        // Verify exact Y positions on Page 1 (margin=10, header=20, items at 30, 75, 120, footer at 170)
        const p1_rects = rec.pages.items[0].rects.items;
        try std.testing.expectApproxEqAbs(@as(f32, 10), p1_rects[0].rect.top, 0.01); // header
        try std.testing.expectApproxEqAbs(@as(f32, 30), p1_rects[1].rect.top, 0.01); // item 0
        try std.testing.expectApproxEqAbs(@as(f32, 75), p1_rects[2].rect.top, 0.01); // item 1
        try std.testing.expectApproxEqAbs(@as(f32, 120), p1_rects[3].rect.top, 0.01); // item 2
        try std.testing.expectApproxEqAbs(@as(f32, 170), p1_rects[4].rect.top, 0.01); // footer
    }

    try ta.expectNoLeaks();
}

test "row: constant, relative, auto sizing and RTL mirroring" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        // LTR page width = 330, spacing = 10 (3 gaps = 30), constant = 60, auto = 40 -> relative remaining = 200 (1:3 => 50, 150)
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

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();

        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expect(!rec.oom);
        try std.testing.expectEqual(@as(u32, 2), stats.page_count);

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

    try ta.expectNoLeaks();
}

test "page: ContinuousSize adjusts page height to content" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var page = doc.addPage(.{ .size = .{ .continuous = 250 }, .margin = .{ .all = 10 } });
        var col = page.content().column(.{ .spacing = 10 });
        _ = col.item().height(50).background(.blue_500);
        _ = col.item().height(70).background(.green_600);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expect(!rec.oom);
        try std.testing.expectEqual(@as(u32, 1), stats.page_count);
        try std.testing.expectApproxEqAbs(@as(f32, 250), rec.pages.items[0].size.width, 0.01);
        // 10(top) + 50 + 10(spacing) + 70 + 10(bottom) = 150
        try std.testing.expectApproxEqAbs(@as(f32, 150), rec.pages.items[0].size.height, 0.01);
    }

    try ta.expectNoLeaks();
}

test "pagination: ShowOnce and SkipOnce preserve hard state inside repeating header" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
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

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();

        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 2), stats.page_count);
        try std.testing.expect(rec.pages.items[0].rects.items[0].color.eql(.red_500));
        try std.testing.expect(rec.pages.items[1].rects.items[0].color.eql(.blue_500));
    }

    try ta.expectNoLeaks();
}

test "pagination: EnsureSpace pushes partial block to next page and marks hard state once started" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        // Page height = 100pt:
        // - Item 0 takes 55pt -> 45pt remaining on page 1.
        // - EnsureSpace(60) wraps a 3-item column (3 * 35pt = 105pt).
        //   On page 1, only 1 item (35pt) fits -> partial_render, but 45pt < 60pt => must wrap entire block to page 2.
        //   On page 2, 100pt >= 60pt => renders 2 items (70pt) and sets hard_bool = true.
        //   On page 3, renders the final 35pt item cleanly.
        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 100 } },
            .background_color = .transparent,
        });
        var outer = page.content().column(.{});
        _ = outer.item().height(55).background(.slate_500);
        var ensured = outer.item().ensureSpace(60).column(.{});
        _ = ensured.item().height(35).background(.blue_500);
        _ = ensured.item().height(35).background(.green_600);
        _ = ensured.item().height(35).background(.amber_600);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();

        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 3), stats.page_count);
        // Page 1 has ONLY the 55pt intro block (none of the ensured items!)
        try std.testing.expectEqual(@as(usize, 1), rec.pages.items[0].rects.items.len);
        try std.testing.expect(rec.pages.items[0].rects.items[0].color.eql(.slate_500));
        // Page 2 has the first 2 ensured items
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items[1].rects.items.len);
        try std.testing.expect(rec.pages.items[1].rects.items[0].color.eql(.blue_500));
        try std.testing.expect(rec.pages.items[1].rects.items[1].color.eql(.green_600));
        // Page 3 has the remaining 3rd ensured item
        try std.testing.expectEqual(@as(usize, 1), rec.pages.items[2].rects.items.len);
        try std.testing.expect(rec.pages.items[2].rects.items[0].color.eql(.amber_600));
    }

    try ta.expectNoLeaks();
}

test "pagination: StopPaging truncates overflow and Repeat resets soft state across pages" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    // 1. StopPaging renders what fits on page 1 and suppresses remaining pages
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var col = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 100 } },
            .background_color = .transparent,
        }).content().stopPaging().column(.{});
        for (0..5) |_| {
            _ = col.item().height(40).background(.blue_500);
        }

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 1), stats.page_count);
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items[0].rects.items.len);
    }

    // 2. Explicit Repeat resets soft-state children (Column/Row) while preserving hard state (ShowOnce)
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 100 } },
            .background_color = .transparent,
        });
        var dec = page.content().decoration();
        var rep_col = dec.before().repeat().column(.{});
        _ = rep_col.item().showOnce().height(10).background(.red_500);
        _ = rep_col.item().height(10).background(.blue_500);

        var body = dec.content().column(.{});
        _ = body.item().height(60).background(.green_600);
        _ = body.item().height(60).background(.green_600);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 2), stats.page_count);
        // Page 1: red(ShowOnce) + blue(repeated) + green(body) = 3 rects
        try std.testing.expectEqual(@as(usize, 3), rec.pages.items[0].rects.items.len);
        // Page 2: blue(repeated, soft-reset!) + green(body) = 2 rects (red stays hidden)
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items[1].rects.items.len);
        try std.testing.expect(rec.pages.items[1].rects.items[0].color.eql(.blue_500));
    }

    try ta.expectNoLeaks();
}

test "pagination: ShowIf static false and ShowIfFn page-aware visibility" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    const onlyLastPage = struct {
        fn check(_: ?*const anyopaque, info: core.tree.ShowIfContext) bool {
            if (info.total_pages) |tot| return info.page_number == tot;
            return false;
        }
    }.check;

    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 100 } },
            .background_color = .transparent,
        });
        // Header has a statically hidden box and a last-page-only box
        var hdr = page.header().column(.{});
        _ = hdr.item().showIf(false).height(30).background(.red_500);
        _ = hdr.item().showIfFn(null, onlyLastPage).height(15).background(.amber_600);

        var col = page.content().column(.{});
        _ = col.item().height(60).background(.green_600);
        _ = col.item().height(60).background(.green_600);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 2), stats.page_count);
        // Page 1: only body green rect (static showIf=false omitted, showIfFn=false on p1)
        try std.testing.expectEqual(@as(usize, 1), rec.pages.items[0].rects.items.len);
        try std.testing.expect(rec.pages.items[0].rects.items[0].color.eql(.green_600));
        // Page 2: amber header (showIfFn=true on last page) + body green rect
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items[1].rects.items.len);
        try std.testing.expect(rec.pages.items[1].rects.items[0].color.eql(.amber_600));
    }

    try ta.expectNoLeaks();
}

test "pagination: LayoutOverflow diagnostics and MaxPagesExceeded guard" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    // 1. LayoutOverflow captures root cause and @src() location
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var page = doc.addPage(.{ .size = .{ .fixed = .{ .width = 200, .height = 100 } } });
        _ = page.content().source(@src()).showEntire().height(180).background(.red_500);

        var diag: core.LayoutDiagnostic = .{ .allocator = alloc };
        defer diag.deinit();

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();

        try std.testing.expectError(error.LayoutOverflow, doc.renderToSink(rec.sink(), .{
            .diagnostic = &diag,
        }));
        try std.testing.expectEqual(@as(u32, 1), diag.page_number);
        try std.testing.expect(std.mem.indexOf(u8, diag.report, "[WRAP]") != null);
        try std.testing.expect(std.mem.indexOf(u8, diag.report, "ShowEntire") != null);
        try std.testing.expect(std.mem.indexOf(u8, diag.report, "core_test.zig") != null);
    }

    // 2. MaxPagesExceeded stops runaway pagination cleanly
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var col = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 50 } },
        }).content().column(.{});
        for (0..6) |_| {
            _ = col.item().height(40).background(.blue_500);
        }

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.MaxPagesExceeded, doc.renderToSink(rec.sink(), .{
            .max_pages = 2,
        }));
    }

    try ta.expectNoLeaks();
}

test "compose errors: sticky validation errors and OOM cleanup safety" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    // 1. MultipleChildrenAssigned on single-child Slot
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        const slot = doc.addPage(.{}).content();
        _ = slot.height(10);
        _ = slot.height(20);
        try std.testing.expectError(error.MultipleChildrenAssigned, doc.validate());
    }

    // 2. DuplicatePageSlot when calling header() twice on the same page
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var page = doc.addPage(.{});
        _ = page.header().height(10);
        _ = page.header().height(20);
        try std.testing.expectError(error.DuplicatePageSlot, doc.validate());
    }

    // 3. MultipleChildrenAssigned on duplicate Decoration slot
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var dec = doc.addPage(.{}).content().decoration();
        _ = dec.before().height(10);
        _ = dec.before().height(10);
        try std.testing.expectError(error.MultipleChildrenAssigned, doc.validate());
    }

    // 4. InvalidColumnDefinition on empty table column slice
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        _ = doc.addPage(.{}).content().table(.{ .columns = &.{} });
        try std.testing.expectError(error.InvalidColumnDefinition, doc.validate());
    }

    // 5. FailingAllocator OOM during registerCleanup still invokes release_fn immediately with zero leaks
    {
        var released: u32 = 0;
        const releaseFn = struct {
            fn release(raw: *anyopaque) void {
                const counter: *u32 = @ptrCast(@alignCast(raw));
                counter.* += 1;
            }
        }.release;

        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
        var doc = core.Document.init(failing.allocator(), .{});
        defer doc.deinit();

        doc.tree.registerCleanup(@ptrCast(&released), releaseFn);
        try std.testing.expectEqual(@as(u32, 1), released);
        try std.testing.expectError(error.OutOfMemory, doc.validate());
    }

    try ta.expectNoLeaks();
}

test "text: multi-page splitting, clamp_lines, custom formatter, section counters, and interleaved spans" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    const customFmt = struct {
        fn fmt(_: ?*const anyopaque, num: ?u32, buf: []u8) []const u8 {
            if (num) |v| return std.fmt.bufPrint(buf, "[{d}]", .{v}) catch "0";
            return "[00]";
        }
    }.fmt;

    // 1. Multi-page text splitting with exact page count & all section page counters
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        // 200pt wide (single-line footer=14.4pt), 90pt tall -> content=75.6pt -> 5 lines of 14.4pt (72pt) per page.
        // 8 lines of intro text -> 5 on page 1, 3 on page 2 -> ch2 starts on page 2 and spans to page 3!
        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 90 } },
            .default_text_style = .{ .size = 12 },
        });

        var ftr = page.footer().alignCenter().richText(.{});
        ftr.span("P", .{});
        ftr.pageNumberFormatted(.current_page, null, null, customFmt, .{});
        ftr.span("/", .{});
        ftr.totalPages(.{});
        ftr.span(" S:", .{});
        ftr.sectionBeginPage("ch2", .{});
        ftr.span("-", .{});
        ftr.sectionEndPage("ch2", .{});
        ftr.span("(", .{});
        ftr.pageInSection("ch2", .{});
        ftr.span("/", .{});
        ftr.totalPagesInSection("ch2", .{});
        ftr.span(")", .{});

        var col = page.content().column(.{});
        col.item().text("L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8", .{});

        var sec_col = col.item().section("ch2").column(.{});
        var ch2 = sec_col.item().richText(.{});
        ch2.hyperlink("Docs", "https://example.com", .{ .underline = true });
        ch2.span(" ", .{});
        // Interleaved RichText inside inline_element exercises Tree.appendTextSpan relocation!
        ch2.element(.middle).text("TAG", .{});
        ch2.span(" ", .{});
        ch2.sectionLink("Back", "ch2", .{});
        sec_col.item().pageBreak();
        sec_col.item().text("Ch2Page2", .{});

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        var mock_text = MockTextEngine.init(alloc);
        defer mock_text.deinit();

        const stats = try doc.renderToSink(rec.sink(), .{ .text_engine = mock_text.engine() });
        try std.testing.expectEqual(@as(u32, 3), stats.page_count);

        // Verify resolved footers across all 3 pages (ch2 spans pages 2..3 -> 2 pages)
        try std.testing.expect(mock_text.hasRendered("P[1]/3 S:2-3(1/2)"));
        try std.testing.expect(mock_text.hasRendered("P[2]/3 S:2-3(1/2)"));
        try std.testing.expect(mock_text.hasRendered("P[3]/3 S:2-3(2/2)"));
        try std.testing.expect(mock_text.hasRendered("TAG"));

        // Hyperlink, named destination, and section link recorded on page 2 (index 1)
        const p2 = rec.pages.items[1];
        try std.testing.expectEqual(@as(usize, 1), p2.urls.items.len);
        try std.testing.expectEqualStrings("https://example.com", p2.urls.items[0]);
        try std.testing.expectEqual(@as(usize, 1), p2.dests.items.len);
        try std.testing.expectEqualStrings("ch2", p2.dests.items[0]);
        try std.testing.expectEqual(@as(usize, 1), p2.links.items.len);
    }

    // 2. clamp_lines truncates tall paragraph so it stays on 1 page
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 100, .height = 40 } },
            .default_text_style = .{ .size = 12 },
        });
        var rt = page.content().richText(.{ .clamp_lines = 2 });
        rt.span("A\nB\nC\nD\nE\nF", .{});

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        var mock_text = MockTextEngine.init(alloc);
        defer mock_text.deinit();

        const stats = try doc.renderToSink(rec.sink(), .{ .text_engine = mock_text.engine() });
        try std.testing.expectEqual(@as(u32, 1), stats.page_count);
        try std.testing.expectEqual(@as(usize, 2), mock_text.records.items[0].line_count);
    }

    // 3. Whitespace-only text still occupies a single line height & check_missing_glyphs propagates error
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        doc.addPage(.{ .size = .{ .continuous = 100 }, .default_text_style = .{ .size = 10 } })
            .content()
            .text("   ", .{});

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        var mock_text = MockTextEngine.init(alloc);
        defer mock_text.deinit();

        const stats = try doc.renderToSink(rec.sink(), .{ .text_engine = mock_text.engine() });
        try std.testing.expectEqual(@as(u32, 1), stats.page_count);
        try std.testing.expectApproxEqAbs(@as(f32, 12.0), rec.pages.items[0].size.height, 0.01);
    }
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        doc.addPage(.{ .size = .{ .fixed = .{ .width = 100, .height = 100 } } })
            .content()
            .text("Hello MISSING world", .{});

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        var mock_text = MockTextEngine.init(alloc);
        defer mock_text.deinit();
        mock_text.missing_glyph_marker = "MISSING";

        try std.testing.expectError(error.MissingGlyphs, doc.renderToSink(rec.sink(), .{
            .text_engine = mock_text.engine(),
            .check_missing_glyphs = true,
        }));
    }

    try ta.expectNoLeaks();
}

test "text: alignRight on container does not leak text alignment into nested Column/Row" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var col = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 400, .height = 200 } },
            .background_color = .transparent,
        }).content().column(.{});

        // Direct alignRight -> text inherits .right
        col.item().alignRight().text("DirectRight", .{});

        // Container alignRight -> box sits at x=160, but inner Column/Row resets text align to .start
        var box_col = col.item().alignRight().width(240).box(.{
            .padding = .{ .all = 10 },
            .background = .slate_50,
        }).column(.{});
        var r = box_col.item().row(.{ .spacing = 8 });
        r.relative(1).text("Subtotal", .{});
        r.auto().alignRight().text("$11849.00", .{});

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        var mock_text = MockTextEngine.init(alloc);
        defer mock_text.deinit();

        _ = try doc.renderToSink(rec.sink(), .{ .text_engine = mock_text.engine() });

        // Outer box is flush right: 400 - 240 = 160
        try std.testing.expectEqual(@as(usize, 1), rec.pages.items[0].rects.items.len);
        try std.testing.expectApproxEqAbs(@as(f32, 160.0), rec.pages.items[0].rects.items[0].rect.left, 0.5);

        try std.testing.expectEqual(core.style.TextAlign.right, mock_text.findAlignment("DirectRight").?);
        try std.testing.expectEqual(core.style.TextAlign.start, mock_text.findAlignment("Subtotal").?);
        try std.testing.expectEqual(core.style.TextAlign.right, mock_text.findAlignment("$11849.00").?);
    }

    try ta.expectNoLeaks();
}

test "table: pagination, repeating header/footer, RowSpan equalization, extend_last_cells, and RTL" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    // 1. Multi-page table with repeating header (20pt) + footer (10pt) and 10 body rows of 30pt on 160pt page
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var tbl = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 160 } },
            .background_color = .transparent,
        }).content().table(.{
            .columns = &.{ .fixed(40), .rel(1), .rel(1) },
        });
        _ = tbl.headerCell().height(20).background(.blue_700);
        _ = tbl.headerCellAt(.{ .col_span = 2 }).height(20).background(.blue_600);
        _ = tbl.footerCellAt(.{ .col_span = 3 }).height(10).background(.slate_300);

        for (0..10) |_| {
            _ = tbl.cell().height(30).background(.slate_100);
            _ = tbl.cell().height(30).background(.slate_50);
            _ = tbl.cell().height(30).background(.slate_100);
        }

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 3), stats.page_count);
        try std.testing.expectEqual(@as(usize, 15), rec.pages.items[0].rects.items.len);
        try std.testing.expectEqual(@as(usize, 15), rec.pages.items[1].rects.items.len);
        try std.testing.expectEqual(@as(usize, 9), rec.pages.items[2].rects.items.len);
    }

    // 2. RowSpan height equalization & extend_last_cells_to_bottom
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var tbl = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 200 } },
            .background_color = .transparent,
        }).content().table(.{
            .columns = &.{ .rel(1), .rel(1) },
            .extend_last_cells_to_bottom = true,
        });
        _ = tbl.cellAt(.{ .row = 1, .col = 1, .row_span = 2 }).background(.blue_500).minHeight(20);
        _ = tbl.cellAt(.{ .row = 1, .col = 2 }).background(.green_600).minHeight(30);
        _ = tbl.cellAt(.{ .row = 2, .col = 2 }).background(.amber_600).minHeight(40);
        // Row 3 only has col 1 (25pt); extend_last_cells_to_bottom extends col 2's row-2 cell to total table height (95pt)
        _ = tbl.cellAt(.{ .row = 3, .col = 1 }).background(.red_500).minHeight(25);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 1), stats.page_count);
        const rects = rec.pages.items[0].rects.items;
        try std.testing.expectEqual(@as(usize, 4), rects.len);
        try std.testing.expectApproxEqAbs(@as(f32, 70), rects[0].rect.height(), 0.01); // row 1-2 col 1
        try std.testing.expectApproxEqAbs(@as(f32, 100), rects[1].rect.left, 0.01); // row 1 col 2
        // Row 2 col 2 starts at y=30 and extends to bottom of row 3 (y=95) -> height 65
        try std.testing.expectApproxEqAbs(@as(f32, 65), rects[2].rect.height(), 0.01);
    }

    // 3. RTL column mirroring
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var tbl = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 100 } },
            .background_color = .transparent,
            .direction = .rtl,
        }).content().table(.{ .columns = &.{ .fixed(60), .fixed(140) } });
        _ = tbl.cell().height(20).background(.red_500);
        _ = tbl.cell().height(20).background(.blue_500);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        _ = try doc.renderToSink(rec.sink(), .{});
        const rects = rec.pages.items[0].rects.items;
        try std.testing.expectApproxEqAbs(@as(f32, 140), rects[0].rect.left, 0.01); // first col (w=60) on right
        try std.testing.expectApproxEqAbs(@as(f32, 0), rects[1].rect.left, 0.01); // second col (w=140) on left
    }

    // 4. Multi-page RowSpan with ShowEntire & cell-level partial_render text splitting
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var tbl = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 100 } },
            .background_color = .transparent,
        }).content().table(.{
            .columns = &.{ .fixed(80), .rel(1) },
        });
        _ = tbl.cellAt(.{ .row = 1, .col = 1 }).background(.slate_200).minHeight(45);
        _ = tbl.cellAt(.{ .row = 1, .col = 2 }).background(.blue_500).minHeight(45);
        _ = tbl.cellAt(.{ .row = 2, .col = 1, .row_span = 2 }).showEntire().background(.green_600).minHeight(60);
        _ = tbl.cellAt(.{ .row = 2, .col = 2 }).background(.amber_600).minHeight(30);
        _ = tbl.cellAt(.{ .row = 3, .col = 2 }).background(.red_500).minHeight(30);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const st = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 2), st.page_count);
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items[0].rects.items.len);
        try std.testing.expectEqual(@as(usize, 3), rec.pages.items[1].rects.items.len);
    }
    {
        // A single tall text cell splits cleanly across 2 pages without losing the following row
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var tbl = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 120, .height = 60 } },
            .background_color = .transparent,
            .default_text_style = .{ .size = 10 },
        }).content().table(.{ .columns = &.{.rel(1)} });
        tbl.cell().text("R1L1\nR1L2\nR1L3\nR1L4\nR1L5\nR1L6\nR1L7", .{});
        _ = tbl.cell().height(20).background(.green_600);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        var mock_text = MockTextEngine.init(alloc);
        defer mock_text.deinit();

        const st = try doc.renderToSink(rec.sink(), .{ .text_engine = mock_text.engine() });
        try std.testing.expectEqual(@as(u32, 2), st.page_count);
        try std.testing.expectEqual(@as(usize, 0), rec.pages.items[0].rects.items.len);
        try std.testing.expectEqual(@as(usize, 1), rec.pages.items[1].rects.items.len);
    }

    try ta.expectNoLeaks();
}

test "table: validation catches empty table, invalid spans, and collisions beyond active window" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    // 1. Empty table (0 cells) renders cleanly as 1 empty page
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        _ = doc.addPage(.{ .size = .{ .fixed = .{ .width = 200, .height = 100 } } }).content().table(.{
            .columns = &.{ .rel(1), .rel(1) },
        });
        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const st = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 1), st.page_count);
    }

    // 2. col_span exceeding columns, col_span=0, row_span=0
    const bad_placements = [_]core.CellPlacement{
        .{ .col_span = 3 },
        .{ .col_span = 0 },
        .{ .row_span = 0 },
    };
    for (bad_placements) |pl| {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var tbl = doc.addPage(.{}).content().table(.{ .columns = &.{ .rel(1), .rel(1) } });
        _ = tbl.cellAt(pl).height(20);
        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.InvalidTableConfiguration, doc.renderToSink(rec.sink(), .{}));
    }

    // 3. Horizontal ColSpan collision & vertical RowSpan collision
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var tbl = doc.addPage(.{}).content().table(.{ .columns = &.{ .rel(1), .rel(1) } });
        _ = tbl.cellAt(.{ .row = 1, .col = 1, .col_span = 2 }).height(20);
        _ = tbl.cellAt(.{ .row = 1, .col = 2 }).height(20);
        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.InvalidTableConfiguration, doc.renderToSink(rec.sink(), .{}));
    }
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var tbl = doc.addPage(.{}).content().table(.{ .columns = &.{ .rel(1), .rel(1) } });
        _ = tbl.cellAt(.{ .row = 1, .col = 1, .row_span = 2 }).height(40);
        _ = tbl.cellAt(.{ .row = 2, .col = 1 }).height(20);
        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.InvalidTableConfiguration, doc.renderToSink(rec.sink(), .{}));
    }

    // 4. Collision window trimming (>16 cells) still detects an overlap on row 10
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var tbl = doc.addPage(.{}).content().table(.{ .columns = &.{ .rel(1), .rel(1) } });
        for (0..18) |_| {
            _ = tbl.cell().height(10); // fills rows 1..9 (18 cells > 16 window threshold)
        }
        _ = tbl.cellAt(.{ .row = 10, .col = 1, .col_span = 2 }).height(10);
        _ = tbl.cellAt(.{ .row = 10, .col = 2 }).height(10);
        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.InvalidTableConfiguration, doc.renderToSink(rec.sink(), .{}));
    }

    try ta.expectNoLeaks();
}

test "containers: Layers, Decoration, Inlined alignments/pagination, and MultiColumn balancing" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    // 1. Layers: primaryLayer determines container height while overlay layers draw in same bounds
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var layers = doc.addPage(.{
            .size = .{ .continuous = 200 },
            .background_color = .transparent,
        }).content().layers();
        _ = layers.layer().background(.slate_100);
        _ = layers.primaryLayer().height(60).background(.blue_500);
        _ = layers.layer().alignRight().size(20, 20).background(.red_500);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        _ = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectApproxEqAbs(@as(f32, 60), rec.pages.items[0].size.height, 0.01);
        try std.testing.expectEqual(@as(usize, 3), rec.pages.items[0].rects.items.len);
        try std.testing.expectApproxEqAbs(@as(f32, 180), rec.pages.items[0].rects.items[2].rect.left, 0.01);
    }

    // 2. Inlined: flow-wrap, pagination across pages, and alignment modes (center, right, justify, space_around)
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var inl = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 160, .height = 48 } },
            .background_color = .transparent,
        }).content().inlined(.{ .horizontal_spacing = 5, .vertical_spacing = 8 });
        // 8 chips of 50x20 -> 3 per line (line h=20, +8 gap -> 2 lines = 48pt fits page 1; 2 chips on page 2)
        for (0..8) |_| _ = inl.item().size(50, 20).background(.blue_500);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const st = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 2), st.page_count);
        try std.testing.expectEqual(@as(usize, 6), rec.pages.items[0].rects.items.len);
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items[1].rects.items.len);
        try std.testing.expectApproxEqAbs(@as(f32, 55), rec.pages.items[0].rects.items[1].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 28), rec.pages.items[0].rects.items[3].rect.top, 0.01);
    }
    {
        // Alignment modes: two 40pt items inside 200pt width (h_spacing=10)
        const cases = [_]struct { mode: core.InlinedAlignment, x0: f32, x1: f32 }{
            .{ .mode = .center, .x0 = 55, .x1 = 105 }, // (200 - 90)/2 = 55
            .{ .mode = .right, .x0 = 110, .x1 = 160 }, // 200 - 90 = 110
            .{ .mode = .justify, .x0 = 0, .x1 = 160 }, // gap = (200 - 80)/1 = 120
            .{ .mode = .space_around, .x0 = 40, .x1 = 120 }, // gap = (200 - 80)/3 = 40
        };
        for (cases) |tc| {
            var doc = core.Document.init(alloc, .{});
            defer doc.deinit();
            var inl = doc.addPage(.{
                .size = .{ .fixed = .{ .width = 200, .height = 50 } },
                .background_color = .transparent,
            }).content().inlined(.{ .horizontal_spacing = 10, .alignment = tc.mode });
            _ = inl.item().size(40, 20).background(.blue_500);
            _ = inl.item().size(40, 20).background(.green_600);

            var rec = RecordingSink.init(alloc);
            defer rec.deinit();
            _ = try doc.renderToSink(rec.sink(), .{});
            const rects = rec.pages.items[0].rects.items;
            try std.testing.expectApproxEqAbs(tc.x0, rects[0].rect.left, 0.01);
            try std.testing.expectApproxEqAbs(tc.x1, rects[1].rect.left, 0.01);
        }
    }

    // 3. MultiColumn with balance_height splits 4 items of 30pt evenly (2 left, 2 right)
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var mc = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 210, .height = 300 } },
            .background_color = .transparent,
        }).content().multiColumn(.{ .columns = 2, .spacing = 10, .balance_height = true });
        var col = mc.content().column(.{});
        for (0..4) |_| _ = col.item().height(30).background(.indigo_600);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const stats = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 1), stats.page_count);
        const rects = rec.pages.items[0].rects.items;
        try std.testing.expectEqual(@as(usize, 4), rects.len);
        try std.testing.expectApproxEqAbs(@as(f32, 0), rects[0].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 0), rects[1].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 110), rects[2].rect.left, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 110), rects[3].rect.left, 0.01);
    }

    try ta.expectNoLeaks();
}

test "primitives: Constrained, Extend, Shrink, AspectRatio, and Transform" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    // 1. Constrained (min/max + enforce_when_empty), Extend, Shrink
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        var col = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 200 } },
            .background_color = .transparent,
        }).content().column(.{});
        _ = col.item().constrained(.{ .min_width = 50, .min_height = 20, .enforce_when_empty = true }).background(.blue_500);
        _ = col.item().shrink().size(60, 25).background(.green_600);
        _ = col.item().extendHorizontal().height(15).background(.amber_600);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        _ = try doc.renderToSink(rec.sink(), .{});
        const rects = rec.pages.items[0].rects.items;
        try std.testing.expectEqual(@as(usize, 3), rects.len);
        try std.testing.expectApproxEqAbs(@as(f32, 20), rects[0].rect.height(), 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 60), rects[1].rect.width(), 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 200), rects[2].rect.width(), 0.01);
    }

    // 2. AspectRatio (fit_area) & invalid ratio <= 0 triggers LayoutOverflow
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        _ = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 80 } },
            .background_color = .transparent,
        }).content().aspectRatio(2.0, .fit_area).background(.blue_500);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        _ = try doc.renderToSink(rec.sink(), .{});
        const r = rec.pages.items[0].rects.items[0].rect;
        // ratio=2.0 inside 200x80 -> height-limited to 160x80
        try std.testing.expectApproxEqAbs(@as(f32, 160), r.width(), 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 80), r.height(), 0.01);
    }
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        _ = doc.addPage(.{ .size = .{ .fixed = .{ .width = 100, .height = 100 } } })
            .content()
            .aspectRatio(0.0, .fit_area)
            .background(.red_500);
        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        try std.testing.expectError(error.LayoutOverflow, doc.renderToSink(rec.sink(), .{}));
    }

    // 3. Transform: scaleToFit shrinks an oversized 400x200 box into 100x100 without overflow
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        _ = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 100, .height = 100 } },
            .background_color = .transparent,
        }).content().scaleToFit().size(400, 200).background(.indigo_600);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const st = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 1), st.page_count);
        try std.testing.expectEqual(@as(usize, 1), rec.pages.items[0].scales.items.len);
        const s = rec.pages.items[0].scales.items[0];
        try std.testing.expect(s.x > 0.20 and s.x <= 0.251);
        try std.testing.expectApproxEqAbs(s.x, s.y, 1e-4);
    }

    // 4. Transform: rotateRight swaps width/height constraints so 150x40 fits inside 60x160
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        _ = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 60, .height = 160 } },
            .background_color = .transparent,
        }).content().rotateRight().size(150, 40).background(.green_600);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        const st = try doc.renderToSink(rec.sink(), .{});
        try std.testing.expectEqual(@as(u32, 1), st.page_count);
        try std.testing.expectEqual(@as(usize, 1), rec.pages.items[0].rotations.items.len);
        try std.testing.expectApproxEqAbs(@as(f32, 90.0), rec.pages.items[0].rotations.items[0], 0.01);
    }

    try ta.expectNoLeaks();
}

test "dynamic: stateful page-aware component and measureElement packing with verified per-page subtotals" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

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
        fn build(subtotal: u32, s: core.Slot) void {
            s.height(20).background(.green_600).print("SUB:{d}", .{subtotal}, .{});
        }
    }.build;

    const compose = struct {
        fn run(st: *State, info: core.tree.DynamicContextInfo, slot: core.Slot) core.tree.DynamicResult {
            const footer_m = info.measureElement(info.available_size, @as(u32, 0), buildSubtotal);
            var remaining_h = info.available_size.height - footer_m.size.height;

            var col = slot.column(.{});
            var page_sum: u32 = 0;
            while (st.cursor < st.items.len) {
                const it = st.items[st.cursor];
                const probe = info.measureElement(.{ .width = info.available_size.width, .height = remaining_h }, it, buildItem);
                if (!probe.fits_completely) break;
                buildItem(it, col.item());
                remaining_h -= probe.size.height;
                page_sum += it.amount;
                st.cursor += 1;
            }
            buildSubtotal(page_sum, col.item());
            return .{ .has_more_content = st.cursor < st.items.len };
        }
    }.run;

    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();
        doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 100 } },
            .background_color = .transparent,
        }).content().dynamic(State, .{ .items = &items }, compose);

        var rec = RecordingSink.init(alloc);
        defer rec.deinit();
        var mock_text = MockTextEngine.init(alloc);
        defer mock_text.deinit();

        const st = try doc.renderToSink(rec.sink(), .{ .text_engine = mock_text.engine() });
        // Available per page minus 20pt subtotal = 80pt:
        // Page 1: [35(10), 35(20)] -> SUB:30 (3 rects)
        // Page 2: [35(30), 25(40)] -> SUB:70 (3 rects)
        // Page 3: [25(50)]         -> SUB:50 (2 rects)
        try std.testing.expectEqual(@as(u32, 3), st.page_count);
        try std.testing.expectEqual(@as(usize, 3), rec.pages.items[0].rects.items.len);
        try std.testing.expectEqual(@as(usize, 3), rec.pages.items[1].rects.items.len);
        try std.testing.expectEqual(@as(usize, 2), rec.pages.items[2].rects.items.len);

        try std.testing.expect(mock_text.hasRendered("SUB:30"));
        try std.testing.expect(mock_text.hasRendered("SUB:70"));
        try std.testing.expect(mock_text.hasRendered("SUB:50"));
    }

    try ta.expectNoLeaks();
}

test "merge: continuous vs independent page numbering and per-document section isolation" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    const buildDoc = struct {
        fn make(a: std.mem.Allocator, item_count: usize) core.Document {
            var doc = core.Document.init(a, .{});
            var page = doc.addPage(.{
                .size = .{ .fixed = .{ .width = 160, .height = 100 } },
                .background_color = .transparent,
                .default_text_style = .{ .size = 10 },
            });
            var ftr = page.footer().richText(.{});
            ftr.span("P", .{});
            ftr.currentPageNumber(.{});
            ftr.span("/", .{});
            ftr.totalPages(.{});
            ftr.span(" S:", .{});
            ftr.sectionBeginPage("intro", .{});

            var col = page.content().column(.{});
            for (0..item_count) |i| {
                const slot = if (i == 0) col.item().section("intro") else col.item();
                _ = slot.height(60).background(.blue_500);
            }
            return doc;
        }
    }.make;

    {
        var d1 = buildDoc(alloc, 1); // 1 page
        defer d1.deinit();
        var d2 = buildDoc(alloc, 2); // 2 pages
        defer d2.deinit();
        const trees = [_]*const core.tree.Tree{ &d1.tree, &d2.tree };

        // 1. Continuous: global 1..3 numbering AND same-named section "intro" isolated by document_id
        {
            var rec = RecordingSink.init(alloc);
            defer rec.deinit();
            var mock_text = MockTextEngine.init(alloc);
            defer mock_text.deinit();

            const st = try core.engine.renderMergedTrees(alloc, &trees, rec.sink(), .continuous, .{
                .text_engine = mock_text.engine(),
            });
            try std.testing.expectEqual(@as(u32, 3), st.page_count);
            try std.testing.expect(mock_text.hasRendered("P1/3 S:1"));
            try std.testing.expect(mock_text.hasRendered("P2/3 S:2"));
            try std.testing.expect(mock_text.hasRendered("P3/3 S:2"));
        }

        // 2. Independent: each document resets numbering to 1..N
        {
            var rec = RecordingSink.init(alloc);
            defer rec.deinit();
            var mock_text = MockTextEngine.init(alloc);
            defer mock_text.deinit();

            const st = try core.engine.renderMergedTrees(alloc, &trees, rec.sink(), .independent, .{
                .text_engine = mock_text.engine(),
            });
            try std.testing.expectEqual(@as(u32, 3), st.page_count);
            try std.testing.expect(mock_text.hasRendered("P1/1 S:1"));
            try std.testing.expect(mock_text.hasRendered("P1/2 S:1"));
            try std.testing.expect(mock_text.hasRendered("P2/2 S:1"));
        }
    }

    try ta.expectNoLeaks();
}

test "snapshot cache: replays static content identically while bypassing dynamic subtrees" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    // 1. Static multi-page content with dynamic footer: Pass 1 records, Pass 2 replays with identical rects
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var page = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 120 } },
            .margin = .{ .all = 10 },
            .background_color = .transparent,
            .default_text_style = .{ .size = 10 },
        });
        var ftr = page.footer().richText(.{});
        ftr.span("P", .{});
        ftr.currentPageNumber(.{});
        ftr.span("/", .{});
        ftr.totalPages(.{});

        var col = page.content().column(.{ .spacing = 5 });
        for (0..4) |i| {
            _ = col.item().height(40).background(if (i % 2 == 0) .blue_500 else .green_600);
        }

        var rec_snap = RecordingSink.initWithSnapshots(alloc);
        defer rec_snap.deinit();
        var mt_snap = MockTextEngine.init(alloc);
        defer mt_snap.deinit();
        const st_snap = try doc.renderToSink(rec_snap.sink(), .{
            .text_engine = mt_snap.engine(),
            .enable_snapshot_cache = true,
        });

        var rec_plain = RecordingSink.initWithSnapshots(alloc);
        defer rec_plain.deinit();
        var mt_plain = MockTextEngine.init(alloc);
        defer mt_plain.deinit();
        const st_plain = try doc.renderToSink(rec_plain.sink(), .{
            .text_engine = mt_plain.engine(),
            .enable_snapshot_cache = false,
        });

        try std.testing.expectEqual(@as(u32, 2), st_snap.page_count);
        try std.testing.expectEqual(st_plain.page_count, st_snap.page_count);
        try std.testing.expectEqual(@as(u32, 2), rec_snap.snapshots_recorded);
        try std.testing.expectEqual(@as(u32, 2), rec_snap.snapshots_replayed);
        try std.testing.expectEqual(@as(u32, 0), rec_plain.snapshots_recorded);

        // Rect-by-rect equivalence between snapshot replay and uncached Pass 2
        for (rec_plain.pages.items, rec_snap.pages.items) |p_plain, p_snap| {
            try std.testing.expectEqual(p_plain.rects.items.len, p_snap.rects.items.len);
            for (p_plain.rects.items, p_snap.rects.items) |a, b| {
                try std.testing.expectApproxEqAbs(a.rect.left, b.rect.left, 0.01);
                try std.testing.expectApproxEqAbs(a.rect.top, b.rect.top, 0.01);
                try std.testing.expectApproxEqAbs(a.rect.right, b.rect.right, 0.01);
                try std.testing.expectApproxEqAbs(a.rect.bottom, b.rect.bottom, 0.01);
                try std.testing.expect(a.color.eql(b.color));
            }
        }
        try std.testing.expect(mt_snap.hasRendered("P1/2"));
        try std.testing.expect(mt_snap.hasRendered("P2/2"));
    }

    // 2. Content containing a hyperlink or section must NOT be snapshotted (preserves annotations)
    {
        var doc = core.Document.init(alloc, .{});
        defer doc.deinit();

        var col = doc.addPage(.{
            .size = .{ .fixed = .{ .width = 200, .height = 100 } },
            .background_color = .transparent,
        }).content().column(.{});
        _ = col.item().hyperlink("https://example.com").height(20).background(.blue_500);

        var rec = RecordingSink.initWithSnapshots(alloc);
        defer rec.deinit();
        _ = try doc.renderToSink(rec.sink(), .{ .enable_snapshot_cache = true });
        try std.testing.expectEqual(@as(u32, 0), rec.snapshots_recorded);
        try std.testing.expectEqual(@as(usize, 1), rec.pages.items[0].urls.items.len);
    }

    try ta.expectNoLeaks();
}
