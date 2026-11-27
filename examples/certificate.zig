//! Landscape Award / Compliance Certificate — Self-contained starter example.
//!
//! Copy this single file into your project and call `certificate.compose(&doc, data)`.
//! Demonstrates:
//! - `.a4_landscape` full-bleed double ornamental border via `page.background()`
//! - Inline vector `svgPath` emblem without external XML DOM parsing
//! - Clickable verification `hyperlink` & multi-authority signatures
//! - Multi-backend export from one `Document`: pass `.pdf`, `.png`, or `.svg` as output path!

const std = @import("std");
const pagine = @import("pagine");

pub const CertificateSigner = struct {
    name: []const u8,
    title: []const u8,
};

pub const CertificateData = struct {
    issuer_name: []const u8,
    title: []const u8 = "CERTIFICATE OF ACHIEVEMENT",
    presentation_line: []const u8 = "THIS CERTIFIES THAT",
    recipient_name: []const u8,
    description: []const u8,
    course_or_program: ?[]const u8 = null,
    issue_date: []const u8,
    certificate_id: []const u8,
    verify_url: ?[]const u8 = null,
    signers: []const CertificateSigner = &.{},
    font_families: ?[]const [:0]const u8 = null,
};

const seal_star_path: [:0]const u8 =
    "M24 2 L29.8 14.2 L43.2 16 L33.4 25.4 L35.8 38.8 L24 32.3 L12.2 38.8 L14.6 25.4 L4.8 16 L18.2 14.2 Z";

