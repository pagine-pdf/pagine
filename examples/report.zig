//! Executive Engineering Report — Self-contained starter example.
//!
//! Copy this single file into your project and call `report.compose(&doc, data)`.
//! Demonstrates:
//! - Multi-`PageSet` composition (full-bleed dark cover page + light body pages)
//! - Auto-resolved clickable Table of Contents (`section`, `sectionLink`, `sectionBeginPage`)
//! - Vector `pagine.Svg` DOM logo + DPI-aware raster `pagine.Image` (`imageRef`)
//! - Native `pagine.drawCanvas(...)` Skia bar chart with declarative X-axis labels
//! - Balanced `MultiColumn` commentary with vertical divider + PDF/UA `heading` / `semantic` tags

const std = @import("std");
const pagine = @import("pagine");
const skia = pagine.skia;

pub const KpiCard = struct {
    label: []const u8,
    value: []const u8,
    accent: pagine.Color = .blue_600,
};

pub const RevenueSeries = struct {
    quarters: []const []const u8,
    /// Normalized bar heights in `[0.0, 1.0]`.
    values: []const f32,
};

pub const ReportData = struct {
    title: []const u8,
    subtitle: []const u8,
    running_header: []const u8,
    org_label: []const u8,
    kpis: []const KpiCard,
    series: *const RevenueSeries,
    commentary_notes: []const []const u8,
    /// Optional vector logo (caller retains ownership and calls `deinit()` after `renderPdf`).
    logo_svg: ?pagine.Svg = null,
    /// Optional raster illustration/photo demonstrating DPI-aware `imageRef` embedding.
    cover_banner: ?pagine.Image = null,
    page_size: pagine.PageSizeMode = .a4,
    font_families: ?[]const [:0]const u8 = null,
};

/// Composes a multi-page executive report (Cover PageSet + Body PageSet) onto `doc`.
pub fn compose(doc: *pagine.Document, data: ReportData) void {
    // Page Set 1: Full-Bleed Executive Cover Page
    {
        var cover = doc.addPage(.{
            .size = data.page_size,
            .margin = .{ .all = 0 },
            .default_text_style = .{
                .font_families = data.font_families,
                .size = 11,
                .color = .white,
            },
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

        var c = cover.content().padding(.{ .all = 56 }).column(.{ .spacing = 18 });
        if (data.logo_svg) |logo| {
            c.item().width(56).svgRef(logo.retainRef(), .{ .scaling = .fit_area });
        }
        _ = c.item().height(28);
        c.item().heading(1).text(data.title, .{ .size = 32, .weight = .bold, .color = .white });
        c.item().text(data.subtitle, .{ .size = 13.5, .color = .blue_100 });

        if (data.cover_banner) |banner| {
            c.item()
                .semantic(.{ .tag = "Figure", .alt = "Executive Cover Visual" })
                .box(.{
                    .border = .{ .all = 1, .color = pagine.Color.white.withAlpha(0x33), .radius = 8 },
                    .clip = true,
                    .radius = 8,
                })
                .imageRef(banner.retainRef(), .{
                .scaling = .fit_width,
                .target_dpi = 150,
                .quality = .high,
            });
        }

        // Table of Contents on Cover with auto-resolved section page numbers!
        var toc = c.item().box(.{
            .padding = .{ .all = 16 },
            .background = pagine.Color.white.withAlpha(0x18),
            .border = .{ .all = 1, .color = pagine.Color.white.withAlpha(0x33), .radius = 8 },
        }).column(.{ .spacing = 8 });
        toc.item().text("CONTENTS", .{ .size = 9, .weight = .bold, .color = .blue_100, .letter_spacing = 0.8 });

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
            .size = data.page_size,
            .margin = .{ .all = pagine.mm(18) },
            .default_text_style = .{
                .font_families = data.font_families,
                .size = 10.5,
                .color = .slate_800,
            },
        });

        var hdr = body.header().padding(.{ .bottom = 10 }).border(.{ .bottom = 0.75, .color = .slate_200 }).row(.{});
        hdr.relative(1).text(data.running_header, .{ .size = 9, .weight = .bold, .color = .slate_600 });
        hdr.auto().alignRight().text(data.org_label, .{ .size = 9, .color = .blue_600 });

        var ftr = body.footer().alignCenter().padding(.{ .top = 8 }).richText(.{ .style = .{ .size = 9, .color = .slate_500 } });
        ftr.span("Page ", .{});
        ftr.currentPageNumber(.{ .weight = .bold });
        ftr.span(" / ", .{});
        ftr.totalPages(.{ .weight = .bold });

        var col = body.content().padding(.{ .vertical = 14 }).column(.{ .spacing = 16 });

        // Section 1: KPI Cards + Skia Vector Bar Chart
        var s1 = col.item().section("sec_kpi").column(.{ .spacing = 12 });
        s1.item().heading(1).text("1. Executive KPIs & Revenue Growth", .{ .size = 18, .weight = .bold, .color = .slate_900 });

        var kpis = s1.item().row(.{ .spacing = 12 });
        for (data.kpis) |card| {
            var k = kpis.relative(1).box(.{
                .padding = .{ .all = 12 },
                .background = .slate_50,
                .border = .{ .all = 1, .color = .slate_200, .radius = 8 },
                .shadow = .{ .offset_y = 2, .blur_sigma = 3 },
            }).column(.{ .spacing = 4 });
            k.item().text(card.label, .{ .size = 8, .weight = .bold, .color = .slate_500 });
            k.item().text(card.value, .{ .size = 15, .weight = .bold, .color = card.accent });
        }

        var chart_card = s1.item().semantic(.{ .tag = "Figure", .alt = "Quarterly Revenue Bar Chart" }).box(.{
            .padding = .{ .all = 14 },
            .background = .white,
            .border = .{ .all = 1, .color = .slate_200, .radius = 8 },
        }).column(.{ .spacing = 8 });
        chart_card.item().text("Quarterly Vector Growth Index (Native Skia Canvas)", .{ .size = 10, .weight = .bold, .color = .slate_700 });

        const chart_slot = chart_card.item().height(155);
        pagine.drawCanvas(chart_slot, data.series, drawRevenueChart);

        // Declarative X-axis labels aligned with bar columns
        if (data.series.quarters.len > 0) {
            var x_axis = chart_card.item().padding(.{ .horizontal = 8 }).row(.{ .spacing = 16 });
            for (data.series.quarters) |q| {
                x_axis.relative(1).alignCenter().text(q, .{ .size = 8.5, .weight = .medium, .color = .slate_600 });
            }
        }

        // Section 2: Balanced Multi-Column Commentary
        var s2 = col.item().section("sec_arch").column(.{ .spacing = 10 });
        s2.item().heading(1).text("2. Architecture & Benchmark Commentary", .{ .size = 18, .weight = .bold, .color = .slate_900 });

        var mc = s2.item().multiColumn(.{ .columns = 2, .spacing = 18, .balance_height = true });
        mc.spacer().alignCenter().lineVertical(.{ .thickness = 0.5, .color = .slate_200 });
        var mc_col = mc.content().column(.{ .spacing = 8 });
        for (data.commentary_notes, 1..) |note, i| {
            var rt = mc_col.item().richText(.{ .alignment = .justify });
            rt.print("Note {d}: ", .{i}, .{ .size = 9.5, .weight = .semi_bold, .color = .slate_900 });
            rt.span(note, .{ .size = 9.5, .color = .slate_700 });
        }
    }
}

