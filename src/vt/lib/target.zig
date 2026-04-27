// Vendored from ghostty-org/ghostty
//   upstream: src/lib/target.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421

/// The target for ABI generation. The detection of this is left to the
/// caller since there are multiple ways to do that.
pub const Target = union(enum) {
    c,
    zig,
};
