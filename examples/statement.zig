//! Multi-Page Financial Account Statement — Self-contained starter example.
//!
//! Copy this single file into your project and call `statement.compose(&doc, data)`.
//! Demonstrates:
//! - Page-aware stateful `dynamic(...)` + `info.measureElement(...)` for exact per-page
//!   "Brought Forward" / "Carried Forward" running balance rows across page breaks
//! - KPI balance cards, 6-column Aging Summary `Table`, and dashed tear-off remittance stub
//! - Two-pass repeating footer with `currentPageNumber()` / `totalPages()`

const std = @import("std");
const pagine = @import("pagine");

pub const PartyInfo = struct {
    name: []const u8,
    subtitle: ?[]const u8 = null,
    address_lines: []const []const u8 = &.{},
    email: ?[]const u8 = null,
};

pub const LedgerEntry = struct {
    date: []const u8,
    reference: []const u8,
    description: []const u8,
    /// Positive charge added to the account balance.
    debit: f64 = 0,
    /// Positive payment/credit subtracted from the account balance.
    credit: f64 = 0,
};

pub const AgingBuckets = struct {
    current: f64 = 0,
    days_1_30: f64 = 0,
    days_31_60: f64 = 0,
    days_61_90: f64 = 0,
    over_90: f64 = 0,
};

pub const StatementData = struct {
    title: []const u8 = "ACCOUNT STATEMENT",
    statement_id: []const u8,
    statement_date: []const u8,
    period_label: []const u8,
    account_number: []const u8,
    currency: []const u8 = "$",
    issuer: PartyInfo,
    customer: PartyInfo,
    opening_balance: f64 = 0,
    /// Caller must keep `entries` alive until `renderPdf` / `renderImages` / `renderSvg` completes.
    entries: []const LedgerEntry,
    aging: ?AgingBuckets = null,
    remittance_note: ?[]const u8 = null,
    footer_note: []const u8 = "Please retain this statement for your accounting records.",
    page_size: pagine.PageSizeMode = .a4,
    font_families: ?[]const [:0]const u8 = null,
};

