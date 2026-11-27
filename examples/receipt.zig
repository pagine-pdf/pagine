//! Continuous-Roll Thermal POS Receipt — Self-contained starter example.
//!
//! Copy this single file into your project and call `receipt.compose(&doc, data)`.
//! Demonstrates:
//! - `.{ .continuous = width }` page sizing (auto-fits vertical height; supports 80mm & 58mm rolls)
//! - Dashed horizontal separators, itemized modifiers, tax/discount/change breakdown
//! - Genuine scannable ISO/IEC 16388 Code 39 vector barcode in pure declarative `pagine.Row`

const std = @import("std");
const pagine = @import("pagine");

pub const ReceiptItem = struct {
    name: []const u8,
    qty: u32 = 1,
    unit_price: f64,
    modifier: ?[]const u8 = null,
};

pub const ReceiptData = struct {
    /// Thermal paper roll width in points (default `pagine.mm(80)`; also supports `pagine.mm(58)`).
    roll_width_pt: f32 = pagine.mm(80),
    currency: []const u8 = "$",
    store_name: []const u8,
    store_address: []const []const u8 = &.{},
    store_phone: ?[]const u8 = null,
    tax_id: ?[]const u8 = null,
    receipt_number: []const u8,
    timestamp: []const u8,
    cashier: ?[]const u8 = null,
    terminal_id: ?[]const u8 = null,
    items: []const ReceiptItem,
    discount: f64 = 0,
    tax_label: []const u8 = "GST (10%)",
    /// When null, computed as `(subtotal - discount) * tax_rate`.
    tax_amount: ?f64 = null,
    tax_rate: f64 = 0.10,
    payment_method: []const u8 = "Card (Visa •••• 4242)",
    amount_tendered: ?f64 = null,
    /// Valid Code 39 characters: `0-9`, `A-Z`, `-`, `.`, space, `$`, `/`, `+`, `%`.
    barcode_value: ?[]const u8 = null,
    footer_lines: []const []const u8 = &.{"Thank you for shopping with us!"},
    font_families: ?[]const [:0]const u8 = null,
};

