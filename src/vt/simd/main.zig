// Vendored from ghostty-org/ghostty
//   upstream: src/simd/main.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   import paths flattened (../../ -> ../, etc.)

//! SIMD-optimized routines. If `build_options.simd` is false, then the API
//! still works but we fall back to pure Zig scalar implementations.

const std = @import("std");

const codepoint_width = @import("codepoint_width.zig");
pub const base64 = @import("base64.zig");
pub const index_of = @import("index_of.zig");
pub const vt = @import("vt.zig");
pub const codepointWidth = codepoint_width.codepointWidth;

test {
    @import("std").testing.refAllDecls(@This());
}