/// Composes a multi-page account statement with KPI balance cards, a `dynamic` running-balance
/// ledger (with per-page Brought Forward / Carried Forward bars), aging buckets, and remittance stub.
pub fn compose(doc: *pagine.Document, data: StatementData) void {
    var page = doc.addPage(.{
        .size = data.page_size,
        .margin = .{ .all = pagine.mm(15) },
        .default_text_style = .{
            .font_families = data.font_families,
            .size = 9,
            .color = .slate_800,
        },
    });

    var total_debits: f64 = 0;
    var total_credits: f64 = 0;
    for (data.entries) |e| {
        total_debits += e.debit;
        total_credits += e.credit;
    }
    const closing_balance = data.opening_balance + total_debits - total_credits;

    // Repeating Header
    var hdr = page.header().padding(.{ .bottom = 8 }).border(.{ .bottom = 1.5, .color = .teal_600 }).row(.{ .spacing = 12 });
    var hdr_l = hdr.relative(1).padding(.{ .bottom = 6 }).column(.{ .spacing = 2 });
    hdr_l.item().heading(1).text(data.title, .{ .size = 16, .weight = .bold, .color = .slate_900 });
    hdr_l.item().text(data.issuer.name, .{ .size = 9.5, .weight = .medium, .color = .teal_600 });

    var hdr_r = hdr.auto().padding(.{ .bottom = 6 }).alignMiddle().column(.{ .spacing = 1.5 });
    hdr_r.item().alignRight().print("Statement: {s}", .{data.statement_id}, .{ .size = 8.5, .weight = .bold, .color = .slate_900 });
    hdr_r.item().alignRight().print("Period: {s}", .{data.period_label}, .{ .size = 8, .color = .slate_500 });
    hdr_r.item().alignRight().print("Account: {s}  •  Date: {s}", .{ data.account_number, data.statement_date }, .{ .size = 8, .color = .slate_500 });

    // Repeating Footer
    var ftr = page.footer().padding(.{ .top = 8 }).border(.{ .top = 0.75, .color = .slate_200 }).row(.{ .spacing = 8 });
    ftr.relative(1).padding(.{ .top = 5 }).text(data.footer_note, .{ .size = 8, .color = .slate_500 });
    var pg = ftr.auto().padding(.{ .top = 5 }).alignRight().richText(.{ .style = .{ .size = 8, .color = .slate_500 } });
    pg.span("Page ", .{});
    pg.currentPageNumber(.{ .weight = .bold, .color = .slate_800 });
    pg.span(" of ", .{});
    pg.totalPages(.{ .weight = .bold, .color = .slate_800 });

    var col = page.content().padding(.{ .vertical = 10 }).column(.{ .spacing = 12 });

    // Account Summary & KPI Strip (kept intact together on Page 1)
    var intro = col.item().showEntire().column(.{ .spacing = 10 });
    var parties = intro.item().row(.{ .spacing = 12 });
    composePartyCard(parties.relative(1), "ACCOUNT HOLDER", data.customer);
    composePartyCard(parties.relative(1), "ISSUED BY", data.issuer);

    var kpi_row = intro.item().row(.{ .spacing = 8 });
    const kpis = [_]struct { label: []const u8, val: f64, accent: pagine.Color, highlight: bool }{
        .{ .label = "OPENING BALANCE", .val = data.opening_balance, .accent = .slate_900, .highlight = false },
        .{ .label = "TOTAL CHARGES", .val = total_debits, .accent = .slate_900, .highlight = false },
        .{ .label = "PAYMENTS / CREDITS", .val = total_credits, .accent = .green_700, .highlight = false },
        .{ .label = "CLOSING BALANCE", .val = closing_balance, .accent = .teal_600, .highlight = true },
    };
    for (kpis) |k| {
        var box = kpi_row.relative(1).box(.{
            .padding = .{ .horizontal = 9, .vertical = 8 },
            .background = if (k.highlight) .green_50 else .slate_50,
            .border = .{ .all = if (k.highlight) 1.0 else 0.75, .color = if (k.highlight) .teal_600 else .slate_200, .radius = 6 },
        }).column(.{ .spacing = 2 });
        box.item().text(k.label, .{ .size = 7, .weight = .bold, .color = .slate_500, .letter_spacing = 0.4 });
        printMoney(box.item(), data.currency, k.val, .{ .size = 11.5, .weight = .bold, .color = k.accent });
    }

    // Stateful Dynamic Ledger: measures every row before committing so each page ends with
    // an exact "Page Subtotal / Carried Forward" bar and the next page opens with "Brought Forward".
    col.item().dynamic(LedgerState, .{
        .entries = data.entries,
        .currency = data.currency,
        .running_balance = data.opening_balance,
    }, composeLedgerPage);

    // Aging Summary Strip
    if (data.aging) |aging| {
        var aging_wrap = col.item().showEntire().column(.{ .spacing = 5 });
        aging_wrap.item().heading(2).text("AGING SUMMARY", .{ .size = 8.5, .weight = .bold, .color = .teal_600, .letter_spacing = 0.5 });

        var a_tbl = aging_wrap.item().table(.{
            .columns = &.{ .rel(1), .rel(1), .rel(1), .rel(1), .rel(1), .rel(1) },
        });
        const a_headers = [_][]const u8{ "Current", "1-30 Days", "31-60 Days", "61-90 Days", "90+ Days", "Total Due" };
        const a_vals = [_]f64{ aging.current, aging.days_1_30, aging.days_31_60, aging.days_61_90, aging.over_90, closing_balance };
        for (a_headers) |h| {
            a_tbl.headerCell().background(.slate_50).border(.{ .all = 0.5, .color = .slate_200 }).padding(.{ .all = 5 }).alignCenter().text(h, .{ .size = 8, .weight = .bold, .color = .slate_500 });
        }
        for (a_vals, 0..) |v, idx| {
            const is_total = idx == a_vals.len - 1;
            const is_overdue = idx == 4 and v > 0.004;
            printMoney(
                a_tbl.cell()
                    .backgroundOpt(if (is_total) .green_50 else null)
                    .border(.{ .all = 0.5, .color = .slate_200 })
                    .padding(.{ .all = 6 })
                    .alignCenter(),
                data.currency,
                v,
                .{
                    .size = 9,
                    .weight = if (is_total or is_overdue) .bold else .normal,
                    .color = if (is_overdue) .red_600 else if (is_total) .teal_600 else .slate_900,
                },
            );
        }
    }

    // Optional tear-off remittance stub
    if (data.remittance_note) |remit| {
        var stub = col.item().showEntire().padding(.{ .top = 6 }).column(.{ .spacing = 8 });
        stub.item().lineHorizontal(.{ .thickness = 0.75, .color = .slate_300, .dash = .{ .on = 4, .off = 3 } });

        var box = stub.item().box(.{
            .padding = .{ .all = 10 },
            .background = .slate_50,
            .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
        }).row(.{ .spacing = 12 });

        var left = box.relative(1).column(.{ .spacing = 3 });
        left.item().text("REMITTANCE ADVICE", .{ .size = 8, .weight = .bold, .color = .teal_600, .letter_spacing = 0.5 });
        left.item().text(remit, .{ .size = 8.5, .color = .slate_800 });

        var right = box.constant(165).column(.{ .spacing = 3 });
        right.item().alignRight().print("Account: {s}", .{data.account_number}, .{ .size = 8.5, .color = .slate_500 });
        right.item().alignRight().print("Statement: {s}", .{data.statement_id}, .{ .size = 8.5, .color = .slate_500 });
        var amt_row = right.item().row(.{});
        amt_row.relative(1).text("Amount Enclosed:", .{ .size = 8.5, .weight = .bold });
        printMoney(amt_row.auto().alignRight(), data.currency, closing_balance, .{ .size = 9.5, .weight = .bold, .color = .teal_600 });
    }
}