/// Composes a continuous-roll thermal POS receipt onto `doc`.
pub fn compose(doc: *pagine.Document, data: ReceiptData) void {
    const is_narrow = data.roll_width_pt < pagine.mm(65);
    const body_size: f32 = if (is_narrow) 7.5 else 8.5;
    const h_margin = pagine.mm(4.5);

    var page = doc.addPage(.{
        .size = .{ .continuous = data.roll_width_pt },
        .margin = .{ .horizontal = h_margin, .vertical = pagine.mm(6) },
        .default_text_style = .{
            .font_families = data.font_families,
            .size = body_size,
            .color = .slate_900,
        },
    });

    var col = page.content().column(.{ .spacing = 5 });

    // Store Header
    var hdr = col.item().column(.{ .spacing = 1.5 });
    hdr.item().alignCenter().heading(1).text(data.store_name, .{
        .size = if (is_narrow) 11 else 13,
        .weight = .bold,
        .color = .black,
    });
    for (data.store_address) |line| {
        hdr.item().alignCenter().text(line, .{ .size = body_size - 0.8, .color = .slate_500 });
    }
    if (data.store_phone) |ph| {
        hdr.item().alignCenter().print("Tel: {s}", .{ph}, .{ .size = body_size - 0.8, .color = .slate_500 });
    }
    if (data.tax_id) |tid| {
        hdr.item().alignCenter().print("Tax ID: {s}", .{tid}, .{ .size = body_size - 1.0, .color = .slate_500 });
    }

    col.item().lineHorizontal(.{ .thickness = 0.75, .color = .slate_400, .dash = .{ .on = 3, .off = 2 } });

    // Order Metadata
    var meta = col.item().column(.{ .spacing = 1.5 });
    var m1 = meta.item().row(.{});
    m1.relative(1).print("Receipt #{s}", .{data.receipt_number}, .{ .size = body_size - 0.5, .weight = .bold });
    m1.auto().alignRight().text(data.timestamp, .{ .size = body_size - 0.8, .color = .slate_500 });

    if (data.cashier != null or data.terminal_id != null) {
        var m2 = meta.item().row(.{});
        if (data.cashier) |cashier| {
            m2.relative(1).print("Staff: {s}", .{cashier}, .{ .size = body_size - 0.8, .color = .slate_500 });
        } else {
            _ = m2.relative(1);
        }
        if (data.terminal_id) |term| {
            m2.auto().alignRight().print("POS: {s}", .{term}, .{ .size = body_size - 0.8, .color = .slate_500 });
        }
    }

    col.item().lineHorizontal(.{ .thickness = 0.75, .color = .slate_400, .dash = .{ .on = 3, .off = 2 } });

    // Items List
    var items_col = col.item().column(.{ .spacing = 4 });
    var subtotal: f64 = 0;
    for (data.items) |item| {
        const line_total = @as(f64, @floatFromInt(item.qty)) * item.unit_price;
        subtotal += line_total;

        var entry = items_col.item().column(.{ .spacing = 1 });
        var line = entry.item().row(.{ .spacing = 4 });
        line.relative(1).text(item.name, .{ .size = body_size, .weight = .medium, .color = .black });
        printMoney(line.auto().alignRight(), data.currency, line_total, .{ .size = body_size, .weight = .medium, .color = .black });

        if (item.qty > 1) {
            entry.item().padding(.{ .left = 6 }).print("{d} x {s}{d:.2}", .{ item.qty, data.currency, item.unit_price }, .{
                .size = body_size - 1.0,
                .color = .slate_500,
            });
        }
        if (item.modifier) |mod| {
            entry.item().padding(.{ .left = 6 }).print("+ {s}", .{mod}, .{
                .size = body_size - 1.0,
                .color = .slate_500,
                .slant = .italic,
            });
        }
    }

    col.item().lineHorizontal(.{ .thickness = 0.75, .color = .slate_400, .dash = .{ .on = 3, .off = 2 } });

    // Totals
    const taxable = @max(0.0, subtotal - data.discount);
    const tax_val = data.tax_amount orelse (taxable * data.tax_rate);
    const grand_total = taxable + tax_val;

    var totals = col.item().column(.{ .spacing = 2.5 });
    var r_sub = totals.item().row(.{});
    r_sub.relative(1).text("Subtotal", .{ .size = body_size, .color = .slate_500 });
    printMoney(r_sub.auto().alignRight(), data.currency, subtotal, .{ .size = body_size });

    if (data.discount > 0.004) {
        var r_disc = totals.item().row(.{});
        r_disc.relative(1).text("Discount", .{ .size = body_size, .color = .slate_500 });
        printMoney(r_disc.auto().alignRight(), data.currency, -data.discount, .{ .size = body_size });
    }

    if (tax_val > 0.004) {
        var r_tax = totals.item().row(.{});
        r_tax.relative(1).text(data.tax_label, .{ .size = body_size, .color = .slate_500 });
        printMoney(r_tax.auto().alignRight(), data.currency, tax_val, .{ .size = body_size });
    }

    totals.item().padding(.{ .vertical = 2 }).lineHorizontal(.{ .thickness = 1.0, .color = .black });

    var r_total = totals.item().row(.{});
    r_total.relative(1).text("TOTAL", .{ .size = body_size + 2.5, .weight = .bold, .color = .black });
    printMoney(r_total.auto().alignRight(), data.currency, grand_total, .{
        .size = body_size + 2.5,
        .weight = .bold,
        .color = .black,
    });

    // Payment & Change
    var pay = col.item().padding(.{ .top = 2 }).column(.{ .spacing = 1.5 });
    var r_pm = pay.item().row(.{});
    r_pm.relative(1).text(data.payment_method, .{ .size = body_size - 0.5, .color = .slate_500 });
    const tendered = data.amount_tendered orelse grand_total;
    printMoney(r_pm.auto().alignRight(), data.currency, tendered, .{ .size = body_size - 0.5 });

    if (tendered - grand_total > 0.004) {
        var r_chg = pay.item().row(.{});
        r_chg.relative(1).text("Change", .{ .size = body_size - 0.5, .weight = .bold });
        printMoney(r_chg.auto().alignRight(), data.currency, tendered - grand_total, .{ .size = body_size - 0.5, .weight = .bold });
    }

    // Scannable Code 39 Vector Barcode (auto-scaled to never overflow 58mm rolls)
    if (data.barcode_value) |code| {
        const content_w = @max(80.0, data.roll_width_pt - 2.0 * h_margin - 4.0);
        col.item().padding(.{ .top = 4 }).lineHorizontal(.{ .thickness = 0.5, .color = .slate_300, .dash = .{ .on = 2, .off = 2 } });
        composeCode39Barcode(col.item().padding(.{ .vertical = 4 }), code, content_w, 28, .black);
    }

    // Footer lines
    if (data.footer_lines.len > 0) {
        var ftr = col.item().padding(.{ .top = 3 }).column(.{ .spacing = 1.5 });
        for (data.footer_lines) |line| {
            ftr.item().alignCenter().text(line, .{ .size = body_size - 0.8, .color = .slate_500 });
        }
    }
}

