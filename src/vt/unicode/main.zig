// Vendored from ghostty-org/ghostty
//   upstream: src/unicode/main.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   import paths flattened (../X -> X for sibling subtrees)

pub const lut = @import("lut.zig");

const grapheme = @import("grapheme.zig");
pub const table = @import("props_table.zig").table;
pub const Properties = @import("props.zig").Properties;
pub const graphemeBreak = grapheme.graphemeBreak;

test {
    @import("std").testing.refAllDecls(@This());
}
