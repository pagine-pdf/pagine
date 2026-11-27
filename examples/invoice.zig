const std = @import("std");
const pagine = @import("pagine");
const skia = @import("skia");

const LineItem = struct {
    sku: []const u8,
    description: []const u8,
    qty: u32,
    unit_price: f64,
};

fn drawPaymentMatrix(_: void, canvas: skia.Canvas, size: pagine.Size) void {
    const dim = @min(size.width, size.height);
    const cells: usize = 9;
    const cell_sz = dim / @as(f32, @floatFromInt(cells));

    var dark = skia.Paint.init(.{ .color = pagine.colorToSkia(.slate_900), .anti_alias = false });
    defer dark.deinit();

    // Deterministic finder + data pattern resembling a crisp vector QR code
    const pattern: [9]u9 = .{
        0b111010111,
        0b101001101,
        0b111011111,
        0b000101000,
        0b101110101,
        0b010011010,
        0b111010110,
        0b101101001,
        0b111001111,
    };

    for (pattern, 0..) |row_bits, r| {
        for (0..cells) |c| {
            if (((row_bits >> @intCast(cells - 1 - c)) & 1) == 1) {
                canvas.drawRect(.fromXYWH(
                    @as(f32, @floatFromInt(c)) * cell_sz,
                    @as(f32, @floatFromInt(r)) * cell_sz,
                    cell_sz,
                    cell_sz,
                ), dark);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const out_path = if (args.len >= 2) args[1] else "invoice.pdf";

    var fonts = try pagine.FontRegistry.init(.{});
    defer fonts.deinit();
    fonts.registerFile("../../skia-zig/skia-zig/assets/fonts/Roboto-Regular.ttf", "Roboto") catch {};

    var doc = pagine.Document.init(gpa, .{});
    defer doc.deinit();

    var page = doc.addPage(.{
        .size = .a4,
        .margin = .{ .all = pagine.mm(16) },
        .default_text_style = .{
            .font_families = &.{"Roboto"},
            .size = 10,
            .color = .slate_800,
        },
    });

    // Repeating Header
    var hdr = page.header().padding(.{ .bottom = 12 }).box(.{
        .padding = .{ .horizontal = 16, .vertical = 12 },
        .gradient = .{
            .angle_deg = 0,
            .stops = &.{
                .{ .pos = 0.0, .color = .slate_900 },
                .{ .pos = 1.0, .color = .blue_700 },
            },
        },
        .radius = 8,
    }).row(.{ .spacing = 12 });
    var hdr_left = hdr.relative(1).column(.{ .spacing = 2 });
    hdr_left.item().heading(1).text("INVOICE", .{ .size = 20, .weight = .bold, .color = .white });
    hdr_left.item().text("Pagine Systems Pty Ltd  •  ABN 12 345 678 901", .{ .size = 9, .color = .slate_200 });

    var hdr_right = hdr.auto().alignMiddle().column(.{ .spacing = 2 });
    hdr_right.item().alignRight().text("#INV-2026-0418", .{ .size = 13, .weight = .bold, .color = .white });
    hdr_right.item().alignRight().text("Issued: 27 Nov 2026  •  Due: 27 Dec 2026", .{ .size = 8.5, .color = .blue_100 });

    // Repeating Footer with two-pass resolved page numbers
    var ftr = page.footer().padding(.{ .top = 8 }).border(.{ .top = 0.75, .color = .slate_200 }).row(.{});
    ftr.relative(1).padding(.{ .top = 6 }).text("Thank you for your business — generated with pagine (Zig 0.17 + Skia)", .{ .size = 8.5, .color = .slate_500 });
    var ftr_pg = ftr.auto().padding(.{ .top = 6 }).alignRight().richText(.{ .style = .{ .size = 8.5, .color = .slate_600 } });
    ftr_pg.span("Page ", .{});
    ftr_pg.currentPageNumber(.{ .weight = .bold });
    ftr_pg.span(" of ", .{});
    ftr_pg.totalPages(.{ .weight = .bold });

    // Main Content
    var col = page.content().padding(.{ .vertical = 12 }).column(.{ .spacing = 14 });

    // Billing & Shipping addresses (only on Page 1 via ShowOnce)
    var addr = col.item().showOnce().row(.{ .spacing = 16 });
    var bill_to = addr.relative(1).box(.{
        .padding = .{ .all = 10 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 3 });
    bill_to.item().text("BILL TO", .{ .size = 8, .weight = .bold, .color = .blue_700 });
    bill_to.item().text("Acme Robotics International", .{ .weight = .bold });
    bill_to.item().text("420 Innovation Drive, Sydney NSW 2000", .{ .size = 9, .color = .slate_600 });
    bill_to.item().text("billing@acme-robotics.example", .{ .size = 9, .color = .slate_600 });

    var pay_info = addr.relative(1).box(.{
        .padding = .{ .all = 10 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 3 });
    pay_info.item().text("PAYMENT DETAILS", .{ .size = 8, .weight = .bold, .color = .blue_700 });
    pay_info.item().text("Bank Transfer (BSB 062-000 / ACC 98765432)", .{ .size = 9 });
    pay_info.item().text("Reference: INV-2026-0418", .{ .size = 9, .color = .slate_600 });
    pay_info.item().text("Currency: USD (Net 30)", .{ .size = 9, .color = .slate_600 });

    // Line items table (36 items -> naturally spans 2 pages with repeating table header!)
    var tbl = col.item().table(.{
        .columns = &.{ .fixed(34), .fixed(76), .rel(3), .fixed(46), .fixed(76), .fixed(84) },
    });
    const headers = [_]struct { label: []const u8, right: bool }{
        .{ .label = "#", .right = false },
        .{ .label = "SKU", .right = false },
        .{ .label = "Description", .right = false },
        .{ .label = "Qty", .right = true },
        .{ .label = "Unit Price", .right = true },
        .{ .label = "Line Total", .right = true },
    };
    for (headers) |h| {
        var s = tbl.headerCell().background(.slate_800).padding(.{ .horizontal = 6, .vertical = 7 });
        if (h.right) s = s.alignRight();
        s.text(h.label, .{ .size = 9, .weight = .bold, .color = .white });
    }

    var subtotal: f64 = 0;
    for (1..37) |idx| {
        const qty: u32 = @intCast((idx % 5) + 1);
        const unit_price: f64 = 45.0 + @as(f64, @floatFromInt((idx * 17) % 140));
        const line_total = @as(f64, @floatFromInt(qty)) * unit_price;
        subtotal += line_total;

        const bg: ?pagine.Color = if (idx % 2 == 0) .slate_50 else null;
        const bdr: pagine.BorderStyle = .{ .bottom = 0.5, .color = .slate_200 };

        tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 6, .vertical = 5 }).print("{d}", .{idx}, .{ .size = 9, .color = .slate_500 });
        tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 6, .vertical = 5 }).print("PAG-{d:0>3}", .{idx}, .{ .size = 9 });
        tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 6, .vertical = 5 }).print("Enterprise Vector Layout Module — Tier {d}", .{(idx % 3) + 1}, .{ .size = 9 });
        tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 6, .vertical = 5 }).alignRight().print("{d}", .{qty}, .{ .size = 9 });
        tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 6, .vertical = 5 }).alignRight().print("${d:.2}", .{unit_price}, .{ .size = 9 });
        tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 6, .vertical = 5 }).alignRight().print("${d:.2}", .{line_total}, .{ .size = 9, .weight = .semi_bold });
    }

    // Summary + Payment QR kept together via ShowEntire
    const tax = subtotal * 0.10;
    const grand_total = subtotal + tax;

    var summary = col.item().showEntire().padding(.{ .top = 6 }).row(.{ .spacing = 16 });
    var qr_box = summary.constant(96).box(.{
        .padding = .{ .all = 8 },
        .background = .white,
        .border = .{ .all = 1, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 4 });
    const qr_slot = qr_box.item().size(78, 78);
    pagine.drawCanvas(qr_slot, {}, drawPaymentMatrix);
    qr_box.item().alignCenter().text("Scan to pay", .{ .size = 7.5, .color = .slate_500 });

    var totals = summary.relative(1).alignRight().width(240).box(.{
        .padding = .{ .all = 12 },
        .background = .slate_50,
        .border = .{ .all = 1, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 6 });

    var r_sub = totals.item().row(.{});
    r_sub.relative(1).text("Subtotal", .{ .color = .slate_600 });
    r_sub.auto().alignRight().print("${d:.2}", .{subtotal}, .{});

    var r_tax = totals.item().row(.{});
    r_tax.relative(1).text("GST (10%)", .{ .color = .slate_600 });
    r_tax.auto().alignRight().print("${d:.2}", .{tax}, .{});

    totals.item().lineHorizontal(.{ .thickness = 1, .color = .slate_300 });

    var r_grand = totals.item().row(.{});
    r_grand.relative(1).text("Total Due", .{ .size = 12, .weight = .bold, .color = .slate_900 });
    r_grand.auto().alignRight().print("${d:.2}", .{grand_total}, .{ .size = 13, .weight = .bold, .color = .blue_700 });

    var pdf = try pagine.renderPdf(&doc, .{
        .fonts = &fonts,
        .title = "Invoice #INV-2026-0418",
        .author = "Pagine Systems",
    });
    defer pdf.deinit();

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = pdf.bytes() });
    std.log.info("Wrote {s} ({d} bytes)", .{ out_path, pdf.bytes().len });
}