/// Renders a genuine ISO/IEC 16388 Code 39 vector barcode wrapped in `*` start/stop delimiters.
fn composeCode39Barcode(slot: pagine.Slot, raw_code: []const u8, max_width: f32, bar_height: f32, color: pagine.Color) void {
    var valid_count: usize = 0;
    for (raw_code) |ch| {
        if (code39Pattern(std.ascii.toUpper(ch)) != null) valid_count += 1;
    }
    const symbol_count = valid_count + 2; // start '*' + data + stop '*'
    const wide_ratio: f32 = 2.2;
    const units_per_symbol: f32 = 6.0 + 3.0 * wide_ratio;
    const total_units: f32 = @as(f32, @floatFromInt(symbol_count)) * units_per_symbol + @as(f32, @floatFromInt(symbol_count - 1));
    const nw: f32 = @min(0.95, max_width / total_units);
    const ww: f32 = nw * wide_ratio;

    var col = slot.column(.{ .spacing = 3 });
    const bars = col.item().height(bar_height).alignCenter().row(.{ .spacing = 0 });

    emitCode39Symbol(bars, code39Pattern('*').?, nw, ww, bar_height, color, true);
    for (raw_code) |ch| {
        if (code39Pattern(std.ascii.toUpper(ch))) |pat| {
            emitCode39Symbol(bars, pat, nw, ww, bar_height, color, true);
        }
    }
    emitCode39Symbol(bars, code39Pattern('*').?, nw, ww, bar_height, color, false);

    col.item().alignCenter().print("*{s}*", .{raw_code}, .{
        .size = 7.2,
        .color = .slate_600,
        .letter_spacing = 0.8,
    });
}

fn emitCode39Symbol(bars: pagine.RowBuilder, pattern: u9, nw: f32, ww: f32, h: f32, color: pagine.Color, trailing_gap: bool) void {
    for (0..9) |bit_idx| {
        const is_wide = ((pattern >> @intCast(8 - bit_idx)) & 1) != 0;
        const w = if (is_wide) ww else nw;
        if ((bit_idx % 2) == 0) {
            _ = bars.constant(w).height(h).background(color);
        } else {
            _ = bars.constant(w);
        }
    }
    if (trailing_gap) _ = bars.constant(nw);
}

fn code39Pattern(ch: u8) ?u9 {
    return switch (ch) {
        '0' => 0b000110100,
        '1' => 0b100100001,
        '2' => 0b001100001,
        '3' => 0b101100000,
        '4' => 0b000110001,
        '5' => 0b100110000,
        '6' => 0b001110000,
        '7' => 0b000100101,
        '8' => 0b100100100,
        '9' => 0b001100100,
        'A' => 0b100001001,
        'B' => 0b001001001,
        'C' => 0b101001000,
        'D' => 0b000011001,
        'E' => 0b100011000,
        'F' => 0b001011000,
        'G' => 0b000001101,
        'H' => 0b100001100,
        'I' => 0b001001100,
        'J' => 0b000011100,
        'K' => 0b100000011,
        'L' => 0b001000011,
        'M' => 0b101000010,
        'N' => 0b000010011,
        'O' => 0b100010010,
        'P' => 0b001010010,
        'Q' => 0b000000111,
        'R' => 0b100000110,
        'S' => 0b001000110,
        'T' => 0b000010110,
        'U' => 0b110000001,
        'V' => 0b011000001,
        'W' => 0b111000000,
        'X' => 0b010010001,
        'Y' => 0b110010000,
        'Z' => 0b011010000,
        '-' => 0b010000101,
        '.' => 0b110000100,
        ' ' => 0b011000100,
        '$' => 0b010101000,
        '/' => 0b010100010,
        '+' => 0b010001010,
        '%' => 0b000101010,
        '*' => 0b010010100,
        else => null,
    };
}

fn printMoney(slot: pagine.Slot, symbol: []const u8, amount: f64, ts: pagine.TextStyle) void {
    if (amount < -0.004) {
        slot.print("-{s}{d:.2}", .{ symbol, @abs(amount) }, ts);
    } else {
        slot.print("{s}{d:.2}", .{ symbol, @abs(amount) }, ts);
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
    const out_path = if (args.len >= 2) args[1] else "zig-out/receipt.pdf";

    const items = [_]ReceiptItem{
        .{ .name = "Flat White (Large)", .qty = 2, .unit_price = 5.50, .modifier = "Oat milk, extra shot" },
        .{ .name = "Almond Croissant", .qty = 1, .unit_price = 6.80 },
        .{ .name = "Single Origin Beans 250g", .qty = 1, .unit_price = 22.00, .modifier = "Whole bean" },
    };

    var doc = pagine.Document.init(gpa, .{});
    defer doc.deinit();

    compose(&doc, .{
        .store_name = "PAGINE ROASTERS",
        .store_address = &.{ "24 Barangaroo Ave", "Sydney NSW 2000" },
        .store_phone = "+61 2 9000 1234",
        .tax_id = "ABN 98 765 432 109",
        .receipt_number = "POS-004819",
        .timestamp = "27/11/2026 09:42",
        .cashier = "Maya L.",
        .terminal_id = "REG-02",
        .items = &items,
        .discount = 2.00,
        .tax_label = "GST (10%)",
        .tax_rate = 0.10,
        .payment_method = "Apple Pay (Visa •••• 1024)",
        .barcode_value = "POS-4819",
        .footer_lines = &.{
            "Thank you for visiting Pagine Roasters!",
            "Wi-Fi: PagineGuest  •  Code: zig017",
        },
    });

    var pdf = try pagine.renderPdf(&doc, .{
        .title = "Receipt POS-004819",
        .author = "Pagine Roasters",
    });
    defer pdf.deinit();

    try writeOutputFile(init.io, out_path, pdf.bytes());
}
