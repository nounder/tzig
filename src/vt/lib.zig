// Vendored from ghostty-org/ghostty
//   upstream: src/terminal/lib.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   import paths remapped: ../lib/main.zig -> lib/main.zig.
//             checkGhosttyHEnum re-export removed (see lib/enum.zig).

const std = @import("std");
const build_options = @import("terminal_options");
const lib = @import("lib/main.zig");

/// The target for the terminal lib in particular.
pub const target: lib.Target = if (build_options.c_abi) .c else .zig;

/// The calling convention to use for C APIs.
///
/// This is always .c for now. I want to make this "Zig" when we're not
/// building the C ABI but there are bigger issues we need to resolve to
/// make that possible (change it and see for yourself).
pub const calling_conv: std.builtin.CallingConvention = .c;

/// Forwarded decls from lib that are used.
pub const alloc = lib.allocator;
pub const Enum = lib.Enum;
pub const TaggedUnion = lib.TaggedUnion;
pub const Struct = lib.Struct;
pub const String = lib.String;
pub const structSizedFieldFits = lib.structSizedFieldFits;
// tzig: checkGhosttyHEnum was a C-ABI test helper; pruned. See lib/enum.zig.