fn drawRevenueChart(series: *const RevenueSeries, canvas: skia.Canvas, size: pagine.Size) void {
    var grid_paint = skia.Paint.init(.{
        .color = pagine.colorToSkia(.slate_200),
        .style = .stroke,
        .stroke_width = 0.75,
    });
    defer grid_paint.deinit();

    for (0..5) |i| {
        const y = size.height * (@as(f32, @floatFromInt(i)) / 4.0);
        canvas.drawLine(0, y, size.width, y, grid_paint);
    }

    if (series.values.len == 0) return;
    const n: f32 = @floatFromInt(series.values.len);
    const gap: f32 = 16;
    const bar_w = (size.width - gap * (n + 1)) / n;

    for (series.values, 0..) |v, i| {
        const h = (size.height - 14) * std.math.clamp(v, 0.0, 1.0);
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

/// Generates a crisp procedural PNG banner in memory so this example stays 100% self-contained
/// without external asset files. In real apps, replace with `pagine.Image.fromBytes(@embedFile("banner.png"))`.
pub fn makeSampleCoverBanner() !pagine.Image {
    const w: i32 = 480;
    const h: i32 = 120;
    var surf = try skia.Surface.makeRasterN32Premul(w, h);
    defer surf.deinit();
    const canvas = surf.canvas();

    // Soft layered waves + geometric accents
    const bg_colors = [_]skia.Color4f{
        pagine.colorToSkia(.blue_700).toColor4f(),
        pagine.colorToSkia(.indigo_600).toColor4f(),
    };
    const stops = [_]f32{ 0.0, 1.0 };
    var grad = skia.Shader.makeLinearGradient(.{ .x = 0, .y = 0 }, .{ .x = @floatFromInt(w), .y = @floatFromInt(h) }, &bg_colors, &stops, .clamp, null);
    defer if (grad) |*g| g.deinit();

    var fill = skia.Paint.init(.{ .color = pagine.colorToSkia(.blue_700), .anti_alias = true });
    defer fill.deinit();
    if (grad) |g| fill.setShader(g);
    canvas.drawRect(.fromXYWH(0, 0, @floatFromInt(w), @floatFromInt(h)), fill);

    var accent = skia.Paint.init(.{ .color = pagine.colorToSkia(pagine.Color.white.withAlpha(0x24)), .anti_alias = true });
    defer accent.deinit();
    canvas.drawCircle(390, 30, 82, accent);
    canvas.drawCircle(440, 105, 58, accent);

    var line_paint = skia.Paint.init(.{
        .color = pagine.colorToSkia(.blue_100),
        .style = .stroke,
        .stroke_width = 2.5,
        .anti_alias = true,
    });
    defer line_paint.deinit();
    const pts = [_][2]f32{ .{ 24, 92 }, .{ 96, 76 }, .{ 168, 82 }, .{ 240, 52 }, .{ 312, 42 }, .{ 384, 24 }, .{ 456, 18 } };
    for (0..pts.len - 1) |i| {
        canvas.drawLine(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], line_paint);
    }

    var snap = try surf.makeImageSnapshot();
    defer snap.deinit();
    var png = try snap.encodePng(null, 6);
    defer png.deinit();
    return pagine.Image.fromBytes(png.bytes());
}

fn writeOutputFile(io: std.Io, out_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len > 0) {
            if (std.Io.Dir.cwd().openDir(io, dir, .{})) |opened| {
                opened.close(io);
            } else |_| {
                try std.Io.Dir.cwd().createDirPath(io, dir);
            }
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = data });
    std.log.info("Wrote {s} ({d} bytes)", .{ out_path, data.len });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const out_path = if (args.len >= 2) args[1] else "zig-out/report.pdf";

    const logo_svg_xml =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="48" height="48">
        \\  <rect x="4" y="4" width="40" height="40" rx="10" fill="#2563EB"/>
        \\  <path d="M16 32 V16 H26 C30 16 32 18 32 21.5 C32 25 30 27 26 27 H21 V32 Z" fill="#FFFFFF"/>
        \\</svg>
    ;
    var logo = try pagine.Svg.fromBytes(logo_svg_xml, null);
    defer logo.deinit();

    var banner = try makeSampleCoverBanner();
    defer banner.deinit();

    const series: RevenueSeries = .{
        .quarters = &.{ "Q1", "Q2", "Q3", "Q4", "Q1'", "Q2'" },
        .values = &.{ 0.35, 0.52, 0.64, 0.78, 0.86, 0.96 },
    };
    const kpis = [_]KpiCard{
        .{ .label = "THROUGHPUT", .value = "530+ pg/s", .accent = .blue_600 },
        .{ .label = "HEAP LEAKS", .value = "0 bytes", .accent = .green_600 },
        .{ .label = "BACKENDS", .value = "PDF / PNG / SVG", .accent = .indigo_600 },
    };
    const notes = [_][]const u8{
        "Pagine stores the document structure in a contiguous Arena node pool and externalizes pagination cursors into a flat StateStore.",
        "Eliminating GC pressure enables O(N) speculative checkpoints for MultiColumn height balancing and deterministic layout recovery.",
        "Two-pass pagination resolves totalPages() and clickable Table of Contents section links without manual page-break bookkeeping.",
        "DPI-aware image downsampling deduplicates embedded PNG/JPEG payloads while preserving crisp vector SVG logos and Skia charts.",
        "The pure-Zig layout core has zero Skia dependencies, enabling millisecond feedback for pagination algorithms via zig build test-core.",
        "Full integration suites run under Zig 0.17 SafeAllocator to enforce zero heap leaks across PDF, raster PNG, and SVG exports.",
    };

    var doc = pagine.Document.init(gpa, .{});
    defer doc.deinit();

    compose(&doc, .{
        .title = "FY2026 Annual Engineering\n& Performance Report",
        .subtitle = "High-Throughput Document Generation with Zig 0.17 & Skia",
        .running_header = "FY2026 Engineering Report",
        .org_label = "pagine-pdf/pagine",
        .kpis = &kpis,
        .series = &series,
        .commentary_notes = &notes,
        .logo_svg = logo,
        .cover_banner = banner,
    });

    var pdf = try pagine.renderPdf(&doc, .{
        .title = "FY2026 Engineering & Performance Report",
        .author = "pagine",
        .lang = "en-US",
        .outline = .structure_element_headers,
    });
    defer pdf.deinit();

    try writeOutputFile(init.io, out_path, pdf.bytes());
}
