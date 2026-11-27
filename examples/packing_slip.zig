//! Warehouse Packing Slip & Multi-Shipment Batch Merge — Self-contained starter example.
//!
//! Copy this single file into your project and call `packing_slip.compose(&doc, data)`.
//! Demonstrates:
//! - `Table` with merged `row_span` cells (`cellAt`) for carton grouping & `extend_last_cells_to_bottom`
//! - `Inlined` flow-wrapped handling tags via zero-boxing struct `slot.component(Badge{ ... })`
//! - Genuine scannable Code 39 tracking barcode + printable pick-and-pack checkboxes
//! - Batch multi-document merging via `pagine.mergePdf(..., .independent, ...)` (each slip keeps its own Page 1/N)

const std = @import("std");
const pagine = @import("pagine");

pub const PartyInfo = struct {
    name: []const u8,
    subtitle: ?[]const u8 = null,
    address_lines: []const []const u8 = &.{},
    phone: ?[]const u8 = null,
};

pub const BadgeTone = enum {
    info,
    success,
    warning,
    danger,

    pub fn background(self: BadgeTone) pagine.Color {
        return switch (self) {
            .info => .blue_100,
            .success => .green_200,
            .warning => .amber_200,
            .danger => .red_200,
        };
    }

    pub fn foreground(self: BadgeTone) pagine.Color {
        return switch (self) {
            .info => .blue_900,
            .success => .green_700,
            .warning => .amber_900,
            .danger => .red_700,
        };
    }
};

/// Zero-boxing reusable component invoked via `slot.component(Badge{ ... })`.
pub const Badge = struct {
    label: []const u8,
    tone: BadgeTone = .warning,

    pub fn compose(self: Badge, slot: pagine.Slot) void {
        slot.box(.{
            // Optical vertical centering: Latin font line-boxes reserve descender space below the
            // baseline, so uppercase badge labels look centered with slightly more top than bottom padding.
            .padding = .{ .left = 7, .right = 7, .top = 3.5, .bottom = 1.8 },
            .background = self.tone.background(),
            .radius = 4,
        }).text(self.label, .{
            .size = 8,
            .weight = .bold,
            .color = self.tone.foreground(),
        });
    }
};

pub const PackingItem = struct {
    sku: []const u8,
    description: []const u8,
    bin_location: []const u8 = "—",
    ordered_qty: u32,
    shipped_qty: u32,
    weight_kg: ?f64 = null,
};

pub const CartonGroup = struct {
    carton_label: []const u8,
    items: []const PackingItem,
};

pub const PackingSlipData = struct {
    title: []const u8 = "PACKING SLIP",
    order_number: []const u8,
    shipment_id: []const u8,
    ship_date: []const u8,
    carrier: []const u8,
    service_level: []const u8 = "Standard Ground",
    /// Valid Code 39 characters: `0-9`, `A-Z`, `-`, `.`, space, `$`, `/`, `+`, `%`.
    tracking_number: ?[]const u8 = null,
    ship_from: PartyInfo,
    ship_to: PartyInfo,
    /// Items grouped by physical carton so the table demonstrates `row_span` grouping.
    cartons: []const CartonGroup,
    gross_weight_kg: ?f64 = null,
    dimensions_cm: ?[]const u8 = null,
    handling_tags: []const Badge = &.{},
    special_instructions: ?[]const u8 = null,
    footer_note: []const u8 = "Verify parcel contents upon delivery and report discrepancies within 48 hours.",
    page_size: pagine.PageSizeMode = .a4,
    font_families: ?[]const [:0]const u8 = null,
};