const LedgerState = struct {
    entries: []const LedgerEntry,
    currency: []const u8,
    cursor: usize = 0,
    running_balance: f64 = 0,
};

const EntryRowCtx = struct {
    entry: LedgerEntry,
    currency: []const u8,
    running: f64,
    striped: bool,
};

const BalanceBarCtx = struct {
    badge: []const u8,
    label: []const u8,
    currency: []const u8,
    debit_sum: ?f64 = null,
    credit_sum: ?f64 = null,
    balance: f64,
    highlight: bool = false,
};

fn buildLedgerHeader(slot: pagine.Slot) void {
    var r = slot.background(.slate_900).padding(.{ .horizontal = 6, .vertical = 6 }).row(.{ .spacing = 6 });
    r.constant(58).text("Date", .{ .size = 8, .weight = .bold, .color = .white });
    r.constant(62).text("Reference", .{ .size = 8, .weight = .bold, .color = .white });
    r.relative(1).text("Activity Description", .{ .size = 8, .weight = .bold, .color = .white });
    r.constant(64).alignRight().text("Debit", .{ .size = 8, .weight = .bold, .color = .white });
    r.constant(64).alignRight().text("Credit", .{ .size = 8, .weight = .bold, .color = .white });
    r.constant(72).alignRight().text("Balance", .{ .size = 8, .weight = .bold, .color = .white });
}

fn buildLedgerRow(ctx: EntryRowCtx, slot: pagine.Slot) void {
    const bg: ?pagine.Color = if (ctx.striped) .slate_50 else null;
    var r = slot.backgroundOpt(bg)
        .border(.{ .bottom = 0.5, .color = .slate_200 })
        .padding(.{ .horizontal = 6, .vertical = 4.5 })
        .row(.{ .spacing = 6 });

    r.constant(58).text(ctx.entry.date, .{ .size = 8.5, .color = .slate_500 });
    r.constant(62).text(ctx.entry.reference, .{ .size = 8.5, .color = .slate_700 });
    r.relative(1).text(ctx.entry.description, .{ .size = 8.5, .color = .slate_900 });

    if (ctx.entry.debit > 0.004) {
        printMoney(r.constant(64).alignRight(), ctx.currency, ctx.entry.debit, .{ .size = 8.5 });
    } else {
        r.constant(64).alignRight().text("—", .{ .size = 8.5, .color = .slate_400 });
    }

    if (ctx.entry.credit > 0.004) {
        printMoney(r.constant(64).alignRight(), ctx.currency, ctx.entry.credit, .{ .size = 8.5, .color = .green_700 });
    } else {
        r.constant(64).alignRight().text("—", .{ .size = 8.5, .color = .slate_400 });
    }

    printMoney(r.constant(72).alignRight(), ctx.currency, ctx.running, .{ .size = 8.5, .weight = .semi_bold, .color = .slate_900 });
}

