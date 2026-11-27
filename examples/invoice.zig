//! Commercial Invoice — Self-contained starter example.
//!
//! Copy this single file into your project and call `invoice.compose(&doc, data)`.
//! Demonstrates:
//! - Gradient `.box(...)` header & repeating page footer with two-pass `totalPages()`
//! - `showEntire()` to keep billing cards and totals/payment block intact
//! - Multi-page `Table` with repeating `headerCell()` and a local `dataCell()` helper
//! - Native `pagine.drawCanvas(...)` using `pagine.skia` (zero extra `"skia"` build import)

const std = @import("std");
const pagine = @import("pagine");
const skia = pagine.skia;

pub const Party = struct {
    name: []const u8,
    tax_id: ?[]const u8 = null,
    address_lines: []const []const u8 = &.{},
    email: ?[]const u8 = null,
};

pub const LineItem = struct {
    sku: []const u8,
    description: []const u8,
    qty: u32,
    unit_price: f64,
};

pub const InvoiceData = struct {
    invoice_number: []const u8,
    issue_date: []const u8,
    due_date: []const u8,
    currency: []const u8 = "$",
    tax_label: []const u8 = "GST (10%)",
    tax_rate: f64 = 0.10,
    seller: Party,
    buyer: Party,
    payment_lines: []const []const u8 = &.{},
    items: []const LineItem,
    footer_note: []const u8 = "Thank you for your business — generated with pagine (Zig 0.17 + Skia)",
    page_size: pagine.PageSizeMode = .a4,
    font_families: ?[]const [:0]const u8 = null,
};

