//! Formal Legal Contract / MSA — Self-contained starter example.
//!
//! Copy this single file into your project and call `contract.compose(&doc, data)`.
//! Demonstrates:
//! - Page 1 full title banner (`showOnce`) + Pages 2+ compact running header (`skipOnce`) inside `page.header()`
//! - Diagonal semi-transparent watermark via `page.foreground()` + `rotate(-32)`
//! - Orphan-heading protection via `ensureSpace(64)` on numbered articles & justified `richText`
//! - Unbreakable signature execution grid via `showEntire()` + PDF/UA headings & outline bookmarks

const std = @import("std");
const pagine = @import("pagine");

pub const PartyInfo = struct {
    name: []const u8,
    tax_id: ?[]const u8 = null,
    address_lines: []const []const u8 = &.{},
};

pub const KeyTerm = struct {
    label: []const u8,
    value: []const u8,
};

pub const Clause = struct {
    title: []const u8,
    paragraphs: []const []const u8,
    bullets: []const []const u8 = &.{},
};

pub const Signatory = struct {
    role_label: []const u8,
    organization: []const u8,
    signer_name: ?[]const u8 = null,
    signer_title: ?[]const u8 = null,
};

pub const ContractData = struct {
    title: []const u8 = "MASTER SERVICES AGREEMENT",
    subtitle: ?[]const u8 = null,
    contract_id: []const u8,
    effective_date: []const u8,
    version: []const u8 = "1.0",
    preamble: ?[]const u8 = null,
    party_a_label: []const u8 = "PARTY A (PROVIDER)",
    party_a: PartyInfo,
    party_b_label: []const u8 = "PARTY B (CLIENT)",
    party_b: PartyInfo,
    key_terms: []const KeyTerm = &.{},
    clauses: []const Clause,
    signatories: []const Signatory = &.{},
    watermark: ?[]const u8 = null,
    footer_note: []const u8 = "Confidential Legal Agreement",
    page_size: pagine.PageSizeMode = .a4,
    font_families: ?[]const [:0]const u8 = null,
};