fn buildBalanceBar(ctx: BalanceBarCtx, slot: pagine.Slot) void {
    var r = slot.background(if (ctx.highlight) .green_50 else .slate_100)
        .border(.{ .top = if (ctx.highlight) 1.0 else 0.5, .bottom = 0.75, .color = if (ctx.highlight) .teal_600 else .slate_300 })
        .padding(.{ .horizontal = 6, .vertical = 5 })
        .row(.{ .spacing = 6 });

    r.constant(58).text(ctx.badge, .{ .size = 7.5, .weight = .bold, .color = if (ctx.highlight) .teal_600 else .slate_600 });
    r.constant(62).text("—", .{ .size = 8, .color = .slate_400 });
    r.relative(1).text(ctx.label, .{ .size = 8.5, .weight = .semi_bold, .color = .slate_900 });

    if (ctx.debit_sum) |d| {
        printMoney(r.constant(64).alignRight(), ctx.currency, d, .{ .size = 8.5, .weight = .semi_bold, .color = .slate_800 });
    } else {
        r.constant(64).alignRight().text("—", .{ .size = 8.5, .color = .slate_400 });
    }

    if (ctx.credit_sum) |c| {
        printMoney(r.constant(64).alignRight(), ctx.currency, c, .{ .size = 8.5, .weight = .semi_bold, .color = .green_700 });
    } else {
        r.constant(64).alignRight().text("—", .{ .size = 8.5, .color = .slate_400 });
    }

    printMoney(r.constant(72).alignRight(), ctx.currency, ctx.balance, .{
        .size = 8.5,
        .weight = .bold,
        .color = if (ctx.highlight) .teal_600 else .slate_900,
    });
}

/// Page-aware Dynamic builder invoked once per page fragment.
/// Automatically reset by the engine between Pass 1 (page counting) and Pass 2 (rendering).
fn composeLedgerPage(st: *LedgerState, info: pagine.DynamicContextInfo, slot: pagine.Slot) pagine.DynamicResult {
    const avail_w = info.available_size.width;
    const hdr_h = info.measureElement(.{ .width = avail_w, .height = info.available_size.height }, {}, buildLedgerHeader).size.height;

    const bf_ctx: BalanceBarCtx = .{
        .badge = if (st.cursor == 0) "OPENING" else "B/FWD",
        .label = if (st.cursor == 0) "Balance Brought Forward (Opening)" else "Balance Brought Forward (from previous page)",
        .currency = st.currency,
        .balance = st.running_balance,
    };
    const bf_h = info.measureElement(.{ .width = avail_w, .height = info.available_size.height }, bf_ctx, buildBalanceBar).size.height;

    // Reserve headroom for the bottom per-page Carried Forward / Closing Balance bar.
    const sample_ftr: BalanceBarCtx = .{
        .badge = "C/FWD",
        .label = "Page Subtotal — Balance Carried Forward",
        .currency = st.currency,
        .debit_sum = 0,
        .credit_sum = 0,
        .balance = st.running_balance,
        .highlight = true,
    };
    const ftr_h = info.measureElement(.{ .width = avail_w, .height = info.available_size.height }, sample_ftr, buildBalanceBar).size.height;

    var remaining_h = info.available_size.height - hdr_h - bf_h - ftr_h - 2.0;

    var col = slot.column(.{});
    buildLedgerHeader(col.item());
    buildBalanceBar(bf_ctx, col.item());

    var page_debits: f64 = 0;
    var page_credits: f64 = 0;
    var placed: usize = 0;

    while (st.cursor < st.entries.len) {
        const entry = st.entries[st.cursor];
        const next_running = st.running_balance + entry.debit - entry.credit;
        const row_ctx: EntryRowCtx = .{
            .entry = entry,
            .currency = st.currency,
            .running = next_running,
            .striped = (placed % 2) == 1,
        };

        const probe = info.measureElement(.{ .width = avail_w, .height = @max(0, remaining_h) }, row_ctx, buildLedgerRow);
        if (!probe.fits_completely and placed > 0) break;

        buildLedgerRow(row_ctx, col.item());
        remaining_h -= probe.size.height;
        st.running_balance = next_running;
        page_debits += entry.debit;
        page_credits += entry.credit;
        st.cursor += 1;
        placed += 1;
    }

    const has_more = st.cursor < st.entries.len;
    buildBalanceBar(.{
        .badge = if (has_more) "C/FWD" else "CLOSING",
        .label = if (has_more) "Page Subtotal — Balance Carried Forward" else "Closing Balance (All Transactions)",
        .currency = st.currency,
        .debit_sum = page_debits,
        .credit_sum = page_credits,
        .balance = st.running_balance,
        .highlight = !has_more,
    }, col.item());

    return .{ .has_more_content = has_more };
}

