// Vendored from ghostty-org/ghostty
//   upstream: src/lib/enum.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   removed checkGhosttyHEnum (depends on a generated ghostty.h
//             module only present in C-ABI builds; tzig is Zig-target only).

const std = @import("std");
const Target = @import("target.zig").Target;

/// Create an enum type with the given keys that is C ABI compatible
/// if we're targeting C, otherwise a Zig enum with smallest possible
/// backing type.
///
/// In all cases, the enum keys will be created in the order given.
/// For C ABI, this means that the order MUST NOT be changed in order
/// to preserve ABI compatibility. You can set a key to null to
/// remove it from the Zig enum while keeping the "hole" in the C enum
/// to preserve ABI compatibility.
///
/// C detection is up to the caller, since there are multiple ways
/// to do that. We rely on the `target` parameter to determine whether we
/// should create a C compatible enum or a Zig enum.
///
/// For the Zig enum, the enum value is not guaranteed to be stable, so
/// it shouldn't be relied for things like serialization.
pub fn Enum(
    target: Target,
    keys: []const ?[:0]const u8,
) type {
    // First pass: count non-null fields. We need this up front because
    // the tag type for `.zig` depends on the field count, and `@Enum`
    // requires the field-values slice to have the tag type as its
    // element type.
    var fields_i: usize = 0;
    for (keys) |key_| {
        if (key_ != null) fields_i += 1;
    }

    const TagType = switch (target) {
        .c => c_int,
        .zig => std.math.IntFittingRange(0, fields_i - 1),
    };

    var field_names: [keys.len][]const u8 = undefined;
    var field_values: [keys.len]TagType = undefined;
    var idx: usize = 0;
    var holes: usize = 0;
    for (keys) |key_| {
        const key: [:0]const u8 = key_ orelse {
            switch (target) {
                // For Zig we don't track holes because the enum value
                // isn't guaranteed to be stable and we want to use the
                // smallest possible backing type.
                .zig => {},

                // For C we must track holes to preserve ABI compatibility
                // with subsequent values.
                .c => holes += 1,
            }
            continue;
        };

        field_names[idx] = key;
        field_values[idx] = @intCast(idx + holes);
        idx += 1;
    }

    // Assigned to var so that the type name is nicer in stack traces.
    const Result = @Enum(
        TagType,
        .exhaustive,
        field_names[0..idx],
        field_values[0..idx],
    );
    return Result;
}

test "zig" {
    const testing = std.testing;
    const T = Enum(.zig, &.{ "a", "b", "c", "d" });
    const info = @typeInfo(T).@"enum";
    try testing.expectEqual(u2, info.tag_type);
}

test "c" {
    const testing = std.testing;
    const T = Enum(.c, &.{ "a", "b", "c", "d" });
    const info = @typeInfo(T).@"enum";
    try testing.expectEqual(c_int, info.tag_type);
}

test "abi by removing a key" {
    const testing = std.testing;
    // C
    {
        const T = Enum(.c, &.{ "a", "b", null, "d" });
        const info = @typeInfo(T).@"enum";
        try testing.expectEqual(c_int, info.tag_type);
        try testing.expectEqual(3, @intFromEnum(T.d));
    }

    // Zig
    {
        const T = Enum(.zig, &.{ "a", "b", null, "d" });
        const info = @typeInfo(T).@"enum";
        try testing.expectEqual(u2, info.tag_type);
        try testing.expectEqual(2, @intFromEnum(T.d));
    }
}

// tzig: removed `checkGhosttyHEnum`. Upstream uses it to verify the
// generated ghostty.h C header matches Zig enum layouts. tzig has no C ABI
// build path and no ghostty.h, so the function is unreachable here. If we
// ever revive the C ABI build, port this back from upstream src/lib/enum.zig.
