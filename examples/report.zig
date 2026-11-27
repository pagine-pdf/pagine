const std = @import("std");
const pagine = @import("pagine");
const skia = @import("skia");

const RevenueSeries = struct {
    quarters: []const []const u8,
    values: []const f32,
};

fn drawRevenueChart(series: *const RevenueSeries, canvas: skia.Canvas, size: pagine.Size) void {
    var grid_paint = skia.Paint.init(.{
        .color = pagine.colorToSkia(.slate_200),
        .style = .stroke,
        .stroke_width = 0.75,
    });
    defer grid_paint.deinit();

    // Horizontal grid lines
    for (0..5) |i| {
        const y = size.height * (@as(f32, @floatFromInt(i)) / 4.0);
        canvas.drawLine(0, y, size.width, y, grid_paint);
    }

    const n: f32 = @floatFromInt(series.values.len);
    const gap: f32 = 16;
    const bar_w = (size.width - gap * (n + 1)) / n;

    for (series.values, 0..) |v, i| {
        const h = (size.height - 16) * v;
        const x = gap + @as(f32, @floatFromInt(i)) * (bar_w + gap);
        const y = size.height - h;

        const colors = [_]skia.Color4f{
            pagine.colorToSkia(.blue_500).toColor4f(),
            pagine.colorToSkia(.indigo_600).toColor4f(),
        };
        const pos = [_]f32{ 0.0, 1.0 };
        var sh = skia.Shader.makeLinearGradient(.{ .x = x, .y = y }, .{ .x = x, .y = size.height }, &colors, &pos, .clamp, null);
        defer if (sh) |*s| s.deinit();

        var bar_paint = skia.Paint.init(.{ .color = pagine.colorToSkia(.blue_600), .anti_alias = true });
        defer bar_paint.deinit();
        if (sh) |s| bar_paint.setShader(s);

        canvas.drawRoundRect(.fromXYWH(x, y, bar_w, h), 5, 5, bar_paint);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const out_path = if (args.len >= 2) args[1] else "report.pdf";

    var fonts = try pagine.FontRegistry.init(.{});
    defer fonts.deinit();
    fonts.registerFile("../../skia-zig/skia-zig/assets/fonts/Roboto-Regular.ttf", "Roboto") catch {};

    const logo_svg =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="48" height="48">
        \\  <rect x="4" y="4" width="40" height="40" rx="10" fill="#2563EB"/>
        \\  <path d="M16 32 V16 H26 C30 16 32 18 32 21.5 C32 25 30 27 26 27 H21 V32 Z" fill="#FFFFFF"/>
        \\</svg>
    ;
    var logo = try pagine.Svg.fromBytes(logo_svg, &fonts);
    defer logo.deinit();

    var doc = pagine.Document.init(gpa, .{});
    defer doc.deinit();

    // Page Set 1: Executive Cover Page
    {
        var cover = doc.addPage(.{
            .size = .a4,
            .margin = .{ .all = 0 },
            .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 11, .color = .white },
        });
        _ = cover.background().backgroundEx(.{
            .gradient = .{
                .angle_deg = 45,
                .stops = &.{
                    .{ .pos = 0.0, .color = .slate_900 },
                    .{ .pos = 1.0, .color = .blue_900 },
                },
            },
        });
        var c = cover.content().padding(.{ .all = 56 }).column(.{ .spacing = 20 });
        c.item().width(56).svgRef(logo.retainRef(), .{ .scaling = .fit_area });
        _ = c.item().height(80);
        c.item().heading(1).text("FY2026 Annual Engineering\n& Performance Report", .{ .size = 34, .weight = .bold, .color = .white });
        c.item().text("High-Throughput Document Generation with Zig 0.17 & Skia", .{ .size = 14, .color = .blue_100 });
        _ = c.item().height(24);

        // Table of contents on cover with auto-resolved section page numbers!
        var toc = c.item().box(.{
            .padding = .{ .all = 16 },
            .background = pagine.Color.white.withAlpha(0x18),
            .border = .{ .all = 1, .color = pagine.Color.white.withAlpha(0x33), .radius = 8 },
        }).column(.{ .spacing = 8 });
        toc.item().text("CONTENTS", .{ .size = 9, .weight = .bold, .color = .blue_100 });

        const toc_entries = [_]struct { title: []const u8, sec: []const u8 }{
            .{ .title = "1. Executive KPIs & Revenue Growth", .sec = "sec_kpi" },
            .{ .title = "2. Architecture & Benchmark Commentary", .sec = "sec_arch" },
        };
        for (toc_entries) |e| {
            var r = toc.item().row(.{});
            var link_rt = r.relative(1).richText(.{});
            link_rt.sectionLink(e.title, e.sec, .{ .size = 11, .color = .white, .underline = true });
            var pg_rt = r.auto().alignRight().richText(.{});
            pg_rt.span("p. ", .{ .color = .blue_100 });
            pg_rt.sectionBeginPage(e.sec, .{ .weight = .bold, .color = .white });
        }
    }

    // Page Set 2: Body Pages
    {
        var body = doc.addPage(.{
            .size = .a4,
            .margin = .{ .all = pagine.mm(18) },
            .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 10.5, .color = .slate_800 },
        });

        var hdr = body.header().padding(.{ .bottom = 10 }).border(.{ .bottom = 0.75, .color = .slate_200 }).row(.{});
        hdr.relative(1).text("FY2026 Engineering Report", .{ .size = 9, .weight = .bold, .color = .slate_600 });
        hdr.auto().alignRight().text("pagine-pdf/pagine", .{ .size = 9, .color = .blue_600 });

        var ftr = body.footer().alignCenter().padding(.{ .top = 8 }).richText(.{ .style = .{ .size = 9, .color = .slate_500 } });
        ftr.span("Page ", .{});
        ftr.currentPageNumber(.{ .weight = .bold });
        ftr.span(" / ", .{});
        ftr.totalPages(.{ .weight = .bold });

        var col = body.content().padding(.{ .vertical = 14 }).column(.{ .spacing = 16 });

        // Section 1: KPI Cards + Skia Chart
        var s1 = col.item().section("sec_kpi").column(.{ .spacing = 12 });
        s1.item().heading(1).text("1. Executive KPIs & Revenue Growth", .{ .size = 18, .weight = .bold, .color = .slate_900 });

        var kpis = s1.item().row(.{ .spacing = 12 });
        const cards = [_]struct { label: []const u8, val: []const u8, accent: pagine.Color }{
            .{ .label = "THROUGHPUT", .val = "2,400+ pg/s", .accent = .blue_600 },
            .{ .label = "HEAP LEAKS", .val = "0 bytes", .accent = .green_600 },
            .{ .label = "BACKENDS", .val = "PDF / PNG / SVG", .accent = .indigo_600 },
        };
        for (cards) |card| {
            var k = kpis.relative(1).box(.{
                .padding = .{ .all = 12 },
                .background = .slate_50,
                .border = .{ .all = 1, .color = .slate_200, .radius = 8 },
                .shadow = .{ .offset_y = 2, .blur_sigma = 3 },
            }).column(.{ .spacing = 4 });
            k.item().text(card.label, .{ .size = 8, .weight = .bold, .color = .slate_500 });
            k.item().text(card.val, .{ .size = 15, .weight = .bold, .color = card.accent });
        }

        const series: RevenueSeries = .{
            .quarters = &.{ "Q1", "Q2", "Q3", "Q4", "Q1'", "Q2'" },
            .values = &.{ 0.35, 0.52, 0.64, 0.78, 0.86, 0.96 },
        };
        var chart_card = s1.item().semantic(.{ .tag = "Figure", .alt = "Quarterly Revenue Bar Chart" }).box(.{
            .padding = .{ .all = 14 },
            .background = .white,
            .border = .{ .all = 1, .color = .slate_200, .radius = 8 },
        }).column(.{ .spacing = 8 });
        chart_card.item().text("Quarterly Vector Growth Index (Native Skia Canvas)", .{ .size = 10, .weight = .bold, .color = .slate_700 });
        const chart_slot = chart_card.item().height(160);
        pagine.drawCanvas(chart_slot, &series, drawRevenueChart);

        // Section 2: Balanced Multi-Column Commentary
        var s2 = col.item().section("sec_arch").column(.{ .spacing = 10 });
        s2.item().heading(1).text("2. Architecture & Benchmark Commentary", .{ .size = 18, .weight = .bold, .color = .slate_900 });

        var mc = s2.item().multiColumn(.{ .columns = 2, .spacing = 18, .balance_height = true });
        mc.spacer().alignCenter().lineVertical(.{ .thickness = 0.5, .color = .slate_200 });
        var mc_col = mc.content().column(.{ .spacing = 8 });
        for (1..7) |i| {
            mc_col.item().richText(.{ .alignment = .justify }).print(
                "Note {d}: Pagine stores the entire document structure in a contiguous Arena node pool and externalizes pagination cursors into a flat StateStore. This eliminates GC pressure, enables O(N) speculative checkpoints for MultiColumn height balancing, and preserves direct access to Skia vector primitives.",
                .{i},
                .{ .size = 9.5, .color = .slate_700 },
            );
        }
    }

    var pdf = try pagine.renderPdf(&doc, .{
        .fonts = &fonts,
        .title = "FY2026 Engineering & Performance Report",
        .author = "pagine",
        .lang = "en-US",
        .outline = .structure_element_headers,
    });
    defer pdf.deinit();

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = pdf.bytes() });
    std.log.info("Wrote {s} ({d} bytes)", .{ out_path, pdf.bytes().len });
}