fn composePartyCard(slot: pagine.Slot, title: []const u8, party: PartyInfo) void {
    var col = slot.box(.{
        .padding = .{ .all = 10 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 2.5 });

    col.item().text(title, .{ .size = 7.5, .weight = .bold, .color = .teal_600, .letter_spacing = 0.5 });
    col.item().text(party.name, .{ .size = 10, .weight = .bold, .color = .slate_900 });
    if (party.subtitle) |sub| col.item().text(sub, .{ .size = 8.5, .color = .slate_500 });
    for (party.address_lines) |line| col.item().text(line, .{ .size = 8.5, .color = .slate_800 });
    if (party.email) |email| col.item().text(email, .{ .size = 8.5, .color = .slate_500 });
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
    const out_path = if (args.len >= 2) args[1] else "zig-out/statement.pdf";

    // 28 sample transactions across the month so the dynamic ledger spans 2 pages
    // and showcases Brought Forward / Carried Forward subtotals automatically.
    const templates = [_]struct { desc: []const u8, debit: f64, credit: f64 }{
        .{ .desc = "Cloud Rendering Platform — Monthly Base Subscription", .debit = 420.00, .credit = 0 },
        .{ .desc = "Batch PDF Pipeline — Asia-Pacific Cluster Usage", .debit = 185.50, .credit = 0 },
        .{ .desc = "ACH Payment Received — Thank You", .debit = 0, .credit = 1200.00 },
        .{ .desc = "High-Volume Invoice Generation Tier (250k pages)", .debit = 310.00, .credit = 0 },
        .{ .desc = "Dedicated Enterprise Support Pack", .debit = 240.00, .credit = 0 },
        .{ .desc = "SLA Uptime Credit Adjustment", .debit = 0, .credit = 45.00 },
        .{ .desc = "Raster PNG Thumbnail Export Add-on", .debit = 95.00, .credit = 0 },
    };

    var entries: [28]LedgerEntry = undefined;
    var balance: f64 = 2400.00;
    for (&entries, 0..) |*slot, i| {
        const tpl = templates[i % templates.len];
        const day = @min(28, i + 1);
        const is_payment = tpl.credit > 0;
        slot.* = .{
            .date = try std.fmt.allocPrint(arena, "2026-11-{d:0>2}", .{day}),
            .reference = try std.fmt.allocPrint(arena, "{s}-{d:0>4}", .{ if (is_payment) "PMT" else "INV", 8400 + i }),
            .description = tpl.desc,
            .debit = tpl.debit,
            .credit = tpl.credit,
        };
        balance = balance + tpl.debit - tpl.credit;
    }

    var doc = pagine.Document.init(gpa, .{});
    defer doc.deinit();

    compose(&doc, .{
        .statement_id = "STM-2026-11-0042",
        .statement_date = "27 Nov 2026",
        .period_label = "01 Nov 2026 – 30 Nov 2026",
        .account_number = "ACC-0048291",
        .issuer = .{
            .name = "Pagine Cloud Billing",
            .address_lines = &.{"180 George St, Sydney NSW 2000"},
            .email = "accounts@pagine.example",
        },
        .customer = .{
            .name = "Northstar Logistics Group",
            .address_lines = &.{ "88 Harbor Blvd, Suite 900", "Melbourne VIC 3000" },
            .email = "finance@northstar.example",
        },
        .opening_balance = 2400.00,
        .entries = &entries,
        .aging = .{
            .current = @max(0, balance - 850.0),
            .days_1_30 = @min(balance, 850.0),
        },
        .remittance_note = "Remit via EFT to BSB 062-000 / ACC 98765432 quoting Account ACC-0048291.",
    });

    var pdf = try pagine.renderPdf(&doc, .{
        .title = "Account Statement STM-2026-11-0042",
        .author = "Pagine Systems",
    });
    defer pdf.deinit();

    try writeOutputFile(init.io, out_path, pdf.bytes());
}