/// Composes a multi-page formal contract with PDF/UA structure headings, running headers,
/// optional confidentiality watermark, and non-splitting signature blocks.
pub fn compose(doc: *pagine.Document, data: ContractData) void {
    var page = doc.addPage(.{
        .size = data.page_size,
        .margin = .{ .horizontal = pagine.mm(20), .vertical = pagine.mm(18) },
        .default_text_style = .{
            .font_families = data.font_families,
            .size = 9.5,
            .color = .slate_800,
        },
    });

    // Optional diagonal watermark across full-page foreground
    if (data.watermark) |wm| {
        page.foreground()
            .alignXY(.center, .middle)
            .rotate(-32)
            .text(wm, .{
            .size = 56,
            .weight = .extra_bold,
            .color = pagine.Color.slate_900.withAlpha(0x14),
            .letter_spacing = 4,
        });
    }

    // Running Header: Page 1 shows the full legal banner (`showOnce`); Pages 2+ show a compact line (`skipOnce`).
    var hdr = page.header().column(.{});

    var hdr_p1 = hdr.item().showOnce().padding(.{ .bottom = 10 }).border(.{ .bottom = 1.5, .color = .slate_900 }).column(.{ .spacing = 4 });
    hdr_p1.item().alignCenter().heading(1).text(data.title, .{
        .size = 17,
        .weight = .bold,
        .color = .slate_900,
        .letter_spacing = 0.6,
    });
    if (data.subtitle) |sub| {
        hdr_p1.item().alignCenter().text(sub, .{ .size = 9.5, .color = .slate_500 });
    }
    hdr_p1.item().padding(.{ .bottom = 4 }).alignCenter().print(
        "Contract ID: {s}   •   Effective Date: {s}   •   Version {s}",
        .{ data.contract_id, data.effective_date, data.version },
        .{ .size = 8.5, .color = .slate_500 },
    );

    var hdr_cont = hdr.item().skipOnce().padding(.{ .bottom = 8 }).border(.{ .bottom = 0.5, .color = .slate_200 }).row(.{});
    hdr_cont.relative(1).padding(.{ .bottom = 4 }).text(data.title, .{ .size = 8, .weight = .bold, .color = .slate_500 });
    hdr_cont.auto().padding(.{ .bottom = 4 }).alignRight().print("{s} (v{s})", .{ data.contract_id, data.version }, .{ .size = 8, .color = .slate_500 });

    // Repeating Footer
    var ftr = page.footer().padding(.{ .top = 8 }).border(.{ .top = 0.75, .color = .slate_200 }).row(.{ .spacing = 8 });
    ftr.relative(1).padding(.{ .top = 5 }).text(data.footer_note, .{ .size = 8, .color = .slate_500 });
    var pg = ftr.auto().padding(.{ .top = 5 }).alignRight().richText(.{ .style = .{ .size = 8, .color = .slate_500 } });
    pg.span("Page ", .{});
    pg.currentPageNumber(.{ .weight = .bold, .color = .slate_800 });
    pg.span(" of ", .{});
    pg.totalPages(.{ .weight = .bold, .color = .slate_800 });

    var col = page.content().padding(.{ .vertical = 12 }).column(.{ .spacing = 12 });

    // Contracting Parties
    var parties_row = col.item().showEntire().row(.{ .spacing = 12 });
    composePartyCard(parties_row.relative(1), data.party_a_label, data.party_a);
    composePartyCard(parties_row.relative(1), data.party_b_label, data.party_b);

    // Optional Preamble / Recitals
    if (data.preamble) |preamble| {
        col.item().richText(.{
            .alignment = .justify,
            .paragraph_spacing = 5,
            .style = .{ .size = 9.5, .color = .slate_800, .line_height = 1.4 },
        }).span(preamble, .{});
    }

    // Optional Schedule of Key Commercial Terms
    if (data.key_terms.len > 0) {
        var kt_wrap = col.item().column(.{ .spacing = 6 });
        kt_wrap.item().heading(2).text("SCHEDULE OF KEY TERMS", .{
            .size = 9.5,
            .weight = .bold,
            .color = .slate_900,
            .letter_spacing = 0.4,
        });
        var tbl = kt_wrap.item().table(.{
            .columns = &.{ .fixed(155), .rel(1) },
        });
        const bdr: pagine.BorderStyle = .{ .all = 0.5, .color = .slate_200 };
        for (data.key_terms, 0..) |term, i| {
            const bg: ?pagine.Color = if (i % 2 == 0) .slate_50 else null;
            tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 8, .vertical = 5.5 }).text(term.label, .{
                .size = 8.5,
                .weight = .bold,
                .color = .slate_900,
            });
            tbl.cell().backgroundOpt(bg).border(bdr).padding(.{ .horizontal = 8, .vertical = 5.5 }).text(term.value, .{
                .size = 8.5,
                .color = .slate_800,
            });
        }
    }

    // Numbered Legal Articles & Clauses (`ensureSpace` prevents orphaned headings at page bottom)
    for (data.clauses, 1..) |clause, idx| {
        var sec = col.item().ensureSpace(64).column(.{ .spacing = 5 });
        sec.item().heading(2).print("{d}. {s}", .{ idx, clause.title }, .{
            .size = 11,
            .weight = .bold,
            .color = .slate_900,
        });

        for (clause.paragraphs, 1..) |para, p_idx| {
            var rt = sec.item().richText(.{
                .alignment = .justify,
                .style = .{ .size = 9.5, .color = .slate_800, .line_height = 1.42 },
            });
            rt.print("{d}.{d}  ", .{ idx, p_idx }, .{ .weight = .semi_bold, .color = .slate_900 });
            rt.span(para, .{});
        }

        if (clause.bullets.len > 0) {
            var blist = sec.item().padding(.{ .left = 14 }).column(.{ .spacing = 3.5 });
            for (clause.bullets) |b| {
                var row = blist.item().row(.{ .spacing = 6 });
                row.constant(8).text("•", .{ .size = 9.5, .weight = .bold, .color = .slate_700 });
                row.relative(1).richText(.{
                    .alignment = .justify,
                    .style = .{ .size = 9.2, .color = .slate_800, .line_height = 1.38 },
                }).span(b, .{});
            }
        }
    }

    // Execution & Signatures block (kept together so signatures never split awkwardly)
    if (data.signatories.len > 0) {
        var sig_section = col.item().showEntire().padding(.{ .top = 10 }).column(.{ .spacing = 10 });
        sig_section.item().lineHorizontal(.{ .thickness = 0.75, .color = .slate_300 });
        sig_section.item().heading(2).text("IN WITNESS WHEREOF", .{
            .size = 10,
            .weight = .bold,
            .color = .slate_900,
            .letter_spacing = 0.5,
        });
        sig_section.item().text(
            "The Parties have caused this Agreement to be executed by their duly authorized representatives as of the Effective Date.",
            .{ .size = 9, .color = .slate_500, .slant = .italic },
        );

        var i: usize = 0;
        while (i < data.signatories.len) : (i += 2) {
            var srow = sig_section.item().row(.{ .spacing = 16 });
            composeSignatoryBox(srow.relative(1), data.signatories[i]);
            if (i + 1 < data.signatories.len) {
                composeSignatoryBox(srow.relative(1), data.signatories[i + 1]);
            } else {
                _ = srow.relative(1);
            }
        }
    }
}

