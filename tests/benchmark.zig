const std = @import("std");
const pagine = @import("pagine");
const support = @import("support");

const roboto_ttf = @embedFile("roboto_ttf");

const Sample = struct {
    compose_ms: f64,
    render_ms: f64,
    total_ms: f64,
    page_count: usize,
    pdf_bytes: usize,
};

fn runOnce(gpa: std.mem.Allocator, io: std.Io, fonts: *const pagine.FontRegistry, row_count: usize) !Sample {
    const t0 = std.Io.Clock.now(.awake, io);

    var doc = pagine.Document.init(gpa, .{});
    defer doc.deinit();

    var page = doc.addPage(.{
        .size = .a4,
        .margin = .{ .all = pagine.mm(15) },
        .default_text_style = .{ .font_families = &.{"Roboto"}, .size = 9.5, .color = .slate_800 },
    });
    page.header().padding(.{ .bottom = 6 }).text("pagine Throughput Benchmark", .{ .size = 13, .weight = .bold, .color = .blue_700 });
    var ftr = page.footer().alignCenter().richText(.{ .style = .{ .size = 8.5, .color = .slate_500 } });
    ftr.span("Page ", .{});
    ftr.currentPageNumber(.{});
    ftr.span(" / ", .{});
    ftr.totalPages(.{});

    var tbl = page.content().table(.{
        .columns = &.{ .fixed(40), .rel(3), .fixed(70), .fixed(80) },
    });
    for ([_][]const u8{ "#", "Item Description", "Quantity", "Subtotal" }) |h| {
        tbl.headerCell().background(.slate_800).padding(.{ .all = 5 }).text(h, .{ .color = .white, .weight = .bold });
    }
    for (1..row_count + 1) |i| {
        const bg: ?pagine.Color = if (i % 2 == 0) .slate_50 else null;
        tbl.cell().backgroundOpt(bg).padding(.{ .all = 4 }).print("{d}", .{i}, .{});
        tbl.cell().backgroundOpt(bg).padding(.{ .all = 4 }).print("Benchmark Vector Line Item #{d}", .{i}, .{});
        tbl.cell().backgroundOpt(bg).padding(.{ .all = 4 }).alignRight().print("{d}", .{(i % 9) + 1}, .{});
        tbl.cell().backgroundOpt(bg).padding(.{ .all = 4 }).alignRight().print("${d}.00", .{i * 12}, .{});
    }

    const t1 = std.Io.Clock.now(.awake, io);

    var pdf = try pagine.renderPdf(&doc, .{
        .fonts = fonts,
        .title = "pagine Benchmark",
    });
    defer pdf.deinit();

    const t2 = std.Io.Clock.now(.awake, io);

    const compose_ms = @as(f64, @floatFromInt(t1.nanoseconds - t0.nanoseconds)) / 1e6;
    const render_ms = @as(f64, @floatFromInt(t2.nanoseconds - t1.nanoseconds)) / 1e6;
    const bytes = pdf.bytes();

    return .{
        .compose_ms = compose_ms,
        .render_ms = render_ms,
        .total_ms = compose_ms + render_ms,
        .page_count = support.countPdfPages(bytes),
        .pdf_bytes = bytes.len,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var fonts = try pagine.FontRegistry.init(.{});
    defer fonts.deinit();
    try fonts.registerBytes(roboto_ttf, "Roboto");

    const row_count: usize = 2_000;
    const iterations: usize = 3;

    // 1 warm-up run (primes font shaping & Skia caches so measured runs reflect steady-state throughput)
    _ = try runOnce(gpa, io, &fonts, row_count);

    var samples: [iterations]Sample = undefined;
    for (0..iterations) |i| {
        samples[i] = try runOnce(gpa, io, &fonts, row_count);
    }

    // Sort by total_ms to report median & best
    std.mem.sort(Sample, &samples, {}, struct {
        fn lessThan(_: void, a: Sample, b: Sample) bool {
            return a.total_ms < b.total_ms;
        }
    }.lessThan);

    const best = samples[0];
    const median = samples[iterations / 2];
    const pages_per_sec = if (median.total_ms > 0) (@as(f64, @floatFromInt(median.page_count)) / (median.total_ms / 1000.0)) else 0;

    var buf: [320]u8 = undefined;
    const summary = try std.fmt.bufPrint(
        &buf,
        "pagine bench ({d} rows -> {d} pages, {d} KB PDF, 1 warmup + {d} runs): median compose={d:.2}ms, render={d:.2}ms, total={d:.2}ms ({d:.1} pages/s; best={d:.2}ms)\n",
        .{
            row_count,
            median.page_count,
            median.pdf_bytes / 1024,
            iterations,
            median.compose_ms,
            median.render_ms,
            median.total_ms,
            pages_per_sec,
            best.total_ms,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(io, summary);
}
