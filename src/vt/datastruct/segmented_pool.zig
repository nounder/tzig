// Vendored from ghostty-org/ghostty
//   upstream: src/datastruct/segmented_pool.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   import paths flattened (../X -> X for sibling subtrees);
//            std.SegmentedList removed in Zig 0.16, so the backing
//            store is now an ArrayList of heap-allocated T pointers
//            (each slot allocated individually to preserve the stable-
//            pointer guarantee SegmentedPool was built for).

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A data structure where you can get stable (never copied) pointers to
/// a type that automatically grows if necessary. The values can be "put back"
/// but are expected to be put back IN ORDER.
///
/// This is implemented specifically for libuv write requests, since the
/// write requests must have a stable pointer and are guaranteed to be processed
/// in order for a single stream.
///
/// This is NOT thread safe.
pub fn SegmentedPool(comptime T: type, comptime prealloc: usize) type {
    return struct {
        const Self = @This();

        i: usize = 0,
        available: usize = prealloc,
        // The first `prealloc` slots live inline (preserving the
        // SegmentedList behavior of never needing an allocator until
        // we grow past `prealloc`). Subsequent slots live in `extra`,
        // each heap-allocated individually so the pointers remain
        // stable across grows.
        inline_buf: [prealloc]T = undefined,
        extra: std.ArrayList(*T) = .empty,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.extra.items) |slot| alloc.destroy(slot);
            self.extra.deinit(alloc);
            self.* = undefined;
        }

        fn totalLen(self: *const Self) usize {
            return prealloc + self.extra.items.len;
        }

        fn slotAt(self: *Self, i: usize) *T {
            if (i < prealloc) return &self.inline_buf[i];
            return self.extra.items[i - prealloc];
        }

        /// Get the next available value out of the list. This will not
        /// grow the list.
        pub fn get(self: *Self) !*T {
            // Error to not have any
            if (self.available == 0) return error.OutOfValues;

            // The index we grab is just i % len, so we wrap around to the front.
            const len = self.totalLen();
            const i = @mod(self.i, len);
            self.i +%= 1; // Wrapping addition so we go back to 0
            self.available -= 1;
            return self.slotAt(i);
        }

        /// Get the next available value out of the list and grow the list
        /// if necessary.
        pub fn getGrow(self: *Self, alloc: Allocator) !*T {
            if (self.available == 0) try self.grow(alloc);
            return try self.get();
        }

        fn grow(self: *Self, alloc: Allocator) !void {
            const old_len = self.totalLen();
            const new_len = old_len * 2;
            const need = new_len - old_len;
            try self.extra.ensureUnusedCapacity(alloc, need);
            var added: usize = 0;
            errdefer {
                while (added > 0) {
                    added -= 1;
                    const slot = self.extra.pop().?;
                    alloc.destroy(slot);
                }
            }
            while (added < need) : (added += 1) {
                const slot = try alloc.create(T);
                self.extra.appendAssumeCapacity(slot);
            }
            self.i = old_len;
            self.available = old_len;
        }

        /// Put a value back. The value put back is expected to be the
        /// in order of get.
        pub fn put(self: *Self) void {
            self.available += 1;
            assert(self.available <= self.totalLen());
        }
    };
}

test "SegmentedPool" {
    var list: SegmentedPool(u8, 2) = .{};
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), list.available);

    // Get to capacity
    const v1 = try list.get();
    const v2 = try list.get();
    try testing.expect(v1 != v2);
    try testing.expectError(error.OutOfValues, list.get());

    // Test writing for later
    v1.* = 42;

    // Put a value back
    list.put();
    const temp = try list.get();
    try testing.expect(v1 == temp);
    try testing.expect(temp.* == 42);
    try testing.expectError(error.OutOfValues, list.get());

    // Grow
    const v3 = try list.getGrow(testing.allocator);
    try testing.expect(v1 != v3 and v2 != v3);
    _ = try list.get();
    try testing.expectError(error.OutOfValues, list.get());

    // Put a value back
    list.put();
    try testing.expect(v1 == try list.get());
    try testing.expectError(error.OutOfValues, list.get());
}
