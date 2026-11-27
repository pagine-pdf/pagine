const std = @import("std");
const pagine = @import("pagine");
const support = @import("support");
const invoice = @import("ex_invoice");
const report = @import("ex_report");
const statement = @import("ex_statement");
const contract = @import("ex_contract");
const receipt = @import("ex_receipt");
const packing_slip = @import("ex_packing_slip");
const certificate = @import("ex_certificate");

const TestAllocator = support.TestAllocator;
const roboto_ttf = @embedFile("roboto_ttf");
const font_fams: []const [:0]const u8 = &.{"Roboto"};

fn initFonts() !pagine.FontRegistry {
    var fonts = try pagine.FontRegistry.init(.{});
    errdefer fonts.deinit();
    try fonts.registerBytes(roboto_ttf, "Roboto");
    return fonts;
}

test "example: commercial invoice renders multi-page PDF with zero leaks" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initFonts();
        defer fonts.deinit();

        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();

        var items: [36]invoice.LineItem = undefined;
        for (&items, 0..) |*slot, i| {
            slot.* = .{
                .sku = "PAG-001",
                .description = "Vector Layout Engine License",
                .qty = @intCast((i % 4) + 1),
                .unit_price = 99.0,
            };
        }

        invoice.compose(&doc, .{
            .invoice_number = "INV-2026-01",
            .issue_date = "27 Nov 2026",
            .due_date = "27 Dec 2026",
            .seller = .{ .name = "Pagine Systems", .tax_id = "ABN 12 345 678 901" },
            .buyer = .{ .name = "Acme Robotics", .address_lines = &.{"Sydney NSW 2000"} },
            .payment_lines = &.{"BSB 062-000 / ACC 98765432"},
            .items = &items,
            .font_families = font_fams,
        });

        var pdf = try pagine.renderPdf(&doc, .{ .fonts = &fonts, .title = "Invoice Test" });
        defer pdf.deinit();
        try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        try std.testing.expect(support.countPdfPages(pdf.bytes()) >= 2);
    }

    try ta.expectNoLeaks();
}

test "example: executive report renders multi-PageSet PDF/UA with zero leaks" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initFonts();
        defer fonts.deinit();

        const logo_xml =
            \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="48" height="48">
            \\  <rect x="4" y="4" width="40" height="40" rx="10" fill="#2563EB"/>
            \\</svg>
        ;
        var logo = try pagine.Svg.fromBytes(logo_xml, &fonts);
        defer logo.deinit();

        var banner = try report.makeSampleCoverBanner();
        defer banner.deinit();

        const series: report.RevenueSeries = .{
            .quarters = &.{ "Q1", "Q2", "Q3", "Q4" },
            .values = &.{ 0.4, 0.6, 0.8, 0.95 },
        };

        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();

        report.compose(&doc, .{
            .title = "FY2026 Engineering Report",
            .subtitle = "Zig 0.17 + Skia",
            .running_header = "Engineering Report",
            .org_label = "pagine",
            .kpis = &.{
                .{ .label = "THROUGHPUT", .value = "530+ pg/s" },
                .{ .label = "LEAKS", .value = "0 bytes", .accent = .green_600 },
            },
            .series = &series,
            .commentary_notes = &.{
                "Arena-allocated tree with flat StateStore enables O(N) speculative checkpoints.",
                "Two-pass pagination resolves totalPages and section links cleanly.",
            },
            .logo_svg = logo,
            .cover_banner = banner,
            .font_families = font_fams,
        });

        var pdf = try pagine.renderPdf(&doc, .{
            .fonts = &fonts,
            .title = "Report Test",
            .lang = "en-US",
            .outline = .structure_element_headers,
        });
        defer pdf.deinit();
        try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        try std.testing.expect(support.countPdfPages(pdf.bytes()) >= 2);
        try std.testing.expect(std.mem.indexOf(u8, pdf.bytes(), "/StructTreeRoot") != null);
    }

    try ta.expectNoLeaks();
}

test "example: account statement renders multi-page Dynamic ledger with zero leaks" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initFonts();
        defer fonts.deinit();

        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();

        var entries: [28]statement.LedgerEntry = undefined;
        for (&entries, 0..) |*slot, i| {
            slot.* = .{
                .date = "2026-11-15",
                .reference = "INV-8400",
                .description = "Cloud Rendering Usage",
                .debit = if (i % 3 == 0) 0 else 250.0,
                .credit = if (i % 3 == 0) 400.0 else 0,
            };
        }

        statement.compose(&doc, .{
            .statement_id = "STM-99",
            .statement_date = "27 Nov 2026",
            .period_label = "Nov 2026",
            .account_number = "ACC-001",
            .issuer = .{ .name = "Pagine Billing" },
            .customer = .{ .name = "Northstar Ltd" },
            .opening_balance = 1000.0,
            .entries = &entries,
            .aging = .{ .current = 1200.0, .days_1_30 = 400.0 },
            .remittance_note = "Quote ACC-001 when transferring.",
            .font_families = font_fams,
        });

        var pdf = try pagine.renderPdf(&doc, .{ .fonts = &fonts, .title = "Statement Test" });
        defer pdf.deinit();
        try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        try std.testing.expect(support.countPdfPages(pdf.bytes()) >= 2);
    }

    try ta.expectNoLeaks();
}