/// Composes a multi-page commercial invoice onto `doc`.
pub fn compose(doc: *pagine.Document, data: InvoiceData) void {
    var page = doc.addPage(.{
        .size = data.page_size,
        .margin = .{ .all = pagine.mm(16) },
        .default_text_style = .{
            .font_families = data.font_families,
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
    if (data.seller.tax_id) |tid| {
        hdr_left.item().print("{s}  •  {s}", .{ data.seller.name, tid }, .{ .size = 9, .color = .slate_200 });
    } else {
        hdr_left.item().text(data.seller.name, .{ .size = 9, .color = .slate_200 });
    }

    var hdr_right = hdr.auto().alignMiddle().column(.{ .spacing = 2 });
    hdr_right.item().alignRight().print("#{s}", .{data.invoice_number}, .{ .size = 13, .weight = .bold, .color = .white });
    hdr_right.item().alignRight().print("Issued: {s}  •  Due: {s}", .{ data.issue_date, data.due_date }, .{ .size = 8.5, .color = .blue_100 });

    // Repeating Footer with two-pass resolved page numbers
    var ftr = page.footer().padding(.{ .top = 8 }).border(.{ .top = 0.75, .color = .slate_200 }).row(.{});
    ftr.relative(1).padding(.{ .top = 6 }).text(data.footer_note, .{ .size = 8.5, .color = .slate_500 });
    var ftr_pg = ftr.auto().padding(.{ .top = 6 }).alignRight().richText(.{ .style = .{ .size = 8.5, .color = .slate_600 } });
    ftr_pg.span("Page ", .{});
    ftr_pg.currentPageNumber(.{ .weight = .bold });
    ftr_pg.span(" of ", .{});
    ftr_pg.totalPages(.{ .weight = .bold });

    // Main Flow Content
    var col = page.content().padding(.{ .vertical = 12 }).column(.{ .spacing = 14 });

    // Billing & Payment cards kept together via `showEntire()`
    var addr = col.item().showEntire().row(.{ .spacing = 16 });
    var bill_to = addr.relative(1).box(.{
        .padding = .{ .all = 10 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 3 });
    bill_to.item().text("BILL TO", .{ .size = 8, .weight = .bold, .color = .blue_700 });
    bill_to.item().text(data.buyer.name, .{ .weight = .bold, .color = .slate_900 });
    for (data.buyer.address_lines) |line| {
        bill_to.item().text(line, .{ .size = 9, .color = .slate_600 });
    }
    if (data.buyer.email) |email| {
        bill_to.item().text(email, .{ .size = 9, .color = .slate_600 });
    }

    var pay_info = addr.relative(1).box(.{
        .padding = .{ .all = 10 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 3 });
    pay_info.item().text("PAYMENT DETAILS", .{ .size = 8, .weight = .bold, .color = .blue_700 });
    for (data.payment_lines) |line| {
        pay_info.item().text(line, .{ .size = 9, .color = .slate_600 });
    }

    // Paginated Line Items Table (header repeats automatically on each page)
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
    const bdr: pagine.BorderStyle = .{ .bottom = 0.5, .color = .slate_200 };
    for (data.items, 1..) |item, idx| {
        const line_total = @as(f64, @floatFromInt(item.qty)) * item.unit_price;
        subtotal += line_total;
        const bg: ?pagine.Color = if (idx % 2 == 0) .slate_50 else null;

        dataCell(tbl, bg, bdr).print("{d}", .{idx}, .{ .size = 9, .color = .slate_500 });
        dataCell(tbl, bg, bdr).text(item.sku, .{ .size = 9 });
        dataCell(tbl, bg, bdr).text(item.description, .{ .size = 9, .color = .slate_900 });
        dataCell(tbl, bg, bdr).alignRight().print("{d}", .{item.qty}, .{ .size = 9 });
        dataCell(tbl, bg, bdr).alignRight().print("{s}{d:.2}", .{ data.currency, item.unit_price }, .{ .size = 9 });
        dataCell(tbl, bg, bdr).alignRight().print("{s}{d:.2}", .{ data.currency, line_total }, .{ .size = 9, .weight = .semi_bold });
    }

    // Summary + Custom Skia Canvas Payment Matrix kept together via `showEntire()`
    const tax = subtotal * data.tax_rate;
    const grand_total = subtotal + tax;

    var summary = col.item().showEntire().padding(.{ .top = 6 }).row(.{ .spacing = 16 });
    var qr_box = summary.constant(96).box(.{
        .padding = .{ .all = 8 },
        .background = .white,
        .border = .{ .all = 1, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 4 });
    const qr_slot = qr_box.item().size(78, 78);
    pagine.drawCanvas(qr_slot, {}, drawPaymentPlaceholderMatrix);
    qr_box.item().alignCenter().text("Payment QR (demo)", .{ .size = 7, .color = .slate_500 });

    _ = summary.relative(1);

    var totals = summary.constant(240).box(.{
        .padding = .{ .all = 12 },
        .background = .slate_50,
        .border = .{ .all = 1, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 6 });

    var r_sub = totals.item().row(.{ .spacing = 8 });
    r_sub.relative(1).text("Subtotal", .{ .color = .slate_600 });
    r_sub.auto().alignRight().print("{s}{d:.2}", .{ data.currency, subtotal }, .{});

    var r_tax = totals.item().row(.{ .spacing = 8 });
    r_tax.relative(1).text(data.tax_label, .{ .color = .slate_600 });
    r_tax.auto().alignRight().print("{s}{d:.2}", .{ data.currency, tax }, .{});

    totals.item().lineHorizontal(.{ .thickness = 1, .color = .slate_300 });

    var r_grand = totals.item().row(.{ .spacing = 8 });
    r_grand.relative(1).text("Total Due", .{ .size = 12, .weight = .bold, .color = .slate_900 });
    r_grand.auto().alignRight().print("{s}{d:.2}", .{ data.currency, grand_total }, .{ .size = 13, .weight = .bold, .color = .blue_700 });
}

fn dataCell(tbl: pagine.TableBuilder, bg: ?pagine.Color, bdr: pagine.BorderStyle) pagine.Slot {
    return tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 6, .vertical = 5 });
}

/// Decorative 9x9 matrix drawn on native `pagine.skia.Canvas`.
/// NOTE: Visual placeholder only (not a scannable QR code — real QR starts at 21x21).
/// Replace with your QR encoder bit-matrix in production.
fn drawPaymentPlaceholderMatrix(_: void, canvas: skia.Canvas, size: pagine.Size) void {
    const dim = @min(size.width, size.height);
    const cells: usize = 9;
    const cell_sz = dim / @as(f32, @floatFromInt(cells));

    var dark = skia.Paint.init(.{ .color = pagine.colorToSkia(.slate_900), .anti_alias = false });
    defer dark.deinit();

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
    const out_path = if (args.len >= 2) args[1] else "zig-out/invoice.pdf";

    // Build 36 sample line items so the table spans 2 pages with a repeating header.
    var items: [36]LineItem = undefined;
    for (&items, 1..) |*slot, idx| {
        slot.* = .{
            .sku = try std.fmt.allocPrint(arena, "PAG-{d:0>3}", .{idx}),
            .description = try std.fmt.allocPrint(arena, "Enterprise Vector Layout Module — Tier {d}", .{(idx % 3) + 1}),
            .qty = @intCast((idx % 5) + 1),
            .unit_price = 45.0 + @as(f64, @floatFromInt((idx * 17) % 140)),
        };
    }

    var doc = pagine.Document.init(gpa, .{});
    defer doc.deinit();

    compose(&doc, .{
        .invoice_number = "INV-2026-0418",
        .issue_date = "27 Nov 2026",
        .due_date = "27 Dec 2026",
        .seller = .{
            .name = "Pagine Systems Pty Ltd",
            .tax_id = "ABN 12 345 678 901",
        },
        .buyer = .{
            .name = "Acme Robotics International",
            .address_lines = &.{"420 Innovation Drive, Sydney NSW 2000"},
            .email = "billing@acme-robotics.example",
        },
        .payment_lines = &.{
            "Bank Transfer (BSB 062-000 / ACC 98765432)",
            "Reference: INV-2026-0418",
            "Currency: USD (Net 30)",
        },
        .items = &items,
    });

    // Uses system fonts by default; pass `.fonts = &fonts` for custom/CJK TTF fonts.
    var pdf = try pagine.renderPdf(&doc, .{
        .title = "Invoice #INV-2026-0418",
        .author = "Pagine Systems",
    });
    defer pdf.deinit();

    try writeOutputFile(init.io, out_path, pdf.bytes());
}
