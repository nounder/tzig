// Vendored from ghostty-org/ghostty
//   upstream: src/lib/types.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421

pub const String = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn init(zig: anytype) String {
        return switch (@TypeOf(zig)) {
            []u8, []const u8 => .{
                .ptr = zig.ptr,
                .len = zig.len,
            },
        };
    }
};