fn composePartyCard(slot: pagine.Slot, title: []const u8, party: PartyInfo) void {
    var col = slot.box(.{
        .padding = .{ .all = 10 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 2.5 });

    col.item().text(title, .{ .size = 7.5, .weight = .bold, .color = .slate_700, .letter_spacing = 0.5 });
    col.item().text(party.name, .{ .size = 10, .weight = .bold, .color = .slate_900 });
    if (party.tax_id) |tid| col.item().print("ID / Tax: {s}", .{tid}, .{ .size = 8.5, .color = .slate_500 });
    for (party.address_lines) |line| col.item().text(line, .{ .size = 8.5, .color = .slate_800 });
}

fn composeSignatoryBox(slot: pagine.Slot, sig: Signatory) void {
    var box = slot.box(.{
        .padding = .{ .all = 11 },
        .background = .slate_50,
        .border = .{ .all = 0.75, .color = .slate_200, .radius = 6 },
    }).column(.{ .spacing = 6 });

    box.item().text(sig.role_label, .{ .size = 7.5, .weight = .bold, .color = .slate_700, .letter_spacing = 0.4 });
    box.item().text(sig.organization, .{ .size = 9.5, .weight = .bold, .color = .slate_900 });

    _ = box.item().height(26);
    box.item().lineHorizontal(.{ .thickness = 0.75, .color = .slate_500 });
    box.item().text("Authorized Signature", .{ .size = 7.5, .color = .slate_500 });

    if (sig.signer_name) |name| {
        box.item().print("Name: {s}", .{name}, .{ .size = 8.5, .color = .slate_800 });
    } else {
        box.item().text("Name: ____________________________", .{ .size = 8.5, .color = .slate_500 });
    }
    if (sig.signer_title) |title| {
        box.item().print("Title: {s}", .{title}, .{ .size = 8.5, .color = .slate_800 });
    } else {
        box.item().text("Title: ____________________________", .{ .size = 8.5, .color = .slate_500 });
    }
    box.item().text("Date:  ____________________________", .{ .size = 8.5, .color = .slate_500 });
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
    const out_path = if (args.len >= 2) args[1] else "zig-out/contract.pdf";

    const key_terms = [_]KeyTerm{
        .{ .label = "Initial Term", .value = "Twenty-four (24) months from Effective Date" },
        .{ .label = "Service Level Target", .value = "99.95% monthly rendering API availability" },
        .{ .label = "Payment Terms", .value = "Net 30 days from invoice issuance in USD" },
        .{ .label = "Governing Law", .value = "New South Wales, Australia" },
    };

    const clauses = [_]Clause{
        .{
            .title = "Scope of Services",
            .paragraphs = &.{
                "Provider agrees to supply Client with licensed access to the Pagine document rendering engine, associated software updates, and enterprise engineering support as specified in the Order Form.",
                "All deliverables shall conform to mutually agreed specifications, including deterministic PDF/A and PDF/UA output compliance where enabled by Client.",
            },
            .bullets = &.{
                "Production deployment rights across Client's cloud and on-premise environments.",
                "Priority security patches and compatibility updates for supported Zig toolchains.",
            },
        },
        .{
            .title = "Confidentiality & Data Protection",
            .paragraphs = &.{
                "Each Party shall maintain in strict confidence all non-public business, technical, and financial information disclosed by the other Party in connection with this Agreement.",
                "The Pagine engine executes locally within Client's infrastructure; Provider does not collect, transmit, or retain end-user document payloads.",
            },
        },
        .{
            .title = "Intellectual Property & Licensing",
            .paragraphs = &.{
                "Client retains all right, title, and interest in and to its templates, data schemas, brand assets, and generated output documents.",
                "Provider retains all right, title, and interest in the core rendering engine, algorithms, and pre-existing libraries.",
            },
        },
        .{
            .title = "Limitation of Liability & Termination",
            .paragraphs = &.{
                "Except for breaches of confidentiality or willful misconduct, neither Party's aggregate liability under this Agreement shall exceed the total fees paid in the preceding twelve (12) months.",
                "Either Party may terminate this Agreement for material breach if such breach remains uncured thirty (30) days after written notice.",
            },
        },
    };

    const signatories = [_]Signatory{
        .{
            .role_label = "FOR AND ON BEHALF OF PROVIDER",
            .organization = "Pagine Systems Pty Ltd",
            .signer_name = "Dacheng Gao",
            .signer_title = "Principal Engineer",
        },
        .{
            .role_label = "FOR AND ON BEHALF OF CLIENT",
            .organization = "Acme Robotics International",
            .signer_name = "Elena Vance",
            .signer_title = "VP of Platform Engineering",
        },
    };

    var doc = pagine.Document.init(gpa, .{});
    defer doc.deinit();

    compose(&doc, .{
        .subtitle = "Enterprise Software Licensing & Support Agreement",
        .contract_id = "MSA-2026-1127",
        .effective_date = "01 Dec 2026",
        .version = "2.1",
        .preamble = "This Master Services Agreement (\"Agreement\") is entered into as of the Effective Date by and between Provider and Client (each a \"Party\" and collectively the \"Parties\").",
        .party_a = .{
            .name = "Pagine Systems Pty Ltd",
            .tax_id = "ABN 12 345 678 901",
            .address_lines = &.{"Level 14, 180 George St, Sydney NSW 2000"},
        },
        .party_b = .{
            .name = "Acme Robotics International",
            .tax_id = "US-EIN 94-3829104",
            .address_lines = &.{"420 Innovation Drive, San Francisco, CA 94107"},
        },
        .key_terms = &key_terms,
        .clauses = &clauses,
        .signatories = &signatories,
        .watermark = "CONFIDENTIAL",
    });

    var pdf = try pagine.renderPdf(&doc, .{
        .title = "Master Services Agreement MSA-2026-1127",
        .author = "Pagine Systems",
        .lang = "en-US",
        .outline = .structure_element_headers,
    });
    defer pdf.deinit();

    try writeOutputFile(init.io, out_path, pdf.bytes());
}