/// Composes a warehouse packing slip onto `doc`.
pub fn compose(doc: *pagine.Document, data: PackingSlipData) void {
    var page = doc.addPage(.{
        .size = data.page_size,
        .margin = .{ .all = pagine.mm(15) },
        .default_text_style = .{
            .font_families = data.font_families,
            .size = 9,
            .color = .slate_800,
        },
    });

    // Repeating Logistics Header
    var hdr = page.header().padding(.{ .bottom = 8 }).border(.{ .bottom = 1.5, .color = .slate_900 }).row(.{ .spacing = 12 });
    var hdr_l = hdr.relative(1).padding(.{ .bottom = 6 }).column(.{ .spacing = 2 });
    hdr_l.item().heading(1).text(data.title, .{ .size = 18, .weight = .bold, .color = .slate_900 });
    hdr_l.item().print("Order #{s}   •   Shipment #{s}", .{ data.order_number, data.shipment_id }, .{
        .size = 9.5,
        .weight = .semi_bold,
        .color = .blue_700,
    });
    hdr_l.item().print("Ship Date: {s}   •   {s} ({s})", .{ data.ship_date, data.carrier, data.service_level }, .{
        .size = 8.5,
        .color = .slate_500,
    });

    if (data.tracking_number) |trk| {
        const hdr_r = hdr.constant(175).padding(.{ .bottom = 4 }).alignMiddle();
        composeCode39Barcode(hdr_r, trk, 170, 26, .slate_900);
    }

    // Repeating Footer
    var ftr = page.footer().padding(.{ .top = 8 }).border(.{ .top = 0.75, .color = .slate_200 }).row(.{ .spacing = 8 });
    ftr.relative(1).padding(.{ .top = 5 }).text(data.footer_note, .{ .size = 8, .color = .slate_500 });
    var pg = ftr.auto().padding(.{ .top = 5 }).alignRight().richText(.{ .style = .{ .size = 8, .color = .slate_500 } });
    pg.span("Page ", .{});
    pg.currentPageNumber(.{ .weight = .bold, .color = .slate_800 });
    pg.span(" of ", .{});
    pg.totalPages(.{ .weight = .bold, .color = .slate_800 });

    var col = page.content().padding(.{ .vertical = 10 }).column(.{ .spacing = 11 });

    // Addresses & Handling Tags kept together
    var top = col.item().showEntire().column(.{ .spacing = 8 });
    var addrs = top.item().row(.{ .spacing = 12 });
    composePartyCard(addrs.relative(1), "SHIP FROM (WAREHOUSE)", data.ship_from);
    composePartyCard(addrs.relative(1), "SHIP TO (RECIPIENT)", data.ship_to);

    if (data.handling_tags.len > 0) {
        var tag_row = top.item().inlined(.{ .horizontal_spacing = 6, .vertical_spacing = 5 });
        for (data.handling_tags) |tag| {
            tag_row.item().component(tag);
        }
    }

    // Pick-and-Pack Checklist Table with `row_span` carton column
    var tbl = col.item().table(.{
        .columns = &.{ .fixed(56), .fixed(66), .rel(3), .fixed(48), .fixed(44), .fixed(44), .fixed(44), .fixed(30) },
        .extend_last_cells_to_bottom = true,
    });
    const headers = [_]struct { label: []const u8, align_mode: enum { left, center, right } }{
        .{ .label = "Carton", .align_mode = .center },
        .{ .label = "SKU", .align_mode = .left },
        .{ .label = "Item Description", .align_mode = .left },
        .{ .label = "Bin", .align_mode = .center },
        .{ .label = "Ord.", .align_mode = .right },
        .{ .label = "Ship", .align_mode = .right },
        .{ .label = "B/O", .align_mode = .right },
        .{ .label = "Chk", .align_mode = .center },
    };
    for (headers) |h| {
        var s = tbl.headerCell().background(.slate_900).padding(.{ .horizontal = 4, .vertical = 6 });
        s = switch (h.align_mode) {
            .left => s,
            .center => s.alignCenter(),
            .right => s.alignRight(),
        };
        s.text(h.label, .{ .size = 8, .weight = .bold, .color = .white });
    }

    var total_ordered: u32 = 0;
    var total_shipped: u32 = 0;
    var total_weight: f64 = 0;
    var row_idx: usize = 0;
    const bdr: pagine.BorderStyle = .{ .bottom = 0.5, .color = .slate_200 };

    for (data.cartons) |carton| {
        if (carton.items.len == 0) continue;

        // First column spans all rows belonging to this carton via `cellAt(.{ .row_span = ... })`.
        tbl.cellAt(.{ .row_span = @intCast(carton.items.len) })
            .background(.blue_50)
            .border(.{ .bottom = 0.75, .right = 0.5, .color = .slate_200 })
            .padding(.{ .horizontal = 4, .vertical = 5 })
            .alignXY(.center, .middle)
            .text(carton.carton_label, .{ .size = 8, .weight = .bold, .color = .blue_700 });

        for (carton.items) |item| {
            total_ordered += item.ordered_qty;
            total_shipped += item.shipped_qty;
            if (item.weight_kg) |w| {
                total_weight += w * @as(f64, @floatFromInt(item.shipped_qty));
            }
            const backordered = if (item.ordered_qty > item.shipped_qty) item.ordered_qty - item.shipped_qty else 0;
            const bg: ?pagine.Color = if (row_idx % 2 == 1) .slate_50 else null;
            row_idx += 1;

            dataCell(tbl, bg, bdr).text(item.sku, .{ .size = 8.5, .weight = .medium });
            dataCell(tbl, bg, bdr).text(item.description, .{ .size = 8.5, .color = .slate_900 });
            dataCell(tbl, bg, bdr).alignCenter().text(item.bin_location, .{ .size = 8, .color = .slate_500 });
            dataCell(tbl, bg, bdr).alignRight().print("{d}", .{item.ordered_qty}, .{ .size = 8.5 });
            dataCell(tbl, bg, bdr).alignRight().print("{d}", .{item.shipped_qty}, .{ .size = 8.5, .weight = .bold, .color = .blue_700 });
            dataCell(tbl, bg, bdr).alignRight().print("{d}", .{backordered}, .{
                .size = 8.5,
                .weight = if (backordered > 0) .bold else .normal,
                .color = if (backordered > 0) .amber_900 else .slate_500,
            });
            _ = dataCell(tbl, bg, bdr)
                .alignXY(.center, .middle)
                .size(11, 11)
                .border(.{ .all = 1.0, .color = .slate_300, .radius = 2 });
        }
    }

    // Shipment Summary + Sign-off kept together
    var bottom = col.item().showEntire().column(.{ .spacing = 10 });

    var stats_row = bottom.item().row(.{ .spacing = 8 });
    const effective_weight = data.gross_weight_kg orelse total_weight;
    composeStatBox(stats_row.relative(1), "TOTAL UNITS SHIPPED", "{d} / {d}", .{ total_shipped, total_ordered });
    composeStatBox(stats_row.relative(1), "PACKAGES / CARTONS", "{d}", .{data.cartons.len});
    if (effective_weight > 0.001) {
        composeStatBox(stats_row.relative(1), "GROSS WEIGHT", "{d:.2} kg", .{effective_weight});
    }
    if (data.dimensions_cm) |dim| {
        composeStatBox(stats_row.relative(1), "DIMENSIONS (CM)", "{s}", .{dim});
    }

    if (data.special_instructions) |inst| {
        var note = bottom.item().box(.{
            .padding = .{ .all = 9 },
            .background = .amber_50,
            .border = .{ .all = 0.75, .color = .amber_200, .radius = 6 },
        }).column(.{ .spacing = 2 });
        note.item().text("DELIVERY / HANDLING INSTRUCTIONS", .{ .size = 7.5, .weight = .bold, .color = .amber_900 });
        note.item().text(inst, .{ .size = 8.5, .color = .slate_800 });
    }

    var sign = bottom.item().row(.{ .spacing = 12 });
    composeSignOff(sign.relative(1), "PACKED & VERIFIED BY (WAREHOUSE)");
    composeSignOff(sign.relative(1), "RECEIVED IN GOOD CONDITION BY");
}

