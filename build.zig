const std = @import("std");

fn defaultSkiaLibDir(b: *std.Build, target: std.Build.ResolvedTarget, profile: []const u8) []const u8 {
    const arch_str = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => @tagName(target.result.cpu.arch),
    };
    const os_str = switch (target.result.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => @tagName(target.result.os.tag),
    };
    return b.fmt("../../skia-zig/skia-zig/.skia/out/{s}-{s}-{s}", .{ arch_str, os_str, profile });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const skia_profile = b.option(
        []const u8,
        "skia-profile",
        "Skia native build profile: release (default) or debug",
    ) orelse "release";

    const skia_lib_dir = b.option(
        []const u8,
        "skia-lib-dir",
        "Directory containing built Skia archives and manifest.json",
    ) orelse defaultSkiaLibDir(b, target, skia_profile);

    const skia_dep = b.dependency("skia_zig", .{
        .target = target,
        .optimize = optimize,
        .@"skia-profile" = skia_profile,
        .@"skia-lib-dir" = skia_lib_dir,
    });
    const skia_mod = skia_dep.module("skia");

    // Primary exportable module for downstream consumers.
    const pagine_mod = b.addModule("pagine", .{
        .root_source_file = b.path("src/pagine.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "skia", .module = skia_mod },
        },
    });

    // Shared pure-Zig test helpers (SafeAllocator wrapper, RecordingSink, MockTextEngine, PDF helpers).
    const test_support_mod = b.createModule(.{
        .root_source_file = b.path("tests/support.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build-injected test font asset (avoids hardcoded cross-repo relative paths & cwd assumptions).
    const test_roboto_path = skia_dep.path("assets/fonts/Roboto-Regular.ttf");
    const test_options = b.addOptions();
    test_options.addOptionPath("roboto_font_path", test_roboto_path);

    // Pure-Zig core tests (geometry, style, layout algorithms without Skia link).
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_tests = b.addTest(.{
        .name = "pagine-core-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "support", .module = test_support_mod },
            },
        }),
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    b.step("test-core", "Run pure-Zig layout core unit tests (no Skia link)").dependOn(&run_core_tests.step);

    // Full integration tests (linking skia-zig).
    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pagine", .module = pagine_mod },
            .{ .name = "skia", .module = skia_mod },
            .{ .name = "support", .module = test_support_mod },
        },
    });
    integration_test_mod.addAnonymousImport("roboto_ttf", .{ .root_source_file = test_roboto_path });
    integration_test_mod.addOptions("test_options", test_options);
    const integration_tests = b.addTest(.{
        .name = "pagine-tests",
        .root_module = integration_test_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Curated self-contained starter examples (each depends ONLY on `pagine`, matching downstream user projects)
    const examples = [_]struct { name: []const u8, mod_name: []const u8, src: []const u8, desc: []const u8 }{
        .{ .name = "invoice", .mod_name = "ex_invoice", .src = "examples/invoice.zig", .desc = "Generate multi-page commercial invoice PDF" },
        .{ .name = "report", .mod_name = "ex_report", .src = "examples/report.zig", .desc = "Generate executive report PDF with cover, image, TOC, charts & PDF/UA" },
        .{ .name = "statement", .mod_name = "ex_statement", .src = "examples/statement.zig", .desc = "Generate multi-page account statement PDF with dynamic per-page subtotals" },
        .{ .name = "contract", .mod_name = "ex_contract", .src = "examples/contract.zig", .desc = "Generate formal contract PDF with running headers, watermark & signatures" },
        .{ .name = "receipt", .mod_name = "ex_receipt", .src = "examples/receipt.zig", .desc = "Generate 80mm continuous-roll thermal POS receipt PDF with Code 39 barcode" },
        .{ .name = "packing-slip", .mod_name = "ex_packing_slip", .src = "examples/packing_slip.zig", .desc = "Generate batch warehouse packing slips PDF (row_span + mergePdf)" },
        .{ .name = "certificate", .mod_name = "ex_certificate", .src = "examples/certificate.zig", .desc = "Generate landscape A4 certificate (supports .pdf, .png, .svg output)" },
    };

    const example_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/examples_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pagine", .module = pagine_mod },
            .{ .name = "support", .module = test_support_mod },
        },
    });
    example_test_mod.addAnonymousImport("roboto_ttf", .{ .root_source_file = test_roboto_path });

    const examples_step = b.step("examples", "Build all curated examples");
    for (examples) |ex| {
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(ex.src),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pagine", .module = pagine_mod },
            },
        });
        example_test_mod.addImport(ex.mod_name, ex_mod);

        const exe = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{ex.name}),
            .root_module = ex_mod,
        });
        examples_step.dependOn(&exe.step);

        const run_exe = b.addRunArtifact(exe);
        run_exe.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{ex.name}), ex.desc).dependOn(&run_exe.step);
    }

    // End-to-end verification of all 7 curated examples (PDF, PNG, SVG, mergePdf & zero leaks).
    const example_tests = b.addTest(.{
        .name = "pagine-example-tests",
        .root_module = example_test_mod,
    });
    const run_example_tests = b.addRunArtifact(example_tests);

    const test_step = b.step("test", "Run all pagine unit and integration tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_example_tests.step);

    // ReleaseFast throughput benchmark
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tests/benchmark.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "pagine", .module = pagine_mod },
            .{ .name = "skia", .module = skia_mod },
            .{ .name = "support", .module = test_support_mod },
        },
    });
    bench_mod.addAnonymousImport("roboto_ttf", .{ .root_source_file = test_roboto_path });
    const bench_exe = b.addExecutable(.{
        .name = "pagine-bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    b.step("bench", "Run ReleaseFast multi-page PDF throughput benchmark").dependOn(&run_bench.step);

    const fmt_step = b.addFmt(.{
        .paths = b.pathList(&.{ "build.zig", "src", "tests", "examples" }),
        .check = true,
    });
    b.step("fmt-check", "Check Zig code formatting").dependOn(&fmt_step.step);
}
