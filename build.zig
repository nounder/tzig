const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit tests");
    const vt_test_step = b.step("test-vt", "Run tests on vendored src/vt/");

    // tzig version, exposed via --version.
    const options = b.addOptions();
    options.addOption([]const u8, "version", "0.1.0");

    // Hardcoded ghostty-vt build flags. tzig is a Zig-only consumer and
    // doesn't ship the kitty/tmux/oniguruma/simd code paths or the C ABI.
    // Schema mirrors vendor/ghostty/src/terminal/build_options.zig.
    const terminal_options = b.addOptions();
    terminal_options.addOption(bool, "c_abi", false);
    terminal_options.addOption(bool, "oniguruma", false);
    terminal_options.addOption(bool, "simd", false);
    terminal_options.addOption(bool, "slow_runtime_safety", false);
    terminal_options.addOption(bool, "kitty_graphics", false);
    terminal_options.addOption(bool, "tmux_control_mode", false);
    terminal_options.addOption(enum { ghostty, lib }, "artifact", .lib);

    // uucode (Unicode width / property data). Two-pass dance required by
    // uucode's API: the first pass produces a generated `tables.zig`
    // tailored to our build_config; the second pass consumes it.
    const uucode_build_config = b.path("src/build/uucode_config.zig");
    const uucode_tables = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = uucode_build_config,
    }).namedLazyPath("tables.zig");
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .tables_path = uucode_tables,
        .build_config_path = uucode_build_config,
    }).module("uucode");

    // Build-time codegen: run two tiny exes that emit `props.zig` and
    // `symbols.zig` lookup tables, importable as anonymous modules.
    const props_output = unigen(b, "props-unigen", "src/vt/unicode/props_uucode.zig", uucode, "props.zig");
    const symbols_output = unigen(b, "symbols-unigen", "src/vt/unicode/symbols_uucode.zig", uucode, "symbols.zig");

    // Vendored ghostty-vt module. Imported as "ghostty-vt" by src/main.zig.
    const vt_mod = b.createModule(.{
        .root_source_file = b.path("src/vt/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    vt_mod.addOptions("terminal_options", terminal_options);
    vt_mod.addImport("uucode", uucode);
    vt_mod.addAnonymousImport("unicode_tables", .{ .root_source_file = props_output });
    vt_mod.addAnonymousImport("symbols_tables", .{ .root_source_file = symbols_output });

    // tzig exe.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", options);
    exe_mod.addImport("ghostty-vt", vt_mod);

    const exe = b.addExecutable(.{ .name = "tzig", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(exe_unit_tests).step);

    const vt_unit_tests = b.addTest(.{ .root_module = vt_mod });
    vt_test_step.dependOn(&b.addRunArtifact(vt_unit_tests).step);
}

/// Build a small host-target codegen exe, run it, capture stdout into
/// `out_name` so it can be wired in as an anonymous module. Mirrors
/// vendor/ghostty/src/build/UnicodeTables.zig.
fn unigen(
    b: *std.Build,
    name: []const u8,
    src: []const u8,
    uucode: *std.Build.Module,
    out_name: []const u8,
) std.Build.LazyPath {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = b.graph.host,
        }),
    });
    exe.root_module.addImport("uucode", uucode);
    return b.addWriteFiles().addCopyFile(b.addRunArtifact(exe).captureStdOut(.{}), out_name);
}
