// Vendored from ghostty-org/ghostty
//   upstream: src/unicode/props_table.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   import paths flattened (../X -> X for sibling subtrees)

const Properties = @import("props.zig").Properties;
const lut = @import("lut.zig");

/// The lookup tables for Ghostty.
pub const table = table: {
    // This is only available after running a generator as part of the Ghostty
    // build.zig process, but due to Zig's lazy analysis we can still reference
    // it here.
    //
    // An example process is the `main` in `props_uucode.zig`
    const generated = @import("unicode_tables").Tables(Properties);
    const Tables = lut.Tables(Properties);
    break :table Tables{
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
        .stage3 = &generated.stage3,
    };
};