test "example: formal contract renders headers, watermark, and PDF/UA with zero leaks" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initFonts();
        defer fonts.deinit();

        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();

        contract.compose(&doc, .{
            .contract_id = "MSA-2026-01",
            .effective_date = "01 Dec 2026",
            .party_a = .{ .name = "Pagine Systems" },
            .party_b = .{ .name = "Client Holdings" },
            .key_terms = &.{.{ .label = "Term", .value = "24 Months" }},
            .clauses = &.{
                .{ .title = "Scope", .paragraphs = &.{"Provider grants a production license to Client."} },
                .{ .title = "Confidentiality", .paragraphs = &.{"Both parties protect confidential materials."} },
            },
            .signatories = &.{
                .{ .role_label = "PROVIDER", .organization = "Pagine Systems" },
                .{ .role_label = "CLIENT", .organization = "Client Holdings" },
            },
            .watermark = "CONFIDENTIAL",
            .font_families = font_fams,
        });

        var pdf = try pagine.renderPdf(&doc, .{
            .fonts = &fonts,
            .title = "Contract Test",
            .lang = "en-US",
            .outline = .structure_element_headers,
        });
        defer pdf.deinit();
        try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        try std.testing.expect(std.mem.indexOf(u8, pdf.bytes(), "/StructTreeRoot") != null);
    }

    try ta.expectNoLeaks();
}

test "example: thermal POS receipt renders 80mm and 58mm continuous rolls with zero leaks" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initFonts();
        defer fonts.deinit();

        for ([_]f32{ pagine.mm(80), pagine.mm(58) }) |roll_w| {
            var doc = pagine.Document.init(alloc, .{});
            defer doc.deinit();

            receipt.compose(&doc, .{
                .roll_width_pt = roll_w,
                .store_name = "Pagine Coffee",
                .receipt_number = "POS-001",
                .timestamp = "27/11/2026 09:30",
                .items = &.{
                    .{ .name = "Flat White", .qty = 2, .unit_price = 5.0, .modifier = "Oat milk" },
                    .{ .name = "Croissant", .qty = 1, .unit_price = 6.5 },
                },
                .barcode_value = "POS-001",
                .font_families = font_fams,
            });

            var pdf = try pagine.renderPdf(&doc, .{ .fonts = &fonts, .title = "Receipt Test" });
            defer pdf.deinit();
            try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
            try std.testing.expectEqual(@as(usize, 1), support.countPdfPages(pdf.bytes()));
        }
    }

    try ta.expectNoLeaks();
}

test "example: batch packing slips merge cleanly with independent page numbers and zero leaks" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initFonts();
        defer fonts.deinit();

        var doc1 = pagine.Document.init(alloc, .{});
        defer doc1.deinit();
        var doc2 = pagine.Document.init(alloc, .{});
        defer doc2.deinit();

        const cartons = [_]packing_slip.CartonGroup{
            .{
                .carton_label = "BOX 1/1",
                .items = &.{
                    .{ .sku = "HW-01", .description = "Sensor Module", .bin_location = "A1", .ordered_qty = 3, .shipped_qty = 2, .weight_kg = 1.2 },
                    .{ .sku = "CB-02", .description = "Power Cable", .bin_location = "B2", .ordered_qty = 2, .shipped_qty = 2, .weight_kg = 0.3 },
                },
            },
        };

        for ([_]*pagine.Document{ &doc1, &doc2 }) |d| {
            packing_slip.compose(d, .{
                .order_number = "SO-100",
                .shipment_id = "SHP-100",
                .ship_date = "27 Nov 2026",
                .carrier = "DHL Express",
                .tracking_number = "DHL-100-AU",
                .ship_from = .{ .name = "Warehouse SYD" },
                .ship_to = .{ .name = "Customer Dock" },
                .cartons = &cartons,
                .handling_tags = &.{.{ .label = "FRAGILE", .tone = .danger }},
                .font_families = font_fams,
            });
        }

        const docs = [_]*const pagine.Document{ &doc1, &doc2 };
        var merged = try pagine.mergePdf(alloc, &docs, .independent, .{ .fonts = &fonts, .title = "Batch Packing Slips" });
        defer merged.deinit();
        try std.testing.expect(std.mem.startsWith(u8, merged.bytes(), "%PDF-"));
        try std.testing.expectEqual(@as(usize, 2), support.countPdfPages(merged.bytes()));
    }

    try ta.expectNoLeaks();
}

test "example: landscape award certificate exports PDF, PNG, and SVG with zero leaks" {
    var ta = TestAllocator.init();
    defer ta.deinit();
    const alloc = ta.allocator();

    {
        var fonts = try initFonts();
        defer fonts.deinit();

        var doc = pagine.Document.init(alloc, .{});
        defer doc.deinit();

        certificate.compose(&doc, .{
            .issuer_name = "PAGINE ACADEMY",
            .recipient_name = "Alex Mercer",
            .description = "Successfully completed all performance and layout engineering modules.",
            .course_or_program = "Native Document Systems",
            .issue_date = "27 Nov 2026",
            .certificate_id = "CERT-2026-01",
            .verify_url = "https://pagine.example/verify/CERT-2026-01",
            .signers = &.{.{ .name = "Dr. Lin", .title = "Director" }},
            .font_families = font_fams,
        });

        var pdf = try pagine.renderPdf(&doc, .{ .fonts = &fonts, .title = "Certificate Test" });
        defer pdf.deinit();
        try std.testing.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));

        var pngs = try pagine.renderImages(&doc, .{ .fonts = &fonts, .format = .png, .dpi = 72.0 });
        defer pngs.deinit();
        try std.testing.expectEqual(@as(usize, 1), pngs.items.len);
        try std.testing.expect(std.mem.startsWith(u8, pngs.items[0].bytes(), "\x89PNG"));

        var svgs = try pagine.renderSvg(&doc, .{ .fonts = &fonts });
        defer svgs.deinit();
        try std.testing.expectEqual(@as(usize, 1), svgs.items.len);
        try std.testing.expect(std.mem.indexOf(u8, svgs.items[0].bytes(), "<svg") != null);
    }

    try ta.expectNoLeaks();
}
