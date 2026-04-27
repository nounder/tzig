// Vendored from ghostty-org/ghostty
//   upstream: src/lib/main.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   removed checkGhosttyHEnum re-export (see lib/enum.zig).

const std = @import("std");
const enumpkg = @import("enum.zig");
const structpkg = @import("struct.zig");
const types = @import("types.zig");
const unionpkg = @import("union.zig");

pub const allocator = @import("allocator.zig");
pub const Enum = enumpkg.Enum;
pub const String = types.String;
pub const Struct = structpkg.Struct;
pub const structSizedFieldFits = structpkg.sizedFieldFits;
pub const Target = @import("target.zig").Target;
pub const TaggedUnion = unionpkg.TaggedUnion;
pub const cutPrefix = @import("string.zig").cutPrefix;

test {
    std.testing.refAllDecls(@This());
}