/// Composes a single-page landscape A4 award/compliance certificate onto `doc`.
pub fn compose(doc: *pagine.Document, data: CertificateData) void {
    var page = doc.addPage(.{
        .size = .a4_landscape,
        .margin = .{ .all = 0 },
        .background_color = .white,
        .default_text_style = .{
            .font_families = data.font_families,
            .size = 11,
            .color = .slate_800,
        },
    });

    // Full-page double ornamental frame in `page.background()`
    var bg = page.background().padding(.{ .all = 20 }).box(.{
        .padding = .{ .all = 8 },
        .background = pagine.Color.amber_50.withAlpha(0x55),
        .border = .{ .all = 3.0, .color = .slate_900, .radius = 4 },
    });
    _ = bg.box(.{
        .background = .white,
        .border = .{ .all = 1.25, .color = .amber_600, .radius = 2 },
    });

    var col = page.content().padding(.{ .horizontal = 76, .vertical = 54 }).column(.{ .spacing = 12 });

    // Top emblem + issuer
    var top = col.item().column(.{ .spacing = 8 });
    top.item().alignCenter().box(.{
        .padding = .{ .all = 9 },
        .background = .slate_900,
        .border = .{ .all = 1.5, .color = .amber_600, .radius = 24 },
    }).size(28, 28).svgPath(seal_star_path, .{ .color = .amber_600 });

    top.item().alignCenter().text(data.issuer_name, .{
        .size = 11,
        .weight = .bold,
        .color = .slate_500,
        .letter_spacing = 2.0,
    });
    top.item().alignCenter().heading(1).text(data.title, .{
        .size = 28,
        .weight = .bold,
        .color = .slate_900,
        .letter_spacing = 1.5,
    });

    // Ornamental divider
    var div_row = col.item().alignCenter().width(220).row(.{ .spacing = 8 });
    div_row.relative(1).alignMiddle().lineHorizontal(.{ .thickness = 1.0, .color = .amber_600 });
    div_row.constant(10).alignMiddle().size(10, 10).svgPath(seal_star_path, .{ .color = .amber_600 });
    div_row.relative(1).alignMiddle().lineHorizontal(.{ .thickness = 1.0, .color = .amber_600 });

    // Recipient showcase
    var rec = col.item().padding(.{ .top = 6 }).column(.{ .spacing = 8 });
    rec.item().alignCenter().text(data.presentation_line, .{
        .size = 9.5,
        .weight = .semi_bold,
        .color = .slate_500,
        .letter_spacing = 1.8,
    });
    rec.item().alignCenter().text(data.recipient_name, .{
        .size = 32,
        .weight = .bold,
        .color = .slate_900,
    });
    rec.item().alignCenter().width(320).lineHorizontal(.{ .thickness = 0.75, .color = .amber_200 });

    rec.item().padding(.{ .top = 4, .horizontal = 36 }).richText(.{
        .alignment = .center,
        .style = .{ .size = 11.5, .color = .slate_800, .line_height = 1.5 },
    }).span(data.description, .{});

    if (data.course_or_program) |prog| {
        rec.item().alignCenter().padding(.{ .top = 2 }).box(.{
            .padding = .{ .horizontal = 16, .vertical = 6 },
            .background = .amber_50,
            .border = .{ .all = 0.75, .color = .amber_600, .radius = 4 },
        }).text(prog, .{ .size = 12, .weight = .bold, .color = .amber_900 });
    }

    // Signatures row
    if (data.signers.len > 0) {
        var sig_row = col.item().padding(.{ .top = 22, .horizontal = 24 }).row(.{ .spacing = 36 });
        for (data.signers) |signer| {
            var s = sig_row.relative(1).column(.{ .spacing = 3 });
            _ = s.item().height(18);
            s.item().lineHorizontal(.{ .thickness = 0.75, .color = .slate_900 });
            s.item().alignCenter().text(signer.name, .{ .size = 10.5, .weight = .bold, .color = .slate_900 });
            s.item().alignCenter().text(signer.title, .{ .size = 8.5, .color = .slate_500 });
        }
    }

    // Bottom credential metadata strip
    var meta = col.item().padding(.{ .top = 14 }).row(.{ .spacing = 12 });
    meta.relative(1).print("Issued: {s}", .{data.issue_date}, .{ .size = 8.5, .color = .slate_500 });

    if (data.verify_url) |url| {
        var v = meta.auto().alignCenter().richText(.{ .style = .{ .size = 8.5, .color = .slate_500 } });
        v.span("Verify: ", .{});
        v.hyperlink(url, url, .{ .color = .amber_600, .underline = true });
    }

    meta.relative(1).alignRight().print("Credential ID: {s}", .{data.certificate_id}, .{ .size = 8.5, .weight = .semi_bold, .color = .slate_500 });
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
    // Pass `.pdf` (default), `.png` (144 DPI raster), or `.svg` (vector) to export that format!
    const out_path = if (args.len >= 2) args[1] else "zig-out/certificate.pdf";

    const signers = [_]CertificateSigner{
        .{ .name = "Dr. Lin Wei", .title = "Director of Systems Architecture" },
        .{ .name = "Sarah Mitchell", .title = "Head of Certification & Standards" },
    };

    var doc = pagine.Document.init(gpa, .{});
    defer doc.deinit();

    compose(&doc, .{
        .issuer_name = "PAGINE SYSTEMS ACADEMY",
        .title = "CERTIFICATE OF EXCELLENCE",
        .recipient_name = "Alex Mercer",
        .description = "For successfully completing all engineering assessments, high-throughput pagination benchmarks, and PDF/UA accessibility compliance modules in",
        .course_or_program = "High-Performance Native Document Systems (Zig 0.17)",
        .issue_date = "27 November 2026",
        .certificate_id = "CERT-PAG-2026-00412",
        .verify_url = "https://pagine.example/verify/CERT-PAG-2026-00412",
        .signers = &signers,
    });

    if (std.mem.endsWith(u8, out_path, ".png")) {
        var pngs = try pagine.renderImages(&doc, .{ .format = .png, .dpi = 144.0 });
        defer pngs.deinit();
        try writeOutputFile(init.io, out_path, pngs.items[0].bytes());
    } else if (std.mem.endsWith(u8, out_path, ".svg")) {
        var svgs = try pagine.renderSvg(&doc, .{});
        defer svgs.deinit();
        try writeOutputFile(init.io, out_path, svgs.items[0].bytes());
    } else {
        var pdf = try pagine.renderPdf(&doc, .{
            .title = "Certificate of Excellence — Alex Mercer",
            .author = "Pagine Systems Academy",
        });
        defer pdf.deinit();
        try writeOutputFile(init.io, out_path, pdf.bytes());
    }
}
