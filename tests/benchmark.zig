const std = @import("std");
const pagine = @import("pagine");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var fonts = try pagine.FontRegistry.init(.{});
    defer fonts.deinit();
    fonts.registerFile("../../skia-zig/skia-zig/assets/fonts/Roboto-Regular.ttf", "Roboto") catch {};

    const row_count: usize = 2_000; // ~85+ A4 pages of rich table rows + repeating header/footer

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
        .fonts = &fonts,
        .title = "pagine Benchmark",
    });
    defer pdf.deinit();

    const t2 = std.Io.Clock.now(.awake, io);

    const compose_ms = @as(f64, @floatFromInt(t1.nanoseconds - t0.nanoseconds)) / 1e6;
    const render_ms = @as(f64, @floatFromInt(t2.nanoseconds - t1.nanoseconds)) / 1e6;
    const total_ms = compose_ms + render_ms;

    // Count emitted pages from PDF bytes
    var page_count: usize = 0;
    var pos: usize = 0;
    const bytes = pdf.bytes();
    while (std.mem.indexOfPos(u8, bytes, pos, "/Type /Page\n")) |idx| {
        page_count += 1;
        pos = idx + 12;
    }
    if (page_count == 0) {
        pos = 0;
        while (std.mem.indexOfPos(u8, bytes, pos, "/MediaBox")) |idx| {
            page_count += 1;
            pos = idx + 9;
        }
    }

    const pages_per_sec = if (total_ms > 0) (@as(f64, @floatFromInt(page_count)) / (total_ms / 1000.0)) else 0;
    var buf: [256]u8 = undefined;
    const summary = try std.fmt.bufPrint(
        &buf,
        "pagine bench ({d} rows -> {d} pages, {d} KB PDF): compose={d:.2}ms, render={d:.2}ms, total={d:.2}ms ({d:.1} pages/s)\n",
        .{ row_count, page_count, bytes.len / 1024, compose_ms, render_ms, total_ms, pages_per_sec },
    );
    try std.Io.File.stdout().writeStreamingAll(io, summary);
}