fn dataCell(tbl: pagine.TableBuilder, bg: ?pagine.Color, bdr: pagine.BorderStyle) pagine.Slot {
    return tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 4, .vertical = 5.5 });
}

fn composePartyCard(slot: pagine.Slot, title: []const u8, party: PartyInfo) void {
    var col = slot.box(.{
        .padding = .{ .all = 10 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 2.5 });

    col.item().text(title, .{ .size = 7.5, .weight = .bold, .color = .blue_700, .letter_spacing = 0.5 });
    col.item().text(party.name, .{ .size = 10, .weight = .bold, .color = .slate_900 });
    if (party.subtitle) |sub| col.item().text(sub, .{ .size = 8.5, .color = .slate_500 });
    for (party.address_lines) |line| col.item().text(line, .{ .size = 8.5, .color = .slate_800 });
    if (party.phone) |ph| col.item().text(ph, .{ .size = 8.5, .color = .slate_500 });
}

fn composeStatBox(slot: pagine.Slot, label: []const u8, comptime fmt: []const u8, args: anytype) void {
    var box = slot.box(.{
        .padding = .{ .horizontal = 9, .vertical = 7 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 2 });
    box.item().text(label, .{ .size = 7, .weight = .bold, .color = .slate_500, .letter_spacing = 0.4 });
    box.item().print(fmt, args, .{ .size = 11, .weight = .bold, .color = .slate_900 });
}

fn composeSignOff(slot: pagine.Slot, title: []const u8) void {
    var box = slot.box(.{
        .padding = .{ .all = 9 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 5 });
    box.item().text(title, .{ .size = 7.5, .weight = .bold, .color = .blue_700 });
    _ = box.item().height(18);
    box.item().lineHorizontal(.{ .thickness = 0.75, .color = .slate_300 });
    var row = box.item().row(.{});
    row.relative(1).text("Signature / Name", .{ .size = 7.5, .color = .slate_500 });
    row.auto().alignRight().text("Date: ____/____/______", .{ .size = 7.5, .color = .slate_500 });
}

/// Renders a genuine ISO/IEC 16388 Code 39 vector barcode wrapped in `*` start/stop delimiters.
fn composeCode39Barcode(slot: pagine.Slot, raw_code: []const u8, max_width: f32, bar_height: f32, color: pagine.Color) void {
    var valid_count: usize = 0;
    for (raw_code) |ch| {
        if (code39Pattern(std.ascii.toUpper(ch)) != null) valid_count += 1;
    }
    const symbol_count = valid_count + 2;
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
    const out_path = if (args.len >= 2) args[1] else "zig-out/packing_slip.pdf";

    const warehouse: PartyInfo = .{
        .name = "Pagine Fulfillment Hub — SYD1",
        .address_lines = &.{ "12 Cargo Way, Mascot NSW 2020", "Australia" },
        .phone = "+61 2 8000 5500",
    };

    // Shipment 1: Multi-carton robotics order
    const cartons_1 = [_]CartonGroup{
        .{
            .carton_label = "BOX 1/2",
            .items = &.{
                .{ .sku = "HW-ARM-01", .description = "6-Axis Servo Actuator Module (Rev C)", .bin_location = "A-04-2", .ordered_qty = 4, .shipped_qty = 4, .weight_kg = 1.45 },
                .{ .sku = "CB-PWR-24", .description = "Shielded 24V Industrial Power Harness (3m)", .bin_location = "B-11-1", .ordered_qty = 8, .shipped_qty = 8, .weight_kg = 0.35 },
            },
        },
        .{
            .carton_label = "BOX 2/2",
            .items = &.{
                .{ .sku = "SN-LID-09", .description = "Solid-State Optical LiDAR Sensor Kit", .bin_location = "C-02-4", .ordered_qty = 2, .shipped_qty = 1, .weight_kg = 0.90 },
                .{ .sku = "MT-BRK-10", .description = "Anodized Aluminum Mounting Bracket Set", .bin_location = "A-01-3", .ordered_qty = 4, .shipped_qty = 4, .weight_kg = 0.40 },
            },
        },
    };
    const tags_1 = [_]Badge{
        .{ .label = "FRAGILE — OPTICAL SENSORS", .tone = .danger },
        .{ .label = "KEEP DRY", .tone = .info },
        .{ .label = "PARTIAL SHIPMENT (1 ITEM BACKORDERED)", .tone = .warning },
    };

    var doc1 = pagine.Document.init(gpa, .{});
    defer doc1.deinit();
    compose(&doc1, .{
        .order_number = "SO-2026-7721",
        .shipment_id = "SHP-99304",
        .ship_date = "27 Nov 2026",
        .carrier = "DHL Express",
        .service_level = "Priority Air Freight",
        .tracking_number = "DHL-99304-AU",
        .ship_from = warehouse,
        .ship_to = .{
            .name = "Acme Robotics — Receiving Dock B",
            .subtitle = "Attn: Logistics Desk",
            .address_lines = &.{ "420 Innovation Drive", "San Francisco, CA 94107, USA" },
            .phone = "+1 415 555 0199",
        },
        .cartons = &cartons_1,
        .dimensions_cm = "60 x 40 x 35",
        .handling_tags = &tags_1,
        .special_instructions = "Call receiving dock 30 minutes prior to delivery. Backordered LiDAR unit (1x SN-LID-09) ships 04 Dec 2026.",
    });

    // Shipment 2: Second order merged into one batch print PDF via `pagine.mergePdf`
    // (`.independent` keeps each packing slip's footer numbered "Page 1 of 1").
    const cartons_2 = [_]CartonGroup{
        .{
            .carton_label = "BOX 1/1",
            .items = &.{
                .{ .sku = "PSU-48V", .description = "48V Redundant Rack Power Supply Unit", .bin_location = "D-01-1", .ordered_qty = 2, .shipped_qty = 2, .weight_kg = 2.10 },
                .{ .sku = "FAN-120", .description = "High-Static-Pressure Cooling Fan Kit", .bin_location = "D-03-4", .ordered_qty = 4, .shipped_qty = 4, .weight_kg = 0.25 },
            },
        },
    };
    const tags_2 = [_]Badge{
        .{ .label = "ESD SENSITIVE", .tone = .warning },
        .{ .label = "COMPLETE ORDER", .tone = .success },
    };

    var doc2 = pagine.Document.init(gpa, .{});
    defer doc2.deinit();
    compose(&doc2, .{
        .order_number = "SO-2026-7722",
        .shipment_id = "SHP-99305",
        .ship_date = "27 Nov 2026",
        .carrier = "FedEx Priority",
        .service_level = "Next Business Day",
        .tracking_number = "FDX-99305-AU",
        .ship_from = warehouse,
        .ship_to = .{
            .name = "Northstar Logistics — Depot 4",
            .address_lines = &.{ "88 Harbor Blvd", "Melbourne VIC 3000, Australia" },
            .phone = "+61 3 9000 4400",
        },
        .cartons = &cartons_2,
        .dimensions_cm = "45 x 35 x 25",
        .handling_tags = &tags_2,
    });

    const docs = [_]*const pagine.Document{ &doc1, &doc2 };
    var pdf = try pagine.mergePdf(gpa, &docs, .independent, .{
        .title = "Warehouse Batch Packing Slips (SHP-99304, SHP-99305)",
        .author = "Pagine Fulfillment",
    });
    defer pdf.deinit();

    try writeOutputFile(init.io, out_path, pdf.bytes());
}
