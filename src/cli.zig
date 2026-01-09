const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// CLI argument parsing errors.
pub const Error = error{
    InvalidArgument,
};

/// Result of parsing CLI arguments.
pub const Action = enum {
    run,
    version,
    help,
};

/// Parse command line arguments and return the action to take.
pub fn parse(args: []const [:0]const u8) Error!Action {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return .version;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        }
        // Unknown argument starting with - is an error
        if (arg.len > 0 and arg[0] == '-') {
            return Error.InvalidArgument;
        }
    }
    return .run;
}

/// Print version information to stdout.
pub fn printVersion(writer: anytype) !void {
    try writer.print(
        \\tzig {s}
        \\
        \\Build Info
        \\  Zig version: {s}
        \\  Build mode:  {s}
        \\  OS:         {s}
        \\  Arch:       {s}
        \\
    , .{
        build_options.version,
        builtin.zig_version_string,
        @tagName(builtin.mode),
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
}

/// Print help information to stdout.
pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: tzig [options]
        \\
        \\A terminal proxy with scrollback capabilities.
        \\
        \\Options:
        \\  -h, --help     Show this help message and exit
        \\  -V, --version  Show version information and exit
        \\
        \\Hotkeys (while running):
        \\  Ctrl+]         Toggle scrollback overlay
        \\  j/k            Scroll down/up in overlay
        \\  q              Exit overlay
        \\
    );
}
